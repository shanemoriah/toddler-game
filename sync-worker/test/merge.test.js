import test from "node:test";
import assert from "node:assert/strict";
import {
  mergeSessionsArr, mergeChecklistArr, mergeCompletions, mergeArcade, mergeStickers,
  mergeProfiles, mergePerProfile, mergeState,
} from "../src/merge.js";
import worker from "../src/index.js";

// ---------- fixtures ----------
const session = (date, theta = 40) => ({
  v: 1, date, ageMonths: 30, name: "Kid", vocabChecked: 10, vocabEstimate: 200,
  domains: { colors: { theta, sd: 3, n: 6, items: [] } },
});
const profile = (id, name, updatedAt, createdAt = updatedAt) => ({
  id, name, bday: "", ageMonths: 30, createdAt, updatedAt, emoji: "🦁",
});
const bundle = (sessions = [], checklist = [], completions = { total: 0, lockedUntil: {} }, arcade = {}) => ({
  sessions, checklist, completions, arcade,
});

// ---------- mergeSessionsArr: union by date, no dupes across devices with different clocks ----------
test("mergeSessionsArr unions distinct dates from two devices", () => {
  const deviceA = [session("2026-08-01T10:00:00.000Z"), session("2026-08-03T10:00:00.000Z")];
  const deviceB = [session("2026-08-02T09:00:00.000Z")];
  const merged = mergeSessionsArr(deviceA, deviceB);
  assert.equal(merged.length, 3);
  assert.deepEqual(merged.map(s => s.date), [
    "2026-08-01T10:00:00.000Z", "2026-08-02T09:00:00.000Z", "2026-08-03T10:00:00.000Z",
  ]);
});
test("mergeSessionsArr does not duplicate the SAME date even with different clock skew ordering", () => {
  // Two devices independently produced a session dated identically (edge case: clock sync or a
  // replayed sync) — the key is the date string, so this must collapse to ONE entry, not two.
  const shared = "2026-08-05T12:00:00.000Z";
  const deviceA = [session(shared, 40)];
  const deviceB = [session(shared, 40)]; // content-identical in practice per merge.js's own comment
  const merged = mergeSessionsArr(deviceA, deviceB);
  assert.equal(merged.length, 1);
});
test("mergeSessionsArr is commutative", () => {
  const a = [session("2026-08-01T00:00:00.000Z"), session("2026-08-04T00:00:00.000Z")];
  const b = [session("2026-08-02T00:00:00.000Z"), session("2026-08-03T00:00:00.000Z")];
  assert.deepEqual(mergeSessionsArr(a, b), mergeSessionsArr(b, a));
});
test("mergeSessionsArr is idempotent (merging a result with itself changes nothing)", () => {
  const a = [session("2026-08-01T00:00:00.000Z")];
  const b = [session("2026-08-02T00:00:00.000Z")];
  const once = mergeSessionsArr(a, b);
  const twice = mergeSessionsArr(once, once);
  assert.deepEqual(once, twice);
});

// ---------- mergeChecklistArr / mergeCompletions / mergeArcade ----------
test("mergeChecklistArr unions words, dedups", () => {
  assert.deepEqual(mergeChecklistArr(["dog", "cat"], ["cat", "ball"]).sort(), ["ball", "cat", "dog"]);
});
test("mergeCompletions takes max total and max per-domain lockedUntil, never drops a one-sided key", () => {
  const a = { total: 5, lockedUntil: { colors: 10 } };
  const b = { total: 3, lockedUntil: { shapes: 8 } };
  const merged = mergeCompletions(a, b);
  assert.equal(merged.total, 5);
  assert.deepEqual(merged.lockedUntil, { colors: 10, shapes: 8 });
});
test("mergeArcade takes max totalPlays/bestStreak, ORs introShown, per mode", () => {
  const a = { mixitup: { totalPlays: 10, bestStreak: 4, introShown: true }, everything: { totalPlays: 0, bestStreak: 0, introShown: false } };
  const b = { mixitup: { totalPlays: 6, bestStreak: 7, introShown: false }, everything: { totalPlays: 2, bestStreak: 1, introShown: true } };
  const merged = mergeArcade(a, b);
  assert.deepEqual(merged, {
    mixitup: { totalPlays: 10, bestStreak: 7, introShown: true },
    everything: { totalPlays: 2, bestStreak: 1, introShown: true },
  });
});
test("mergeArcade migrates the old flat v10 shape transparently", () => {
  const flatOld = { totalPlays: 5, bestStreak: 2, introShown: true }; // pre-v10.1 shape
  const nested = { mixitup: { totalPlays: 1, bestStreak: 9, introShown: false }, everything: { totalPlays: 0, bestStreak: 0, introShown: false } };
  const merged = mergeArcade(flatOld, nested);
  assert.equal(merged.mixitup.totalPlays, 5);
  assert.equal(merged.mixitup.bestStreak, 9);
});

