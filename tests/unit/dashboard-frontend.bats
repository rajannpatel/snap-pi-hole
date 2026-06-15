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
const { loadFunctions, loadModule } = require(process.argv[2]);
const { humanDuration, workflowButtonLabel, liveJobDurationSeconds } = loadFunctions(process.argv[3], [
  "humanDuration",
  "workflowButtonLabel",
  "liveJobDurationSeconds",
]);
const { workflowButtonHtml } = loadModule(process.argv[3], {
  consts: ["githubLogoSvg"],
  functions: ["escapeHtml", "humanDuration", "workflowButtonLabel", "workflowButtonHtml"],
});
const assert = require("assert");

assert.strictEqual(workflowButtonLabel(null), "Loading...");
assert.strictEqual(workflowButtonLabel(185), "3m 5s");
assert.strictEqual(workflowButtonLabel(3661), "1h 1m");

const buttonHtml = workflowButtonHtml("https://example.test/run?x=1&y=2", 185, "Build job");
assert.match(buttonHtml, /<span class="workflow-btn__label">3m 5s<\/span>/);
assert.doesNotMatch(buttonHtml, />Build job</);
assert.match(buttonHtml, /aria-label="Build job duration: 3m 5s"/);
assert.match(buttonHtml, /href="https:\/\/example\.test\/run\?x=1&amp;y=2"/);

const pendingHtml = workflowButtonHtml("", null, "Publish job");
assert.match(pendingHtml, /aria-disabled="true"/);
assert.match(pendingHtml, /class="workflow-btn__spinner"/);
assert.doesNotMatch(pendingHtml, /href=/);

const fs = require("fs");
const path = require("path");
const htmlPath = process.argv[3];
const source = fs.readFileSync(htmlPath, "utf8");
const cssPath = htmlPath.endsWith(path.join("docs", "index.html"))
  ? path.join(path.dirname(htmlPath), "dashboard.css")
  : path.join(path.dirname(htmlPath), "dashboard.css");
