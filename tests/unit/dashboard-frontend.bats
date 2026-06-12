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

@test "frontend: statusBadgeUrl treats cancelled as neutral, not a failure" {
    for html in "${HTML_FILES[@]}"; do
        run_node - "$HELPER" "$html" <<'JS'
const { loadModule } = require(process.argv[2]);
const { statusBadgeUrl } = loadModule(process.argv[3], {
  consts: ["FAILURE_STATES"],
  functions: ["statusBadgeUrl"],
});
const assert = require("assert");

// Genuine failures still render as a failed badge.
assert.ok(statusBadgeUrl("failure").includes("status-failed-critical"));
assert.ok(statusBadgeUrl("timed_out").includes("status-failed-critical"));

// A cancelled run means no new build was produced, not a broken build:
// it must render as neutral grey, never as a failure.
const cancelled = statusBadgeUrl("cancelled");
assert.ok(!cancelled.includes("failed-critical"), cancelled);
assert.ok(cancelled.includes("status-cancelled-lightgrey"), cancelled);
JS
    done
}

@test "frontend: snapStatusDescriptor marks lagging builds 'behind', never 'failing'" {
    for html in "${HTML_FILES[@]}"; do
        run_node - "$HELPER" "$html" <<'JS'
const { loadFunctions } = require(process.argv[2]);
const { snapStatusDescriptor } = loadFunctions(process.argv[3], ["snapStatusDescriptor"]);
const assert = require("assert");

// A current revision is serving on its channel.
const current = snapStatusDescriptor({ build_status: "current", channel: "stable" });
assert.strictEqual(current.cls, "status-success");
assert.strictEqual(current.label, "Serving · stable");

// A stale Launchpad arch (e.g. riscv64 on edge whose store revision lags the
// newest build) is "behind" on its real channel, not "Build failing · stable".
const lp = snapStatusDescriptor({ build_status: "stale", channel: "edge", build_source: "launchpad" });
assert.strictEqual(lp.cls, "status-caution");
assert.strictEqual(lp.label, "Behind · edge");
assert.ok(!/fail/i.test(lp.label), lp.label);

// Stale GitHub arches are described the same way (no failing language).
const gh = snapStatusDescriptor({ build_status: "stale", channel: "stable", build_source: "github" });
assert.strictEqual(gh.label, "Behind · stable");
JS
    done
}

@test "frontend: trendPointColor renders cancelled/skipped as neutral grey, not success green" {
    for html in "${HTML_FILES[@]}"; do
        run_node - "$HELPER" "$html" <<'JS'
const { loadModule } = require(process.argv[2]);
const { trendPointColor } = loadModule(process.argv[3], {
  consts: ["FAILURE_STATES"],
  functions: ["trendPointColor"],
});
const assert = require("assert");

const GREEN = "#0e8420";
const RED = "#c7162b";
const GREY = "#757575";

// Successful builds stay green; genuine failures stay red.
assert.strictEqual(trendPointColor("success"), GREEN);
assert.strictEqual(trendPointColor("failure"), RED);
// All failure-class conclusions share the red treatment.
assert.strictEqual(trendPointColor("timed_out"), RED);
assert.strictEqual(trendPointColor("startup_failure"), RED);

// Regression guard: a cancelled run produced no new build. It must never be
// painted green like a success (the bug that made run #94 "show successful").
assert.strictEqual(trendPointColor("cancelled"), GREY);
assert.strictEqual(trendPointColor("skipped"), GREY);
assert.notStrictEqual(trendPointColor("cancelled"), GREEN);

// Case-insensitive and resilient to empty input.
assert.strictEqual(trendPointColor("CANCELLED"), GREY);
assert.strictEqual(trendPointColor(""), "#0b6bc5");
JS
    done
}

@test "frontend: trendTooltipDescriptor styles cancelled runs as caution, never positive success" {
    for html in "${HTML_FILES[@]}"; do
        run_node - "$HELPER" "$html" <<'JS'
const { loadModule } = require(process.argv[2]);
const { trendTooltipDescriptor } = loadModule(process.argv[3], {
  consts: ["FAILURE_STATES"],
  functions: ["trendTooltipDescriptor"],
});
const assert = require("assert");

// A normal success keeps the green positive tooltip with no qualifier.
const ok = trendTooltipDescriptor("success", false);
assert.strictEqual(ok.notificationClass, "p-notification--positive is-inline");
assert.strictEqual(ok.titlePrefix, "");

// A failure reads as the red negative tooltip.
const failed = trendTooltipDescriptor("failure", false);
assert.strictEqual(failed.notificationClass, "p-notification--negative is-inline");
assert.strictEqual(failed.titlePrefix, "Failed ");

// Regression guard: a cancelled run must NOT use the positive/success style.
// It produced no new build, so it reads as a neutral caution labelled clearly.
const cancelled = trendTooltipDescriptor("cancelled", false);
assert.ok(!/positive/.test(cancelled.notificationClass), cancelled.notificationClass);
assert.strictEqual(cancelled.notificationClass, "p-notification--caution is-inline");
assert.strictEqual(cancelled.titlePrefix, "Cancelled ");

const skipped = trendTooltipDescriptor("skipped", false);
assert.strictEqual(skipped.titlePrefix, "Skipped ");
assert.ok(!/positive/.test(skipped.notificationClass), skipped.notificationClass);

// A suspiciously fast success is flagged as caution, not plain positive.
const fast = trendTooltipDescriptor("success", true);
assert.strictEqual(fast.notificationClass, "p-notification--caution is-inline");
assert.strictEqual(fast.titlePrefix, "Suspiciously Fast ");
assert.strictEqual(fast.messageSuffix, " (potential bypass)");
JS
    done
}