// ---------- mergeProfiles: union by id, last-writer-wins by updatedAt ----------
test("mergeProfiles unions distinct ids", () => {
  const a = [profile("p1", "Milo", "2026-08-01T00:00:00.000Z")];
  const b = [profile("p2", "Ada", "2026-08-01T00:00:00.000Z")];
  const merged = mergeProfiles(a, b);
  assert.deepEqual(merged.map(p => p.id).sort(), ["p1", "p2"]);
});
test("mergeProfiles keeps the greater updatedAt on a shared id (last-writer-wins)", () => {
  const older = profile("p1", "Milo", "2026-08-01T00:00:00.000Z");
  const newer = profile("p1", "Milo Jr.", "2026-08-10T00:00:00.000Z");
  assert.equal(mergeProfiles([older], [newer])[0].name, "Milo Jr.");
  assert.equal(mergeProfiles([newer], [older])[0].name, "Milo Jr.");
});
test("mergeProfiles is commutative and idempotent", () => {
  const a = [profile("p1", "Milo", "2026-08-01T00:00:00.000Z")];
  const b = [profile("p1", "Milo Jr.", "2026-08-10T00:00:00.000Z"), profile("p2", "Ada", "2026-08-02T00:00:00.000Z")];
  const ab = mergeProfiles(a, b), ba = mergeProfiles(b, a);
  assert.deepEqual(ab.map(p=>p.id).sort(), ba.map(p=>p.id).sort());
  const once = mergeProfiles(a, b);
  const twice = mergeProfiles(once, once);
  assert.deepEqual(once, twice);
});

// ---------- mergePerProfile: per-child bundles merge independently ----------
test("mergePerProfile merges two profiles' bundles independently (union, no cross-contamination)", () => {
  const a = { p1: bundle([session("2026-08-01T00:00:00.000Z")], ["dog"]) };
  const b = { p2: bundle([session("2026-08-02T00:00:00.000Z")], ["cat"]) };
  const merged = mergePerProfile(a, b);
  assert.deepEqual(Object.keys(merged).sort(), ["p1", "p2"]);
  assert.equal(merged.p1.sessions.length, 1);
  assert.equal(merged.p1.checklist[0], "dog");
  assert.equal(merged.p2.sessions.length, 1);
  assert.equal(merged.p2.checklist[0], "cat");
});
test("mergePerProfile unions sessions WITHIN the same profile id from two devices", () => {
  const a = { p1: bundle([session("2026-08-01T00:00:00.000Z")]) };
  const b = { p1: bundle([session("2026-08-02T00:00:00.000Z")]) };
  const merged = mergePerProfile(a, b);
  assert.equal(merged.p1.sessions.length, 2);
});

