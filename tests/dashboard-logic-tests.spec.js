/**
 * JSDOM tests for pure JavaScript logic from dashboard.js
 *
 * These test functions that do pure data transformation (math, formatting,
 * string manipulation, status mapping) without touching the DOM.
 * They run in Node + JSDOM for speed, no browser needed.
 */
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const DASHBOARD_JS = resolve(__dirname, "../snap/local/assets/dashboard.js");

// Load the JS source and wrap constants/functions into a module
function loadDashboardAPI() {
  const src = readFileSync(DASHBOARD_JS, "utf8");

  // Strip the trailing initDashboard() call — the rest of the file just
  // declares constants and functions, which we can evaluate safely without
  // a DOM. (We only need the function definitions, not the bootstrap.)
  const stripped = src.replace(/\n\s*initDashboard\(\);\s*$/, "");

  const code = `"use strict";\n${stripped}\n`;

  const exports = [
    "escapeHtml",
    "formatDate",
    "formatBytes",
    "humanDuration",
    "relativeTime",
    "countdownLabel",
    "nextHourBoundary",
    "statusBadgeUrl",
    "trendPointColor",
    "trendTooltipDescriptor",
    "snapStatusDescriptor",
    "buildJobNamePrefixes",
    "findBuildJob",
    "normalizedLiveStatus",
    "liveStatusChip",
    "workflowButtonLabel",
    "workflowButtonHtml",
    "liveJobDurationSeconds",
    "liveRunDurationSeconds",
    "liveUpdateFrequencyDays",
    "githubCommitUrl",
    "upstreamCommitLinkHtml",
    "sourceVersionWithCommitHtml",
    "shouldApplySnapPayload",
    "mergeChannelSwitchData",
    "trackUpstreamJobFromJobs",
    "componentStatusHtml",
    "statusClass",
    "githubRunnerChipHtml",
    "formatDateWithTimezone",
    "scheduledCheckCountdownParts",
    "scheduledCheckLabel",
    "pluralizeUnit",
  ];

  const factory = new Function(`"use strict"; ${code}; return { ${exports.join(", ")} };`);
  return factory();
}

const api = loadDashboardAPI();

// ---------------------------------------------------------------------------
// escapeHtml
// ---------------------------------------------------------------------------
describe("escapeHtml", () => {
  it("escapes & < > \" '", () => {
    assert.equal(api.escapeHtml(`&<>"'"`), "&amp;&lt;&gt;&quot;&#39;&quot;");
  });
  it("passes through safe strings", () => {
    assert.equal(api.escapeHtml("hello world"), "hello world");
  });
  it("handles empty string", () => {
    assert.equal(api.escapeHtml(""), "");
  });
});

// ---------------------------------------------------------------------------
// formatDate
// ---------------------------------------------------------------------------
describe("formatDate", () => {
  it("returns Unknown for empty", () => {
    assert.equal(api.formatDate(""), "Unknown");
    assert.equal(api.formatDate(null), "Unknown");
    assert.equal(api.formatDate(undefined), "Unknown");
  });
  it("echoes unparseable strings", () => {
    assert.equal(api.formatDate("totally-bogus"), "totally-bogus");
  });
  it("formats valid ISO timestamps", () => {
    const rendered = api.formatDate("2026-06-11T12:23:15Z");
    assert.notEqual(rendered, "Unknown");
    assert.notEqual(rendered, "totally-bogus");
    assert(rendered.includes("2026"), `got ${rendered}`);
  });
});

// ---------------------------------------------------------------------------
// formatDateWithTimezone
// ---------------------------------------------------------------------------
describe("formatDateWithTimezone", () => {
  it("returns Unknown for empty", () => {
    assert.equal(api.formatDateWithTimezone(""), "Unknown");
    assert.equal(api.formatDateWithTimezone(null), "Unknown");
    assert.equal(api.formatDateWithTimezone(undefined), "Unknown");
  });
  it("includes a timezone abbreviation or offset", () => {
    const rendered = api.formatDateWithTimezone("2026-06-18T17:00:00Z");
    assert.notEqual(rendered, "Unknown");
    assert(rendered.includes("2026"), `got ${rendered}`);
    assert(rendered.length > 20, `Expected timezone in: ${rendered}`);
  });
});

