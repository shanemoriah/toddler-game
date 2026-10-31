#!/usr/bin/env bash
# tools/gen_audio_11labs.sh — regenerate bundled TTS audio for the toddler game
# with ElevenLabs instead of macOS `say`. Same contract as tools/gen_audio.sh:
# same strings source (collectAllSayStrings() via tools/dump_say_strings.js),
# same filenames (first 16 hex chars of sha256(exact string) + ".m4a"), same
# audio/manifest.json shape (key = exact spoken string, value = filename),
# same AAC .m4a output (mono, 22.05 kHz, ~48 kbps — matches the Samantha clips).
#
# Usage (from anywhere; it cd's to the repo root):
#   ELEVENLABS_API_KEY="$(gcloud secrets versions access latest \
#     --secret=elevenlabs-api-key --project=settle-claude-bots-prod)" \
#     tools/gen_audio_11labs.sh [strings.json] [options]
#
#   (no strings.json argument -> runs `node tools/dump_say_strings.js` itself)
#
# Options (env equivalents in parens):
#   --filter RE     only (re)synthesize strings matching the JS regex RE,
#                   case-insensitive, tested against the exact spoken string
#                   (TG_FILTER). Clips for strings outside the filter are
#                   NEVER touched or pruned.
#   --force         resynthesize matching strings even if already done
#   --dry-run       print the strings that would be synthesized + total
#                   character count (ElevenLabs bills per character), then
#                   exit — no API call, no key needed, nothing written
#   --list-voices   GET /v1/voices and print name, voice_id, category, labels
#                   (accent/age/gender/use case); --filter narrows the list.
#                   No audio, no files written.
#   --synth-to FILE --text STR
#                   one-shot: synthesize STR to FILE (.m4a) with the current
#                   voice/model/settings and exit. Does not touch audio/,
#                   the manifest or the ledger. Used for voice auditions.
#   -h, --help      show this header
#
# Env knobs:
#   ELEVENLABS_API_KEY   REQUIRED for any API call (never put it in a file/argv)
#   ELEVEN_VOICE_ID      voice id (default: Jessica, a premade voice)
#   ELEVEN_MODEL         eleven_multilingual_v2 (default) | eleven_turbo_v2_5 |
#                        eleven_flash_v2_5 | eleven_v3 — passed through verbatim,
#                        the API decides what it accepts
#   ELEVEN_STABILITY / ELEVEN_SIMILARITY / ELEVEN_STYLE / ELEVEN_SPEED
#                        voice_settings passthroughs (stability, similarity_boost,
#                        style, speed); unset ones are omitted so the voice's
#                        stored defaults apply. NB: eleven_v3 only accepts
#                        stability 0.0 / 0.5 / 1.0.
#   ELEVEN_OUTPUT_FORMAT API output_format (default mp3_44100_128)
#   ELEVEN_SAMPLE_RATE   AAC sample rate (default 22050, same as Samantha clips)
#   ELEVEN_LEDGER        provenance ledger path (default tools/eleven_ledger.json)
#   ELEVEN_MAX_RETRIES   retries on 429/5xx/network error (default 6)
#
# UPGRADE PATH / why there is a ledger: sha(string) filenames collide between
# voices — Samantha's clip and an ElevenLabs clip for the same string are the
# SAME filename. When ElevenLabs regenerates a string it simply OVERWRITES the
# Samantha clip for that string; that is the intended "upgrade" path (do a
# subset first with --filter, e.g. only Letter Sounds & Rhymes, keep the rest
# Samantha). Because an existing file therefore can't tell us who made it, the
# script records provenance in a small ledger (sha -> voice|model|settings,
# tools/eleven_ledger.json, commit it with the audio). A clip is skipped only
# when its file exists AND the ledger says it was made with the SAME
# voice/model/settings; so a Samantha clip is upgraded on the first run, a
# finished run is a no-op on re-run (idempotent, resumable after an
# interruption/quota error), and changing voice/model/settings re-renders.
# --force ignores the ledger.
#
# Prune: like gen_audio.sh, a full run (no --filter) deletes audio/*.m4a that
# no current string (and no preserved Mandarin manifest entry) references. A
# --filter run NEVER prunes, and neither does a run with failures.
#
# Phono-only filter (Letter Sounds & Rhymes strings):
#   PHONO='^(mmm|sss|fff|rrr|lll|buh|tuh|puh)$|^Which letter says |^The letter [A-Z] says |^Which one rhymes with |^[a-z]+ rhymes with |Letter Sounds & Rhymes'
#   tools/gen_audio_11labs.sh --filter "$PHONO" --dry-run
#
# Needs: bash, node (JSON + hashing; byte-identical to `printf '%s' s | shasum -a 256`),
# curl, ffmpeg (/opt/homebrew/bin). Nothing to npm install.