// ---------- mergeState: top-level, full round trip ----------
test("mergeState migrates a single legacy profile cleanly (one profile, one bundle, nothing dropped)", () => {
  const local = {
    profiles: [profile("p1", "Milo", "2026-08-01T00:00:00.000Z")],
    perProfile: { p1: bundle([session("2026-08-01T00:00:00.000Z")], ["dog", "cat"]) },
  };
  const merged = mergeState(local, null);
  assert.equal(merged.profiles.length, 1);
  assert.equal(merged.perProfile.p1.sessions.length, 1);
  assert.deepEqual(merged.perProfile.p1.checklist.sort(), ["cat", "dog"]);
});
test("mergeState with two profiles (siblings) preserves both, independently merged", () => {
  const local = {
    profiles: [profile("p1", "Milo", "2026-08-01T00:00:00.000Z"), profile("p2", "Ada", "2026-08-01T00:00:00.000Z")],
    perProfile: {
      p1: bundle([session("2026-08-01T00:00:00.000Z")]),
      p2: bundle([session("2026-08-01T00:00:00.000Z")]),
    },
  };
  const remote = {
    profiles: [profile("p1", "Milo", "2026-08-01T00:00:00.000Z"), profile("p2", "Ada", "2026-08-01T00:00:00.000Z")],
    perProfile: {
      p1: bundle([session("2026-08-05T00:00:00.000Z")]),
      p2: bundle([session("2026-08-06T00:00:00.000Z")]),
    },
  };
  const merged = mergeState(local, remote);
  assert.equal(merged.profiles.length, 2);
  assert.equal(merged.perProfile.p1.sessions.length, 2);
  assert.equal(merged.perProfile.p2.sessions.length, 2);
});
test("mergeState sync round trip: device A's history + device B's history both survive after two PUTs", () => {
  // Simulates: device A plays offline, then syncs (PUT local-only -> server stores it as-is via
  // mergeState(null, deviceA)); device B (fresh, empty local) then syncs too — its PUT carries
  // device B's own new session, merged with what's now on the server.
  const deviceAFirstSync = mergeState(null, {
    profiles: [profile("p1", "Milo", "2026-08-01T00:00:00.000Z")],
    perProfile: { p1: bundle([session("2026-08-01T00:00:00.000Z")]) },
  });
  const deviceBPut = {
    profiles: [profile("p1", "Milo", "2026-08-01T00:00:00.000Z")],
    perProfile: { p1: bundle([session("2026-08-02T00:00:00.000Z")]) },
  };
  const afterDeviceB = mergeState(deviceAFirstSync, deviceBPut);
  assert.equal(afterDeviceB.perProfile.p1.sessions.length, 2);
});

// ---------- the critical "must not wipe" cases ----------
test("mergeState: an EMPTY local blob merged against real server data does not wipe the server data", () => {
  // This is the scenario the task calls out explicitly: a device with empty local state + a
  // valid family code must not be able to PUT an empty blob and erase everyone else's history.
  // The SERVER MERGES rather than overwrites — assert that here directly on mergeState, which
  // is exactly what src/index.js's PUT handler calls with (existing, incoming).
  const serverHasData = {
    profiles: [profile("p1", "Milo", "2026-08-01T00:00:00.000Z")],
    perProfile: { p1: bundle([session("2026-08-01T00:00:00.000Z"), session("2026-08-02T00:00:00.000Z")], ["dog", "cat", "ball"]) },
  };
  const emptyDevicePut = { profiles: [], perProfile: {} };
  const merged = mergeState(serverHasData, emptyDevicePut);
  assert.equal(merged.profiles.length, 1);
  assert.equal(merged.perProfile.p1.sessions.length, 2);
  assert.equal(merged.perProfile.p1.checklist.length, 3);
});
test("mergeState: null/undefined on either side never throws and never drops the other side's data", () => {
  const real = {
    profiles: [profile("p1", "Milo", "2026-08-01T00:00:00.000Z")],
    perProfile: { p1: bundle([session("2026-08-01T00:00:00.000Z")]) },
  };
  assert.doesNotThrow(() => mergeState(real, null));
  assert.doesNotThrow(() => mergeState(null, real));
  assert.doesNotThrow(() => mergeState(undefined, undefined));
  assert.equal(mergeState(real, null).perProfile.p1.sessions.length, 1);
  assert.equal(mergeState(null, real).perProfile.p1.sessions.length, 1);
  assert.deepEqual(mergeState(undefined, undefined).profiles, []);
});
test("mergeState is idempotent: merging a blob with itself is a no-op on content (aside from updatedAt)", () => {
  const blob = {
    profiles: [profile("p1", "Milo", "2026-08-01T00:00:00.000Z")],
    perProfile: { p1: bundle([session("2026-08-01T00:00:00.000Z")], ["dog"]) },
  };
  const once = mergeState(null, blob);
  const twice = mergeState(once, once);
  assert.deepEqual(twice.profiles, once.profiles);
  assert.deepEqual(twice.perProfile, once.perProfile);
});
test("mergeState is commutative on content (aside from updatedAt, which is always 'now')", () => {
  const a = {
    profiles: [profile("p1", "Milo", "2026-08-01T00:00:00.000Z")],
    perProfile: { p1: bundle([session("2026-08-01T00:00:00.000Z")]) },
  };
  const b = {
    profiles: [profile("p2", "Ada", "2026-08-01T00:00:00.000Z")],
    perProfile: { p2: bundle([session("2026-08-02T00:00:00.000Z")]) },
  };
  const ab = mergeState(a, b), ba = mergeState(b, a);
  assert.deepEqual(ab.profiles.map(p=>p.id).sort(), ba.profiles.map(p=>p.id).sort());
  assert.deepEqual(ab.perProfile, ba.perProfile);
});