// ---------------------------------------------------------------------------
// formatBytes
// ---------------------------------------------------------------------------
describe("formatBytes", () => {
  it("returns Unknown for missing", () => {
    assert.equal(api.formatBytes(undefined), "Unknown");
    assert.equal(api.formatBytes(null), "Unknown");
  });
  it("renders binary units", () => {
    assert.equal(api.formatBytes(0), "0 B");
    assert.equal(api.formatBytes(512), "512 B");
    assert.equal(api.formatBytes(1024), "1.0 KB");
    assert.equal(api.formatBytes(1536), "1.5 KB");
    assert.equal(api.formatBytes(1048576), "1.0 MB");
  });
});

// ---------------------------------------------------------------------------
// humanDuration
// ---------------------------------------------------------------------------
describe("humanDuration", () => {
  it("returns Unknown for null/undefined", () => {
    assert.equal(api.humanDuration(null), "Unknown");
    assert.equal(api.humanDuration(undefined), "Unknown");
  });
  it("formats seconds, minutes and hours", () => {
    assert.equal(api.humanDuration(0), "0s");
    assert.equal(api.humanDuration(45), "45s");
    assert.equal(api.humanDuration(90), "1m 30s");
    assert.equal(api.humanDuration(3661), "1h 1m");
  });
});

// ---------------------------------------------------------------------------
// relativeTime
// ---------------------------------------------------------------------------
describe("relativeTime", () => {
  it("returns unknown for empty/invalid", () => {
    assert.equal(api.relativeTime(""), "unknown");
    assert.equal(api.relativeTime(null), "unknown");
    assert.equal(api.relativeTime(undefined), "unknown");
    assert.equal(api.relativeTime("not-a-date"), "unknown");
  });
  it("formats relative time descriptions", () => {
    const now = Date.now();
    const iso = (msAgo) => new Date(now - msAgo).toISOString();
    assert.match(api.relativeTime(iso(5 * 1000)), /^\d+s ago$/);
    assert.match(api.relativeTime(iso(5 * 60 * 1000)), /^\d+m ago$/);
    assert.match(api.relativeTime(iso(3 * 60 * 60 * 1000)), /^\d+h ago$/);
    assert.match(api.relativeTime(iso(3 * 24 * 60 * 60 * 1000)), /^\d+d ago$/);
  });
});

// ---------------------------------------------------------------------------
// countdownLabel
// ---------------------------------------------------------------------------
describe("countdownLabel", () => {
  it("returns null for null input", () => {
    assert.equal(api.countdownLabel(null), null);
  });
  it("rounds up while waiting", () => {
    const realNow = Date.now;
    try {
      Date.now = () => 1_000_000;
      assert.equal(api.countdownLabel(1_000_000), "0:00");
    } finally {
      Date.now = realNow;
    }
  });
});

// ---------------------------------------------------------------------------
// scheduledCheckCountdownParts
// ---------------------------------------------------------------------------
describe("scheduledCheckCountdownParts", () => {
  it("returns null for falsy input", () => {
    assert.equal(api.scheduledCheckCountdownParts(null), null);
    assert.equal(api.scheduledCheckCountdownParts(undefined), null);
    assert.equal(api.scheduledCheckCountdownParts(0), null);
  });
  it("breaks duration into hours, minutes, and seconds", () => {
    const now = 1_000_000_000_000;
    const to = now + (5 * 3600 + 10 * 60 + 2) * 1000;
    const parts = api.scheduledCheckCountdownParts(to, now);
    assert.deepEqual(parts, { hours: 5, minutes: 10, seconds: 2 });
  });
  it("clamps expired timestamps to zero", () => {
    const now = 1_000_000_000_000;
    const parts = api.scheduledCheckCountdownParts(now - 1000, now);
    assert.deepEqual(parts, { hours: 0, minutes: 0, seconds: 0 });
  });
});

// ---------------------------------------------------------------------------
// pluralizeUnit
// ---------------------------------------------------------------------------
describe("pluralizeUnit", () => {
  it("uses singular for 1", () => {
    assert.equal(api.pluralizeUnit(1, "hour"), "1 hour");
    assert.equal(api.pluralizeUnit(1, "minute"), "1 minute");
    assert.equal(api.pluralizeUnit(1, "second"), "1 second");
  });
  it("uses plural for 0 or > 1", () => {
    assert.equal(api.pluralizeUnit(0, "hour"), "0 hours");
    assert.equal(api.pluralizeUnit(2, "minute"), "2 minutes");
    assert.equal(api.pluralizeUnit(5, "second"), "5 seconds");
  });
});

