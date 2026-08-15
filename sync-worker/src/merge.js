// =====================================================================
// toddler-game v11 family sync — shared merge logic.
//
// THIS FILE'S FUNCTIONS ARE PASTED VERBATIM (textually identical bodies) INTO
// index.html's <script> as well, in the block marked "v11: FAMILY SYNC — shared
// mergeState (see sync-worker/src/merge.js, kept textually identical)". Any
// change here must be mirrored there and vice versa — the whole point is that
// the client and the server compute IDENTICAL merges, so a client-side
// pre-merge (on load) and the server's authoritative merge (on PUT) never
// disagree about what the combined state should be. The only difference between the two copies
// is the `export` keyword on each function signature here, which index.html's copy omits (it's
// a plain inline <script>, not an ES module) — every function body is otherwise identical.
//
// Design: a family sync blob is
//   { v:1, updatedAt: <ISO>, profiles: [ {id,name,bday,ageMonths,createdAt,updatedAt,emoji} ],
//     perProfile: { [profileId]: { sessions:[], checklist:[], completions:{}, arcade:{} } } }
// `sessions` entries are the existing per-session objects (each carries its own `date` ISO
// string, already globally unique-enough per profile — see mergeSessionsArr). `completions` is
// { total, lockedUntil:{domainKey:n} } (rotation lock). `arcade` is the per-mode nested shape
// { mixitup:{...}, everything:{...} } (see normalizeArcadeStats).
//
// Every merge below is a UNION/max-wins rule, chosen so applying it twice (idempotence) or in
// either order (commutativity) produces the same result — see sync-worker/test/merge.test.js.
// A profile's own game data is never dropped by a merge: an id present on only one side passes
// through unchanged; an id present on both sides gets the field-by-field union/max rules below.
// =====================================================================