// ---------- "PUT storm" simulation: many rapid PUTs from one device settle to a stable state ----------
test("repeated identical PUTs (a PUT storm from a debounce race) converge and never lose data", () => {
  let server = null;
  const clientBlob = {
    profiles: [profile("p1", "Milo", "2026-08-01T00:00:00.000Z")],
    perProfile: { p1: bundle([session("2026-08-01T00:00:00.000Z")], ["dog"]) },
  };
  for (let i = 0; i < 5; i++){
    server = mergeState(server, clientBlob); // same PUT body fired 5x (retry storm)
  }
  assert.equal(server.perProfile.p1.sessions.length, 1);
  assert.deepEqual(server.perProfile.p1.checklist, ["dog"]);
});

// ---------- v15.3: sticker book (tg_stickers) + tg_completions.counts ----------
test("mergeStickers unions by key and keeps the EARLIEST date", () => {
  const a = { d_colors: "2026-10-02T10:00:00.000Z", m_first: "2026-10-01T09:00:00.000Z" };
  const b = { d_colors: "2026-10-01T08:00:00.000Z", d_shapes: "2026-10-03T00:00:00.000Z" };
  assert.deepEqual(mergeStickers(a, b), {
    d_colors: "2026-10-01T08:00:00.000Z", d_shapes: "2026-10-03T00:00:00.000Z", m_first: "2026-10-01T09:00:00.000Z",
  });
});
test("mergeStickers is commutative, idempotent and tolerant of junk / missing sides", () => {
  const a = { d_a: "2026-10-02T00:00:00.000Z", g_a: "2026-10-05T00:00:00.000Z" };
  const b = { d_a: "2026-10-02T00:00:00+00:00", d_b: "not-a-date", "bad key!": "2026-10-01T00:00:00.000Z", d_c: 12, d_d: null };
  const ab = mergeStickers(a, b), ba = mergeStickers(b, a);
  assert.deepEqual(ab, ba);
  assert.deepEqual(mergeStickers(ab, ab), ab);
  assert.deepEqual(Object.keys(ab), ["d_a", "d_b", "g_a"]); // junk keys/values dropped, sorted
  assert.deepEqual(mergeStickers(undefined, undefined), {});
  assert.deepEqual(mergeStickers(null, a), a);
  assert.deepEqual(mergeStickers([1, 2], a), a);
  assert.deepEqual(mergeStickers("x", "y"), {});
});
test("mergeCompletions max-merges per-domain counts and survives an old-client side with no counts", () => {
  const withCounts = { total: 4, lockedUntil: { colors: 9 }, counts: { colors: 3, shapes: 1 } };
  const oldClient = { total: 2, lockedUntil: { colors: 7 } }; // pre-v15.3: no `counts`
  const m1 = mergeCompletions(withCounts, oldClient), m2 = mergeCompletions(oldClient, withCounts);
  assert.deepEqual(m1, m2);
  assert.deepEqual(m1.counts, { colors: 3, shapes: 1 });
  assert.equal(m1.total, 4);
  assert.deepEqual(mergeCompletions({ counts: { a: 2 } }, { counts: { a: 5, b: "9", c: -1, d: NaN } }).counts, { a: 5, b: 0, c: 0, d: 0 });
  assert.deepEqual(mergeCompletions(null, null), { total: 0, lockedUntil: {}, counts: {} });
});
test("two devices' stickers union through mergeState; OLD-client blob (no stickers/counts) never drops them", () => {
  const P = profile("p1", "Milo", "2026-10-01T00:00:00.000Z");
  const deviceA = { profiles: [P], perProfile: { p1: { ...bundle([session("2026-10-01T00:00:00.000Z")]), completions: { total: 1, lockedUntil: { colors: 6 }, counts: { colors: 1 } }, stickers: { d_colors: "2026-10-01T00:00:00.000Z", m_first: "2026-10-01T00:00:00.000Z" } } } };
  const deviceB = { profiles: [P], perProfile: { p1: { ...bundle([session("2026-10-02T00:00:00.000Z")]), stickers: { d_shapes: "2026-10-02T00:00:00.000Z", d_colors: "2026-10-02T00:00:00.000Z" } } } };
  const server1 = mergeState(null, deviceA);
  const server2 = mergeState(server1, deviceB);
  assert.deepEqual(server2.perProfile.p1.stickers, { d_colors: "2026-10-01T00:00:00.000Z", d_shapes: "2026-10-02T00:00:00.000Z", m_first: "2026-10-01T00:00:00.000Z" });
  assert.deepEqual(mergeState(deviceB, server1).perProfile.p1.stickers, server2.perProfile.p1.stickers); // order-independent
  // an OLD client (bundle has exactly the 4 pre-v15.3 keys) PUTs: stickers + counts on the server survive
  const oldClient = { profiles: [P], perProfile: { p1: { sessions: [session("2026-10-03T00:00:00.000Z")], checklist: [], completions: { total: 1, lockedUntil: {} }, arcade: {} } } };
  const afterOld = mergeState(server2, oldClient);
  assert.deepEqual(afterOld.perProfile.p1.stickers, server2.perProfile.p1.stickers);
  assert.deepEqual(afterOld.perProfile.p1.completions.counts, { colors: 1 });
  assert.equal(afterOld.perProfile.p1.sessions.length, 3);
  // ...and the 1MB-cap GET+merge retry path (client simulates mergeState(serverBlob, localBlob)): same result either order
  assert.deepEqual(mergeState(oldClient, server2).perProfile.p1.stickers, server2.perProfile.p1.stickers);
  // a stickers-less state through a fresh (new-client) merge gets an empty record, not undefined
  assert.deepEqual(mergeState(oldClient, null).perProfile.p1.stickers, {});
});