// ---------------------------------------------------------------------------
// scheduledCheckLabel
// ---------------------------------------------------------------------------
describe("scheduledCheckLabel", () => {
  it("returns Unknown when target is null", () => {
    assert.equal(api.scheduledCheckLabel(null), "Next scheduled auto-rebuild check: Unknown");
  });
  it("includes the countdown and timezone-bearing scheduled time", () => {
    const now = 1_000_000_000_000;
    const to = now + (5 * 3600 + 10 * 60 + 2) * 1000;
    const label = api.scheduledCheckLabel(to, now);
    const scheduledAt = api.formatDateWithTimezone(new Date(to).toISOString());

    assert(label.includes("In 5 hours, 10 minutes, and 2 seconds"), `got ${label}`);
    assert(label.includes("the next scheduled auto-rebuild check will occur, at"), `got ${label}`);
    assert(label.includes(scheduledAt), `got ${label}`);
  });
});

// ---------------------------------------------------------------------------
// nextHourBoundary
// ---------------------------------------------------------------------------
describe("nextHourBoundary", () => {
  it("targets the expected hourly boundary", () => {
    assert.equal(
      new Date(api.nextHourBoundary(Date.parse("2026-06-12T22:00:00Z"))).toISOString(),
      "2026-06-12T23:00:00.000Z",
    );
    assert.equal(
      new Date(api.nextHourBoundary(Date.parse("2026-06-12T22:59:59Z"))).toISOString(),
      "2026-06-12T23:00:00.000Z",
    );
  });
});

// ---------------------------------------------------------------------------
// statusBadgeUrl
// ---------------------------------------------------------------------------
describe("statusBadgeUrl", () => {
  it("treats cancelled as neutral, not a failure", () => {
    assert(api.statusBadgeUrl("failure").includes("status-failed-critical"));
    assert(api.statusBadgeUrl("timed_out").includes("status-failed-critical"));
    // Cancelled is not in FAILURE_STATES
    assert(!api.statusBadgeUrl("cancelled").includes("critical"));
    assert(!api.statusBadgeUrl("skipped").includes("critical"));
  });
  it("maps queued/waiting to lightgrey", () => {
    assert(api.statusBadgeUrl("queued").includes("lightgrey"));
    assert(api.statusBadgeUrl("waiting").includes("lightgrey"));
  });
  it("maps success to a green badge", () => {
    assert(api.statusBadgeUrl("success").includes("success"));
  });
});

// ---------------------------------------------------------------------------
// trendPointColor
// ---------------------------------------------------------------------------
describe("trendPointColor", () => {
  it("renders cancelled/skipped as neutral grey, not success green", () => {
    const GREEN = "#0e8420";
    const RED = "#c7162b";
    const GREY = "#757575";

    assert.equal(api.trendPointColor("success"), GREEN);
    assert.equal(api.trendPointColor("failure"), RED);

    // Cancelled and skipped are not build failures, so they must read as
    // neutral grey — never RED or GREEN.
    assert.equal(api.trendPointColor("cancelled"), GREY, "cancelled should be grey");
    assert.equal(api.trendPointColor("skipped"), GREY, "skipped should be grey");
  });
});

// ---------------------------------------------------------------------------
// trendTooltipDescriptor
// ---------------------------------------------------------------------------
describe("trendTooltipDescriptor", () => {
  it("styles cancelled runs as caution, never positive success", () => {
    const ok = api.trendTooltipDescriptor("success", false);
    assert.equal(ok.notificationClass, "p-notification--positive is-inline");
    assert.equal(ok.titlePrefix, "");

    const cancelled = api.trendTooltipDescriptor("cancelled", false);
    assert.equal(cancelled.notificationClass, "p-notification--caution is-inline");
    assert.equal(cancelled.titlePrefix, "Cancelled ");

    const skipped = api.trendTooltipDescriptor("skipped", false);
    assert.equal(skipped.notificationClass, "p-notification--caution is-inline");
    assert.equal(skipped.titlePrefix, "Skipped ");
  });
  it("flags suspiciously fast builds", () => {
    const fast = api.trendTooltipDescriptor("success", true);
    assert.equal(fast.titlePrefix, "Suspiciously Fast ");
    assert(fast.messageSuffix.includes("potential bypass"));
  });
});

