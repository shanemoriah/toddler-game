// toddler-game v11 family sync worker.
// Routes:
//   POST /v1/new                 -> { code } — generates a fresh, unused family code.
//   GET  /v1/state/:code         -> the stored blob, or 404 if nothing saved yet.
//   PUT  /v1/state/:code         -> body is the caller's full local blob; stored value becomes
//                                    mergeState(existing, body) (see merge.js) and that MERGED
//                                    result is returned — callers should overwrite their own
//                                    local state with the response, not assume their PUT "won".
// Public data keyed by an unguessable code — no auth beyond knowing the code (see README.md).
import { mergeState } from "./merge.js";

const CODE_RE = /^[a-z0-9]{4}-[a-z0-9]{4}$/;
const MAX_BODY_BYTES = 1024 * 1024; // 1MB size cap
const RATE_LIMIT_PER_MIN = 60;
const CODE_ALPHABET = "abcdefghijklmnopqrstuvwxyz0123456789";

function corsHeaders(){
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET,PUT,POST,OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type",
  };
}
function json(data, status = 200, extraHeaders = {}){
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json", ...corsHeaders(), ...extraHeaders },
  });
}
// Adversarial-review fix: `str.length` counts UTF-16 code units, not bytes — every emoji in
// this app's own data (profile avatars) is 1-2 UTF-16 units but 4 UTF-8 bytes, so a naive
// `.length` check under-counts real payload size. Use the actual encoded byte length instead.
function byteLength(str){ return new TextEncoder().encode(str).length; }
function randomSegment(len){
  let out = "";
  const bytes = new Uint8Array(len);
  crypto.getRandomValues(bytes);
  for (let i = 0; i < len; i++) out += CODE_ALPHABET[bytes[i] % CODE_ALPHABET.length];
  return out;
}
async function generateUnusedCode(kv){
  // Collision odds are astronomically low (36^8 space) but check-and-retry a few times anyway
  // rather than trusting probability alone — cheap insurance, this only costs a KV read.
  for (let attempt = 0; attempt < 5; attempt++){
    const code = `${randomSegment(4)}-${randomSegment(4)}`;
    const existing = await kv.get(`state:${code}`);
    if (existing === null) return code;
  }
  throw new Error("could not allocate an unused code");
}
// Lightweight per-IP rate limit via a KV counter keyed to the current minute — best-effort
// (KV is eventually consistent, so this is a soft cap, not a hard guarantee), which is fine for
// "lightly" rate-limiting a free public endpoint rather than enforcing an exact quota.
async function checkRateLimit(kv, ip){
  if (!ip) return true; // no client IP header available (e.g. local `wrangler dev`) — don't block
  const bucket = Math.floor(Date.now() / 60000);
  const key = `rl:${ip}:${bucket}`;
  const current = parseInt((await kv.get(key)) || "0", 10);
  if (current >= RATE_LIMIT_PER_MIN) return false;
  await kv.put(key, String(current + 1), { expirationTtl: 120 });
  return true;
}

export default {
  async fetch(request, env){
    const url = new URL(request.url);
    if (request.method === "OPTIONS"){
      return new Response(null, { status: 204, headers: corsHeaders() });
    }

    if (!env.SYNC || typeof env.SYNC.get !== "function"){
      return json({ error: "SYNC KV namespace not bound — see sync-worker/README.md" }, 500);
    }

    const ip = request.headers.get("CF-Connecting-IP") || "";
    if (request.method !== "OPTIONS"){
      const ok = await checkRateLimit(env.SYNC, ip);
      if (!ok) return json({ error: "rate limit exceeded, try again in a minute" }, 429);
    }

    if (request.method === "POST" && url.pathname === "/v1/new"){
      try {
        const code = await generateUnusedCode(env.SYNC);
        return json({ code });
      } catch (e){
        return json({ error: "failed to generate a code, try again" }, 500);
      }
    }

    const stateMatch = url.pathname.match(/^\/v1\/state\/([a-z0-9-]+)$/);
    if (stateMatch){
      const code = stateMatch[1];
      if (!CODE_RE.test(code)) return json({ error: "invalid code format (expected xxxx-xxxx)" }, 400);
      const key = `state:${code}`;

      if (request.method === "GET"){
        const raw = await env.SYNC.get(key);
        if (raw === null) return json({ error: "not found" }, 404);
        try { return json(JSON.parse(raw)); }
        catch (e){ return json({ error: "stored state is corrupt" }, 500); }
      }

      if (request.method === "PUT"){
        let bodyText;
        try { bodyText = await request.text(); }
        catch (e){ return json({ error: "could not read request body" }, 400); }
        if (byteLength(bodyText) > MAX_BODY_BYTES){
          return json({ error: `body exceeds ${MAX_BODY_BYTES} byte cap` }, 413);
        }
        let incoming;
        try { incoming = JSON.parse(bodyText); }
        catch (e){ return json({ error: "body is not valid JSON" }, 400); }
        if (!incoming || typeof incoming !== "object"){
          return json({ error: "body must be a JSON object" }, 400);
        }

        const existingRaw = await env.SYNC.get(key);
        let existing = null;
        if (existingRaw !== null){
          try { existing = JSON.parse(existingRaw); } catch (e){ existing = null; }
        }

        const merged = mergeState(existing, incoming);
        const mergedText = JSON.stringify(merged);
        if (byteLength(mergedText) > MAX_BODY_BYTES){
          return json({ error: `merged state exceeds ${MAX_BODY_BYTES} byte cap` }, 413);
        }
        await env.SYNC.put(key, mergedText);
        return json(merged);
      }

      return json({ error: "method not allowed" }, 405);
    }

    return json({ error: "not found" }, 404);
  },
};
