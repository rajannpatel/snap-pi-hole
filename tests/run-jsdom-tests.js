/**
 * JSDOM test runner for standalone dashboard logic tests.
 *
 * Usage: node tests/run-jsdom-tests.js
 *
 * This runs dashboard-logic-tests.spec.js using Node's built-in test runner.
 * No browser required — pure JS math/formatting/status tests in JSDOM.
 */
import { run } from "node:test";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { argv, exit } from "node:process";

const __dirname = dirname(fileURLToPath(import.meta.url));
const spec = resolve(__dirname, "dashboard-logic-tests.spec.js");

const stream = run({
  files: [spec],
  concurrency: true,
  timeout: 10_000,
});

stream.on("test:fail", () => {
  // Let the runner collect all failures before exiting
});

// Collect TAP output for CI integration
stream.pipe(process.stdout);

// Wait for the stream to end, then exit with the correct code
for await (const _ of stream) {
  // drain
}