// ---------- v15.3: the real Worker handler end to end (in-memory KV) ----------
function fakeEnv(){
  const m = new Map();
  return { SYNC: { get: async (k) => (m.has(k) ? m.get(k) : null), put: async (k, v) => { m.set(k, v); } }, _m: m };
}
async function call(env, method, path, body){
  const res = await worker.fetch(new Request("https://x.test" + path, { method, body: body === undefined ? undefined : JSON.stringify(body), headers: { "Content-Type": "application/json" } }), env);
  return { status: res.status, body: await res.json() };
}
test("worker handler: new-client PUT stores stickers; old-client PUT does not erase them; GET returns them; junk entries are dropped", async () => {
  const env = fakeEnv();
  const P = profile("p1", "Milo", "2026-10-01T00:00:00.000Z");
  const code = "abcd-1234";
  const newBlob = { v: 1, profiles: [P], perProfile: { p1: { sessions: [], checklist: [], completions: { total: 1, lockedUntil: { colors: 6 }, counts: { colors: 1 } }, arcade: {}, stickers: { d_colors: "2026-10-01T00:00:00.000Z", "evil key": "x", d_x: 5 } } } };
  let r = await call(env, "PUT", `/v1/state/${code}`, newBlob);
  assert.equal(r.status, 200);
  assert.deepEqual(r.body.perProfile.p1.stickers, { d_colors: "2026-10-01T00:00:00.000Z" });
  const oldBlob = { v: 1, profiles: [P], perProfile: { p1: { sessions: [session("2026-10-04T00:00:00.000Z")], checklist: [], completions: { total: 1, lockedUntil: { colors: 6 } }, arcade: {} } } };
  r = await call(env, "PUT", `/v1/state/${code}`, oldBlob);
  assert.equal(r.status, 200);
  assert.deepEqual(r.body.perProfile.p1.stickers, { d_colors: "2026-10-01T00:00:00.000Z" });
  assert.deepEqual(r.body.perProfile.p1.completions.counts, { colors: 1 });
  r = await call(env, "GET", `/v1/state/${code}`);
  assert.deepEqual(r.body.perProfile.p1.stickers, { d_colors: "2026-10-01T00:00:00.000Z" });
  assert.equal(r.body.perProfile.p1.sessions.length, 1);
});
test("worker handler: 413 on a merged-over-cap PUT leaves stored stickers intact (retry path never loses them)", async () => {
  const env = fakeEnv();
  const P = profile("p1", "Milo", "2026-10-01T00:00:00.000Z");
  const code = "wxyz-9876";
  const base = { v: 1, profiles: [P], perProfile: { p1: { sessions: [], checklist: [], completions: {}, arcade: {}, stickers: { m_first: "2026-10-01T00:00:00.000Z" } } } };
  assert.equal((await call(env, "PUT", `/v1/state/${code}`, base)).status, 200);
  const fat = (n) => Array.from({ length: n }, (_, i) => ({ ...session(new Date(Date.UTC(2026, 9, 1, 0, 0, i)).toISOString()), pad: "x".repeat(1500) }));
  const big = { v: 1, profiles: [P], perProfile: { p1: { sessions: fat(800), checklist: [], completions: {}, arcade: {} } } };
  const r = await call(env, "PUT", `/v1/state/${code}`, big);
  assert.equal(r.status, 413);
  const g = await call(env, "GET", `/v1/state/${code}`);
  assert.deepEqual(g.body.perProfile.p1.stickers, { m_first: "2026-10-01T00:00:00.000Z" });
});

// v15.3 review fix: domain keys are camelCase (dragSounds, zhColors, zhDragNumbers, ...) so sticker ids must survive the key filter.
test("mergeStickers keeps camelCase domain-key ids (d_dragSounds, g_zhDragNumbers) and still drops junk", () => {
  const ids = ["d_dragSounds","d_dragLetters","d_dragNumbers","d_dragShapes","d_dragColors","d_zhColors","d_zhNumbers","d_zhWords","g_zhDragNumbers","m_first"];
  const rec = Object.fromEntries(ids.map(k => [k, "2026-10-01T00:00:00.000Z"]));
  assert.deepEqual(Object.keys(mergeStickers(rec, null)).sort(), [...ids].sort());
  assert.deepEqual(mergeStickers({ "d_has space": "x", ["d_" + "x".repeat(60)]: "2026-10-01T00:00:00.000Z" }, null), {});
  const m = mergeState(null, { profiles: [profile("p1", "M", "2026-10-01T00:00:00.000Z")], perProfile: { p1: { ...bundle(), stickers: rec } } });
  assert.deepEqual(Object.keys(m.perProfile.p1.stickers).sort(), [...ids].sort());
});