export function mergeSessionsArr(a, b){
  // Union by `date` (a session's own unique-enough key, matching index.html's existing
  // importData() dedup logic) — a session present on EITHER side is never lost. Ties (same
  // date on both sides — e.g. the SAME session round-tripped through two devices) resolve to
  // whichever object literal wins the Map overwrite below; since a session's own content is
  // fixed once written (endGame() never rewrites a past date), any tie is content-identical in
  // practice, so which one "wins" is immaterial.
  const byDate = new Map();
  for (const s of (a || [])) if (s && s.date) byDate.set(s.date, s);
  for (const s of (b || [])) if (s && s.date) byDate.set(s.date, s);
  return [...byDate.values()].sort((x,y) => new Date(x.date) - new Date(y.date));
}
export function mergeChecklistArr(a, b){
  return [...new Set([...(a || []), ...(b || [])])];
}
export function mergeCompletions(a, b){
  // Rotation lock: total is a monotonic counter (take the max, not a union — it's a count, not
  // a list); lockedUntil is merged per-domain-key, also taking the max of each key present on
  // either side (never drop a key present on only one side — that would silently unlock a
  // domain the OTHER side still correctly remembers as locked).
  a = a || {}; b = b || {};
  const total = Math.max(a.total || 0, b.total || 0);
  const au = a.lockedUntil || {}, bu = b.lockedUntil || {};
  const lockedUntil = {};
  for (const k of new Set([...Object.keys(au), ...Object.keys(bu)])) lockedUntil[k] = Math.max(au[k] || 0, bu[k] || 0);
  return { total, lockedUntil };
}
// Normalizes tg_arcade-shaped data to the per-mode nested shape { mixitup:{...}, everything:{...} },
// migrating the old v10 flat shape (a single undifferentiated {totalPlays,bestStreak,introShown})
// into `.mixitup` on read, with `.everything` starting fresh. Self-healing: the first write after
// this reads it rewrites storage in the new nested shape permanently.
export function normalizeArcadeStats(raw){
  raw = raw || {};
  const norm = (m) => ({ totalPlays: (m && m.totalPlays) || 0, bestStreak: (m && m.bestStreak) || 0, introShown: !!(m && m.introShown) });
  if (raw.mixitup || raw.everything) return { mixitup: norm(raw.mixitup), everything: norm(raw.everything) };
  return { mixitup: norm(raw), everything: norm(null) };
}
export function mergeArcade(a, b){
  // Same "monotonic counters, take the max" reasoning as mergeCompletions — totalPlays only
  // ever grows, bestStreak only ever grows within one device's history, and introShown is a
  // one-way flag (once true on EITHER side, stays true) — applied PER MODE. Both sides are
  // normalized first so this is correct regardless of which shape (old flat / new nested)
  // either side is currently in.
  const na = normalizeArcadeStats(a), nb = normalizeArcadeStats(b);
  const mergeMode = (x, y) => ({
    totalPlays: Math.max(x.totalPlays || 0, y.totalPlays || 0),
    bestStreak: Math.max(x.bestStreak || 0, y.bestStreak || 0),
    introShown: !!(x.introShown || y.introShown),
  });
  return { mixitup: mergeMode(na.mixitup, nb.mixitup), everything: mergeMode(na.everything, nb.everything) };
}
// v11: one profile's full per-child bundle — reuses every merge* above unchanged, just applied
// once per profile id instead of once globally (this is the whole reason those functions were
// already factored out as pure (a,b)->merged helpers rather than reading/writing storage
// directly). Missing sub-fields on either side default to the same empty value loadSessions()/
// loadCompletions()/normalizeArcadeStats() already treat as "nothing yet".
export function mergeProfileBundle(a, b){
  a = a || {}; b = b || {};
  return {
    sessions: mergeSessionsArr(a.sessions, b.sessions),
    checklist: mergeChecklistArr(a.checklist, b.checklist),
    completions: mergeCompletions(a.completions, b.completions),
    arcade: mergeArcade(a.arcade, b.arcade),
  };
}
// v11: profiles union by id. An id present on both sides keeps whichever copy has the GREATER
// own `updatedAt` (last-writer-wins on name/bday/ageMonths/emoji edits) — falls back to `a` (the
// local/first-argument side) on a tie or if either side's updatedAt is missing/unparseable, so
// this never throws and never silently drops a profile.
export function mergeProfiles(a, b){
  const byId = new Map();
  for (const p of (a || [])) if (p && p.id) byId.set(p.id, p);
  for (const p of (b || [])){
    if (!p || !p.id) continue;
    const existing = byId.get(p.id);
    if (!existing){ byId.set(p.id, p); continue; }
    const tExisting = Date.parse(existing.updatedAt || "") || 0;
    const tIncoming = Date.parse(p.updatedAt || "") || 0;
    if (tIncoming > tExisting) byId.set(p.id, p);
  }
  return [...byId.values()].sort((x,y) => (Date.parse(x.createdAt||"")||0) - (Date.parse(y.createdAt||"")||0));
}
// v11: perProfile union of profile-id keys — an id present on only one side passes through
// unchanged (normalized, in case it's an old flat-shape arcade blob); an id present on both
// sides gets mergeProfileBundle's field-by-field union.
export function mergePerProfile(a, b){
  a = a || {}; b = b || {};
  const out = {};
  for (const id of new Set([...Object.keys(a), ...Object.keys(b)])){
    out[id] = mergeProfileBundle(a[id], b[id]);
  }
  return out;
}
// v11: top-level family blob merge — the ONE function both the client (pre-merge on load) and
// the server (authoritative merge on PUT) call. `local`/`remote` may each be null/undefined
// (e.g. a brand-new family code with no server data yet, or a device with no local state at
// all) — every field below defaults to empty rather than throwing, and a genuinely empty side
// contributes nothing (never wipes data the other side has, see merge.test.js "empty blob does
// not wipe" case).
export function mergeState(local, remote){
  local = local || {}; remote = remote || {};
  return {
    v: 1,
    updatedAt: new Date().toISOString(),
    profiles: mergeProfiles(local.profiles, remote.profiles),
    perProfile: mergePerProfile(local.perProfile, remote.perProfile),
  };
}

