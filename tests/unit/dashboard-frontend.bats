#!/usr/bin/env bats

# Unit tests for the pure client-side helpers embedded in the dashboard HTML.
# These functions render values in the UI (e.g. the "Released" column of the
# Published channels table); a regression here is what made every release date
# display as "unknown".

setup() {
    REPO_ROOT="$(git rev-parse --show-toplevel)"
    HELPER="${REPO_ROOT}/tests/helpers/extract-js-funcs.js"
    # Both shipped copies must stay in sync; tests run against each.
    HTML_FILES=(
        "${REPO_ROOT}/snap/local/assets/dashboard.html"
        "${REPO_ROOT}/docs/index.html"
    )
}

run_node() {
    run node "$@"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "frontend: relativeTime formats values and falls back to 'unknown' for empty/invalid input" {
    for html in "${HTML_FILES[@]}"; do
        run_node - "$HELPER" "$html" <<'JS'
const { loadFunctions } = require(process.argv[2]);
const { relativeTime } = loadFunctions(process.argv[3], ["relativeTime"]);
const assert = require("assert");

// Regression guard: an empty or unparseable date must read "unknown",
// never crash or render "NaN".
assert.strictEqual(relativeTime(""), "unknown");
assert.strictEqual(relativeTime(null), "unknown");
assert.strictEqual(relativeTime(undefined), "unknown");
assert.strictEqual(relativeTime("not-a-date"), "unknown");

const now = Date.now();
const iso = (msAgo) => new Date(now - msAgo).toISOString();
assert.match(relativeTime(iso(5 * 1000)), /^\d+s ago$/);
assert.match(relativeTime(iso(5 * 60 * 1000)), /^\d+m ago$/);
assert.match(relativeTime(iso(3 * 60 * 60 * 1000)), /^\d+h ago$/);
assert.match(relativeTime(iso(3 * 24 * 60 * 60 * 1000)), /^\d+d ago$/);
JS
    done
}

@test "frontend: formatDate returns 'Unknown' for empty and echoes unparseable input" {
    for html in "${HTML_FILES[@]}"; do
        run_node - "$HELPER" "$html" <<'JS'
const { loadFunctions } = require(process.argv[2]);
const { formatDate } = loadFunctions(process.argv[3], ["formatDate"]);
const assert = require("assert");

assert.strictEqual(formatDate(""), "Unknown");
assert.strictEqual(formatDate(null), "Unknown");
assert.strictEqual(formatDate("totally-bogus"), "totally-bogus");

// A valid timestamp must render something other than the fallbacks.
const rendered = formatDate("2026-06-11T12:23:15Z");
assert.notStrictEqual(rendered, "Unknown");
assert.notStrictEqual(rendered, "2026-06-11T12:23:15Z");
assert.match(rendered, /\d/);
JS
    done
}

@test "frontend: formatBytes renders binary units and 'Unknown' for missing values" {
    for html in "${HTML_FILES[@]}"; do
        run_node - "$HELPER" "$html" <<'JS'
const { loadFunctions } = require(process.argv[2]);
const { formatBytes } = loadFunctions(process.argv[3], ["formatBytes"]);
const assert = require("assert");

assert.strictEqual(formatBytes(undefined), "Unknown");
assert.strictEqual(formatBytes(null), "Unknown");
assert.strictEqual(formatBytes(0), "0 B");
assert.strictEqual(formatBytes(512), "512 B");
assert.strictEqual(formatBytes(1024), "1.0 KB");
assert.strictEqual(formatBytes(1536), "1.5 KB");
assert.strictEqual(formatBytes(1048576), "1.0 MB");
assert.strictEqual(formatBytes(1073741824), "1.0 GB");
JS
    done
}

@test "frontend: humanDuration formats seconds, minutes and hours" {
    for html in "${HTML_FILES[@]}"; do
        run_node - "$HELPER" "$html" <<'JS'
const { loadFunctions } = require(process.argv[2]);
const { humanDuration } = loadFunctions(process.argv[3], ["humanDuration"]);
const assert = require("assert");

assert.strictEqual(humanDuration(null), "Unknown");
assert.strictEqual(humanDuration(undefined), "Unknown");
assert.strictEqual(humanDuration(0), "0s");
assert.strictEqual(humanDuration(45), "45s");
assert.strictEqual(humanDuration(90), "1m 30s");
assert.strictEqual(humanDuration(3661), "1h 1m");
JS
    done
}
