"use strict";

// Extracts named top-level JavaScript functions from an HTML file so they can
// be unit-tested in isolation without a DOM. The dashboard ships its client
// logic inline in <script> blocks, so the tests load the *real* shipped source
// rather than a hand-maintained copy that could drift.

const fs = require("fs");

// Returns the source text of `function <name>(...) { ... }` using brace
// matching. Assumes the function body has textually balanced braces (true for
// the pure helpers we test; template-literal `${x}` pairs stay balanced too).
function extractFunction(src, name) {
  const sig = `function ${name}(`;
  const start = src.indexOf(sig);
  if (start === -1) {
    throw new Error(`function ${name} not found`);
  }
  let depth = 0;
  let seenBrace = false;
  for (let i = src.indexOf("{", start); i < src.length; i += 1) {
    const c = src[i];
    if (c === "{") {
      depth += 1;
      seenBrace = true;
    } else if (c === "}") {
      depth -= 1;
      if (seenBrace && depth === 0) {
        return src.slice(start, i + 1);
      }
    }
  }
  throw new Error(`unterminated function ${name}`);
}

// Returns the source text of a single-line `const <name> = ...;` declaration so
// constants the tested functions depend on (e.g. FAILURE_STATES) can be loaded
// straight from the shipped source alongside them.
function extractConst(src, name) {
  const sig = `const ${name}`;
  const start = src.indexOf(sig);
  if (start === -1) {
    throw new Error(`const ${name} not found`);
  }
  const eol = src.indexOf("\n", start);
  return src.slice(start, eol === -1 ? src.length : eol);
}

// Loads the given function names from an HTML file and returns them as an
// object keyed by name.
function loadFunctions(htmlPath, names) {
  const src = fs.readFileSync(htmlPath, "utf8");
  const bodies = names.map((name) => extractFunction(src, name));
  const factory = new Function(`${bodies.join("\n")}\nreturn { ${names.join(", ")} };`);
  return factory();
}

// Loads a mix of consts and functions together so functions can be exercised
// with the real constants they close over.
function loadModule(htmlPath, { consts = [], functions = [] }) {
  const src = fs.readFileSync(htmlPath, "utf8");
  const parts = [
    ...consts.map((name) => extractConst(src, name)),
    ...functions.map((name) => extractFunction(src, name)),
  ];
  const names = [...consts, ...functions];
  const factory = new Function(`${parts.join("\n")}\nreturn { ${names.join(", ")} };`);
  return factory();
}

module.exports = { extractFunction, extractConst, loadFunctions, loadModule };