# Never let a caller's `bash -x` / SHELLOPTS=xtrace echo a key-bearing command.
set +x 2>/dev/null
set -euo pipefail
cd "$(dirname "$0")/.."

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

OUT_DIR="audio"
API_BASE="https://api.elevenlabs.io/v1"
DEFAULT_VOICE_ID="cgSgspJ2msm6clMCkdW9" # Jessica (premade) — placeholder until Shane picks
VOICE_ID="${ELEVEN_VOICE_ID:-$DEFAULT_VOICE_ID}"
MODEL="${ELEVEN_MODEL:-eleven_multilingual_v2}"
OUTPUT_FORMAT="${ELEVEN_OUTPUT_FORMAT:-mp3_44100_128}"
SAMPLE_RATE="${ELEVEN_SAMPLE_RATE:-22050}"
BITRATE="48k"
LEDGER="${ELEVEN_LEDGER:-tools/eleven_ledger.json}"
MAX_RETRIES="${ELEVEN_MAX_RETRIES:-6}"
FILTER="${TG_FILTER:-}"
FORCE=0
DRY_RUN=0
LIST_VOICES=0
SYNTH_TO=""
SYNTH_TEXT=""
HAVE_SYNTH_TEXT=0
STRINGS_JSON=""

usage() { sed -n '2,/^# Needs:/p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --filter)       [ $# -ge 2 ] || { echo "--filter needs a regex" >&2; exit 2; }; FILTER="$2"; shift 2 ;;
    --filter=*)     FILTER="${1#--filter=}"; shift ;;
    --force)        FORCE=1; shift ;;
    --dry-run)      DRY_RUN=1; shift ;;
    --list-voices)  LIST_VOICES=1; shift ;;
    --synth-to)     [ $# -ge 2 ] || { echo "--synth-to needs a file" >&2; exit 2; }; SYNTH_TO="$2"; shift 2 ;;
    --text)         [ $# -ge 2 ] || { echo "--text needs a string" >&2; exit 2; }; SYNTH_TEXT="$2"; HAVE_SYNTH_TEXT=1; shift 2 ;;
    -h|--help)      usage; exit 0 ;;
    --)             shift; [ $# -gt 0 ] && STRINGS_JSON="$1" && shift; break ;;
    -*)             echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
    *)              if [ -z "$STRINGS_JSON" ]; then STRINGS_JSON="$1"; else echo "unexpected argument: $1" >&2; exit 2; fi; shift ;;
  esac
done

if [ -n "$SYNTH_TO" ] && [ "$HAVE_SYNTH_TEXT" -ne 1 ]; then echo "--synth-to requires --text" >&2; exit 2; fi
if [ "$HAVE_SYNTH_TEXT" -eq 1 ] && [ -z "$SYNTH_TO" ]; then echo "--text requires --synth-to" >&2; exit 2; fi

# Same work-dir hygiene as gen_audio.sh: ONE mktemp -d, removed on any exit.
WORK_DIR="$(mktemp -d -t tg_gen_audio11)"
cleanup() {
  rm -rf "$WORK_DIR"
  # half-written clip staged next to its destination (see publish_clip)
  rm -f "$OUT_DIR"/.*.part 2>/dev/null || true
}
trap cleanup EXIT

# ---- key handling -----------------------------------------------------------
# The key is only ever read from the environment and handed to curl through
# `-K -` (config on stdin) so it never appears in argv (`ps`) or a trace.
require_key() {
  if [ -z "${ELEVENLABS_API_KEY:-}" ]; then
    echo "ELEVENLABS_API_KEY is not set. Pull it from Secret Manager into the env for this one command:" >&2
    echo "  ELEVENLABS_API_KEY=\"\$(gcloud secrets versions access latest --secret=elevenlabs-api-key --project=settle-claude-bots-prod)\" $0 ..." >&2
    exit 1
  fi
}
redact() { # stdin -> stdout with the key (if it somehow appears) masked
  node -e '
    const k = process.env.ELEVENLABS_API_KEY || "";
    let s = require("fs").readFileSync(0, "utf8");
    if (k) s = s.split(k).join("***");
    process.stdout.write(s);'
}