// ---------------------------------------------------------------------------
// snapStatusDescriptor
// ---------------------------------------------------------------------------
describe("snapStatusDescriptor", () => {
  it("marks lagging store revisions as store lag, never failing", () => {
    const current = api.snapStatusDescriptor({
      build_status: "current",
      channel: "stable",
    });
    assert.equal(current.cls, "status-success");
    assert.equal(current.label, "Serving · stable");

    const stale = api.snapStatusDescriptor({
      build_status: "stale",
      channel: "edge",
    });
    assert(stale.cls !== "status-success", "stale should not be success");
    assert(!stale.label.includes("fail"), "stale should not mention failure");
  });
});

// ---------------------------------------------------------------------------
// buildJobNamePrefixes
// ---------------------------------------------------------------------------
describe("buildJobNamePrefixes", () => {
  it("is channel-aware for GitHub and Launchpad runners", () => {
    assert.deepEqual(api.buildJobNamePrefixes("AMD64", "edge", true), [
      "build github (edge, amd64)",
      "build github (amd64)",
    ]);
    assert.deepEqual(api.buildJobNamePrefixes("AMD64", "stable", false), [
      "build and publish launchpad (stable, amd64)",
      "build and publish launchpad (amd64)",
    ]);
  });
});

// ---------------------------------------------------------------------------
// workflowButtonLabel
// ---------------------------------------------------------------------------
describe("workflowButtonLabel", () => {
  it("returns Loading... for null/undefined", () => {
    assert.equal(api.workflowButtonLabel(null), "Loading...");
    assert.equal(api.workflowButtonLabel(undefined), "Loading...");
  });
  it("formats duration labels", () => {
    assert.equal(api.workflowButtonLabel(185), "3m 5s");
    assert.equal(api.workflowButtonLabel(3661), "1h 1m");
  });
});

// ---------------------------------------------------------------------------
// githubCommitUrl
// ---------------------------------------------------------------------------
describe("githubCommitUrl", () => {
  it("returns empty for missing repository or sha", () => {
    assert.equal(api.githubCommitUrl(null, null), "");
    assert.equal(api.githubCommitUrl({}, ""), "");
  });
  it("builds correct commit URLs", () => {
    const url = api.githubCommitUrl(
      { repository: "pi-hole/FTL" },
      "6a976208ae647c1f6b289c35db83b47533c17c5b",
    );
    assert.equal(
      url,
      "https://github.com/pi-hole/FTL/commit/6a976208ae647c1f6b289c35db83b47533c17c5b",
    );
  });
});

// ---------------------------------------------------------------------------
// trackUpstreamJobFromJobs
// ---------------------------------------------------------------------------
describe("trackUpstreamJobFromJobs", () => {
  it("prefers update-sources job", () => {
    const jobs = [
      { name: "setup", html_url: "https://example.test/setup" },
      {
        name: "update-sources",
        html_url: "https://example.test/update-sources",
      },
      { name: "update-tags", html_url: "https://example.test/update-tags" },
    ];
    assert.equal(
      api.trackUpstreamJobFromJobs(jobs).html_url,
      "https://example.test/update-sources",
    );
  });
  it("falls back to update-tags", () => {
    const jobs = [
      { name: "setup", html_url: "https://example.test/setup" },
      { name: "update-tags", html_url: "https://example.test/update-tags" },
    ];
    assert.equal(api.trackUpstreamJobFromJobs(jobs).html_url, "https://example.test/update-tags");
  });
  it("falls back to first job", () => {
    const jobs = [{ name: "random", html_url: "https://example.test/random" }];
    assert.equal(api.trackUpstreamJobFromJobs(jobs).html_url, "https://example.test/random");
  });
});

