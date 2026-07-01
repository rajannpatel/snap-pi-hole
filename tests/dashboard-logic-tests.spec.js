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
import { JSDOM } from "jsdom";

const __dirname = dirname(fileURLToPath(import.meta.url));
const DASHBOARD_JS = resolve(__dirname, "../snap/local/assets/dashboard.js");
const DASHBOARD_CHANNEL_SWITCH_JS = resolve(
  __dirname,
  "../snap/local/assets/dashboard-channel-switch.js",
);

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
    "durationTrendDescription",
    "trendPointColor",
    "trendTooltipDescriptor",
    "snapStatusDescriptor",
    "buildJobNamePrefixes",
    "findBuildJob",
    "normalizedLiveStatus",
    "liveStatusChip",
    "workflowButtonLabel",
    "workflowButtonHtml",
    "renderSecurity",
    "liveMatrixJobsAndRun",
    "applyLiveChannelSwitch",
    "shouldApplyLiveChannelSwitch",
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
    "__setGlobalDashboardData",
  ];

  const factory = new Function(
    `"use strict"; ${code}; function __setGlobalDashboardData(value) { globalDashboardData = value; } return { ${exports.join(", ")} };`,
  );
  return factory();
}

const api = loadDashboardAPI();

function withDashboardDocument(markup, callback) {
  const previousDocument = globalThis.document;
  const dom = new JSDOM(markup);
  globalThis.document = dom.window.document;
  try {
    callback(dom.window.document);
  } finally {
    if (previousDocument === undefined) {
      delete globalThis.document;
    } else {
      globalThis.document = previousDocument;
    }
  }
}

async function withDashboardDocumentAsync(markup, callback) {
  const previousDocument = globalThis.document;
  const dom = new JSDOM(markup);
  globalThis.document = dom.window.document;
  try {
    await callback(dom.window.document);
  } finally {
    if (previousDocument === undefined) {
      delete globalThis.document;
    } else {
      globalThis.document = previousDocument;
    }
  }
}

function loadChannelSwitchAPI() {
  const src = readFileSync(DASHBOARD_CHANNEL_SWITCH_JS, "utf8");
  const factory = new Function(
    `"use strict"; const root = {}; const module = { exports: {} }; ${src}; return module.exports;`,
  );
  return factory();
}

