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
  console,
  document: {
    getElementById: () => stubEl(),
    querySelectorAll: () => [],
    createElement: () => stubEl(),
    body: stubEl(),
  },
  localStorage: { getItem: () => null, setItem() {}, removeItem() {} },
  navigator: { userAgent: 'node' },
  Math, JSON, Array, Object, Set, Map, String, Number, Date, RegExp, Promise,
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