// ---------------------------------------------------------------------------
// shouldApplySnapPayload
// ---------------------------------------------------------------------------
describe("shouldApplySnapPayload", () => {
  it("older snap gist cannot override newer deployed snapshot", () => {
    const deployed = "2026-06-12T22:57:25Z";
    const olderGist = { generated_at: "2026-06-12T22:25:04Z" };
    const sameGist = { generated_at: deployed };
    const newerGist = { generated_at: "2026-06-12T23:05:00Z" };

    assert.equal(api.shouldApplySnapPayload(deployed, olderGist), false);
    assert.equal(api.shouldApplySnapPayload(deployed, sameGist), true);
    assert.equal(api.shouldApplySnapPayload(deployed, newerGist), true);
    assert.equal(api.shouldApplySnapPayload(null, olderGist), true);
    assert.equal(api.shouldApplySnapPayload(deployed, null), true);
    assert.equal(api.shouldApplySnapPayload("invalid-date", olderGist), true);
  });
});

// ---------------------------------------------------------------------------
// mergeChannelSwitchData
// ---------------------------------------------------------------------------
describe("mergeChannelSwitchData", () => {
  it("keeps existing evidence when a newer same-run payload has none", () => {
    const current = {
      run_id: 123,
      status: "success",
      rows: [
        {
          arch: "arm64",
          status: "success",
          duration_seconds: 59,
          evidence: [
            {
              title: "DNS query through local FTL",
              command: "dig +short @127.0.0.1 pi.hole",
              status: "success",
              output: "127.0.0.1",
            },
          ],
        },
      ],
    };
    const incoming = {
      run_id: 123,
      status: "success",
      rows: [
        {
          arch: "arm64",
          status: "success",
          duration_seconds: 89,
          evidence: [],
        },
      ],
    };

    const merged = api.mergeChannelSwitchData(current, incoming);

    assert.equal(merged.rows[0].duration_seconds, 89);
    assert.deepEqual(merged.rows[0].evidence, current.rows[0].evidence);
  });

  it("does not carry evidence across different channel-switch runs", () => {
    const current = {
      run_id: 123,
      rows: [
        {
          arch: "arm64",
          evidence: [{ title: "Old run", status: "success" }],
        },
      ],
    };
    const incoming = {
      run_id: 124,
      rows: [{ arch: "arm64", evidence: [] }],
    };

    const merged = api.mergeChannelSwitchData(current, incoming);

    assert.equal(merged.run_id, 124);
    assert.deepEqual(merged.rows[0].evidence, []);
  });
});

// ---------------------------------------------------------------------------
// liveJobDurationSeconds, liveRunDurationSeconds
// ---------------------------------------------------------------------------
describe("liveJobDurationSeconds", () => {
  it("returns null for missing data", () => {
    assert.equal(api.liveJobDurationSeconds(null), null);
    assert.equal(api.liveJobDurationSeconds({}), null);
    assert.equal(api.liveJobDurationSeconds({ started_at: null }), null);
    assert.equal(api.liveJobDurationSeconds({ started_at: "" }), null);
  });
  it("calculates duration from timestamps", () => {
    assert.equal(
      api.liveJobDurationSeconds({
        started_at: "2026-06-14T14:00:00Z",
        completed_at: "2026-06-14T14:03:05Z",
        status: "completed",
      }),
      185,
    );
  });
});

describe("liveRunDurationSeconds", () => {
  it("returns null for null input", () => {
    assert.equal(api.liveRunDurationSeconds(null), null);
  });
});

// ---------------------------------------------------------------------------
// statusClass
// ---------------------------------------------------------------------------
describe("statusClass", () => {
  it("maps statuses to CSS class targets", () => {
    assert.equal(api.statusClass("success"), "status-success");
    assert.equal(api.statusClass("failure"), "status-failure");
    assert.equal(api.statusClass("in_progress"), "status-in_progress");
    assert.equal(api.statusClass(null), "status-neutral");
    assert.equal(api.statusClass(undefined), "status-neutral");
  });
});

// ---------------------------------------------------------------------------
// normalizedLiveStatus
// ---------------------------------------------------------------------------
describe("normalizedLiveStatus", () => {
  it("maps completed runs to their conclusion", () => {
    assert.equal(
      api.normalizedLiveStatus({ status: "completed", conclusion: "success" }),
      "success",
    );
    assert.equal(
      api.normalizedLiveStatus({ status: "completed", conclusion: "failure" }),
      "failure",
    );
  });
  it("returns queued for pending runs", () => {
    assert.equal(api.normalizedLiveStatus({ status: "in_progress" }), "in_progress");
    assert.equal(api.normalizedLiveStatus(null), "");
  });
});
