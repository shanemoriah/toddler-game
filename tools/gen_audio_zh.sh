#!/usr/bin/env bash
# tools/gen_audio_zh.sh — regenerate bundled MANDARIN TTS audio for the toddler game
# (audio/*.m4a + audio/manifest.json) from collectMandarinSayStrings()'s own enumeration in
# index.html, so the Mandarin bundle can never silently drift from what the game actually says.
#
# Sibling to tools/gen_audio.sh (same hash-keyed idempotent-clip / manifest-merge shape), but
# uses Microsoft Edge-TTS (via `uvx edge-tts`, no local install — uvx fetches it into an ephemeral
# venv) with the zh-CN-YunxiaNeural voice instead of macOS `say`/Samantha, which cannot speak
# Mandarin. Writes into the SAME audio/ directory and the SAME manifest.json as gen_audio.sh —
# safe to do because the two scripts' key sets are DISJOINT by construction (hanzi strings vs
# English strings, see collectMandarinSayStrings()'s own comment) and this script MERGES into the
# existing manifest.json rather than regenerating it from scratch.
#
# Regen flow (2 commands), from the repo root:
#   node tools/dump_say_strings_zh.js > /tmp/tg_strings_zh.json
#   tools/gen_audio_zh.sh /tmp/tg_strings_zh.json
#
# (or just run `tools/gen_audio_zh.sh` with no argument — it runs the dump step itself first.)
#
# Requires: `uvx` (for `uvx edge-tts`), `afconvert` (macOS built-in AAC encode), `shasum`, `node`.
# Network: each string is one Edge-TTS call (Microsoft's cloud endpoint) — a small sleep between
# calls is rate-limit-friendly, and a transient failure is retried once before giving up on that
# one string (the OVERALL run still continues and reports a final failure count rather than
# aborting, since ~200 strings means a single flaky call shouldn't cost the whole regen).
#
# Deliberately does NOT prune orphaned .m4a files (unlike gen_audio.sh) — this script only ever
# knows its OWN (Mandarin) string set, and pruning by "not in my set" would delete every English
# clip. Manifest merge is purely additive: existing keys (English or a since-removed Mandarin
# string) are left untouched.
#
# Safe to re-run any time: a clip's filename is the first 16 hex chars of sha256(exact string), so
# an unchanged string always re-resolves to the same filename and is skipped (not re-synthesized).
#
# Bug fix (2026-08-23, req 4): Edge-TTS's default zh-CN-YunxiaNeural pace reads WAY too fast for a
# toddler starting from zero Mandarin exposure (the parent's report: "half speed" needed) —
# --rate="-50%" is now the pipeline DEFAULT (RATE below), not a one-off flag, so every future
# regen stays at the slowed pace with no extra step. Because the output filename is
# sha256(text)-keyed (NOT rate-keyed), an existing fast clip's filename is IDENTICAL to its
# slow replacement's — this script's own "skip if file exists" optimization (see the main loop
# below) would otherwise skip re-synthesizing every already-bundled Mandarin string forever.
# Regenerating at the new rate REQUIRES deleting the existing zh .m4a files first (see the
# one-time force-regen note in NOTES.md v13.1 / the worklog) — this script itself has no
# "--force" flag by design, to keep its normal safe/idempotent re-run behavior for everyday use
# (adding a NEW word later must stay a cheap, skip-existing operation).

set -uo pipefail
cd "$(dirname "$0")/.."

VOICE="zh-CN-YunxiaNeural"
RATE="-50%"            # req 4: half speed — see the comment block above
BITRATE=48000
OUT_DIR="audio"
STRINGS_JSON="${1:-}"
SLEEP_BETWEEN=0.35

WORK_DIR="$(mktemp -d -t tg_gen_audio_zh)"
trap 'rm -rf "$WORK_DIR"' EXIT

if [ -z "$STRINGS_JSON" ]; then
  STRINGS_JSON="$WORK_DIR/strings.json"
  echo "No strings file given — dumping via node tools/dump_say_strings_zh.js..."
  node tools/dump_say_strings_zh.js > "$STRINGS_JSON"
fi

mkdir -p "$OUT_DIR"
PAIRS_FILE="$WORK_DIR/pairs.bin"
: > "$PAIRS_FILE"

new_count=0
total_count=0
fail_count=0

