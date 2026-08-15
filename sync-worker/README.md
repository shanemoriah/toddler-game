# toddler-game-sync — deploy runbook

Cloudflare Worker + KV backing the game's cross-device family sync (see `../NOTES.md` v11).
Public data keyed by an unguessable family code — no auth beyond the code.

1. `cd sync-worker && wrangler login`
2. `wrangler kv namespace create SYNC` — copy the `id = "..."` it prints.
3. Paste that id into `wrangler.toml`'s `[[kv_namespaces]]` block, replacing
   `REPLACE_ME_WITH_KV_NAMESPACE_ID`.
4. `wrangler deploy`
5. Copy the `https://toddler-game-sync.<your-subdomain>.workers.dev` URL it prints into
   `SYNC_URL` near the top of `../index.html`'s `<script>`, then commit + push (GitHub Pages
   redeploys automatically).

Run `node --test test/` to exercise the merge logic standalone (no deploy needed).
