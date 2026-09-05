#!/usr/bin/env node
// tools/dump_say_strings_zh.js — prints the JSON array of every MANDARIN string
// collectMandarinSayStrings() (defined in index.html's <script>, v13) enumerates, by running
// that script inside a Node vm sandbox with minimal browser-global stubs (no real
// browser/headless-Chrome needed). Sibling to tools/dump_say_strings.js (same sandboxing
// technique, same reasons for each stub) — kept as a SEPARATE file rather than a shared flag so
// the two audio pipelines (gen_audio.sh / gen_audio_zh.sh) can never accidentally cross: this
// file can only ever emit collectMandarinSayStrings()'s output, never collectAllSayStrings()'s.
//
// Usage:  node tools/dump_say_strings_zh.js > strings_zh.json
//         node tools/dump_say_strings_zh.js --lines    # NUL-separated instead of JSON (used by gen_audio_zh.sh)
'use strict';
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const htmlPath = path.join(__dirname, '..', 'index.html');
const html = fs.readFileSync(htmlPath, 'utf8');
const m = html.match(/<script>([\s\S]*?)<\/script>/);
if (!m) {
  console.error('dump_say_strings_zh.js: could not find a <script> block in index.html');
  process.exit(1);
}
let src = m[1];
const marker = '/* ---------- init ---------- */';
const markerIdx = src.indexOf(marker);
if (markerIdx >= 0) src = src.slice(0, markerIdx);

// Minimal stub DOM element — see dump_say_strings.js's identical comment.
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
  // Route console.* to stderr — see dump_say_strings.js's identical fix (stdout is reserved for
  // the one process.stdout.write call at the bottom, otherwise the emoji tofu-detection
  // diagnostic corrupts the JSON payload).
  console: { log: (...a) => console.error(...a), warn: (...a) => console.error(...a), error: (...a) => console.error(...a), info: (...a) => console.error(...a), assert: (...a) => console.error(...a), debug: (...a) => console.error(...a) },
  document: {
    getElementById: () => stubEl(),
    querySelectorAll: () => [],
    createElement: () => stubEl(),
    body: stubEl(),
  },
  localStorage: { getItem: () => null, setItem() {}, removeItem() {} },
  navigator: { userAgent: 'node' },
  // Bug fix (QA pass 4) — see dump_say_strings.js's identical fix/comment: v14.1's global crash
  // catcher's bare top-level `window.addEventListener(...)` calls need a stub or the whole
  // sandboxed evaluation throws before collectMandarinSayStrings() is even defined.
  addEventListener() {}, removeEventListener() {},
  Math, JSON, Array, Object, Set, Map, String, Number, Date, RegExp, Promise,
  // Real (unref'd) timers — see dump_say_strings.js's identical fix for v11's top-level setInterval.
  setInterval: (...a) => { const h = setInterval(...a); h.unref && h.unref(); return h; },
  clearInterval,
  setTimeout: (...a) => { const h = setTimeout(...a); h.unref && h.unref(); return h; },
  clearTimeout,
};
sandbox.window = sandbox;

vm.createContext(sandbox);
try {
  vm.runInContext(src, sandbox, { filename: 'index.html#script' });
} catch (e) {
  console.error('dump_say_strings_zh.js: failed to evaluate index.html script:', e.stack || e);
  process.exit(1);
}

let strings;
try {
  strings = vm.runInContext('collectMandarinSayStrings()', sandbox);
} catch (e) {
  console.error('dump_say_strings_zh.js: collectMandarinSayStrings() threw:', e.stack || e);
  process.exit(1);
}

if (process.argv.includes('--lines')) {
  process.stdout.write(strings.map(s => s + '\0').join(''));
} else {
  process.stdout.write(JSON.stringify(strings, null, 0));
}