# curl wrapper: curl_eleven <extra curl args...>  (key via stdin config)
curl_eleven() {
  { set +x; } 2>/dev/null
  printf 'header = "xi-api-key: %s"\n' "$ELEVENLABS_API_KEY" | curl -sS -K - "$@"
}

# ---- list voices ------------------------------------------------------------
if [ "$LIST_VOICES" -eq 1 ]; then
  require_key
  code=$(curl_eleven -o "$WORK_DIR/voices.json" -w '%{http_code}' "$API_BASE/voices" 2>"$WORK_DIR/curl.err") || {
    redact < "$WORK_DIR/curl.err" >&2; echo "list-voices: request failed" >&2; exit 1; }
  if [ "$code" != "200" ]; then
    echo "list-voices: HTTP $code: $(head -c 300 "$WORK_DIR/voices.json" | redact)" >&2; exit 1
  fi
  FILTER_RE="$FILTER" node -e '
    const j = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const re = process.env.FILTER_RE ? new RegExp(process.env.FILTER_RE, "i") : null;
    for (const v of j.voices || []) {
      const labels = Object.entries(v.labels || {}).map(([k, x]) => `${k}=${x}`).join(", ");
      const line = `${v.name}\t${v.voice_id}\t${v.category || ""}\t${labels}\t${v.description || ""}`;
      if (!re || re.test(line)) console.log(line);
    }' "$WORK_DIR/voices.json"
  exit 0
fi

# ---- single synth (shared by one-shot and bulk) -----------------------------
# synth_one <text> <dest.m4a>   returns 0 on success, 1 retryable-exhausted /
# bad request (message printed), 2 fatal auth/quota (caller should stop).
# Nothing is written to <dest> until the whole mp3->aac chain succeeded.
synth_one() {
  local text="$1" dest="$2" attempt=0 code delay retry_after
  printf '%s' "$text" > "$WORK_DIR/text.txt"
  TEXT_FILE="$WORK_DIR/text.txt" MODEL="$MODEL" \
    ST="${ELEVEN_STABILITY:-}" SIM="${ELEVEN_SIMILARITY:-}" STY="${ELEVEN_STYLE:-}" SPD="${ELEVEN_SPEED:-}" \
    node -e '
      const fs = require("fs"), e = process.env;
      const vs = {};
      if (e.ST !== "") vs.stability = Number(e.ST);
      if (e.SIM !== "") vs.similarity_boost = Number(e.SIM);
      if (e.STY !== "") vs.style = Number(e.STY);
      if (e.SPD !== "") vs.speed = Number(e.SPD);
      const body = { text: fs.readFileSync(e.TEXT_FILE, "utf8"), model_id: e.MODEL };
      if (Object.keys(vs).length) body.voice_settings = vs;
      process.stdout.write(JSON.stringify(body));' > "$WORK_DIR/body.json"
  while :; do
    rm -f "$WORK_DIR/resp.bin" "$WORK_DIR/resp.hdr"
    code=$(curl_eleven -X POST -H 'Content-Type: application/json' -H 'Accept: audio/mpeg' \
      --data-binary @"$WORK_DIR/body.json" -D "$WORK_DIR/resp.hdr" -o "$WORK_DIR/resp.bin" -w '%{http_code}' \
      "$API_BASE/text-to-speech/$VOICE_ID?output_format=$OUTPUT_FORMAT" 2>"$WORK_DIR/curl.err") || code="000"
    case "$code" in
      200)
        if [ ! -s "$WORK_DIR/resp.bin" ]; then echo "  empty audio response for: $text" >&2; return 1; fi
        rm -f "$WORK_DIR/clip.m4a"
        if ! ffmpeg -nostdin -y -loglevel error -i "$WORK_DIR/resp.bin" -ac 1 -ar "$SAMPLE_RATE" \
              -c:a aac -b:a "$BITRATE" -movflags +faststart "$WORK_DIR/clip.m4a" 2>"$WORK_DIR/ffmpeg.err"; then
          echo "  ffmpeg failed for: $text" >&2; head -c 300 "$WORK_DIR/ffmpeg.err" >&2; return 1
        fi
        if [ "$(wc -c < "$WORK_DIR/clip.m4a")" -lt 500 ]; then echo "  encoded clip implausibly small for: $text" >&2; return 1; fi
        publish_clip "$WORK_DIR/clip.m4a" "$dest"
        return 0 ;;
      401|403)
        echo "  HTTP $code (auth/quota — stopping): $(head -c 300 "$WORK_DIR/resp.bin" 2>/dev/null | redact)" >&2
        return 2 ;;
      429|500|502|503|504|000)
        attempt=$((attempt + 1))
        if [ "$attempt" -gt "$MAX_RETRIES" ]; then
          echo "  HTTP $code after $MAX_RETRIES retries, giving up on: $text" >&2; return 1
        fi
        delay=$((2 ** attempt)); [ "$delay" -gt 60 ] && delay=60
        retry_after=$(awk 'tolower($1)=="retry-after:" {gsub(/\r/,"",$2); print $2}' "$WORK_DIR/resp.hdr" 2>/dev/null | tail -1)
        case "$retry_after" in ''|*[!0-9]*) ;; *) [ "$retry_after" -le 120 ] && delay="$retry_after" ;; esac
        echo "  HTTP $code, retry $attempt/$MAX_RETRIES in ${delay}s..." >&2
        sleep "$delay" ;;
      *)
        echo "  HTTP $code for: $text: $(head -c 300 "$WORK_DIR/resp.bin" 2>/dev/null | redact)" >&2
        return 1 ;;
    esac
  done
}

