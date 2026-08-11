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

# assemble manifest.json (exact string -> filename) from the sha\0text\0 pairs
# collected above — one node call handles all JSON string-escaping correctly.
node -e '
const fs = require("fs");
const parts = fs.readFileSync(process.argv[1], "utf8").split("\0");
const manifest = {};
for (let i = 0; i + 1 < parts.length; i += 2){
  const sha = parts[i], text = parts[i + 1];
  if (!sha) continue;
  manifest[text] = sha + ".m4a";
}
fs.writeFileSync(process.argv[2], JSON.stringify(manifest));
' "$PAIRS_FILE" "$OUT_DIR/manifest.json"

echo "Strings processed: $total_count | new clips synthesized: $new_count"

# prune orphaned .m4a files no longer referenced by any current string
pruned=0
shopt -s nullglob
for f in "$OUT_DIR"/*.m4a; do
  base=$(basename "$f")
  found=0
  for k in "${keep_files[@]}"; do
    if [ "$k" = "$base" ]; then found=1; break; fi
  done
  if [ "$found" -eq 0 ]; then
    rm -f "$f"
    pruned=$((pruned + 1))
  fi
done
shopt -u nullglob
[ "$pruned" -gt 0 ] && echo "Pruned $pruned orphaned clip(s)."

echo "audio/ total size: $(du -sh "$OUT_DIR" | cut -f1)"
echo "manifest entries: $(node -e 'console.log(Object.keys(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))).length)' "$OUT_DIR/manifest.json")"