const channelSwitchApi = loadChannelSwitchAPI();

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
// durationTrendDescription
// ---------------------------------------------------------------------------
describe("durationTrendDescription", () => {
  it("summarizes the latest run and duration range", () => {
    const description = api.durationTrendDescription([
      {
        run_number: 102,
        duration_seconds: 90,
        duration_label: "1m 30s",
        conclusion: "success",
      },
      {
        run_number: 101,
        duration_seconds: 120,
        duration_label: "2m 0s",
        conclusion: "failure",
      },
    ]);

    assert.match(description, /Build duration trend chart with 2 recent runs/);
    assert.match(description, /Latest run #102 took 1m 30s/);
    assert.match(description, /Durations range from 1m 30s to 2m 0s/);
  });

  it("describes an empty chart without data", () => {
    assert.equal(
      api.durationTrendDescription([]),
      "Build duration trend chart. No duration data available.",
    );
  });

  it("mentions skipped runs when duration rows are absent", () => {
    assert.equal(
      api.durationTrendDescription([
        { run_number: 10, conclusion: "skipped", workflow_state: "skipped" },
      ]),
      "Build duration trend chart. 1 recent run was skipped.",
    );
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
  it("does not flag intentionally skipped work as suspiciously fast", () => {
    const skipped = api.trendTooltipDescriptor("success", true, {
      skipped_jobs: 3,
    });
    assert.equal(skipped.titlePrefix, "Skipped ");
    assert(skipped.messageSuffix.includes("skipped jobs"));
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
// findBuildJob
// ---------------------------------------------------------------------------
describe("findBuildJob", () => {
  it("returns null when no matching build/publish job exists (e.g. only lint run)", () => {
    const jobs = [{ name: "shellcheck + bats", status: "completed", conclusion: "success" }];
    assert.equal(api.findBuildJob(jobs, "amd64", "stable", true), null);
  });
  it("finds a matching build/publish job when it exists", () => {
    const jobs = [
      { name: "shellcheck + bats", status: "completed", conclusion: "success" },
      { name: "build github (stable, amd64)", status: "completed", conclusion: "success" },
    ];
    const found = api.findBuildJob(jobs, "amd64", "stable", true);
    assert.notEqual(found, null);
    assert.equal(found.name, "build github (stable, amd64)");
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
  it("labels explicit skipped and unavailable states without implying loading", () => {
    assert.equal(api.workflowButtonLabel(null, "skipped"), "Skipped");
    assert.equal(api.workflowButtonLabel(null, "no_data"), "No data");
    assert.equal(api.workflowButtonLabel(null, "unknown"), "Unavailable");
  });
  it("formats duration labels", () => {
    assert.equal(api.workflowButtonLabel(185), "3m 5s");
    assert.equal(api.workflowButtonLabel(3661), "1h 1m");
  });
});

describe("workflowButtonHtml", () => {
  it("renders skipped workflow links without a spinner", () => {
    const html = api.workflowButtonHtml(
      "https://example.test/run/1",
      null,
      "Build job",
      false,
      "skipped",
    );

    assert.match(html, /<a class="p-button workflow-btn"/);
    assert.match(html, />Skipped</);
    assert.doesNotMatch(html, /p-icon--spinner/);
    assert.match(html, /aria-label="Build job skipped"/);
  });

  it("renders unavailable workflow controls as disabled non-loading text", () => {
    const html = api.workflowButtonHtml("", null, "Test job", false, "no_data");

    assert.match(html, /<span class="p-button workflow-btn is-disabled"/);
    assert.match(html, /aria-disabled="true"/);
    assert.match(html, />No data</);
    assert.doesNotMatch(html, /p-icon--spinner/);
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

  it("keeps last known good channel-switch rows when incoming rows are empty", () => {
    const current = {
      run_id: 123,
      status: "success",
      rows: [
        {
          arch: "arm64",
          status: "success",
          duration_seconds: 59,
          evidence: [{ title: "DNS query through local FTL", status: "success" }],
        },
      ],
    };
    const incoming = {
      run_id: 124,
      status: "success",
      rows: [],
    };

    const merged = api.mergeChannelSwitchData(current, incoming);

    assert.equal(merged.run_id, 123);
    assert.deepEqual(merged.rows, current.rows);
  });
});

// ---------------------------------------------------------------------------
// channelSwitchEvidenceHtml
// ---------------------------------------------------------------------------
describe("channelSwitchEvidenceHtml", () => {
  it("shows success summary details when artifact evidence is unavailable", () => {
    const html = channelSwitchApi.channelSwitchEvidenceHtml({
      status: "success",
      summary: "stable r840 -> edge r838 -> stable r840",
      evidence: [],
    });

    assert.match(html, /Health checks passed/);
    assert.match(html, /stable r840 -&gt; edge r838 -&gt; stable r840/);
  });

  it("shows fallback summary details for success when summary is empty and evidence is unavailable", () => {
    const html = channelSwitchApi.channelSwitchEvidenceHtml({
      status: "success",
      path: "stable-to-edge",
      evidence: [],
    });

    assert.match(html, /Health checks passed/);
    assert.match(html, /stable -&gt; edge/);
  });

  it("shows success summary details when artifact evidence is available", () => {
    const html = channelSwitchApi.channelSwitchEvidenceHtml({
      status: "success",
      summary: "stable r840 -> edge r838 -> stable r840",
      evidence: [{ title: "Check 1", status: "success" }],
    });

    assert.match(html, /Health checks passed/);
    assert.match(html, /stable r840 -&gt; edge r838 -&gt; stable r840/);
    assert.match(html, /Check 1/);
  });
});

// ---------------------------------------------------------------------------
// channel revision chips
// ---------------------------------------------------------------------------
describe("channelRevisionChipHtml", () => {
  it("gives revision chips an accessible name", () => {
    const html = channelSwitchApi.channelRevisionChipHtml({
      channel: "stable",
      revision: "840",
    });

    assert.match(html, /aria-label="stable revision 840"/);
    assert.match(html, /aria-hidden="true">stable/);
    assert.match(html, /aria-hidden="true">r840/);
  });
});

// ---------------------------------------------------------------------------
// renderSecurity
// ---------------------------------------------------------------------------
describe("renderSecurity", () => {
  it("uses persisted summary totals for headline security metrics", () => {
    withDashboardDocument(
      `
        <span id="security-total-vulns"></span>
        <span id="security-confined-vulns"></span>
        <table><tbody id="security-arch-body"></tbody></table>
      `,
      (document) => {
        api.renderSecurity({
          total_vulnerabilities: 3,
          affected_packages: 2,
          raw_vulnerability_matches: 5,
          raw_affected_packages: 2,
          confined_mitigation_vulnerabilities: 4,
          architectures: [
            {
              channel: "stable",
              architecture: "amd64",
              affected_packages: 1,
              vulnerabilities: 1,
              raw_vulnerability_matches: 2,
              raw_affected_packages: 1,
              confined_mitigation_vulnerabilities: 1,
              report: "osv-amd64.json",
              generated_at: "2026-06-08T10:03:05Z",
            },
          ],
        });

        assert.equal(document.getElementById("security-total-vulns").textContent, "3");
        assert.equal(document.getElementById("security-confined-vulns").textContent, "4");
      },
    );
  });
});

describe("liveMatrixJobsAndRun", () => {
  it("skips completed runs where every distro job was skipped", async () => {
    const previousFetch = globalThis.fetch;
    const jobsByRun = {
      124: [
        {
          name: "distro test (ubuntu, stable) / Validate Snap Installation",
          status: "completed",
          conclusion: "skipped",
        },
      ],
      123: [
        {
          name: "distro test (ubuntu, stable) / Validate Snap Installation",
          status: "completed",
          conclusion: "success",
        },
      ],
    };
    globalThis.fetch = async (url) => {
      const runId = String(url).match(/actions\/runs\/(\d+)\/jobs/)?.[1];
      return {
        ok: true,
        headers: { get: () => "100" },
        json: async () => ({ jobs: jobsByRun[runId] || [] }),
      };
    };

    try {
      const result = await api.liveMatrixJobsAndRun([
        { id: 124, status: "completed", conclusion: "success" },
        { id: 123, status: "completed", conclusion: "success" },
      ]);

      assert.equal(result.run.id, 123);
      assert.equal(result.jobs[0].conclusion, "success");
    } finally {
      if (previousFetch === undefined) {
        delete globalThis.fetch;
      } else {
        globalThis.fetch = previousFetch;
      }
    }
  });

  it("continues past ten all-skipped distro runs to find live evidence", async () => {
    const previousFetch = globalThis.fetch;
    const skippedRuns = Array.from({ length: 10 }, (_, index) => ({
      id: 200 - index,
      status: "completed",
      conclusion: "success",
    }));
    const goodRun = { id: 123, status: "completed", conclusion: "success" };

    globalThis.fetch = async (url) => {
      const runId = String(url).match(/actions\/runs\/(\d+)\/jobs/)?.[1];
      const conclusion = runId === "123" ? "success" : "skipped";
      return {
        ok: true,
        headers: { get: () => "100" },
        json: async () => ({
          jobs: [
            {
              name: "distro test (ubuntu, stable) / Validate Snap Installation",
              status: "completed",
              conclusion,
            },
          ],
        }),
      };
    };

    try {
      const result = await api.liveMatrixJobsAndRun([...skippedRuns, goodRun]);

      assert.equal(result.run.id, 123);
      assert.equal(result.jobs[0].conclusion, "success");
    } finally {
      if (previousFetch === undefined) {
        delete globalThis.fetch;
      } else {
        globalThis.fetch = previousFetch;
      }
    }
  });
});

describe("shouldApplyLiveChannelSwitch", () => {
  it("keeps baked channel-switch evidence when a newer completed run has no durable evidence", () => {
    const snapshot = {
      run_id: 123,
      rows: [
        {
          arch: "arm64",
          evidence: [{ title: "DNS query through local FTL", status: "success" }],
        },
      ],
    };

    assert.equal(
      api.shouldApplyLiveChannelSwitch(snapshot, { id: 124, status: "completed" }, "success"),
      false,
    );
  });

  it("allows live channel-switch overlay for active or same-run updates", () => {
    const snapshot = {
      run_id: 123,
      rows: [{ arch: "arm64", evidence: [{ title: "Old run", status: "success" }] }],
    };

    assert.equal(
      api.shouldApplyLiveChannelSwitch(snapshot, { id: 124, status: "in_progress" }, "in_progress"),
      true,
    );
    assert.equal(
      api.shouldApplyLiveChannelSwitch(snapshot, { id: 123, status: "completed" }, "success"),
      true,
    );
  });
});

describe("applyLiveChannelSwitch", () => {
  it("restores baked evidence when an active no-evidence run completes without durable details", async () => {
    const previousFetch = globalThis.fetch;
    const previousChannelSwitch = globalThis.DashboardChannelSwitch;
    const snapshot = {
      run_id: 123,
      status: "success",
      updated_at: "2026-06-08T10:03:05Z",
      rows: [
        {
          arch: "arm64",
          status: "success",
          path: "roundtrip",
          updated_at: "2026-06-08T10:03:05Z",
          duration_seconds: 59,
          url: "https://example.test/channel-switch-good",
          evidence: [{ title: "DNS query through local FTL", status: "success" }],
        },
      ],
    };
    let fetchCount = 0;

    globalThis.DashboardChannelSwitch = channelSwitchApi;
    globalThis.fetch = async () => {
      fetchCount += 1;
      const active = fetchCount === 1;
      return {
        ok: true,
        headers: { get: () => "100" },
        json: async () => ({
          jobs: [
            {
              name: "channel switch smoke test (arm64)",
              status: active ? "in_progress" : "completed",
              conclusion: active ? null : "success",
              started_at: "2026-06-08T11:00:00Z",
              completed_at: active ? null : "2026-06-08T11:03:05Z",
              html_url: "https://example.test/channel-switch-new",
            },
          ],
        }),
      };
    };

    try {
      await withDashboardDocumentAsync(
        `
          <ul id="channel-switch-timeline"></ul>
          <p id="channel-switch-summary"></p>
          <table><tbody id="channel-switch-matrix-body"></tbody></table>
        `,
        async (document) => {
          api.__setGlobalDashboardData({ channel_switch: snapshot });

          await api.applyLiveChannelSwitch({
            "channel-switch.yml": {
              id: 124,
              status: "in_progress",
              head_branch: "main",
              updated_at: "2026-06-08T11:00:00Z",
              html_url: "https://example.test/channel-switch-new",
            },
          });
          assert.doesNotMatch(
            document.getElementById("channel-switch-matrix-body").textContent,
            /DNS query through local FTL/,
          );

          await api.applyLiveChannelSwitch({
            "channel-switch.yml": {
              id: 124,
              status: "completed",
              conclusion: "success",
              head_branch: "main",
              updated_at: "2026-06-08T11:03:05Z",
              html_url: "https://example.test/channel-switch-new",
            },
          });

          assert.match(
            document.getElementById("channel-switch-matrix-body").textContent,
            /DNS query through local FTL/,
          );
        },
      );
    } finally {
      api.__setGlobalDashboardData(null);
      if (previousFetch === undefined) {
        delete globalThis.fetch;
      } else {
        globalThis.fetch = previousFetch;
      }
      if (previousChannelSwitch === undefined) {
        delete globalThis.DashboardChannelSwitch;
      } else {
        globalThis.DashboardChannelSwitch = previousChannelSwitch;
      }
    }
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
// generated status chip accessibility
// ---------------------------------------------------------------------------
describe("generated status chip accessibility", () => {
  it("labels component status chips and hides decorative icon text", () => {
    const pending = api.componentStatusHtml({ update_available: true });
    assert.match(pending, /aria-label="Status: Stable commit pending"/);
    assert.match(pending, /aria-hidden="true"/);

    const behind = api.componentStatusHtml({ lag_days: 3 });
    assert.match(behind, /aria-label="Status: 3 days behind"/);
    assert.match(behind, /aria-hidden="true">3d behind/);
  });

  it("labels the GitHub runner builder chip", () => {
    const html = api.githubRunnerChipHtml();
    assert.match(html, /aria-label="Builder: GitHub runner"/);
    assert.match(html, /aria-hidden="true">GitHub runner/);
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