# Atomic-ish publish: stage next to the destination (same filesystem), then rename.
publish_clip() {
  local src="$1" dest="$2" dir stage
  dir="$(dirname "$dest")"; mkdir -p "$dir"
  stage="$dir/.$(basename "$dest").part"
  cp "$src" "$stage" && mv -f "$stage" "$dest"
}

# ---- one-shot mode ----------------------------------------------------------
if [ -n "$SYNTH_TO" ]; then
  require_key
  rc=0; synth_one "$SYNTH_TEXT" "$SYNTH_TO" || rc=$?
  [ "$rc" -eq 0 ] && echo "wrote $SYNTH_TO (${#SYNTH_TEXT} chars, voice=$VOICE_ID model=$MODEL)"
  exit "$rc"
fi

# ---- strings ---------------------------------------------------------------
if [ -z "$STRINGS_JSON" ]; then
  STRINGS_JSON="$WORK_DIR/strings.json"
  echo "No strings file given — dumping via node tools/dump_say_strings.js..."
  node tools/dump_say_strings.js > "$STRINGS_JSON"
fi

# Fingerprint of everything that changes the audio (not the output encoding).
FINGERPRINT="${VOICE_ID}|${MODEL}|${ELEVEN_STABILITY:-}|${ELEVEN_SIMILARITY:-}|${ELEVEN_STYLE:-}|${ELEVEN_SPEED:-}"