const cssSource = fs.readFileSync(cssPath, "utf8");
assert.match(cssSource, /td \.workflow-btn \{[\s\S]*display: inline-flex !important;[\s\S]*gap: 0\.35rem;[\s\S]*justify-content: flex-start !important;[\s\S]*text-align: left !important;/);
assert.match(cssSource, /td \.workflow-btn \.workflow-btn__label \{[\s\S]*flex: 1 1 auto;[\s\S]*text-align: left;/);
assert.match(cssSource, /td \.workflow-buttons \{[\s\S]*display: flex;[\s\S]*justify-content: flex-start;[\s\S]*width: 100%;/);
assert.match(cssSource, /td \.workflow-btn \.workflow-btn__spinner \{[\s\S]*border-radius: 50%;[\s\S]*box-sizing: border-box;[\s\S]*flex: 0 0 0\.75rem;[\s\S]*height: 0\.75rem;[\s\S]*width: 0\.75rem;/);
assert.match(cssSource, /td \.workflow-btn \.status-chip-logo \{[\s\S]*flex: 0 0 0\.875rem;[\s\S]*height: 0\.875rem;[\s\S]*width: 0\.875rem;/);
assert.match(source, /btn\.querySelector\("\.workflow-btn__label"\)/);

assert.strictEqual(liveJobDurationSeconds(null), null);
assert.strictEqual(liveJobDurationSeconds({}), null);
assert.strictEqual(liveJobDurationSeconds({ started_at: null }), null);
assert.strictEqual(liveJobDurationSeconds({ started_at: "" }), null);

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

@test "frontend: Pi-hole component workflow links prefer the track-upstream job" {
    for html in "${HTML_FILES[@]}"; do
        run_node - "$HELPER" "$html" <<'JS'
const { loadFunctions } = require(process.argv[2]);
const { trackUpstreamJobFromJobs } = loadFunctions(process.argv[3], ["trackUpstreamJobFromJobs"]);
const assert = require("assert");

const jobs = [
  { name: "setup", html_url: "https://example.test/setup" },
  { name: "update-sources", html_url: "https://example.test/update-sources" },
  { name: "update-tags", html_url: "https://example.test/update-tags" },
];

assert.strictEqual(trackUpstreamJobFromJobs(jobs).html_url, "https://example.test/update-sources");
assert.strictEqual(trackUpstreamJobFromJobs([{ name: "update-tags", html_url: "https://example.test/update-tags" }]).html_url, "https://example.test/update-tags");
assert.strictEqual(trackUpstreamJobFromJobs([{ name: "only-job" }]).name, "only-job");
assert.strictEqual(trackUpstreamJobFromJobs([]), null);
assert.strictEqual(trackUpstreamJobFromJobs(null), null);
JS
    done
}

@test "frontend: upstream component commit hashes link to GitHub commits" {
    for html in "${HTML_FILES[@]}"; do
        run_node - "$HELPER" "$html" <<'JS'
const { loadFunctions } = require(process.argv[2]);
const { githubCommitUrl, upstreamCommitLinkHtml } = loadFunctions(process.argv[3], [
  "githubCommitUrl",
  "upstreamCommitLinkHtml",
]);
const assert = require("assert");

const row = {
  repository: "pi-hole/FTL",
  upstream_commit: "6a976208ae647c1f6b289c35db83b47533c17c5b",
};

assert.strictEqual(
  githubCommitUrl(row, row.upstream_commit),
  "https://github.com/pi-hole/FTL/commit/6a976208ae647c1f6b289c35db83b47533c17c5b"
);
assert.strictEqual(
  upstreamCommitLinkHtml(row),
  '<a href="https://github.com/pi-hole/FTL/commit/6a976208ae647c1f6b289c35db83b47533c17c5b" target="_blank" rel="noopener noreferrer">6a97620</a>'
);
assert.strictEqual(githubCommitUrl({}, row.upstream_commit), "");
assert.strictEqual(upstreamCommitLinkHtml({ repository: "pi-hole/FTL" }), "");
JS
    done
}

@test "frontend: edge component source cells keep version labels before commit links" {
    for html in "${HTML_FILES[@]}"; do
        run_node - "$HELPER" "$html" <<'JS'
const { loadModule } = require(process.argv[2]);
const { sourceVersionWithCommitHtml } = loadModule(process.argv[3], {
  functions: ["githubCommitUrl", "sourceVersionWithCommitHtml"],
});
const assert = require("assert");

const row = {
  repository: "pi-hole/pi-hole",
  local_tag: "v6.4.2",
  local_commit: "23c3b4a64839179fe25d91b5fe8eff4f642eb4ca",
};

const html = sourceVersionWithCommitHtml(row, "local_tag", "local_commit");
assert.match(html, /^v6\.4\.2 \(/, html);
assert.match(html, /23c3b4a/, html);
assert.match(html, /https:\/\/github\.com\/pi-hole\/pi-hole\/commit\/23c3b4a64839179fe25d91b5fe8eff4f642eb4ca/, html);
assert.strictEqual(sourceVersionWithCommitHtml({}, "local_tag", "local_commit"), "Unknown");
JS
    done
}

@test "frontend: edge live refresh updates upstream version tags as well as commits" {
    for html in "${HTML_FILES[@]}"; do
        run_node - "$html" <<'JS'
const fs = require("fs");
const source = fs.readFileSync(process.argv[2], "utf8");
const assert = require("assert");

assert.match(
  source,
  /async function refreshEdgeCommits\(\)[\s\S]*\/commits\/\$\{item\.upstream_ref \|\| "development"\}[\s\S]*\/releases\/latest[\s\S]*item\.upstream_tag = releaseData\.tag_name;/,
  "Edge live refresh should keep upstream version tags current, not only commit SHAs"
);
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

@test "frontend: snapStatusDescriptor does not report store lag while live API is using snapshot" {
    for html in "${HTML_FILES[@]}"; do
        run_node - "$HELPER" "$html" <<'JS'
const { loadFunctions } = require(process.argv[2]);
const { snapStatusDescriptor } = loadFunctions(process.argv[3], ["snapStatusDescriptor"]);
const assert = require("assert");

global.freshnessState = { live: { status: "stale" } };

const stale = snapStatusDescriptor({ build_status: "stale", channel: "edge" });
assert.strictEqual(stale.cls, "status-neutral");
assert.strictEqual(stale.label, "Snapshot · edge");
assert.strictEqual(stale.short, "snapshot");

const current = snapStatusDescriptor({ build_status: "current", channel: "edge" });
assert.strictEqual(current.cls, "status-success");
assert.strictEqual(current.label, "Serving · edge");
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

@test "frontend: snap package refresh preserves live workflow job overlays" {
    for html in "${HTML_FILES[@]}"; do
        run_node - "$html" <<'JS'
const fs = require("fs");
const source = fs.readFileSync(process.argv[2], "utf8");
const assert = require("assert");

assert.match(source, /lpJobs:\s*null,\s*lpRun:\s*null/, "Launchpad run metadata must be cached with jobs");
assert.match(
  source,
  /renderSnapPackage\(payload\.snap_package \|\| \{\}\);\s*applyLiveSnapStatus\(liveState\.cicdJobs, liveState\.cicdRun, liveState\.lpJobs, liveState\.lpRun\);/s,
  "Snap Store refresh must reapply live job links and durations"
);
assert.match(
  source,
  /function resetLiveWorkflowCache\(\)[\s\S]*liveState\.lastLpRunId = null;[\s\S]*liveState\.lpJobs = null;[\s\S]*liveState\.lpRun = null;/,
  "Channel switches must invalidate Launchpad job cache as well as CI/CD job cache"
);
assert.match(
  source,
  /applyLiveSnapStatus\(cicdJobs, cicdRun, lpJobs, lpRun\);/,
  "Live Snap status must use the cached Launchpad run object passed through refreshLiveData"
);
assert.match(
  source,
  /if \(statusHtml\) \{\s*tr\.cells\[6\]\.innerHTML = statusHtml;\s*\}/,
  "Live Snap status must update the status column after Released"
);
JS
    done
}

@test "frontend: component table workflow buttons use live track-upstream job links" {
    for html in "${HTML_FILES[@]}"; do
        run_node - "$html" <<'JS'
const fs = require("fs");
const source = fs.readFileSync(process.argv[2], "utf8");
const assert = require("assert");

assert.match(source, /trackUpstreamJobUrl:\s*null/, "Track-upstream job URL must be cached");
assert.match(source, /trackUpstreamJobDurationSeconds:\s*null/, "Track-upstream job duration must be cached");
assert.match(source, /trackUpstreamJobStatus:\s*null/, "Track-upstream job status must be cached");
assert.match(source, /snapOverlayInFlight:\s*false/, "Snap package live overlay must have an in-flight guard");
assert.match(
  source,
  /const fallbackUrl = trackRun\.url \|\| `https:\/\/github\.com\/\$\{REPO_SLUG\}\/actions\/workflows\/track-upstream-releases\.yml`;/,
  "Component table should fall back to the latest track-upstream run URL before using the workflow definition"
);
assert.match(
  source,
  /const jobUrl = liveState\.trackUpstreamJobUrl \|\| fallbackUrl;/,
  "Component table should prefer the live track-upstream job URL"
);
assert.match(
  source,
  /const syncDurationSeconds = liveState\.trackUpstreamJobDurationSeconds \?\? trackRun\.duration_seconds;/,
  "Component table should use live or baked track-upstream duration"
);
assert.match(
  source,
  /workflowButtonHtml\(jobUrl, syncDurationSeconds, liveState\.trackUpstreamJobUrl \? "Upstream sync job" : "Upstream sync run", isUpstreamBuilding\)/,
  "Component table should render live or baked track-upstream links as duration-only buttons"
);
assert.match(source, /<th>Test duration<\/th>/, "Test matrix workflow type should move into the duration column heading");
assert.match(source, /<th>Sync duration<\/th>/, "Sync workflow type should move into the duration column heading");
assert.match(source, /<th>Build\/publish duration<\/th>/, "Build and publish workflow type should move into the duration column heading");
assert.match(source, /<h3 class="p-muted-heading">Publish and store<\/h3>/, "Snap package section should keep a muted category heading");
assert.doesNotMatch(source, /Installation availability/, "Snap package section should use channel-specific package heading text");
assert.match(source, /id="snap-packages-title">Stable channel snap packages<\/h2>/, "Snap package heading should default to stable channel package text");
assert.match(
  source,
  /snapPackagesTitle\.textContent = selectedBranch === "stable" \? "Stable channel snap packages" : "Edge channel snap packages";/,
  "Snap package heading should follow the selected channel"
);
assert.doesNotMatch(source, /#'\s*\+\s*trackRun\.run_number/, "Upstream tracking buttons must not show run numbers");
assert.doesNotMatch(source, /<span>\$\{[^}]*\}(?:Sync job|Sync run|Test job|Test run|Build job|Publish job|Build workflow|Publish workflow)<\/span>/, "Workflow button visible labels should be duration-only");
assert.match(
  source,
  /await applyLiveTrackUpstream\(latestByWorkflow\);/,
  "Live refresh must await track-upstream job lookup before rendering component links"
);
assert.match(
  source,
  /function componentStatusHtml\(item, currentLabel\)[\s\S]*liveStatusChip\(liveStatus, "checking"\)/,
  "Component status chips should show a live checking indicator while the upstream sync job is running"
);
assert.match(
  source,
  /liveState\.trackUpstreamJobStatus = status;/,
  "Track-upstream job status must be stored for component status rendering"
);
assert.match(
  source,
  /statusHtml = liveStatusChip\(status, isGitHub \? "building" : "publishing", true\);/,
  "Snap package table should use live build/publish indicators for active jobs"
);
assert.match(
  source,
  /const GITHUB_BUILD_ARCHES = new Set\(\["AMD64", "ARM64"\]\);/,
  "Snap package table must know which architectures are built on GitHub runners"
);
assert.match(
  source,
  /const isGitHub = GITHUB_BUILD_ARCHES\.has\(arch\);/,
  "Snap package table should choose GitHub versus Launchpad jobs from the architecture"
);
assert.match(
  source,
  /const workflowSnapshot = \(row\.workflow_runs \|\| \{\}\)\[selectedBranch\] \|\| \{\};/,
  "Snap package table should use baked per-architecture workflow metadata before live API refresh"
);
assert.match(
  source,
  /workflowSnapshot\.url \|\| "",\s*workflowSnapshot\.duration_seconds,/,
  "Snap package table should render baked workflow job URLs and durations"
);
assert.doesNotMatch(
  source,
  /const fallbackUrl = isGitHub[\s\S]*actions\/workflows\/cicd\.yml[\s\S]*actions\/workflows\/launchpad-builds\.yml[\s\S]*workflowButtonHtml\(fallbackUrl, null/,
  "Build/publish duration buttons must not fall back to workflow YAML URLs"
);
assert.match(
  source,
  /applyLiveSnapStatus\(cicdJobs, cicdRun, lpJobs, lpRun\);\s*let buildBuilding = false;/,
  "Snap package live overlay must run before other live dashboard sections can fail"
);
assert.match(
  source,
  /try \{\s*await applyLiveTrackUpstream\(latestByWorkflow\);[\s\S]*Keep the package table live even if upstream tracking rendering fails/,
  "Upstream tracking failures must not block snap package live overlays"
);
assert.match(
  source,
  /refreshLiveSnapPackageStatus\(\);/,
  "Snap package table should request its own live job overlay whenever the table renders"
);
assert.match(
  source,
  /async function refreshLiveSnapPackageStatus\(\)[\s\S]*fetchRecentRuns\(\)[\s\S]*fetchRunJobs\(latestLp\.id\)[\s\S]*applyLiveSnapStatus\(cicdJobs, cicdRun, lpJobs, lpRun\);/,
  "Independent snap package overlay must fetch live runs/jobs and apply status"
);
JS
    done
}

@test "frontend: live snap publish success preserves current store package details" {
    for html in "${HTML_FILES[@]}"; do
        run_node - "$html" <<'JS'
const fs = require("fs");
const source = fs.readFileSync(process.argv[2], "utf8");
const assert = require("assert");

// Assert targetVersion computation in renderSnapPackage
assert.match(
  source,
  /let targetVersion = "";[\s\S]*snapState\.targetVersion = targetVersion;/,
  "renderSnapPackage must compute and store snapState.targetVersion"
);

// Assert Serving status override on live success, without replacing Snap Store cells
assert.match(
  source,
  /status === "success"[\s\S]*Serving · \$\{selectedBranch\}/,
  "applyLiveSnapStatus must update status on live build success"
);
assert.doesNotMatch(source, /revisionCell\.textContent = "—";/, "Live snap overlay must not blank the store revision");
assert.doesNotMatch(source, /sizeCell\.textContent = "—";/, "Live snap overlay must not blank the store size");
assert.doesNotMatch(source, /versionCell\.textContent = snapState\.targetVersion;/, "Live snap overlay must not replace the currently served store version");
assert.doesNotMatch(source, /dateCell\.textContent = formatDate\(completionTime\);/, "Live snap overlay must not replace the store release date with workflow completion time");

// Assert same status override on live run success when job details are absent
assert.match(
  source,
  /run && run\.status === "completed" && run\.conclusion === "success"[\s\S]*Serving · \$\{selectedBranch\}/,
  "applyLiveSnapStatus must update status on live run success when job is absent"
);

// Assert track status override to "Up to date" on live publish success
assert.match(
  source,
  /isStableSuccessful[\s\S]*stable-track-status[\s\S]*Up to date/,
  "applyLiveSnapStatus must override stable track status to Up to date on live success"
);
assert.match(
  source,
  /isEdgeSuccessful[\s\S]*edge-track-status[\s\S]*Up to date/,
  "applyLiveSnapStatus must override edge track status to Up to date on live success"
);

// Assert component status override via isLivePublishSuccess()
assert.match(
  source,
  /function isLivePublishSuccess\(\)/,
  "isLivePublishSuccess must be defined"
);
assert.match(
  source,
  /if \(isLivePublishSuccess\(\)\)[\s\S]*Up to date/,
  "componentStatusHtml must return Up to date if live snap publish succeeded"
);
JS
    done
}

@test "frontend: release tracking upstream mismatches are pending cautions, not update failures" {
    for html in "${HTML_FILES[@]}"; do
        run_node - "$html" <<'JS'
const fs = require("fs");
const source = fs.readFileSync(process.argv[2], "utf8");
const assert = require("assert");

assert.match(
  source,
  /const pendingLabel = selectedBranch === "edge" \? "Dev commit pending" : "Stable commit pending";/,
  "Release tracking should label upstream mismatches by selected channel scope"
);
assert.match(
  source,
  /status-chip status-caution">\$\{warningIconSvg\}\$\{pendingLabel\}/,
  "Release tracking upstream mismatches should use caution styling and warning icon"
);
assert.doesNotMatch(
  source,
  /status-chip status-failure">\$\{errorIconSvg\}Update available/,
  "Release tracking must not present upstream tag lag as an installable update failure"
);
JS
    done
}

@test "frontend: freshnessDetail and freshnessStatus show retry clocks for fallback states" {
    for html in "${HTML_FILES[@]}"; do
        run_node - "$HELPER" "$html" <<'JS'
const { loadModule } = require(process.argv[2]);
const { freshnessDetail, freshnessStatus } = loadModule(process.argv[3], {
  consts: ["LIVE_POLL_MS_BUILDING", "LIVE_POLL_MS_IDLE", "LIVE_POLL_MS_BACKOFF"],
  functions: [
    "relativeTime",
    "countdownLabel",
    "nextHourBoundary",
    "fallbackFreshnessNextAt",
    "freshnessDetail",
    "freshnessStatus",
  ],
});
const assert = require("assert");

Date.now = () => new Date("2026-06-14T14:00:00Z").getTime();

global.freshnessState = {
  live: { updatedAt: "2026-06-14T14:00:00Z", nextAt: null, status: "paused" },
  snap: { updatedAt: null, nextAt: null, fromGist: false, source: "build-time snapshot" }
};

assert.strictEqual(freshnessDetail("live"), "paused");
assert.strictEqual(freshnessStatus("live"), "muted");

global.freshnessState.live = {
  updatedAt: "2026-06-14T13:55:00Z",
  nextAt: new Date("2026-06-14T14:15:00Z").getTime(),
  status: "stale",
};
assert.strictEqual(freshnessDetail("live"), "unavailable — using snapshot · next 15:00");
assert.strictEqual(freshnessStatus("live"), "stale");

global.freshnessState.live = {
  updatedAt: null,
  nextAt: new Date("2026-06-14T14:01:30Z").getTime(),
  status: "idle",
};
assert.strictEqual(freshnessDetail("live"), "connecting… · next 1:30");

global.freshnessState.live = {
  updatedAt: "2026-06-14T13:59:10Z",
  nextAt: null,
  status: "idle",
};
assert.strictEqual(freshnessDetail("live"), "updated 50s ago · next 10:00");

global.freshnessState.snap = {
  updatedAt: null,
  nextAt: new Date("2026-06-14T15:00:00Z").getTime(),
  fromGist: false,
  source: "build-time snapshot",
};
assert.strictEqual(freshnessDetail("snap"), "build-time snapshot · next 60:00");
JS
    done
}