# One Edge-TTS call, with one retry on failure. Returns 0 on success (outfile written), 1 on
# failure (outfile NOT written — caller counts it and moves on, never aborting the whole run).
synth_one() {
  local text="$1" outfile="$2"
  local tmp_mp3="$WORK_DIR/clip.mp3"
  rm -f "$tmp_mp3"
  local attempt
  for attempt in 1 2; do
    # Bug fix (2026-08-23): `--rate "$RATE"` (space-separated) broke argparse — a value starting
    # with `-` (e.g. "-50%") passed as a separate argv token is misread as another flag ("expected
    # one argument"). The `--rate=VALUE` single-token form sidesteps this entirely.
    if uvx edge-tts --voice "$VOICE" --rate="$RATE" --text "$text" --write-media "$tmp_mp3" >/dev/null 2>"$WORK_DIR/edge-tts.err"; then
      if [ -s "$tmp_mp3" ]; then
        if afconvert "$tmp_mp3" -f m4af -d aac -b "$BITRATE" "$OUT_DIR/$outfile" 2>"$WORK_DIR/afconvert.err"; then
          rm -f "$tmp_mp3"
          return 0
        fi
        echo "  afconvert failed for: $text" >&2
        cat "$WORK_DIR/afconvert.err" >&2
      else
        echo "  edge-tts wrote an empty file for: $text (attempt $attempt)" >&2
      fi
    else
      echo "  edge-tts call failed for: $text (attempt $attempt)" >&2
      cat "$WORK_DIR/edge-tts.err" >&2
    fi
    sleep 1 # brief backoff before the retry
  done
  rm -f "$tmp_mp3"
  return 1
}

while IFS= read -r -d '' text; do
  [ -z "$text" ] && continue
  total_count=$((total_count + 1))
  sha=$(printf '%s' "$text" | shasum -a 256 | awk '{print substr($1,1,16)}')
  outfile="${sha}.m4a"
  printf '%s\0%s\0' "$sha" "$text" >> "$PAIRS_FILE"
  if [ -f "$OUT_DIR/$outfile" ]; then
    continue # identical text -> identical sha -> identical audio, already generated
  fi
  if synth_one "$text" "$outfile"; then
    new_count=$((new_count + 1))
  else
    fail_count=$((fail_count + 1))
    echo "FAILED (kept out of the manifest, will retry on next run): $text" >&2
  fi
  sleep "$SLEEP_BETWEEN"
done < <(node -e '
const fs = require("fs");
const strings = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
process.stdout.write(strings.map(s => s + "\0").join(""));
' "$STRINGS_JSON")

# Merge (sha,text) pairs for strings that ACTUALLY have a clip on disk into the EXISTING
# manifest.json — additive only, never touches a key not produced by this run's own string set
# that already exists (English keys, or a Mandarin string dropped from a prior run).
node -e '
const fs = require("fs");
const manifestPath = process.argv[3];
const parts = fs.readFileSync(process.argv[1], "utf8").split("\0");
const outDir = process.argv[2];
let manifest = {};
try { manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8")); } catch(e){ manifest = {}; }
let merged = 0;
for (let i = 0; i + 1 < parts.length; i += 2){
  const sha = parts[i], text = parts[i + 1];
  if (!sha) continue;
  const file = sha + ".m4a";
  if (!fs.existsSync(outDir + "/" + file)) continue; // synth failed for this one — leave it OUT of the manifest so the game falls back gracefully (speakZh) rather than 404ing
  if (manifest[text] !== file){ manifest[text] = file; merged++; }
}
fs.writeFileSync(manifestPath, JSON.stringify(manifest));
console.error(`manifest: ${merged} Mandarin key(s) added/updated, ${Object.keys(manifest).length} total entries`);
' "$PAIRS_FILE" "$OUT_DIR" "$OUT_DIR/manifest.json"

echo "Mandarin strings processed: $total_count | new clips synthesized: $new_count | failed: $fail_count"
[ "$fail_count" -gt 0 ] && echo "NOTE: $fail_count string(s) failed to synthesize (see stderr above) — re-run this script to retry just those (already-successful clips are skipped)."

echo "audio/ total size: $(du -sh "$OUT_DIR" | cut -f1)"
echo "manifest entries: $(node -e 'console.log(Object.keys(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))).length)' "$OUT_DIR/manifest.json")"

exit 0