# ---- plan: which strings need synthesis ------------------------------------
# Emits NUL-delimited sha\0text\0 pairs (same NUL discipline as gen_audio.sh —
# a string with a tab/newline can't be split) to $TODO_FILE; human summary on
# stderr; and a JSON sidecar of ALL current (sha,text) pairs for the manifest step.
cat > "$WORK_DIR/plan.js" <<'EOF'
const fs = require("fs"), crypto = require("crypto");
const [stringsPath, todoPath, allPath, ledgerPath, outDir] = process.argv.slice(2);
const e = process.env;
const strings = JSON.parse(fs.readFileSync(stringsPath, "utf8"));
if (!Array.isArray(strings) || !strings.every(s => typeof s === "string")) { console.error("strings JSON must be an array of strings"); process.exit(1); }
const sha16 = s => crypto.createHash("sha256").update(s, "utf8").digest("hex").slice(0, 16);
let re = null;
if (e.FILTER_RE) { try { re = new RegExp(e.FILTER_RE, "i"); } catch (x) { console.error("bad --filter regex: " + x.message); process.exit(2); } }
let ledger = {};
try { ledger = JSON.parse(fs.readFileSync(ledgerPath, "utf8")); } catch (x) { ledger = {}; }
const force = e.FORCE === "1";
const all = [], todo = [], seen = new Set();
let matched = 0, skipped = 0, chars = 0;
for (const text of strings) {
  if (text === "" || seen.has(text)) continue; // same skip rule as gen_audio.sh (empty); dedupe is harmless
  seen.add(text);
  const sha = sha16(text);
  all.push([sha, text]);
  if (re && !re.test(text)) continue;
  matched++;
  const have = fs.existsSync(`${outDir}/${sha}.m4a`);
  if (!force && have && ledger[sha] === e.FINGERPRINT) { skipped++; continue; }
  todo.push([sha, text]);
  chars += [...text].length;
}
fs.writeFileSync(todoPath, todo.map(([s, t]) => s + "\0" + t + "\0").join(""));
fs.writeFileSync(allPath, JSON.stringify(all));
fs.writeFileSync(todoPath + ".meta", JSON.stringify({ total: all.length, matched, skipped, todo: todo.length, chars }));
if (e.DRY_RUN === "1") for (const [sha, text] of todo) console.log(`${sha}\t${JSON.stringify(text)}`);
EOF

TODO_FILE="$WORK_DIR/todo.bin"
ALL_FILE="$WORK_DIR/all.json"
FILTER_RE="$FILTER" FORCE="$FORCE" DRY_RUN="$DRY_RUN" FINGERPRINT="$FINGERPRINT" \
  node "$WORK_DIR/plan.js" "$STRINGS_JSON" "$TODO_FILE" "$ALL_FILE" "$LEDGER" "$OUT_DIR"
meta() { node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))[process.argv[2]])' "$TODO_FILE.meta" "$1"; }
TOTAL=$(meta total); MATCHED=$(meta matched); SKIPPED=$(meta skipped); TODO_N=$(meta todo); CHARS=$(meta chars)

if [ -n "$FILTER" ] && [ "$MATCHED" -eq 0 ]; then
  echo "Filter matched 0 of $TOTAL strings — nothing to do, manifest untouched." >&2
  exit 1
fi

if [ "$DRY_RUN" -eq 1 ]; then
  echo "---"
  echo "DRY RUN (no API call, nothing written). voice=$VOICE_ID model=$MODEL${FILTER:+ filter=/$FILTER/i}$([ "$FORCE" -eq 1 ] && echo ' force')"
  echo "strings total: $TOTAL | matching filter: $MATCHED | already done (same voice/model/settings): $SKIPPED"
  echo "would synthesize: $TODO_N strings | $CHARS characters (billed per character)"
  exit 0
fi

require_key
mkdir -p "$OUT_DIR"

# ---- synthesize -------------------------------------------------------------
cat > "$WORK_DIR/ledger_set.js" <<'EOF'
const fs = require("fs");
const [ledgerPath, sha, fp] = process.argv.slice(2);
let l = {}; try { l = JSON.parse(fs.readFileSync(ledgerPath, "utf8")); } catch (x) { l = {}; }
l[sha] = fp;
const tmp = ledgerPath + ".tmp";
fs.writeFileSync(tmp, JSON.stringify(l, null, 0) + "\n");
fs.renameSync(tmp, ledgerPath);
EOF

new_count=0
fail_count=0
aborted=0
i=0
echo "Synthesizing $TODO_N of $MATCHED matching strings ($CHARS chars) with voice=$VOICE_ID model=$MODEL..."
exec 3< "$TODO_FILE" # dedicated fd so curl/ffmpeg/node never eat the loop's input
while IFS= read -r -d '' -u 3 sha && IFS= read -r -d '' -u 3 text; do
  i=$((i + 1))
  rc=0; synth_one "$text" "$OUT_DIR/$sha.m4a" || rc=$?
  if [ "$rc" -eq 0 ]; then
    node "$WORK_DIR/ledger_set.js" "$LEDGER" "$sha" "$FINGERPRINT"
    new_count=$((new_count + 1))
    [ $((i % 25)) -eq 0 ] && echo "  ...$i/$TODO_N"
  elif [ "$rc" -eq 2 ]; then
    aborted=1; fail_count=$((fail_count + 1)); break
  else
    fail_count=$((fail_count + 1))
  fi
