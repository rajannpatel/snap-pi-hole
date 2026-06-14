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

@test "frontend: build job matching is channel-aware for GitHub and Launchpad runners" {
    for html in "${HTML_FILES[@]}"; do
        run_node - "$HELPER" "$html" <<'JS'
const { loadFunctions } = require(process.argv[2]);
const { buildJobNamePrefixes, findBuildJob } = loadFunctions(process.argv[3], [
  "buildJobNamePrefixes",
  "findBuildJob",
]);
const assert = require("assert");

assert.deepStrictEqual(buildJobNamePrefixes("AMD64", "edge", true), [
  "build github (edge, amd64)",
  "build github (amd64)",
]);
assert.deepStrictEqual(buildJobNamePrefixes("RISCV64", "stable", false), [
  "build and publish launchpad (stable, riscv64)",
  "build and publish launchpad (riscv64)",
]);

const jobs = [
  { name: "build github (stable, amd64)" },
  { name: "build github (edge, amd64)" },
  { name: "build and publish launchpad (edge, riscv64)" },
];

assert.strictEqual(findBuildJob(jobs, "AMD64", "edge", true).name, "build github (edge, amd64)");
assert.strictEqual(findBuildJob(jobs, "AMD64", "stable", true).name, "build github (stable, amd64)");
assert.strictEqual(findBuildJob(jobs, "RISCV64", "edge", false).name, "build and publish launchpad (edge, riscv64)");
assert.strictEqual(findBuildJob(jobs, "ARMHF", "edge", false), null);
JS
    done
}

@test "frontend: workflow buttons include job/run duration when available" {
    for html in "${HTML_FILES[@]}"; do
        run_node - "$HELPER" "$html" <<'JS'
const { loadFunctions } = require(process.argv[2]);
const { humanDuration, workflowButtonLabel, liveJobDurationSeconds } = loadFunctions(process.argv[3], [
  "humanDuration",
  "workflowButtonLabel",
  "liveJobDurationSeconds",
]);
const assert = require("assert");

assert.strictEqual(workflowButtonLabel(null, "Job"), "Job");
assert.strictEqual(workflowButtonLabel(185, "Job"), "3m 5s Job");
assert.strictEqual(workflowButtonLabel(3661, "Run"), "1h 1m Run");

assert.strictEqual(liveJobDurationSeconds({
  started_at: "2026-06-14T14:00:00Z",
  completed_at: "2026-06-14T14:03:05Z",
  status: "completed",
}), 185);

const realNow = Date.now;
try {
  Date.now = () => Date.parse("2026-06-14T14:04:00Z");
  assert.strictEqual(liveJobDurationSeconds({
    started_at: "2026-06-14T14:00:00Z",
    completed_at: null,
    status: "in_progress",
  }), 240);
} finally {
  Date.now = realNow;
}
JS
    done
}

@test "frontend: countdownLabel rounds up while waiting for the next refresh" {
    for html in "${HTML_FILES[@]}"; do
        run_node - "$HELPER" "$html" <<'JS'
const { loadFunctions } = require(process.argv[2]);
const { countdownLabel } = loadFunctions(process.argv[3], ["countdownLabel"]);
const assert = require("assert");

const realNow = Date.now;
try {
  Date.now = () => 1_000_000;

  assert.strictEqual(countdownLabel(null), null);
  assert.strictEqual(countdownLabel(1_000_000), "0:00");

  // Do not show 0:00 while there is still a fractional second left; otherwise
  // the chip appears stuck at zero before the scheduler advances its target.
  assert.strictEqual(countdownLabel(1_000_001), "0:01");
  assert.strictEqual(countdownLabel(1_000_999), "0:01");
  assert.strictEqual(countdownLabel(1_001_001), "0:02");
} finally {
  Date.now = realNow;
}
JS
    done
}

@test "frontend: nextHourBoundary targets the expected hourly gist refresh time" {
    for html in "${HTML_FILES[@]}"; do
        run_node - "$HELPER" "$html" <<'JS'
const { loadFunctions } = require(process.argv[2]);
const { nextHourBoundary } = loadFunctions(process.argv[3], ["nextHourBoundary"]);
const assert = require("assert");

assert.strictEqual(
  new Date(nextHourBoundary(Date.parse("2026-06-12T22:00:00Z"))).toISOString(),
  "2026-06-12T23:00:00.000Z"
);
assert.strictEqual(
  new Date(nextHourBoundary(Date.parse("2026-06-12T22:59:59Z"))).toISOString(),
  "2026-06-12T23:00:00.000Z"
);
assert.strictEqual(
  new Date(nextHourBoundary(Date.parse("2026-06-12T23:30:00Z"))).toISOString(),
  "2026-06-13T00:00:00.000Z"
);
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

@test "frontend: snapStatusDescriptor marks lagging store revisions as store lag, never failing" {
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
// newest build) is store lag on its real channel, not "Build failing · stable".
const lp = snapStatusDescriptor({ build_status: "stale", channel: "edge", build_source: "launchpad" });
assert.strictEqual(lp.cls, "status-caution");
assert.strictEqual(lp.label, "Store lag · edge");
assert.ok(!/fail/i.test(lp.label), lp.label);

// Stale GitHub arches are described the same way (no failing language).
const gh = snapStatusDescriptor({ build_status: "stale", channel: "stable", build_source: "github" });
assert.strictEqual(gh.label, "Store lag · stable");
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

@test "frontend: older snap gist data cannot override a newer deployed snapshot" {
    for html in "${HTML_FILES[@]}"; do
        run_node - "$HELPER" "$html" <<'JS'
const { loadFunctions } = require(process.argv[2]);
const { shouldApplySnapPayload } = loadFunctions(process.argv[3], ["shouldApplySnapPayload"]);
const assert = require("assert");

const deployed = "2026-06-12T22:57:25Z";
const olderGist = { generated_at: "2026-06-12T22:25:04Z" };
const sameGist = { generated_at: deployed };
const newerGist = { generated_at: "2026-06-12T23:05:00Z" };

// Regression guard: Pages can have newer Snap Store data than the hourly gist
// immediately after deployment. That older gist must not overwrite it.
assert.strictEqual(shouldApplySnapPayload(deployed, olderGist), false);

// Equal or newer gist data may apply.
assert.strictEqual(shouldApplySnapPayload(deployed, sameGist), true);
assert.strictEqual(shouldApplySnapPayload(deployed, newerGist), true);

// Missing or malformed timestamps remain permissive so partial data does not
// permanently block updates.
assert.strictEqual(shouldApplySnapPayload("", olderGist), true);
assert.strictEqual(shouldApplySnapPayload(deployed, {}), true);
assert.strictEqual(shouldApplySnapPayload("not-a-date", olderGist), true);
assert.strictEqual(shouldApplySnapPayload(deployed, { generated_at: "bad" }), true);
JS
    done
}
