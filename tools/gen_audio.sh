#!/usr/bin/env bash
# tools/gen_audio.sh — regenerate bundled TTS audio for the toddler game
# (audio/*.m4a + audio/manifest.json) from collectAllSayStrings()'s own
# enumeration in index.html, so the bundle can never silently drift from
# what the game actually says.
#
# Regen flow (2 commands), from the repo root:
#   node tools/dump_say_strings.js > /tmp/tg_strings.json
#   tools/gen_audio.sh /tmp/tg_strings.json
#
# (or just run `tools/gen_audio.sh` with no argument — it runs the dump
# step itself first.)
#
# Uses only macOS built-ins: `say` (TTS synth), `afconvert` (AAC encode),
# `shasum`. `node` is used only to parse/emit JSON (already required for the
# dump step above) — no packages are installed, nothing new to `npm install`.
#
# Safe to re-run any time: a clip's filename is the first 16 hex chars of
# sha256(exact string), so an unchanged string always re-resolves to the
# same filename and is skipped (not re-synthesized); a changed/new string
# gets a new filename; and any audio/*.m4a no longer referenced by the
# CURRENT collectAllSayStrings() output is pruned at the end (e.g. after
# copy changed or a domain/def was removed).

set -euo pipefail
cd "$(dirname "$0")/.."

VOICE="Samantha"
RATE=175
BITRATE=48000
OUT_DIR="audio"
STRINGS_JSON="${1:-}"

# v9 adversarial-review fix: everything scratch-file-shaped lives under ONE
# `mktemp -d` work dir, removed via trap on any exit — the original version
# built per-file temp paths as `"$(mktemp -t X).ext"`, which creates a real
# (empty) file at the mktemp-returned path and then only ever touches a
# DIFFERENT, extension-suffixed path, orphaning one empty temp file per
# synthesized clip (761 of them were found still sitting in $TMPDIR from an
# earlier real run of this script before this fix).
WORK_DIR="$(mktemp -d -t tg_gen_audio)"
trap 'rm -rf "$WORK_DIR"' EXIT

if [ -z "$STRINGS_JSON" ]; then
  STRINGS_JSON="$WORK_DIR/strings.json"
  echo "No strings file given — dumping via node tools/dump_say_strings.js..."
  node tools/dump_say_strings.js > "$STRINGS_JSON"
fi

mkdir -p "$OUT_DIR"
# v9 adversarial-review fix: NUL-delimited sha/text pairs, not TAB/newline-
# delimited — a `.say` string containing a literal tab or newline would
# previously split across TSV lines and get silently truncated when the
# manifest was assembled (no current string does, but nothing enforced that
# for a future one; NUL can never legally appear in this content either way,
# so this is robust regardless of what future copy looks like).
PAIRS_FILE="$WORK_DIR/pairs.bin"
: > "$PAIRS_FILE"

new_count=0
total_count=0
keep_files=()

while IFS= read -r -d '' text; do
  [ -z "$text" ] && continue
  total_count=$((total_count + 1))
  sha=$(printf '%s' "$text" | shasum -a 256 | awk '{print substr($1,1,16)}')
  outfile="${sha}.m4a"
  keep_files+=("$outfile")
  printf '%s\0%s\0' "$sha" "$text" >> "$PAIRS_FILE"
  if [ -f "$OUT_DIR/$outfile" ]; then
    continue # identical text -> identical sha -> identical audio, already generated
  fi
  tmp_aiff="$WORK_DIR/clip.aiff"
  say -v "$VOICE" -r "$RATE" -o "$tmp_aiff" -- "$text"
  afconvert "$tmp_aiff" -f m4af -d aac -b "$BITRATE" "$OUT_DIR/$outfile"
  rm -f "$tmp_aiff"
  new_count=$((new_count + 1))
done < <(node -e '
const fs = require("fs");
const strings = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
process.stdout.write(strings.map(s => s + "\0").join(""));
' "$STRINGS_JSON")

# Bug fix (2026-08-23): this used to WRITE manifest.json from scratch (English-only content)
# and prune every .m4a not in ITS OWN keep_files — fine back when this was the only audio
# pipeline, but v13 added tools/gen_audio_zh.sh (Mandarin, MERGES into this same manifest.json /
# audio/ dir — see its own header comment). Running this script after gen_audio_zh.sh silently
# WIPED every Mandarin manifest entry AND deleted all 181 Mandarin .m4a files, since neither was
# in this script's own (English) string set — caught live during the v13.1 second-tier-colors
# regen (had to re-run gen_audio_zh.sh a second time to recover). Fixed by MERGING into the
# existing manifest rather than overwriting it, and by identifying "foreign" (Mandarin) entries
# via a CJK-character heuristic on the manifest KEY (English `say`/`explain` strings never
# contain CJK ideographs; every Mandarin string does) — foreign entries, and the audio files they
# reference, are now preserved through both the merge and the prune step, regardless of whether
# this run's own (English-only) string set mentions them.
node -e '
const fs = require("fs");
const parts = fs.readFileSync(process.argv[1], "utf8").split("\0");
const isForeign = (key) => /[㐀-鿿]/.test(key); // CJK ideograph range — Mandarin strings only
let existing = {};
try { existing = JSON.parse(fs.readFileSync(process.argv[2], "utf8")); } catch(e){ existing = {}; }
const manifest = {};
// keep every foreign (Mandarin) entry untouched
for (const [k, v] of Object.entries(existing)) if (isForeign(k)) manifest[k] = v;
// this run'"'"'s own (English) entries — full replace of the English subset, same as before
for (let i = 0; i + 1 < parts.length; i += 2){
  const sha = parts[i], text = parts[i + 1];
  if (!sha) continue;
  manifest[text] = sha + ".m4a";
}
fs.writeFileSync(process.argv[2], JSON.stringify(manifest));
console.error(`manifest: ${Object.keys(manifest).length} total entries (${Object.keys(existing).filter(isForeign).length} foreign/Mandarin preserved)`);
' "$PAIRS_FILE" "$OUT_DIR/manifest.json"

echo "Strings processed: $total_count | new clips synthesized: $new_count"

# prune orphaned .m4a files no longer referenced by any current string OR by a preserved
# foreign (Mandarin) manifest entry (see the merge step's comment above for why this matters).
preserved_files=$(node -e '
const fs = require("fs");
const manifest = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const isForeign = (key) => /[㐀-鿿]/.test(key);
for (const [k, v] of Object.entries(manifest)) if (isForeign(k)) console.log(v);
' "$OUT_DIR/manifest.json")
pruned=0
shopt -s nullglob
for f in "$OUT_DIR"/*.m4a; do
  base=$(basename "$f")
  found=0
  for k in "${keep_files[@]}"; do
    if [ "$k" = "$base" ]; then found=1; break; fi
  done
  if [ "$found" -eq 0 ] && grep -qxF "$base" <<< "$preserved_files"; then found=1; fi
  if [ "$found" -eq 0 ]; then
    rm -f "$f"
    pruned=$((pruned + 1))
  fi
done
shopt -u nullglob
[ "$pruned" -gt 0 ] && echo "Pruned $pruned orphaned clip(s)."

echo "audio/ total size: $(du -sh "$OUT_DIR" | cut -f1)"
echo "manifest entries: $(node -e 'console.log(Object.keys(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))).length)' "$OUT_DIR/manifest.json")"