done
exec 3<&-

# ---- manifest (same merge rule as gen_audio.sh) ----------------------------
# Rebuilt from ALL current strings (not just the filtered subset), foreign
# (CJK/Mandarin) entries preserved untouched. An English string whose clip
# does not exist yet (e.g. a failed/aborted synth on a never-generated string)
# is left out rather than pointing at a missing file.
mkdir -p "$(dirname "$LEDGER")"
node -e '
const fs = require("fs");
const [allPath, manifestPath, outDir] = process.argv.slice(1);
const all = JSON.parse(fs.readFileSync(allPath, "utf8"));
const isForeign = (key) => /[㐀-鿿]/.test(key); // CJK ideograph range — Mandarin strings only
let existing = {};
try { existing = JSON.parse(fs.readFileSync(manifestPath, "utf8")); } catch (e) { existing = {}; }
const manifest = {};
for (const [k, v] of Object.entries(existing)) if (isForeign(k)) manifest[k] = v;
let missing = 0;
for (const [sha, text] of all) {
  if (!fs.existsSync(`${outDir}/${sha}.m4a`)) { missing++; continue; }
  manifest[text] = sha + ".m4a";
}
const tmp = manifestPath + ".tmp";
fs.writeFileSync(tmp, JSON.stringify(manifest));
fs.renameSync(tmp, manifestPath);
console.error(`manifest: ${Object.keys(manifest).length} total entries (${Object.keys(existing).filter(isForeign).length} foreign/Mandarin preserved${missing ? `, ${missing} current string(s) without a clip omitted` : ""})`);
' "$ALL_FILE" "$OUT_DIR/manifest.json" "$OUT_DIR"

echo "Strings processed: $MATCHED matching ($TOTAL total) | new clips synthesized: $new_count | skipped (already done): $SKIPPED | failed: $fail_count"

# ---- prune (full runs only) -------------------------------------------------
if [ -n "$FILTER" ]; then
  echo "Filter active — prune skipped (clips outside the filter are never touched)."
elif [ "$fail_count" -gt 0 ] || [ "$aborted" -eq 1 ]; then
  echo "There were failures — prune skipped."
elif [ "$TOTAL" -eq 0 ]; then
  echo "Zero strings in input — prune skipped."
else
  node -e '
  const fs = require("fs");
  const [allPath, manifestPath, outDir, ledgerPath] = process.argv.slice(1);
  const all = JSON.parse(fs.readFileSync(allPath, "utf8"));
  const isForeign = (key) => /[㐀-鿿]/.test(key);
  const keep = new Set(all.map(([sha]) => sha + ".m4a"));
  const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
  for (const [k, v] of Object.entries(manifest)) if (isForeign(k)) keep.add(v);
  let pruned = 0;
  for (const f of fs.readdirSync(outDir)) {
    if (!f.endsWith(".m4a") || f.startsWith(".")) continue;
    if (!keep.has(f)) { fs.unlinkSync(`${outDir}/${f}`); pruned++; }
  }
  if (pruned) console.log(`Pruned ${pruned} orphaned clip(s).`);
  // drop ledger entries for clips that no longer exist, so a later Samantha clip with the
  // same sha is never mistaken for an ElevenLabs one
  try {
    const l = JSON.parse(fs.readFileSync(ledgerPath, "utf8"));
    let changed = false;
    for (const sha of Object.keys(l)) if (!fs.existsSync(`${outDir}/${sha}.m4a`)) { delete l[sha]; changed = true; }
    if (changed) { fs.writeFileSync(ledgerPath + ".tmp", JSON.stringify(l) + "\n"); fs.renameSync(ledgerPath + ".tmp", ledgerPath); }
  } catch (e) { /* no ledger yet */ }
  ' "$ALL_FILE" "$OUT_DIR/manifest.json" "$OUT_DIR" "$LEDGER"
fi

echo "audio/ total size: $(du -sh "$OUT_DIR" | cut -f1)"
echo "manifest entries: $(node -e 'console.log(Object.keys(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))).length)' "$OUT_DIR/manifest.json")"
[ "$fail_count" -eq 0 ] || exit 1
