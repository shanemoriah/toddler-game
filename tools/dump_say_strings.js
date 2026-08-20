#!/usr/bin/env node
// tools/dump_say_strings.js — prints the JSON array of every string
// collectAllSayStrings() (defined in index.html's <script>) enumerates, by
// running that script inside a Node vm sandbox with minimal browser-global
// stubs (no real browser/headless-Chrome needed).
//
// Usage:  node tools/dump_say_strings.js > strings.json
//         node tools/dump_say_strings.js --lines    # NUL-separated instead of JSON (used by gen_audio.sh)
//
// Only the DOM-dependent init() IIFE at the very end of the script is
// skipped (everything collectAllSayStrings() needs — DOMAINS, every
// *_DEFS array, every make*Item function — is defined well before it and
// has no DOM/localStorage/speechSynthesis dependency of its own).
'use strict';
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const htmlPath = path.join(__dirname, '..', 'index.html');
const html = fs.readFileSync(htmlPath, 'utf8');
const m = html.match(/<script>([\s\S]*?)<\/script>/);
if (!m) {
  console.error('dump_say_strings.js: could not find a <script> block in index.html');
  process.exit(1);
}
let src = m[1];
const marker = '/* ---------- init ---------- */';
const markerIdx = src.indexOf(marker);
if (markerIdx >= 0) src = src.slice(0, markerIdx);

// Minimal stub DOM element: enough surface for any top-level code path this
// script might touch while merely being PARSED/DEFINED (nothing here is
// actually rendering a game screen) to not throw.
function stubEl() {
  const el = {
    style: {},
    classList: { add() {}, remove() {}, toggle() {}, contains() { return false; } },
    children: [],
    value: '', textContent: '', innerHTML: '',
    dataset: {},
    appendChild() {}, addEventListener() {}, removeEventListener() {},
    querySelectorAll() { return []; }, querySelector() { return null; },
    setAttribute() {}, getAttribute() { return null; }, remove() {},
  };
  return el;
}
const sandbox = {
  // Bug fix: index.html's OWN top-level code logs a diagnostic via console.log (the emoji
  // tofu-detection sweep, "N glyphs checked, M unsupported..." — see its own comment there) —
  // with the real `console` passed straight through, that landed on STDOUT, ahead of (and thus
  // corrupting) the actual JSON payload this script writes via process.stdout.write below.
  // Harmless when run interactively (console.error below also goes to a separate stream), but
  // fatal for gen_audio.sh's `node tools/dump_say_strings.js > "$STRINGS_JSON"` pipeline, whose
  // downstream `JSON.parse(fs.readFileSync(...))` would choke on the leading non-JSON line.
  // Routes every sandboxed console.* call to the real console.error (stderr) instead — this
  // script's own diagnostics already use console.error, so stdout is now reserved exclusively
  // for the one process.stdout.write call at the bottom.
  console: { log: (...a) => console.error(...a), warn: (...a) => console.error(...a), error: (...a) => console.error(...a), info: (...a) => console.error(...a), assert: (...a) => console.error(...a), debug: (...a) => console.error(...a) },
  document: {
    getElementById: () => stubEl(),
    querySelectorAll: () => [],
    createElement: () => stubEl(),
    body: stubEl(),
  },
  localStorage: { getItem: () => null, setItem() {}, removeItem() {} },
  navigator: { userAgent: 'node' },
  Math, JSON, Array, Object, Set, Map, String, Number, Date, RegExp, Promise,
  // Bug fix: v11's family-sync code has a bare top-level `setInterval(...)` call (polling
  // renderSyncStatus) — not inside init()'s IIFE, so it executes during mere top-level
  // evaluation of the script, same as every *_DEFS array/function declaration this dumper
  // actually needs. Node's `vm` sandbox has no timer globals by default, so this threw
  // "setInterval is not defined" and made the WHOLE script fail to evaluate (not just that one
  // statement) — collectAllSayStrings() itself never even got defined.
  // Real Node timer fns (not plain no-ops), so a call site's return value/clearX() pairing still
  // behaves — but every handle is IMMEDIATELY .unref()'d so a real (never-fired-in-this-dumper's-
  // lifetime) interval/timeout can't keep the process alive after the synchronous top-level
  // evaluation below finishes (first attempt at this fix used real un-unref'd timers and hung
  // the dumper indefinitely — setInterval's handle blocks Node's event loop from ever going
  // idle by design).
  setInterval: (...a) => { const h = setInterval(...a); h.unref && h.unref(); return h; },
  clearInterval,
  setTimeout: (...a) => { const h = setTimeout(...a); h.unref && h.unref(); return h; },
  clearTimeout,
};
sandbox.window = sandbox; // `"speechSynthesis" in window` etc. all resolve against this same stub object

vm.createContext(sandbox);
try {
  vm.runInContext(src, sandbox, { filename: 'index.html#script' });
} catch (e) {
  console.error('dump_say_strings.js: failed to evaluate index.html script:', e.stack || e);
  process.exit(1);
}

let strings;
try {
  strings = vm.runInContext('collectAllSayStrings()', sandbox);
} catch (e) {
  console.error('dump_say_strings.js: collectAllSayStrings() threw:', e.stack || e);
  process.exit(1);
}

if (process.argv.includes('--lines')) {
  process.stdout.write(strings.map(s => s + '\0').join(''));
} else {
  process.stdout.write(JSON.stringify(strings, null, 0));
}
