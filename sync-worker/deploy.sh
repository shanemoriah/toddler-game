#!/usr/bin/env bash
# One-shot deploy for the toddler-game sync worker.
# Run from anywhere:  ~/dev/personal/toddler-game/sync-worker/deploy.sh
# The ONLY interactive step is the Cloudflare browser login on first run.
set -euo pipefail
cd "$(dirname "$0")"
W=./node_modules/.bin/wrangler
[ -x "$W" ] || npm i --silent wrangler@4

# 1) login (opens a browser tab once; no-op if already logged in).
#    `whoami` exits 0 even when unauthenticated, so check its OUTPUT.
if ! $W whoami 2>&1 | grep -q "You are logged in"; then
  echo "→ Opening Cloudflare login in your browser (free account is fine)…"
  $W login < /dev/tty
  $W whoami 2>&1 | grep -q "You are logged in" || { echo "!! login did not complete"; exit 1; }
fi

# 2) KV namespace (create once, then reuse)
if grep -q REPLACE_ME_WITH_KV_NAMESPACE_ID wrangler.toml; then
  echo "→ Creating KV namespace…"
  OUT=$($W kv namespace create SYNC 2>&1 | tee /dev/stderr)
  ID=$(echo "$OUT" | grep -Eo 'id = "[a-f0-9]+"' | head -1 | grep -Eo '[a-f0-9]{16,}')
  [ -n "$ID" ] || { echo "!! could not parse namespace id from wrangler output above"; exit 1; }
  sed -i '' "s/REPLACE_ME_WITH_KV_NAMESPACE_ID/$ID/" wrangler.toml
  echo "→ wrangler.toml updated with namespace id $ID"
fi

# 3) deploy
echo "→ Deploying…"
OUT=$($W deploy 2>&1 | tee /dev/stderr)
URL=$(echo "$OUT" | grep -Eo 'https://[a-z0-9.-]+\.workers\.dev' | head -1)
[ -n "$URL" ] || { echo "!! deploy finished but no workers.dev URL found in output above"; exit 1; }

# 4) wire the URL into the game
sed -i '' -E "s|const SYNC_URL = \"[^\"]*\"|const SYNC_URL = \"$URL\"|" ../index.html
echo
echo "✓ Deployed: $URL"
echo "✓ index.html SYNC_URL set. Committing + pushing…"
cd .. && git add index.html sync-worker/wrangler.toml && git commit -q -m "v11: wire deployed sync worker URL

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>" && git push -q && echo "✓ Pushed. GitHub Pages will pick it up in ~1 min."
