// 1. CONFIGURATION & STATE
const REPO_SLUG = "rajannpatel/snap-pi-hole";
const GITHUB_API_BASE = "https://api.github.com";
const GITHUB_BUILD_ARCHES = new Set(["AMD64", "ARM64"]);

// Build/job pipeline status categories
const BUILDING_STATES = new Set([
  "queued",
  "in_progress",
  "requested",
  "waiting",
  "pending",
  "running",
]);
const FAILURE_STATES = new Set(["failure", "timed_out", "action_required", "startup_failure"]);
const isBuildingStatus = (status) => BUILDING_STATES.has(status);

// Live API polling parameters
const LIVE_POLL_MS_BUILDING = 60000;
const LIVE_POLL_MS_IDLE = 600000;
const LIVE_POLL_MS_BACKOFF = 900000;
const LIVE_RATE_FLOOR = 8;

// Core live application state variables
const liveState = {
  rateRemaining: null,
  pollTimer: null,
  releaseLagDone: false,
  releaseLagDue: false,
  lastCicdRunId: null,
  lastLpRunId: null,
  lastChannelSwitchRunId: null,
  lastChannelSwitchRunUpdatedAt: null,
  channelSwitchJobs: null,
  trackUpstreamRunId: null,
  trackUpstreamJobUrl: null,
  trackUpstreamJobDurationSeconds: null,
  trackUpstreamJobStatus: null,
  cicdJobs: null,
  cicdRun: null,
  lpJobs: null,
  lpRun: null,
  snapOverlayInFlight: false,
  snapOverlayLastFetch: 0,
};
const matrixState = { rows: [], failedLinks: [] };

// Snap Store Gist integration (workaround for lack of CORS support on api.snapcraft.io)
const SNAP_GIST_FILENAME = "snapcraft-dashboard-data.json";
const SNAP_GIST_DESCRIPTION = "snap-pi-hole dashboard data (auto-updated hourly; do not edit)";
const SNAP_MIN_REFETCH_MS = 300000;
const SNAP_OVERLAY_MIN_REFETCH_MS = 30000;
const snapState = {
  gistId: null,
  rawUrl: null,
  discovered: false,
  hasGistData: false,
  generatedAt: null,
  lastFetch: 0,
  nextAt: null,
  inFlight: false,
  snapPackage: null,
};

// Freshness clocks state tracking
const freshnessState = {
  live: { updatedAt: null, nextAt: null, status: "idle" },
  snap: {
    updatedAt: null,
    nextAt: null,
    fromGist: false,
    source: "build-time snapshot",
  },
  build: { updatedAt: null },
};
const activityState = {
  upstream: "Loading...",
  build: "Loading...",
  store: "Loading...",
  install: "Loading...",
};
let freshnessTimer = null;
let dependencyRows = [];
let durationTrendResizeHandler = null;
let releaseTrackingNextCheckMs = null;

// Brand design assets
const osBadgeByFamily = {
  Ubuntu: "https://img.shields.io/badge/-%20-E95420?style=flat-square&logo=ubuntu&logoColor=white",
  Debian: "https://img.shields.io/badge/-%20-A81D33?style=flat-square&logo=debian&logoColor=white",
  Fedora: "https://img.shields.io/badge/-%20-3C6EB4?style=flat-square&logo=fedora&logoColor=white",
  Rocky:
    "https://img.shields.io/badge/-%20-10B981?style=flat-square&logo=rockylinux&logoColor=white",
  AlmaLinux:
    "https://img.shields.io/badge/-%20-F43F5E?style=flat-square&logo=almalinux&logoColor=white",
  openSUSE:
    "https://img.shields.io/badge/-%20-73BA25?style=flat-square&logo=opensuse&logoColor=white",
  Arch: "https://img.shields.io/badge/-%20-1793D1?style=flat-square&logo=archlinux&logoColor=white",
};

const githubLogoSvg = `<svg class="status-chip-logo" viewBox="0 0 16 16" width="12" height="12" fill="currentColor"><path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27s1.36.09 2 .27c1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.01 8.01 0 0 0 16 8c0-4.42-3.58-8-8-8"/></svg>`;
const launchpadLogoSvg = `<svg class="status-chip-logo" viewBox="0 0 24 24" width="12" height="12" fill="currentColor"><path d="M1.518 7.088 2.68 5.351c.107-.158.175-.162.293-.106 2.556 1.476 4.848 1.685 7.212.662 2.35-1.019 3.763-2.82 4.445-5.659.072-.256.166-.254.231-.245l2.03.44c.343.086.33.18.322.25-.45 3.328-2.755 6.251-6.019 7.632-3.317 1.426-6.92 1.112-9.64-.84-.056-.048-.182-.177-.032-.397h-.003Zm10.115 16.798 2.081.114c.35.006.36-.087.369-.156.45-3.328-.999-6.758-3.779-8.953-2.82-2.256-6.378-2.91-9.519-1.749-.065.033-.222.123-.136.373l.659 1.984c.063.18.125.202.254.179 2.855-.744 5.12-.339 7.128 1.275 1.996 1.606 2.88 3.716 2.784 6.644.003.258.093.281.158.29l.001-.001Zm1.335-13.868a2.04 2.04 0 0 0-.28-.02c-.422 0-.82.132-1.146.38a1.907 1.907 0 0 0-.725 1.28c-.07.508.06 1.01.362 1.411.305.407.759.67 1.277.74a1.915 1.915 0 0 0 2.15-1.64 1.892 1.892 0 0 0-1.64-2.152l.002.001ZM23.36 6.525l-.966-1.85c-.137-.304-.247-.274-.36-.236-3.089 1.332-5.22 4.26-5.703 7.838-.483 3.58.797 6.973 3.426 9.075.059.052.117.07.182.065a.3.3 0 0 0 .2-.109l1.358-1.628c.125-.157.071-.238.006-.306-2.13-2.096-2.926-4.18-2.58-6.748.349-2.583 1.71-4.433 4.286-5.827.204-.123.17-.228.151-.276v.002Z"/></svg>`;
const checkIconSvg = `<svg class="status-chip-logo" viewBox="0 0 16 16" width="12" height="12" fill="currentColor"><path d="M13.78 4.22a.75.75 0 0 1 0 1.06l-7.25 7.25a.75.75 0 0 1-1.06 0L2.22 9.28a.75.75 0 0 1 1.06-1.06L6 10.94l6.72-6.72a.75.75 0 0 1 1.06 0z"/></svg>`;
const warningIconSvg = `<svg class="status-chip-logo" viewBox="0 0 16 16" width="12" height="12" fill="currentColor"><path d="M8 15A7 7 0 1 1 8 1a7 7 0 0 1 0 14zm0 1A8 8 0 1 0 8 0a8 8 0 0 0 0 16z"/><path d="M7.002 11a1 1 0 1 1 2 0 1 1 0 0 1-2 0zM7.1 4.995a.905.905 0 1 1 1.8 0l-.35 3.5a.552.552 0 0 1-1.1 0l-.35-3.5z"/></svg>`;
const errorIconSvg = `<svg class="status-chip-logo" viewBox="0 0 16 16" width="12" height="12" fill="currentColor"><path d="M4.646 4.646a.5.5 0 0 1 .708 0L8 7.293l2.646-2.647a.5.5 0 0 1 .708.708L8.707 8l2.647 2.646a.5.5 0 0 1-.708.708L8 8.707l-2.646 2.647a.5.5 0 0 1-.708-.708L7.293 8 4.646 5.354a.5.5 0 0 1 0-.708z"/></svg>`;
const clockIconSvg = `<svg class="status-chip-logo" viewBox="0 0 16 16" width="12" height="12" fill="currentColor"><path d="M8 15A7 7 0 1 1 8 1a7 7 0 0 1 0 14zm0 1A8 8 0 1 0 8 0a8 8 0 0 0 0 16z"/><path d="M8 3.5a.75.75 0 0 1 .75.75v3.25h3.25a.75.75 0 0 1 0 1.5h-4a.75.75 0 0 1-.75-.75v-4A.75.75 0 0 1 8 3.5z"/></svg>`;
const skippedIconSvg = `<svg class="status-chip-logo" viewBox="0 0 16 16" width="12" height="12" fill="currentColor"><path d="M8 15A7 7 0 1 1 8 1a7 7 0 0 1 0 14zm0 1A8 8 0 1 0 8 0a8 8 0 0 0 0 16z"/><path d="M4.25 7.25h7.5a.75.75 0 0 1 0 1.5h-7.5a.75.75 0 0 1 0-1.5z"/></svg>`;
const cpuIconSvg = `<svg class="status-chip-logo" viewBox="0 0 16 16" width="12" height="12" fill="none" stroke="currentColor" stroke-width="1" stroke-linecap="round" stroke-linejoin="round"><rect x="4" y="5" width="8" height="6" rx="0.5"/><line x1="6" y1="3" x2="6" y2="5"/><line x1="10" y1="3" x2="10" y2="5"/><line x1="6" y1="11" x2="6" y2="13"/><line x1="10" y1="11" x2="10" y2="13"/></svg>`;

// Resolves appropriate status logo SVG icon based on status string
function statusIconSvg(status) {
  const normalized = (status || "unknown").toLowerCase();
  if (normalized === "success") {
    return checkIconSvg;
  }
  if (FAILURE_STATES.has(normalized)) {
    return errorIconSvg;
  }
  if (BUILDING_STATES.has(normalized) || normalized === "building") {
    return clockIconSvg;
  }
  if (normalized === "skipped" || normalized === "cancelled") {
    return skippedIconSvg;
  }
  return warningIconSvg;
}

// 2. FORMATTING & UTILITY HELPERS

function escapeHtml(value) {
  return String(value).replace(
    /[&<>"']/g,
    (ch) =>
      ({
        "&": "&amp;",
        "<": "&lt;",
        ">": "&gt;",
        '"': "&quot;",
        "'": "&#39;",
      })[ch],
  );
}

// Maps API status values to CSS class targets
const statusClass = (status) =>
  `status-${(status || "neutral").replace(/[^a-z_]/gi, "_").toLowerCase()}`;

// Translates date strings into formatted local dates/times
function formatDate(value) {
  if (!value) return "Unknown";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return `${date.toLocaleDateString()} ${date.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}`;
}

// Translates date strings into formatted local dates/times with timezone
function formatDateWithTimezone(value) {
  if (!value) return "Unknown";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return `${date.toLocaleDateString()} ${date.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", timeZoneName: "short" })}`;
}

// Breaks a future event timestamp into hours, minutes and seconds remaining
function scheduledCheckCountdownParts(toMs, nowMs = Date.now()) {
  if (!toMs) return null;
  const totalSeconds = Math.max(0, Math.ceil((toMs - nowMs) / 1000));
  return {
    hours: Math.floor(totalSeconds / 3600),
    minutes: Math.floor((totalSeconds % 3600) / 60),
    seconds: totalSeconds % 60,
  };
}

// Pluralises a unit word (e.g. "1 hour" vs "2 hours")
function pluralizeUnit(value, unit) {
  return `${value} ${unit}${value === 1 ? "" : "s"}`;
}

// Builds a countdown sentence for the next scheduled auto-rebuild check
function scheduledCheckLabel(toMs, nowMs = Date.now()) {
  const parts = scheduledCheckCountdownParts(toMs, nowMs);
  if (!parts) return "Next scheduled auto-rebuild check: Unknown";
  const scheduledAt = formatDateWithTimezone(new Date(toMs).toISOString());
  return `In ${pluralizeUnit(parts.hours, "hour")}, ${pluralizeUnit(parts.minutes, "minute")}, and ${pluralizeUnit(parts.seconds, "second")}, the next scheduled auto-rebuild check will occur, at ${scheduledAt}.`;
}

// Translates integer bytes into binary unit labels
function formatBytes(bytes) {
  if (!bytes && bytes !== 0) return "Unknown";
  const units = ["B", "KB", "MB", "GB"];
  let size = bytes;
  let index = 0;
  while (size >= 1024 && index < units.length - 1) {
    size /= 1024;
    index += 1;
  }
  return `${size.toFixed(index === 0 ? 0 : 1)} ${units[index]}`;
}

// Converts seconds to human-readable duration strings
function humanDuration(seconds) {
  if (seconds === null || seconds === undefined) return "Unknown";
  if (seconds < 60) return `${seconds}s`;
  const minutes = Math.floor(seconds / 60);
  const secs = seconds % 60;
  if (minutes < 60) return `${minutes}m ${secs}s`;
  const hours = Math.floor(minutes / 60);
  const mins = minutes % 60;
  return `${hours}h ${mins}m`;
}

// Safely sets textContent of an element if it exists
function setText(id, value) {
  const node = document.getElementById(id);
  if (node) node.textContent = value;
}

// Maps build conclusions to graph node fill colors
function trendPointColor(conclusion) {
  const normalized = String(conclusion || "").toLowerCase();
  if (normalized === "success") return "#0e8420";
  if (FAILURE_STATES.has(normalized)) return "#c7162b";
  if (normalized === "cancelled" || normalized === "skipped") return "#757575";
  return "#0b6bc5";
}

// Maps a build conclusion to its trend tooltip styling, title prefix and
// message suffix. A cancelled or skipped run produced no new build, so it
// must read as a neutral caution, never the green "positive" success style.
function trendTooltipDescriptor(conclusion, isSuspiciouslyFast) {
  const normalized = String(conclusion || "unknown").toLowerCase();
  if (FAILURE_STATES.has(normalized)) {
    return {
      notificationClass: "p-notification--negative is-inline",
      titlePrefix: "Failed ",
      messageSuffix: "",
    };
  }
  if (normalized === "cancelled" || normalized === "skipped") {
    const titlePrefix = normalized === "cancelled" ? "Cancelled " : "Skipped ";
    return {
      notificationClass: "p-notification--caution is-inline",
      titlePrefix,
      messageSuffix: "",
    };
  }
  if (normalized === "success") {
    if (isSuspiciouslyFast) {
      return {
        notificationClass: "p-notification--caution is-inline",
        titlePrefix: "Suspiciously Fast ",
        messageSuffix: " (potential bypass)",
      };
    }
    return {
      notificationClass: "p-notification--positive is-inline",
      titlePrefix: "",
      messageSuffix: "",
    };
  }
  return {
    notificationClass: "p-notification--caution is-inline",
    titlePrefix: `${normalized.replace(/_/g, " ")} `,
    messageSuffix: "",
  };
}

// Calculates run duration in seconds
function liveRunDurationSeconds(run) {
  if (!run) return null;
  const started = new Date(run.run_started_at || run.created_at);
  const ended = run.status === "completed" ? new Date(run.updated_at) : new Date(Date.now());
  if (Number.isNaN(started.getTime()) || Number.isNaN(ended.getTime())) return null;
  return Math.max(0, Math.round((ended - started) / 1000));
}

// Computes the average days between recent completed main-branch push runs
function liveUpdateFrequencyDays(cicdRuns) {
  const times = cicdRuns
    .filter((run) => run.event === "push" && run.status === "completed")
    .slice(0, 12)
    .map((run) => new Date(run.updated_at).getTime())
    .filter((value) => !Number.isNaN(value))
    .sort((a, b) => b - a);
  if (times.length < 2) return null;
  let total = 0;
  for (let i = 0; i < times.length - 1; i += 1) {
    total += (times[i] - times[i + 1]) / 86400000;
  }
  return Math.round((total / (times.length - 1)) * 100) / 100;
}

// Calculates job duration in seconds
function jobDurationSeconds(job) {
  const started = new Date(job.started_at);
  const ended = new Date(job.completed_at);
  if (Number.isNaN(started.getTime()) || Number.isNaN(ended.getTime())) return null;
  return Math.max(0, Math.round((ended - started) / 1000));
}

// Calculates job duration for completed jobs, or elapsed runtime for active jobs
function liveJobDurationSeconds(job) {
  if (!job || !job.started_at) return null;
  const started = new Date(job.started_at);
  const ended = job.completed_at ? new Date(job.completed_at) : new Date(Date.now());
  if (Number.isNaN(started.getTime()) || Number.isNaN(ended.getTime())) return null;
  return Math.max(0, Math.round((ended - started) / 1000));
}

function workflowButtonLabel(durationSeconds) {
  if (durationSeconds === null || durationSeconds === undefined) return "Loading...";
  return humanDuration(durationSeconds);
}

function workflowButtonHtml(url, durationSeconds, contextLabel, isBuilding = false) {
  const showSpinner = isBuilding || durationSeconds === null || durationSeconds === undefined;
  const spinnerHtml = `<i class="p-icon--spinner u-animation--spin" aria-hidden="true"></i>`;

  let contentHtml;
  let accessibleLabel;
  let dataAttrs = "";

  if (showSpinner) {
    if (durationSeconds !== null && durationSeconds !== undefined) {
      const durationLabel = humanDuration(durationSeconds);
      contentHtml = `${githubLogoSvg}${spinnerHtml}<span class="workflow-btn__label">${escapeHtml(durationLabel)}</span>`;
      accessibleLabel = `${contextLabel || "Workflow"} active, duration: ${durationLabel}`;
      const startTime = Date.now() - durationSeconds * 1000;
      dataAttrs = ` data-start-time="${startTime}" data-context-label="${escapeHtml(contextLabel || "Workflow")}"`;
    } else {
      contentHtml = `${githubLogoSvg}${spinnerHtml}<span class="workflow-btn__label">&#8203;</span>`;
      accessibleLabel = `${contextLabel || "Workflow"} loading`;
    }
  } else {
    const durationLabel = humanDuration(durationSeconds);
    contentHtml = `${githubLogoSvg}<span class="workflow-btn__label">${escapeHtml(durationLabel)}</span>`;
    accessibleLabel = `${contextLabel || "Workflow"} duration: ${durationLabel}`;
  }

  if (!url) {
    return `<div class="workflow-buttons"><span class="p-button workflow-btn is-disabled"${dataAttrs} aria-disabled="true" aria-label="${escapeHtml(accessibleLabel)}" title="${escapeHtml(accessibleLabel)}">${contentHtml}</span></div>`;
  }
  return `<div class="workflow-buttons"><a class="p-button workflow-btn"${dataAttrs} href="${escapeHtml(url)}" target="_blank" rel="noopener noreferrer" aria-label="${escapeHtml(accessibleLabel)}" title="${escapeHtml(accessibleLabel)}">${contentHtml}</a></div>`;
}

function normalizedLiveStatus(jobOrRun) {
  if (!jobOrRun) return "";
  return jobOrRun.status === "completed"
    ? jobOrRun.conclusion || "unknown"
    : jobOrRun.status || "queued";
}

function liveStatusChip(status, buildingLabel) {
  const normalized = String(status || "unknown").toLowerCase();
  const text = normalized.replace(/_/g, " ");
  if (isBuildingStatus(normalized)) {
    const label = buildingLabel || "building";
    return `<span class="status-chip status-building is-building" aria-label="Status: ${label}">${statusIconSvg("building")}<span class="status-text-full" aria-hidden="true">${label}</span><span class="status-text-short" aria-hidden="true">${label}</span></span>`;
  }
  return `<span class="status-chip ${statusClass(normalized)}" aria-label="Status: ${text}">${statusIconSvg(normalized)}<span class="status-text-full" aria-hidden="true">${text}</span><span class="status-text-short" aria-hidden="true">${text}</span></span>`;
}

function selectedChannelLabel() {
  return selectedBranch === "edge" ? "edge" : "stable";
}

function updateChannelScopeSummary() {
  const label = selectedChannelLabel();
  const summary =
    label === "edge"
      ? "Viewing edge: upstream development commits, edge Snap Store publication, and edge install tests."
      : "Viewing stable: upstream stable branch commits, stable Snap Store publication, and stable install tests.";
  setText("channel-scope-summary", summary);

  const descEl = document.getElementById("components-section-desc");
  if (descEl) {
    descEl.textContent =
      label === "edge"
        ? "Bundled FTL, Core, and Web sources compared with the latest upstream development commits (development-v6 branch). The edge channel builds and rolls out automatically on every commit."
        : "Bundled FTL, Core, and Web sources compared with the latest upstream stable branch commits. Release tags are shown as version labels, but stable packaging follows the upstream branch head.";
  }
}

function renderCurrentActivity() {
  const container = document.getElementById("current-activity");
  if (!container) return;
  const items = [
    ["Pi-hole Components", activityState.upstream],
    ["Build", activityState.build],
    ["Store", activityState.store],
    ["Install", activityState.install],
  ];
  container.innerHTML = "";
  items.forEach(([label, value]) => {
    const item = document.createElement("div");
    const labelEl = document.createElement("span");
    const valueEl = document.createElement("span");
    item.className = "activity-item";
    labelEl.className = "activity-item__label";
    valueEl.className = "activity-item__value";
    labelEl.textContent = label;
    valueEl.textContent = value || "Unknown";
    item.appendChild(labelEl);
    item.appendChild(valueEl);
    container.appendChild(item);
  });
}

function updateUpstreamActivity() {
  const label = selectedChannelLabel();
  const rows =
    label === "edge"
      ? globalDashboardData?.auto_update?.edge_releases || []
      : dependencyRows.length
        ? dependencyRows
        : globalDashboardData?.release_info?.components || [];
  if (!rows.length) {
    activityState.upstream = "No upstream data";
  } else {
    const pending = rows.filter((row) => row.update_available).length;
    if (label === "edge") {
      activityState.upstream = pending
        ? `${pending} dev commit${pending === 1 ? "" : "s"} pending`
        : "Up to date with dev commits";
    } else {
      activityState.upstream = pending
        ? `${pending} stable commit${pending === 1 ? "" : "s"} pending`
        : "Up to date with stable branch";
    }
  }
  renderCurrentActivity();
}

function updateBuildActivity(buildStatus) {
  const latest = (buildStatus || {}).latest_run || {};
  if (!latest.number) {
    activityState.build = "No run data";
  } else if (isBuildingStatus(latest.status)) {
    activityState.build = `Run #${latest.number} building (${latest.duration_label || "0s"})`;
  } else {
    activityState.build = `Run #${latest.number} ${latest.status || "unknown"}`;
  }
  renderCurrentActivity();
}

function updateInstallActivity(rows) {
  const matrixRows = rows || matrixState.rows || [];
  if (!matrixRows.length) {
    activityState.install = "No test data";
  } else {
    const building = matrixRows.filter((row) => isBuildingStatus(row.status)).length;
    const failed = matrixRows.filter((row) => FAILURE_STATES.has(row.status)).length;
    const passed = matrixRows.filter((row) => row.status === "success").length;
    if (building) {
      activityState.install = `${building} test${building === 1 ? "" : "s"} running`;
    } else if (failed) {
      activityState.install = `${failed} failing, ${passed} passing`;
    } else {
      activityState.install = `${passed}/${matrixRows.length} passing`;
    }
  }
  renderCurrentActivity();
}

function updateStoreActivity(snapPackage) {
  const rows = (snapPackage || {}).channels || [];
  if (!rows.length) {
    activityState.store = "No store data";
  } else {
    const lagging = rows.filter((row) => row.build_status !== "current").length;
    activityState.store = lagging
      ? `${lagging} architecture${lagging === 1 ? "" : "s"} store lag`
      : "Serving all architectures";
  }
  renderCurrentActivity();
}

function buildJobNamePrefixes(arch, channel, isGitHub) {
  const normalizedArch = String(arch || "").toLowerCase();
  const normalizedChannel = String(channel || "stable").toLowerCase();
  if (isGitHub) {
    return [
      `build github (${normalizedChannel}, ${normalizedArch})`,
      `build github (${normalizedArch})`,
    ];
  }
  return [
    `build and publish launchpad (${normalizedChannel}, ${normalizedArch})`,
    `build and publish launchpad (${normalizedArch})`,
  ];
}

function findBuildJob(jobs, arch, channel, isGitHub) {
  if (!jobs || !jobs.length) return null;
  const normalizedArch = String(arch || "").toLowerCase();
  const normalizedChannel = String(channel || "stable").toLowerCase();
  const buildingStates =
    typeof BUILDING_STATES !== "undefined"
      ? BUILDING_STATES
      : new Set(["queued", "in_progress", "requested", "waiting", "pending", "running"]);

  if (isGitHub) {
    const stages = [
      `publish github (${normalizedChannel}, ${normalizedArch})`,
      `publish github (${normalizedArch})`,
      `smoke test (${normalizedChannel}, ${normalizedArch})`,
      `smoke test (${normalizedArch})`,
      `build github (${normalizedChannel}, ${normalizedArch})`,
      `build github (${normalizedArch})`,
    ];

    // 1. Try to find an active job in progress
    for (const stage of stages) {
      const found = jobs.find((job) => {
        const name = String(job.name || "").toLowerCase();
        return name.startsWith(stage) && buildingStates.has((job.status || "").toLowerCase());
      });
      if (found) return found;
    }

    // 2. Fallback to the latest stage that has run
    for (const stage of stages) {
      const found = jobs.find((job) => {
        const name = String(job.name || "").toLowerCase();
        return name.startsWith(stage);
      });
      if (found) return found;
    }

    return null;
  } else {
    const prefixes = buildJobNamePrefixes(arch, channel, isGitHub);
    return (
      jobs.find((job) => {
        const name = String(job.name || "").toLowerCase();
        return prefixes.some((prefix) => name.startsWith(prefix));
      }) || null
    );
  }
}

// Generates flat status shield badge URLs matching status
function statusBadgeUrl(status) {
  let color, label;
  if (status === "success") {
    color = "success";
    label = "passed";
  } else if (FAILURE_STATES.has(status)) {
    color = "critical";
    label = "failed";
  } else if (status === "in_progress" || status === "running") {
    color = "blue";
    label = "running";
  } else if (
    status === "queued" ||
    status === "waiting" ||
    status === "no_data" ||
    status === "unknown"
  ) {
    color = "lightgrey";
    label = status === "no_data" ? "no--data" : "queued";
  } else {
    color = "lightgrey";
    label = status;
  }
  return `https://img.shields.io/badge/status-${label}-${color}?style=flat-square`;
}

// 3. CORE PAGE RENDERING (DOM GENERATORS & DRAWER FUNCTIONS)

// Draws the SVG build duration trend line graph and configures interactive tooltips
function renderDurationTrendChart(trendRows) {
  const container = document.getElementById("duration-trend-chart");
  if (!container) return;

  const ordered = (trendRows || [])
    .slice(0, 12)
    .filter((row) => row.duration_seconds !== null && row.duration_seconds !== undefined)
    .reverse();

  if (!ordered.length) {
    container.innerHTML = "";
    return;
  }

  const durations = ordered.map((row) => row.duration_seconds);
  const sortedDurations = durations.slice().sort((a, b) => a - b);
  const medianDuration = sortedDurations[Math.floor(sortedDurations.length / 2)] || 0;
  const minDuration = Math.min(...durations);
  const maxDuration = Math.max(...durations);
  let yMin = Math.max(0, Math.floor((minDuration * 0.9) / 10) * 10);
  let yMax = Math.ceil((maxDuration * 1.1) / 10) * 10;
  if (yMin === yMax) yMax = yMin + 10;

  container.innerHTML = "";
  const width = Math.max(container.clientWidth || 0, 320);
  const height = Math.max(container.clientHeight || 0, 260);
  const margin = { top: 16, right: 20, bottom: 34, left: 56 };
  const plotWidth = width - margin.left - margin.right;
  const plotHeight = height - margin.top - margin.bottom;
  const slotCount = ordered.length + 1; // reserve one slot for a future run
  const step = plotWidth / slotCount;
  const xAt = (index) => margin.left + (index + 1) * step;
  const yRange = Math.max(10, yMax - yMin);
  const yAt = (value) => margin.top + ((yMax - value) / yRange) * plotHeight;

  const ns = "http://www.w3.org/2000/svg";
  const svg = document.createElementNS(ns, "svg");
  svg.setAttribute("class", "finance-chart-svg");
  svg.setAttribute("viewBox", `0 0 ${width} ${height}`);
  svg.setAttribute("preserveAspectRatio", "none");

  const defs = document.createElementNS(ns, "defs");
  const gradient = document.createElementNS(ns, "linearGradient");
  gradient.setAttribute("id", "duration-area-gradient");
  gradient.setAttribute("x1", "0");
  gradient.setAttribute("y1", "0");
  gradient.setAttribute("x2", "0");
  gradient.setAttribute("y2", "1");
  const stopTop = document.createElementNS(ns, "stop");
  stopTop.setAttribute("offset", "0%");
  stopTop.setAttribute("stop-color", "rgba(11, 107, 197, 0.26)");
  const stopBottom = document.createElementNS(ns, "stop");
  stopBottom.setAttribute("offset", "100%");
  stopBottom.setAttribute("stop-color", "rgba(11, 107, 197, 0.03)");
  gradient.append(stopTop, stopBottom);
  defs.appendChild(gradient);
  svg.appendChild(defs);

  const maxYLabels = 6;
  const rawStepUnits = Math.max(1, Math.ceil((yMax - yMin) / 10 / (maxYLabels - 1)));
  const yLabelStep = rawStepUnits * 10;
  for (let value = yMin; value <= yMax; value += yLabelStep) {
    const y = yAt(value);

    const line = document.createElementNS(ns, "line");
    line.setAttribute("x1", String(margin.left));
    line.setAttribute("x2", String(width - margin.right));
    line.setAttribute("y1", String(y));
    line.setAttribute("y2", String(y));
    line.setAttribute("stroke", "rgba(0,0,0,0.09)");
    line.setAttribute("stroke-width", "1");
    svg.appendChild(line);

    if (value !== 0) {
      const label = document.createElementNS(ns, "text");
      label.setAttribute("x", String(margin.left - 10));
      label.setAttribute("y", String(y + 4));
      label.setAttribute("text-anchor", "end");
      label.setAttribute("fill", "#666");
      label.setAttribute("font-size", "12");
      label.setAttribute("font-family", "'Ubuntu Mono', monospace");
      label.textContent = `${value}`;
      svg.appendChild(label);
    }
  }

  ordered.forEach((row, index) => {
    if (index === 0) return;
    const x = xAt(index);
    const tickLabel = document.createElementNS(ns, "text");
    tickLabel.setAttribute("x", String(x));
    tickLabel.setAttribute("y", String(height - 10));
    tickLabel.setAttribute("text-anchor", "middle");
    tickLabel.setAttribute("fill", "#666");
    tickLabel.setAttribute("font-size", "12");
    tickLabel.setAttribute("font-family", "'Ubuntu Mono', monospace");
    tickLabel.textContent = `${row.run_number}`;
    svg.appendChild(tickLabel);
  });

  const points = ordered.map((row, index) => ({
    x: xAt(index),
    y: yAt(row.duration_seconds),
    row,
  }));
  const linePath = points
    .map((point, index) => {
      if (index === 0) return `M ${point.x} ${point.y}`;
      return `L ${point.x} ${point.y}`;
    })
    .join(" ");

  const areaPath = `${linePath} L ${points[points.length - 1].x} ${height - margin.bottom} L ${points[0].x} ${height - margin.bottom} Z`;

  const area = document.createElementNS(ns, "path");
  area.setAttribute("d", areaPath);
  area.setAttribute("fill", "url(#duration-area-gradient)");
  svg.appendChild(area);

  const line = document.createElementNS(ns, "path");
  line.setAttribute("d", linePath);
  line.setAttribute("fill", "none");
  line.setAttribute("stroke", "#0b6bc5");
  line.setAttribute("stroke-width", "2.5");
  line.setAttribute("stroke-linecap", "round");
  line.setAttribute("stroke-linejoin", "round");
  svg.appendChild(line);

  points.forEach((point) => {
    const dot = document.createElementNS(ns, "circle");
    dot.setAttribute("cx", String(point.x));
    dot.setAttribute("cy", String(point.y));
    dot.setAttribute("r", "3.5");
    dot.setAttribute("fill", trendPointColor(point.row.conclusion));
    dot.setAttribute("stroke", "#fff");
    dot.setAttribute("stroke-width", "1.5");
    svg.appendChild(dot);
  });

  const crosshair = document.createElementNS(ns, "line");
  crosshair.setAttribute("y1", String(margin.top));
  crosshair.setAttribute("y2", String(height - margin.bottom));
  crosshair.setAttribute("stroke", "rgba(11, 107, 197, 0.35)");
  crosshair.setAttribute("stroke-width", "1.25");
  crosshair.setAttribute("stroke-dasharray", "3 3");
  crosshair.style.opacity = "0";
  svg.appendChild(crosshair);

  const focusDot = document.createElementNS(ns, "circle");
  focusDot.setAttribute("r", "5");
  focusDot.setAttribute("fill", "#fff");
  focusDot.setAttribute("stroke", "#0b6bc5");
  focusDot.setAttribute("stroke-width", "2");
  focusDot.style.opacity = "0";
  svg.appendChild(focusDot);

  const focusHalo = document.createElementNS(ns, "circle");
  focusHalo.setAttribute("r", "10");
  focusHalo.setAttribute("fill", "rgba(11, 107, 197, 0.18)");
  focusHalo.style.opacity = "0";
  svg.appendChild(focusHalo);

  const overlay = document.createElementNS(ns, "rect");
  overlay.setAttribute("x", String(margin.left));
  overlay.setAttribute("y", String(margin.top));
  overlay.setAttribute("width", String(plotWidth));
  overlay.setAttribute("height", String(plotHeight));
  overlay.setAttribute("fill", "transparent");
  svg.appendChild(overlay);

  const tooltip = document.createElement("div");
  tooltip.className = "finance-chart-tooltip";
  container.appendChild(svg);
  container.appendChild(tooltip);

  const showPoint = (index, pointerX = null) => {
    const point = points[index];
    if (!point) return;
    crosshair.setAttribute("x1", String(point.x));
    crosshair.setAttribute("x2", String(point.x));
    crosshair.style.opacity = "1";
    focusHalo.setAttribute("cx", String(point.x));
    focusHalo.setAttribute("cy", String(point.y));
    focusHalo.style.opacity = "1";
    focusDot.setAttribute("cx", String(point.x));
    focusDot.setAttribute("cy", String(point.y));
    focusDot.style.opacity = "1";

    const conclusion = String(point.row.conclusion || "unknown").toLowerCase();
    const isSuspiciouslyFast =
      conclusion === "success" && point.row.duration_seconds < medianDuration * 0.5;
    const dotColor = trendPointColor(conclusion);
    focusDot.setAttribute("stroke", dotColor);
    focusHalo.setAttribute("fill", dotColor);
    focusHalo.setAttribute("fill-opacity", "0.18");
    const descriptor = trendTooltipDescriptor(conclusion, isSuspiciouslyFast);
    const messageText = `: ${point.row.duration_label}${descriptor.messageSuffix}`;
    tooltip.innerHTML = `<div class="${descriptor.notificationClass}"><div class="p-notification__content"><h5 class="p-notification__title">${descriptor.titlePrefix}Run #${escapeHtml(point.row.run_number)}</h5><p class="p-notification__message">${escapeHtml(messageText)}</p></div></div>`;
    const tooltipWidth = 288;
    const xAnchor = pointerX === null ? point.x : pointerX;
    const tooltipX = Math.min(
      width - margin.right - tooltipWidth,
      Math.max(margin.left, xAnchor - tooltipWidth / 2),
    );
    const tooltipY = margin.top + 6;
    tooltip.style.left = `${tooltipX}px`;
    tooltip.style.top = `${tooltipY}px`;
    tooltip.classList.add("is-visible");
  };

  overlay.addEventListener("mousemove", (event) => {
    const rect = overlay.getBoundingClientRect();
    const pointerX = event.clientX - rect.left;
    const svgPointerX = margin.left + (pointerX / rect.width) * plotWidth;
    let index = 0;
    let nearestDistance = Number.POSITIVE_INFINITY;
    points.forEach((point, pointIndex) => {
      const distance = Math.abs(point.x - svgPointerX);
      if (distance < nearestDistance) {
        nearestDistance = distance;
        index = pointIndex;
      }
    });
    showPoint(index, svgPointerX);
  });
  overlay.addEventListener("mouseleave", () => {
    crosshair.style.opacity = "0";
    focusHalo.style.opacity = "0";
    focusDot.style.opacity = "0";
    tooltip.classList.remove("is-visible");
  });

  showPoint(points.length - 1);
  if (durationTrendResizeHandler) window.removeEventListener("resize", durationTrendResizeHandler);
  durationTrendResizeHandler = () => renderDurationTrendChart(trendRows);
  window.addEventListener("resize", durationTrendResizeHandler, {
    passive: true,
  });
}

// Updates build status metrics cards and duration baseline/regression descriptions
function renderBuildStatus(buildStatus) {
  updateBuildActivity(buildStatus);
  const latest = buildStatus.latest_run || {};
  setText("latest-run-title", latest.number ? `Run #${latest.number}` : "No run data");
  const building = isBuildingStatus(latest.status);
  setText("latest-run-updated", formatDate(latest.updated_at));
  const chip = document.getElementById("latest-run-status-chip");
  if (chip) {
    const statusVal = building ? "building" : latest.status || "unknown";
    const statusText = statusVal.replace(/_/g, " ");
    const statusClassStr = building
      ? "status-chip status-building is-building"
      : `status-chip ${statusClass(latest.status)}`;

    chip.parentElement.innerHTML = `<span id="latest-run-status-chip" class="${statusClassStr}" aria-label="Status: ${statusText}">${statusIconSvg(statusVal)}<span class="status-text-full" aria-hidden="true">${statusText}</span><span class="status-text-short" aria-hidden="true">${statusText}</span></span>`;
  }
  const latestLink = document.getElementById("latest-run-link");
  if (latestLink) {
    const durationLabel = latest.duration_label || (building ? "0s" : "Unknown");
    const accessibleLabel = building
      ? `Latest pipeline run active, duration: ${durationLabel}`
      : `Latest pipeline run duration: ${durationLabel}`;
    const label = latestLink.querySelector(".workflow-btn__label");
    const icon = latestLink.querySelector(".status-chip-logo");
    const spinner = latestLink.querySelector(".p-icon--spinner");
    if (label) label.textContent = durationLabel;
    if (building) {
      if (!spinner && icon) {
        icon.insertAdjacentHTML(
          "afterend",
          '<i class="p-icon--spinner u-animation--spin" aria-hidden="true"></i>',
        );
      }
      const durationSeconds =
        typeof latest.duration_seconds === "number" ? latest.duration_seconds : 0;
      latestLink.setAttribute("data-start-time", String(Date.now() - durationSeconds * 1000));
      latestLink.setAttribute("data-context-label", "Latest pipeline run");
    } else {
      if (spinner) spinner.remove();
      latestLink.removeAttribute("data-start-time");
      latestLink.removeAttribute("data-context-label");
    }
    latestLink.setAttribute("aria-label", accessibleLabel);
    latestLink.setAttribute("title", accessibleLabel);
    if (latest.url) {
      latestLink.href = latest.url;
    }
  }

  const baseline = buildStatus.duration_baseline_seconds;
  const regression = buildStatus.duration_regression_seconds;
  let regressionText = "Not enough data to compute regression baseline yet.";
  if (baseline !== null && baseline !== undefined) {
    regressionText = `Recent baseline: ${Math.round(baseline)}s. `;
    if (regression !== null && regression !== undefined) {
      if (regression > 0) {
        regressionText += `Latest build is +${Math.round(regression)}s slower.`;
      } else if (regression < 0) {
        regressionText += `Latest build is ${Math.round(Math.abs(regression))}s faster.`;
      } else {
        regressionText += "Latest build matches baseline.";
      }
    }
  }
  setText("duration-regression", regressionText);

  const trend = buildStatus.duration_trend || [];
  renderDurationTrendChart(trend);
}

// Populates a list of hyperlinks pointing to failed pipeline log files
function renderFailedLogs(testMatrix) {
  const list = document.getElementById("failed-log-links");
  if (!list) return;
  list.innerHTML = "";
  const links = testMatrix.failed_links || [];
  if (!links.length) {
    list.innerHTML = '<li class="p-list__item">No failed distro jobs in latest workflow runs.</li>';
    return;
  }
  links.forEach((item) => {
    const li = document.createElement("li");
    li.className = "p-list__item";
    li.innerHTML = `<a href="${item.url}" target="_blank" rel="noopener noreferrer">${item.distro} · ${item.job_name}</a>`;
    list.appendChild(li);
  });
}

// Generates rows for the distribution OS compatibility matrix table
function renderMatrixRows() {
  const tbody = document.getElementById("compatibility-matrix-body");
  if (!tbody) return;
  const rows = matrixState.rows || [];
  updateInstallActivity(rows);
  tbody.innerHTML = "";
  if (!rows.length) {
    tbody.innerHTML = '<tr><td colspan="5">No matrix rows available.</td></tr>';
    return;
  }
  rows.forEach((row) => {
    const tr = document.createElement("tr");
    const logUrl = row.failed_job_url || row.run_url;
    const badgeSrc = osBadgeByFamily[row.family] || "";
    const statusText = (row.status || "unknown").replace("_", " ");
    const statusBadgeAlt = `${row.label} status: ${statusText}`;
    const logoAlt = row.family ? `${row.family} logo` : "Operating system logo";
    const badgeCell = badgeSrc
      ? `<img class="os-badge" src="${badgeSrc}" alt="${logoAlt}">`
      : `<span class="mono">${row.family || ""}</span>`;
    const statusCell = isBuildingStatus(row.status)
      ? `<span class="status-chip status-building is-building" aria-label="Status: building">${statusIconSvg(row.status)}<span class="status-text-full" aria-hidden="true">building</span><span class="status-text-short" aria-hidden="true">building</span></span>`
      : `<span class="status-chip ${statusClass(row.status)}" aria-label="Status: ${statusText}">${statusIconSvg(row.status)}<span class="status-text-full" aria-hidden="true">${statusText}</span><span class="status-text-short" aria-hidden="true">${statusText}</span></span>`;
    tr.innerHTML = `
          <td class="os-logo-col">${badgeCell}</td>
          <td class="distribution-col">${row.label}</td>
          <td>${statusCell}</td>
          <td class="mono">${formatDate(row.updated_at)}</td>
          <td>${workflowButtonHtml(logUrl, row.duration_seconds, row.failed_job_url ? "Test job" : "Test run", isBuildingStatus(row.status))}</td>
        `;
    tbody.appendChild(tr);
  });

  // Equalize workflow button widths based on the widest button
  setTimeout(() => {
    const buttons = tbody.querySelectorAll(".workflow-btn");
    if (buttons.length === 0) return;
    let maxWidth = 0;
    buttons.forEach((btn) => {
      btn.style.width = "auto"; // Reset for measurement
      maxWidth = Math.max(maxWidth, btn.offsetWidth);
    });
    buttons.forEach((btn) => {
      btn.style.width = maxWidth + "px";
    });
  }, 0);
}

// Draws target architectural security vulnerability metrics tables
function renderSecurity(security) {
  const archRows = (security.architectures || []).filter((row) => {
    const ch = (row.channel || "stable").toLowerCase();
    return ch === selectedBranch.toLowerCase();
  });

  const totalVulns = archRows.length
    ? Math.max(...archRows.map((row) => row.vulnerabilities ?? 0))
    : 0;
  const totalConfined = archRows.length
    ? Math.max(...archRows.map((row) => row.confined_mitigation_vulnerabilities ?? 0))
    : 0;

  setText("security-total-vulns", String(totalVulns));
  setText("security-confined-vulns", String(totalConfined));

  const body = document.getElementById("security-arch-body");
  if (!body) return;
  if (!archRows.length) {
    body.innerHTML = `<tr><td colspan="6">No vulnerability report summary found for the ${escapeHtml(selectedBranch)} channel.</td></tr>`;
    return;
  }
  body.innerHTML = "";
  archRows.forEach((row) => {
    const tr = document.createElement("tr");
    const architecture = String(row.architecture || "").toLowerCase();
    const architectureLabel = String(row.architecture || "").toUpperCase();
    const channelLabel = String(row.channel || "stable").toLowerCase();
    const actionable = row.vulnerabilities ?? 0;
    const actionablePackages = row.affected_packages ?? 0;
    const reportOnly = row.confined_mitigation_vulnerabilities ?? 0;
    const rawMatches = row.raw_vulnerability_matches ?? actionable + reportOnly;
    const rawPackages = row.raw_affected_packages ?? actionablePackages;
    const actionChip =
      actionable > 0
        ? `<span class="status-chip status-caution" aria-label="${actionable} actionable USN vulnerabilities require review">${warningIconSvg}<span class="status-text-full" aria-hidden="true">Review ${actionable} USN</span><span class="status-text-short" aria-hidden="true">review</span></span>`
        : `<span class="status-chip status-success" aria-label="No actionable USN vulnerabilities">${checkIconSvg}<span class="status-text-full" aria-hidden="true">No USN action</span><span class="status-text-short" aria-hidden="true">clear</span></span>`;
    const osvUrl = row.report ? `vulnerabilities/${row.report}` : "";
    const vexUrl = architecture
      ? `vulnerabilities/vex-${channelLabel}-${architecture}.cdx.json`
      : "";

    let datePart = "Unknown";
    let timePart = "";
    if (row.generated_at) {
      const date = new Date(row.generated_at);
      if (!Number.isNaN(date.getTime())) {
        datePart = date.toLocaleDateString();
        timePart = date.toLocaleTimeString([], {
          hour: "2-digit",
          minute: "2-digit",
        });
      } else {
        datePart = row.generated_at;
      }
    }

    tr.innerHTML = `
          <td><span class="mono">${escapeHtml(architectureLabel)}</span></td>
          <td>
            ${actionChip}
            <span class="security-count-note">${actionablePackages} actionable package${actionablePackages === 1 ? "" : "s"}</span>
          </td>
          <td>
            <strong class="security-count">${reportOnly}</strong>
            <span class="security-count-note">confined / report-only</span>
          </td>
          <td>
            <strong class="security-count">${rawMatches}</strong>
            <span class="security-count-note">across ${rawPackages} package${rawPackages === 1 ? "" : "s"}</span>
          </td>
          <td>
            <strong class="security-count">${datePart}</strong>
            ${timePart ? `<span class="security-count-note">${timePart}</span>` : ""}
          </td>
          <td>
            ${
              row.report
                ? `
              <div class="report-button-group">
                <a class="p-button" href="${escapeHtml(osvUrl)}" download title="Download the OSV JSON report">OSV JSON</a>
                <a class="p-button" href="${escapeHtml(vexUrl)}" download title="Download the CycloneDX VEX JSON report">VEX JSON</a>
              </div>
            `
                : "N/A"
            }
          </td>
        `;
    body.appendChild(tr);
  });
}

function isLivePublishSuccess() {
  const channel = selectedBranch || "stable";
  if (liveState.cicdJobs && liveState.cicdJobs.length) {
    return liveState.cicdJobs.some((j) => {
      const name = String(j.name || "").toLowerCase();
      return (
        name.startsWith(`publish github (${channel}, amd64)`) &&
        normalizedLiveStatus(j) === "success"
      );
    });
  }
  return false;
}

// Draws rows for component dependency local/upstream version grids
function componentStatusHtml(item, currentLabel) {
  const liveStatus = liveState.trackUpstreamJobStatus;
  if (liveStatus && isBuildingStatus(liveStatus)) {
    return liveStatusChip(liveStatus, "checking");
  }
  if (
    liveStatus &&
    (FAILURE_STATES.has(liveStatus) || liveStatus === "cancelled" || liveStatus === "skipped")
  ) {
    return liveStatusChip(liveStatus);
  }
  if (item.update_available) {
    const pendingLabel = selectedBranch === "edge" ? "Dev commit pending" : "Stable commit pending";
    return `<span class="status-chip status-caution">${warningIconSvg}${pendingLabel}</span>`;
  }
  if (isLivePublishSuccess()) {
    return `<span class="status-chip status-success">${checkIconSvg}${currentLabel || "Up to date"}</span>`;
  }
  if (
    item.lag_days === null ||
    item.lag_days === undefined ||
    item.lag_days === 0 ||
    currentLabel
  ) {
    return `<span class="status-chip status-success">${checkIconSvg}${currentLabel || "Up to date"}</span>`;
  }
  return `<span class="status-chip status-caution">${item.lag_days}d behind</span>`;
}

function githubCommitUrl(item, sha) {
  if (!item || !item.repository || !sha) return "";
  return `https://github.com/${item.repository}/commit/${sha}`;
}

function upstreamCommitLinkHtml(item) {
  const sha = item && item.upstream_commit;
  if (!sha) return "";
  const shortSha = sha.substring(0, 7);
  const url = githubCommitUrl(item, sha);
  if (!url) return shortSha;
  return `<a href="${url}" target="_blank" rel="noopener noreferrer">${shortSha}</a>`;
}

function sourceVersionWithCommitHtml(item, tagKey, commitKey) {
  const version = item?.[tagKey] || "Unknown";
  const sha = item?.[commitKey] || "";
  if (!sha) return version;
  const shortSha = sha.substring(0, 7);
  const url = githubCommitUrl(item, sha);
  const commit = url
    ? `<a href="${url}" target="_blank" rel="noopener noreferrer">${shortSha}</a>`
    : shortSha;
  return `${version} (${commit})`;
}

function renderDependencies() {
  const body = document.getElementById("dependency-rows");
  if (!body) return;
  body.innerHTML = "";

  const trackRun = globalDashboardData?.auto_update?.latest_success_run || {};
  const fallbackUrl =
    trackRun.url || `https://github.com/${REPO_SLUG}/actions/workflows/track-upstream-releases.yml`;
  const jobUrl = liveState.trackUpstreamJobUrl || fallbackUrl;
  const syncDurationSeconds =
    liveState.trackUpstreamJobDurationSeconds ?? trackRun.duration_seconds;
  const isUpstreamBuilding = liveState.trackUpstreamJobStatus
    ? isBuildingStatus(liveState.trackUpstreamJobStatus)
    : false;
  const workflowHtml = workflowButtonHtml(
    jobUrl,
    syncDurationSeconds,
    liveState.trackUpstreamJobUrl ? "Upstream sync job" : "Upstream sync run",
    isUpstreamBuilding,
  );
  updateUpstreamActivity();

  if (selectedBranch === "stable") {
    const rows = dependencyRows.length
      ? dependencyRows
      : globalDashboardData?.release_info?.components || [];
    if (!rows.length) {
      body.innerHTML = '<tr><td colspan="5">No dependency rows match current filter.</td></tr>';
      return;
    }
    rows.forEach((item) => {
      const statusHtml = componentStatusHtml(item);

      const localCommitShort = item.local_commit ? ` (${item.local_commit.substring(0, 7)})` : "";
      const upstreamCommit = upstreamCommitLinkHtml(item);
      const upstreamCommitShort = upstreamCommit ? ` (${upstreamCommit})` : "";

      const tr = document.createElement("tr");
      tr.innerHTML = `
            <td>${item.name}</td>
            <td class="mono">${item.local_tag || "Unknown"}${localCommitShort}</td>
            <td class="mono">${item.upstream_tag || "Unknown"}${upstreamCommitShort}</td>
            <td>${statusHtml}</td>
            <td>${workflowHtml}</td>
          `;
      body.appendChild(tr);
    });
  } else {
    const rows = globalDashboardData?.auto_update?.edge_releases || [];
    if (!rows.length) {
      body.innerHTML = '<tr><td colspan="5">No edge dependency rows available.</td></tr>';
      return;
    }
    rows.forEach((item) => {
      const statusHtml = componentStatusHtml(item, "Up to date");

      const localSource = sourceVersionWithCommitHtml(item, "local_tag", "local_commit");
      const upstreamSource = sourceVersionWithCommitHtml(item, "upstream_tag", "upstream_commit");

      const tr = document.createElement("tr");
      tr.innerHTML = `
            <td>${item.name}</td>
            <td class="mono">${localSource}</td>
            <td class="mono">${upstreamSource}</td>
            <td>${statusHtml}</td>
            <td>${workflowHtml}</td>
          `;
      body.appendChild(tr);
    });
  }

  // Equalize button widths for components table
  setTimeout(() => {
    const buttons = body.querySelectorAll(".workflow-btn");
    if (buttons.length === 0) return;
    let maxWidth = 0;
    buttons.forEach((btn) => {
      btn.style.width = "auto"; // Reset for measurement
      maxWidth = Math.max(maxWidth, btn.offsetWidth);
    });
    buttons.forEach((btn) => {
      btn.style.width = maxWidth + "px";
    });
  }, 0);
}

// Renders active snap-package store upload/freshness notification banners
function renderSnapFreshness(snapPackage, rows) {
  const el = document.getElementById("snap-package-freshness");
  if (!el) return;
  const sha = snapPackage.expected_commit || "";
  const rev = (rows || []).map((r) => r.revision).filter(Boolean)[0];
  const lastKnown = rev ? ` (revision ${rev})` : "";
  const notes = {
    current: {
      cls: "positive",
      text: `Serving current revision: commit <code>${sha}</code> is selected in the Snap Store.`,
    },
    uploaded_not_selected: {
      cls: "caution",
      text: `Awaiting store selection: commit <code>${sha}</code> is uploaded but not yet selected for this channel.`,
    },
    pending: {
      cls: "caution",
      text: `Store propagation pending: commit <code>${sha}</code> published successfully, while the store still reports the last known revision${lastKnown}.`,
    },
    publish_failed: {
      cls: "negative",
      text: `Publishing commit <code>${sha}</code> to the Snap Store failed after retries. Showing the last known good revision${lastKnown}.`,
    },
  };
  const note = sha ? notes[snapPackage.freshness] : null;
  if (!note) {
    el.hidden = true;
    el.removeAttribute("class");
    el.innerHTML = "";
    return;
  }
  el.className = `p-notification--${note.cls} is-inline`;
  el.innerHTML = `<div class="p-notification__content"><p class="p-notification__message">${note.text}</p></div>`;
  el.hidden = false;
}

// Writes the live countdown sentence for the next scheduled rebuild check
function renderReleaseTrackingScheduleNote() {
  setText("release-tracking-schedule-note", scheduledCheckLabel(releaseTrackingNextCheckMs));
}
function getNextCronTime() {
  const now = new Date();
  const next = new Date(now);
  const hours = now.getUTCHours();
  const nextHours = Math.floor(hours / 3) * 3 + 3;
  next.setUTCHours(nextHours, 0, 0, 0);
  return next;
}

// Aggregates and displays general snap store track updates and release indicators
function renderReleaseInfo(data) {
  const trackRun = data.auto_update?.latest_success_run || {};
  const lastCheck = trackRun.updated_at;
  const nextCheckDate = getNextCronTime();
  const nextCheck = nextCheckDate.toISOString();

  setText("stable-track-updated", formatDate(lastCheck));
  setText("edge-track-updated", formatDate(lastCheck));
  setText("stable-track-next", formatDate(nextCheck));
  setText("edge-track-next", formatDate(nextCheck));
  releaseTrackingNextCheckMs = nextCheckDate.getTime();
  renderReleaseTrackingScheduleNote();

  // Calculate status for stable
  const stableComponents = data.release_info?.components || [];
  const stableUpdateAvailable = stableComponents.some((c) => c.update_available);
  const stableStatusEl = document.getElementById("stable-track-status");
  if (stableStatusEl) {
    const stableClass = stableUpdateAvailable
      ? "status-chip status-caution"
      : "status-chip status-success";
    const stableIcon = stableUpdateAvailable ? warningIconSvg : checkIconSvg;
    const stableText = stableUpdateAvailable ? "Update pending" : "Up to date";
    const stableShort = stableUpdateAvailable ? "pending" : "current";
    stableStatusEl.parentElement.innerHTML = `<span id="stable-track-status" class="${stableClass}" aria-label="Status: ${stableText}">${stableIcon}<span class="status-text-full" aria-hidden="true">${stableText}</span><span class="status-text-short" aria-hidden="true">${stableShort}</span></span>`;
  }

  // Calculate status for edge
  const edgeComponents = data.auto_update?.edge_releases || [];
  const edgeUpdateAvailable = edgeComponents.some((c) => c.update_available);
  const edgeStatusEl = document.getElementById("edge-track-status");
  if (edgeStatusEl) {
    const edgeClass = edgeUpdateAvailable
      ? "status-chip status-caution"
      : "status-chip status-success";
    const edgeIcon = edgeUpdateAvailable ? warningIconSvg : checkIconSvg;
    const edgeText = edgeUpdateAvailable ? "Update pending" : "Up to date";
    const edgeShort = edgeUpdateAvailable ? "pending" : "current";
    edgeStatusEl.parentElement.innerHTML = `<span id="edge-track-status" class="${edgeClass}" aria-label="Status: ${edgeText}">${edgeIcon}<span class="status-text-full" aria-hidden="true">${edgeText}</span><span class="status-text-short" aria-hidden="true">${edgeShort}</span></span>`;
  }

  // Set up the static/fallback workflow links
  const stableWorkflowEl = document.getElementById("stable-track-workflow");
  const edgeWorkflowEl = document.getElementById("edge-track-workflow");
  const workflowHtml = workflowButtonHtml(
    trackRun.url,
    trackRun.duration_seconds,
    "Upstream sync run",
  );
  if (stableWorkflowEl) stableWorkflowEl.innerHTML = workflowHtml;
  if (edgeWorkflowEl) edgeWorkflowEl.innerHTML = workflowHtml;

  // Equalize button widths for sync tracking table
  if (stableStatusEl) {
    const containerTable = stableStatusEl.closest("table");
    if (containerTable) {
      setTimeout(() => {
        const buttons = containerTable.querySelectorAll(".workflow-btn");
        if (buttons.length === 0) return;
        let maxWidth = 0;
        buttons.forEach((btn) => {
          btn.style.width = "auto";
          maxWidth = Math.max(maxWidth, btn.offsetWidth);
        });
        buttons.forEach((btn) => {
          btn.style.width = maxWidth + "px";
        });
      }, 0);
    }
  }

  // The deployed snapshot seeds the snap table and can be fresher than the
  // hourly gist immediately after publishing. Record its generation time so
  // older gist data cannot replace newer deploy-time store data.
  if (!snapState.hasGistData) {
    renderSnapPackage(data.snap_package || {});
    snapState.generatedAt = data.generated_at || snapState.generatedAt;
    setSnapClock((data.snap_package || {}).last_updated || data.data_last_updated, false);
  }
}

// Maps a snap architecture row to its serving-status chip. A non-current
// build is store lag (an older revision is still selected), never "failing":
// a lagging or not-yet-propagated revision is a publication state.
function snapStatusDescriptor(row) {
  const channel = row.channel || (row.on_stable ? "stable" : "edge");
  if (row.build_status === "current") {
    return {
      cls: "status-success",
      label: `Serving · ${channel}`,
      short: "serving",
    };
  }
  if (typeof freshnessState !== "undefined" && freshnessState.live?.status === "stale") {
    return {
      cls: "status-neutral",
      label: `Snapshot · ${channel}`,
      short: "snapshot",
    };
  }
  return {
    cls: "status-caution",
    label: `Store lag · ${channel}`,
    short: "lag",
  };
}

// Draws target architectural snap release version tables
function renderSnapPackage(snapPackage) {
  snapState.snapPackage = snapPackage;
  const packageBody = document.getElementById("snap-package-rows");
  if (!packageBody) return;

  const allRows = snapPackage.all_channels || snapPackage.channels || [];
  const selectedRows = [];
  const arches = Array.from(new Set(allRows.map((r) => r.architecture)));

  arches.forEach((arch) => {
    const archRows = allRows.filter((r) => r.architecture === arch);
    if (selectedBranch === "stable") {
      const stableEntry = archRows.find((r) => r.channel === "stable");
      if (stableEntry) {
        selectedRows.push(stableEntry);
      } else {
        const edgeEntry = archRows.find((r) => r.channel === "edge");
        if (edgeEntry) selectedRows.push(edgeEntry);
      }
    } else {
      const edgeEntry = archRows.find((r) => r.channel === "edge");
      if (edgeEntry) {
        selectedRows.push(edgeEntry);
      } else {
        const stableEntry = archRows.find((r) => r.channel === "stable");
        if (stableEntry) selectedRows.push(stableEntry);
      }
    }
  });
  const rows = selectedRows;

  updateStoreActivity(snapPackage || {});
  renderSnapFreshness(snapPackage || {}, rows);

  let targetVersion = "";
  const currentChannel = rows.find((c) => c.build_status === "current");
  if (currentChannel) {
    targetVersion = currentChannel.full_version || currentChannel.version || "";
  } else {
    let newest = null;
    rows.forEach((c) => {
      if (!newest || new Date(c.released_at) > new Date(newest.released_at)) {
        newest = c;
      }
    });
    if (newest) {
      targetVersion = newest.full_version || newest.version || "";
    }
  }
  snapState.targetVersion = targetVersion;

  packageBody.innerHTML = "";
  if (!rows.length) {
    packageBody.innerHTML = '<tr><td colspan="8">snap package metadata unavailable.</td></tr>';
    return;
  }
  rows.forEach((row) => {
    const isGitHub = row.build_source === "github";
    const builtOn = isGitHub
      ? `<span class="status-chip status-neutral status-chip--github-builder">${githubLogoSvg}GitHub builder</span>`
      : `<span class="status-chip status-neutral status-chip--launchpad-builder">${launchpadLogoSvg}Launchpad builder</span>`;
    const desc = snapStatusDescriptor(row);
    const statusIcon = desc.cls === "status-success" ? checkIconSvg : warningIconSvg;
    const status = `<span class="status-chip ${desc.cls}" aria-label="Status: ${desc.label}">${statusIcon}<span class="status-text-full" aria-hidden="true">${desc.label}</span><span class="status-text-short" aria-hidden="true">${desc.short}</span></span>`;
    const version = row.full_version || row.version || "Unknown";

    const workflowSnapshot = (row.workflow_runs || {})[selectedBranch] || {};
    const workflow = workflowButtonHtml(
      workflowSnapshot.url || "",
      workflowSnapshot.duration_seconds,
      isGitHub ? "Build job" : "Publish job",
    );

    const tr = document.createElement("tr");
    tr.innerHTML = `
          <td>${row.architecture || "Unknown"}</td>
          <td>${builtOn}</td>
          <td class="mono snap-version">${version}</td>
          <td class="mono">${row.revision || "Unknown"}</td>
          <td class="mono">${formatBytes(row.size_bytes)}</td>
          <td class="mono">${formatDate(row.released_at)}</td>
          <td>${status}</td>
          <td>${workflow}</td>
        `;
    packageBody.appendChild(tr);
  });

  // Equalize button widths for snap package table initially
  setTimeout(() => {
    const buttons = packageBody.querySelectorAll(".workflow-btn");
    if (buttons.length === 0) return;
    let maxWidth = 0;
    buttons.forEach((btn) => {
      btn.style.width = "auto";
      maxWidth = Math.max(maxWidth, btn.offsetWidth);
    });
    buttons.forEach((btn) => {
      btn.style.width = maxWidth + "px";
    });
  }, 0);

  refreshLiveSnapPackageStatus();
}

// Applies live architecture build runner status and specific workflow urls
function applyLiveSnapStatus(cicdJobs, cicdRun, lpJobs, lpRun) {
  const packageBody = document.getElementById("snap-package-rows");
  if (!packageBody) return;

  const rows = packageBody.querySelectorAll("tr");
  rows.forEach((tr) => {
    const archCell = tr.cells[0];
    if (!archCell) return;
    const arch = archCell.textContent.trim().toUpperCase();

    const isGitHub = GITHUB_BUILD_ARCHES.has(arch);
    let job = null;
    let run = null;

    if (isGitHub) {
      run = cicdRun;
      job = findBuildJob(cicdJobs, arch, selectedBranch, true);
    } else {
      run = lpRun;
      job = findBuildJob(lpJobs, arch, selectedBranch, false);
    }

    if (!job) {
      return;
    }

    let statusHtml = null;
    let isBuilding = false;
    const runUrl = (job && job.html_url) || "";

    if (job) {
      const status = normalizedLiveStatus(job);
      if (isBuildingStatus(status)) {
        isBuilding = true;
        statusHtml = liveStatusChip(status, isGitHub ? "building" : "publishing", true);
      } else if (FAILURE_STATES.has(status) || status === "cancelled" || status === "skipped") {
        statusHtml = liveStatusChip(status);
      } else if (status === "success") {
        statusHtml = `<span class="status-chip status-success" aria-label="Status: Serving · ${selectedBranch}">${checkIconSvg}<span class="status-text-full" aria-hidden="true">Serving · ${selectedBranch}</span><span class="status-text-short" aria-hidden="true">serving</span></span>`;
      }
    }

    if (statusHtml) {
      tr.cells[6].innerHTML = statusHtml;
    }

    const duration = job ? liveJobDurationSeconds(job) : null;
    const workflowContext = job
      ? isGitHub
        ? "Build job"
        : "Publish job"
      : isGitHub
        ? "Build run"
        : "Publish run";
    const workflowHtml = workflowButtonHtml(runUrl, duration, workflowContext, isBuilding);

    if (tr.cells.length <= 7) {
      const td = tr.insertCell(7);
      td.innerHTML = workflowHtml;
    } else {
      tr.cells[7].innerHTML = workflowHtml;
    }
  });

  // Equalize button widths for snap package table
  setTimeout(() => {
    const buttons = packageBody.querySelectorAll(".workflow-btn");
    if (buttons.length === 0) return;
    let maxWidth = 0;
    buttons.forEach((btn) => {
      btn.style.width = "auto";
      maxWidth = Math.max(maxWidth, btn.offsetWidth);
    });
    buttons.forEach((btn) => {
      btn.style.width = maxWidth + "px";
    });
  }, 0);

  // Check if we can override stable/edge track status to "Up to date"
  let isStableSuccessful = false;
  let isEdgeSuccessful = false;

  if (cicdJobs && cicdJobs.length) {
    const stableAmd64Publish = cicdJobs.find((j) => {
      const name = String(j.name || "").toLowerCase();
      return (
        name.startsWith("publish github (stable, amd64)") && normalizedLiveStatus(j) === "success"
      );
    });
    const edgeAmd64Publish = cicdJobs.find((j) => {
      const name = String(j.name || "").toLowerCase();
      return (
        name.startsWith("publish github (edge, amd64)") && normalizedLiveStatus(j) === "success"
      );
    });
    if (stableAmd64Publish) isStableSuccessful = true;
    if (edgeAmd64Publish) isEdgeSuccessful = true;
  }

  const isChecking =
    liveState.trackUpstreamJobStatus && isBuildingStatus(liveState.trackUpstreamJobStatus);

  if (isStableSuccessful && !isChecking) {
    const stableStatusEl = document.getElementById("stable-track-status");
    if (stableStatusEl) {
      const stableClass = "status-chip status-success";
      const stableIcon = checkIconSvg;
      const stableText = "Up to date";
      const stableShort = "current";
      stableStatusEl.parentElement.innerHTML = `<span id="stable-track-status" class="${stableClass}" aria-label="Status: ${stableText}">${stableIcon}<span class="status-text-full" aria-hidden="true">${stableText}</span><span class="status-text-short" aria-hidden="true">${stableShort}</span></span>`;
    }
  }

  if (isEdgeSuccessful && !isChecking) {
    const edgeStatusEl = document.getElementById("edge-track-status");
    if (edgeStatusEl) {
      const edgeClass = "status-chip status-success";
      const edgeIcon = checkIconSvg;
      const edgeText = "Up to date";
      const edgeShort = "current";
      edgeStatusEl.parentElement.innerHTML = `<span id="edge-track-status" class="${edgeClass}" aria-label="Status: ${edgeText}">${edgeIcon}<span class="status-text-full" aria-hidden="true">${edgeText}</span><span class="status-text-short" aria-hidden="true">${edgeShort}</span></span>`;
    }
  }
}

async function refreshLiveSnapPackageStatus() {
  if (liveState.snapOverlayInFlight) return;
  if (liveState.rateRemaining !== null && liveState.rateRemaining <= LIVE_RATE_FLOOR) return;
  const now = Date.now();
  if (
    liveState.snapOverlayLastFetch &&
    now - liveState.snapOverlayLastFetch < SNAP_OVERLAY_MIN_REFETCH_MS
  ) {
    applyLiveSnapStatus(liveState.cicdJobs, liveState.cicdRun, liveState.lpJobs, liveState.lpRun);
    return;
  }

  liveState.snapOverlayInFlight = true;
  try {
    const runs = await fetchRecentRuns();
    if (!runs) return;

    const branchName = "main";
    const cicdRuns = runs.filter(
      (run) => (run.path || "").endsWith("/cicd.yml") && run.head_branch === branchName,
    );
    const lpRuns = runs.filter(
      (run) => (run.path || "").endsWith("/launchpad-builds.yml") && run.head_branch === branchName,
    );
    const latestCicd = cicdRuns[0] || null;
    const latestLp = lpRuns[0] || null;

    let cicdJobs = liveState.cicdJobs;
    let cicdRun = liveState.cicdRun || latestCicd;
    if (latestCicd) {
      const latestCicdBuilding = BUILDING_STATES.has((latestCicd.status || "").toLowerCase());
      const latestChanged =
        latestCicd.id !== liveState.lastCicdRunId ||
        !liveState.cicdJobs ||
        (liveState.cicdRun && liveState.cicdRun.id !== latestCicd.id);
      if (latestChanged || latestCicdBuilding) {
        cicdJobs = await fetchRunJobs(latestCicd.id);
        cicdRun = latestCicd;
        liveState.lastCicdRunId = latestCicd.id;
        liveState.cicdJobs = cicdJobs;
        liveState.cicdRun = cicdRun;
      } else {
        cicdJobs = liveState.cicdJobs;
        cicdRun = liveState.cicdRun;
      }
    }

    let lpJobs = liveState.lpJobs;
    let lpRun = liveState.lpRun || latestLp;
    if (latestLp && (latestLp.id !== liveState.lastLpRunId || !lpJobs)) {
      lpJobs = await fetchRunJobs(latestLp.id);
      lpRun = latestLp;
      liveState.lastLpRunId = latestLp.id;
      liveState.lpJobs = lpJobs;
      liveState.lpRun = lpRun;
    }

    applyLiveSnapStatus(cicdJobs, cicdRun, lpJobs, lpRun);
    liveState.snapOverlayLastFetch = Date.now();
  } finally {
    liveState.snapOverlayInFlight = false;
  }
}

// Renders the published snap channels as a table with architectures per channel

// Renders the summary textual copy descriptive tags for report cards
function renderReportSummaries(data) {
  const latestRun = data.build_status?.latest_run || {};
  setText(
    "report-coverage-summary",
    `Latest CI/CD run #${latestRun.number || "?"} finished with ${latestRun.status || "unknown"} status in ${latestRun.duration_label || "unknown duration"}.`,
  );

  const bundled = data.dependencies?.bundled_versions || {};
  const bundledSummary = [
    `FTL ${bundled.ftl || "unknown"}`,
    `Core ${bundled.pi_hole || "unknown"}`,
    `Web ${bundled.web || "unknown"}`,
  ].join(" · ");
  setText(
    "report-sbom-summary",
    `Bundled component versions currently tracked: ${bundledSummary}.`,
  );

  const security = data.security || {};
  const rawMatches = security.raw_vulnerability_matches ?? security.total_vulnerabilities ?? 0;
  const confinedMatches =
    security.confined_mitigation_vulnerabilities ??
    Math.max(0, rawMatches - (security.total_vulnerabilities ?? 0));
  setText(
    "report-vuln-summary",
    `${security.total_vulnerabilities ?? 0} actionable USN vulnerability matches across ${security.affected_packages ?? 0} actionable packages. ${confinedMatches} non-USN OSV matches are tracked as confined-mitigation report-only findings.`,
  );
}

// Renders the channel switch post-publish release-health test summary and matrix
function renderChannelSwitch(cs) {
  if (!cs) {
    cs = {
      status: "no_data",
      summary: "No data available",
      duration_label: "Unknown",
      updated_at: "",
      html_url: "",
      rows: [],
    };
  }
  renderChannelSwitchTimeline(cs);

  const body = document.getElementById("channel-switch-matrix-body");
  if (body) {
    body.innerHTML = "";
    const rows = cs.rows || [];
    if (!rows.length) {
      body.innerHTML = '<tr><td colspan="6">No channel switch runs recorded.</td></tr>';
    } else {
      rows.forEach((row) => {
        const tr = document.createElement("tr");
        const detailsTr = document.createElement("tr");
        const isBuilding = isBuildingStatus(row.status);
        const statusBadge = liveStatusChip(row.status, "running");

        const arch = escapeHtml(row.arch || "unknown");
        const testedOn = githubRunnerChipHtml();
        const path = escapeHtml(row.path || "roundtrip");
        const updated = escapeHtml(formatDate(row.updated_at || cs.updated_at));
        const details = DashboardChannelSwitch.channelSwitchEvidenceHtml(row);

        const wfButton = workflowButtonHtml(
          row.url || "",
          row.duration_seconds,
          "Workflow run",
          isBuilding,
        );

        tr.innerHTML = `
              <td class="mono font-weight-bold">${arch}</td>
              <td>${testedOn}</td>
              <td class="mono">${path}</td>
              <td>${statusBadge}</td>
              <td class="mono">${updated}</td>
              <td>${wfButton}</td>
            `;
        detailsTr.className = "channel-switch-details-row";
        detailsTr.innerHTML = `
              <td class="channel-switch-details-cell" colspan="6">
                <div class="channel-switch-details-grid">
                  <div class="channel-switch-explanation channel-switch-explanation--contained">
                    <h4 class="channel-switch-explanation__title">Details</h4>
                    ${details}
                  </div>
                </div>
              </td>
            `;
        body.appendChild(tr);
        body.appendChild(detailsTr);
      });
    }
  }
}

function githubRunnerChipHtml() {
  return `<span class="status-chip status-neutral status-chip--github-builder">${githubLogoSvg}GitHub runner</span>`;
}

function renderChannelSwitchTimeline(cs) {
  const timeline = document.getElementById("channel-switch-timeline");
  if (!timeline) return;
  timeline.innerHTML = DashboardChannelSwitch.channelSwitchTimelineHtml(cs);
  setText("channel-switch-summary", cs.summary || "No data available");
}

// 4. TIME & FRESHNESS CLOCKS

// Returns a relative time description (e.g. "5m ago")
function relativeTime(value) {
  if (!value) return "unknown";
  const then = new Date(value).getTime();
  if (Number.isNaN(then)) return "unknown";
  const secs = Math.max(0, Math.round((Date.now() - then) / 1000));
  if (secs < 60) return `${secs}s ago`;
  const mins = Math.round(secs / 60);
  if (mins < 60) return `${mins}m ago`;
  const hrs = Math.round(mins / 60);
  if (hrs < 24) return `${hrs}h ago`;
  return `${Math.round(hrs / 24)}d ago`;
}

// Builds a countdown MM:SS string from milliseconds
function countdownLabel(toMs) {
  if (!toMs) return null;
  const secs = Math.max(0, Math.ceil((toMs - Date.now()) / 1000));
  const mins = Math.floor(secs / 60);
  return `${mins}:${String(secs % 60).padStart(2, "0")}`;
}

// Resolves time values to the nearest next top-of-the-hour boundary
function nextHourBoundary(fromMs) {
  const date = new Date(fromMs);
  date.setMinutes(0, 0, 0);
  date.setHours(date.getHours() + 1);
  return date.getTime();
}

// Resets snap store freshness clock metadata fields
function setSnapClock(updatedAt, fromGist) {
  freshnessState.snap.updatedAt = updatedAt || null;
  freshnessState.snap.fromGist = fromGist;
  freshnessState.snap.source = fromGist ? "Snap Store · hourly gist" : "build-time snapshot";
  freshnessState.snap.nextAt = nextHourBoundary(Date.now());
}

function fallbackFreshnessNextAt(kind, clock) {
  if (clock.nextAt) return clock.nextAt;
  if (kind === "live") {
    if (clock.status === "paused") return null;
    const interval =
      clock.status === "building"
        ? LIVE_POLL_MS_BUILDING
        : clock.status === "stale"
          ? LIVE_POLL_MS_BACKOFF
          : LIVE_POLL_MS_IDLE;
    const updatedAt = new Date(clock.updatedAt || "").getTime();
    return (Number.isNaN(updatedAt) ? Date.now() : updatedAt) + interval;
  }
  if (kind === "snap") return nextHourBoundary(Date.now());
  return null;
}

// Evaluates status details text labels of target freshness kinds
function freshnessDetail(kind) {
  const nextSuffix = (clock) => {
    const cd = countdownLabel(fallbackFreshnessNextAt(kind, clock));
    return cd ? ` · next ${cd}` : "";
  };
  if (kind === "live") {
    const clock = freshnessState.live;
    if (clock.status === "paused") return "paused";
    if (clock.status === "stale") return `unavailable — using snapshot${nextSuffix(clock)}`;
    if (!clock.updatedAt) return `connecting…${nextSuffix(clock)}`;
    return `updated ${relativeTime(clock.updatedAt)}${nextSuffix(clock)}`;
  }
  if (kind === "snap") {
    const clock = freshnessState.snap;
    if (!clock.updatedAt) return `${clock.source}${nextSuffix(clock)}`;
    return `updated ${relativeTime(clock.updatedAt)}${nextSuffix(clock)}`;
  }
  if (kind === "build") {
    const clock = freshnessState.build;
    return clock.updatedAt ? `published ${relativeTime(clock.updatedAt)} · on deploy` : "on deploy";
  }
  return "";
}

// Resolves state flags (stale, building, fresh, muted) of target freshness kinds
function freshnessStatus(kind) {
  if (kind === "live") {
    const status = freshnessState.live.status;
    if (status === "building") return "building";
    if (status === "stale") return "stale";
    if (status === "paused") return "muted";
    if (status === "fresh" || status === "active" || status === "idle") return "fresh";
    return "muted";
  }
  if (kind === "snap") return freshnessState.snap.fromGist ? "fresh" : "muted";
  return "muted";
}

// Orchestrates visual refresh of the inline freshness chips
function renderFreshnessChips() {
  document.querySelectorAll("[data-freshness]").forEach((chip) => {
    const kind = chip.getAttribute("data-freshness");
    if (kind === "cadence") {
      chip.dataset.status = "muted";
      return;
    }
    chip.dataset.status = freshnessStatus(kind);
    const detail = chip.querySelector("[data-freshness-detail]");
    if (detail) detail.textContent = freshnessDetail(kind);
  });
}

// Live ticks active workflow buttons to increment duration in real-time
function tickWorkflowButtons() {
  document.querySelectorAll(".workflow-btn[data-start-time]").forEach((btn) => {
    const startTime = Number(btn.getAttribute("data-start-time"));
    if (Number.isNaN(startTime)) return;
    const elapsed = Math.max(0, Math.round((Date.now() - startTime) / 1000));
    const durationLabel = humanDuration(elapsed);

    const textSpan = btn.querySelector(".workflow-btn__label");
    if (textSpan) {
      textSpan.textContent = durationLabel;
    }

    const contextLabel = btn.getAttribute("data-context-label") || "Workflow";
    const newAccessibleLabel = `${contextLabel} active, duration: ${durationLabel}`;
    btn.setAttribute("aria-label", newAccessibleLabel);
    btn.setAttribute("title", newAccessibleLabel);
  });
}

// Spawns the central 1-second ticks loop for ticking relative times and countdown timers
function startFreshnessTicker() {
  if (freshnessTimer) clearInterval(freshnessTimer);
  freshnessTimer = setInterval(() => {
    renderFreshnessChips();
    tickWorkflowButtons();
    renderReleaseTrackingScheduleNote();
    if (snapState.nextAt && Date.now() >= snapState.nextAt) {
      maybeRefreshSnap();
    }
  }, 1000);
}

// 5. LIVE GITHUB ACTIONS API SYNCHRONIZATION

// Fetches the 100 newest workflow runs from the GitHub Actions endpoint
async function fetchRecentRuns() {
  let response;
  try {
    response = await fetch(`${GITHUB_API_BASE}/repos/${REPO_SLUG}/actions/runs?per_page=100`, {
      headers: { Accept: "application/vnd.github+json" },
      cache: "no-store",
    });
  } catch (error) {
    return null;
  }
  const remaining = Number(response.headers.get("X-RateLimit-Remaining"));
  if (!Number.isNaN(remaining)) liveState.rateRemaining = remaining;
  if (!response.ok) return null;
  try {
    const payload = await response.json();
    return payload.workflow_runs || [];
  } catch (error) {
    return null;
  }
}

// Fetches all jobs generated by a target run ID
async function fetchRunJobs(runId) {
  let response;
  try {
    response = await fetch(
      `${GITHUB_API_BASE}/repos/${REPO_SLUG}/actions/runs/${runId}/jobs?per_page=100`,
      {
        headers: { Accept: "application/vnd.github+json" },
        cache: "no-store",
      },
    );
  } catch (error) {
    return null;
  }
  const remaining = Number(response.headers.get("X-RateLimit-Remaining"));
  if (!Number.isNaN(remaining)) liveState.rateRemaining = remaining;
  if (!response.ok) return null;
  try {
    const payload = await response.json();
    return payload.jobs || [];
  } catch (error) {
    return null;
  }
}

// Maps workflow file names to their newest workflow run record
function latestRunByWorkflow(runs) {
  const map = {};
  runs.forEach((run) => {
    const file = (run.path || "").split("/").pop();
    if (file && !(file in map)) map[file] = run;
  });
  return map;
}

// Finds the newest runs and jobs that contain active distro test matrix items
async function liveMatrixJobsAndRun(cicdRuns) {
  const candidates = [];
  if (cicdRuns[0]) candidates.push(cicdRuns[0]);
  const newestCompleted = cicdRuns.find((run) => run.status === "completed");
  if (newestCompleted && newestCompleted !== cicdRuns[0]) candidates.push(newestCompleted);
  let latestJobs = null;
  for (const run of candidates) {
    const jobs = await fetchRunJobs(run.id);
    if (run === cicdRuns[0]) latestJobs = jobs;
    if (jobs && jobs.some((job) => (job.name || "").startsWith("distro test ("))) {
      return { jobs, run };
    }
  }
  return { jobs: latestJobs, run: cicdRuns[0] || null };
}

// Translates GHA job lists into compatibility matrix records and failing log links
function applyLiveMatrixFromJobs(jobs, run) {
  if (!jobs || !jobs.length) return { matched: false, building: false };
  let matched = 0;
  let building = false;
  const liveFailedLinks = [];
  matrixState.rows = matrixState.rows.map((row) => {
    const key = row.distro || (row.workflow || "").replace(/^test-/, "").replace(/\.yml$/, "");
    const prefix = `distro test (${key}, ${selectedBranch})`;
    const legacyPrefix = `distro test (${key})`;
    const job =
      jobs.find((candidate) => (candidate.name || "").startsWith(prefix)) ||
      jobs.find((candidate) => (candidate.name || "").startsWith(legacyPrefix));
    if (!job) {
      const fallback = (matrixState.failedLinks || []).find(
        (link) => link.workflow === row.workflow,
      );
      if (fallback) liveFailedLinks.push(fallback);
      return row;
    }
    matched += 1;
    const status =
      job.status === "completed" ? job.conclusion || "unknown" : job.status || "queued";
    if (isBuildingStatus(status)) building = true;
    const durationSeconds = liveJobDurationSeconds(job) ?? liveRunDurationSeconds(run);
    const failed = FAILURE_STATES.has(status);
    const failedUrl = failed ? job.html_url || (run && run.html_url) || "" : "";
    if (failed) {
      liveFailedLinks.push({
        distro: row.label,
        workflow: row.workflow,
        job_name: job.name,
        url: failedUrl,
      });
    }
    return {
      ...row,
      status,
      conclusion: job.conclusion || (job.status === "completed" ? "unknown" : job.status),
      run_number: (run && run.run_number) ?? row.run_number,
      updated_at: job.completed_at || job.started_at || row.updated_at,
      duration_seconds: durationSeconds,
      duration_label: humanDuration(durationSeconds),
      status_badge_url: statusBadgeUrl(status),
      run_url: job.html_url || (run && run.html_url) || row.run_url,
      failed_job_url: failedUrl,
    };
  });
  if (!matched) return { matched: false, building: false };

  renderMatrixRows();
  renderFailedLogs({ failed_links: liveFailedLinks });
  return { matched: true, building };
}

async function applyLiveChannelSwitch(latestByWorkflow) {
  const run = latestByWorkflow["channel-switch.yml"];
  if (!run) return false;
  // Allow 'main' branch OR allow any 'workflow_run' event (which defaults to main but often returns head_branch: null)
  if (run.head_branch !== "main" && run.event !== "workflow_run") {
    return false;
  }

  const runStatus =
    run.status === "completed" ? run.conclusion || "unknown" : run.status || "queued";
  const runBuilding = isBuildingStatus(runStatus);
  const cachedJobsBuilding = (liveState.channelSwitchJobs || []).some((candidate) =>
    isBuildingStatus(normalizedLiveStatus(candidate)),
  );
  const runUpdated = run.updated_at && run.updated_at !== liveState.lastChannelSwitchRunUpdatedAt;
  const shouldFetchJobs =
    runBuilding ||
    cachedJobsBuilding ||
    runUpdated ||
    run.id !== liveState.lastChannelSwitchRunId ||
    !liveState.channelSwitchJobs;
  let jobs = liveState.channelSwitchJobs;
  if (shouldFetchJobs) {
    jobs = await fetchRunJobs(run.id);
    liveState.lastChannelSwitchRunId = run.id;
    liveState.lastChannelSwitchRunUpdatedAt = run.updated_at || null;
    liveState.channelSwitchJobs = jobs;
  }

  const job =
    (jobs || []).find((candidate) => {
      const name = String(candidate.name || "").toLowerCase();
      return name.includes("channel switch") && name.includes("arm64");
    }) || null;

  const rowStatus = job ? normalizedLiveStatus(job) : runStatus;
  const durationSeconds = (job ? liveJobDurationSeconds(job) : null) ?? liveRunDurationSeconds(run);
  const snapshot = globalDashboardData?.channel_switch || {};
  const snapshotRow = (snapshot.rows || []).find((row) => row.arch === "arm64") || {};
  const snapshotMatchesRun = String(snapshot.run_id || "") === String(run.id || "");
  const snapshotHasRevisions = Boolean(snapshot.stable_revision && snapshot.edge_revision);
  const keepSnapshotRevisionEvidence = snapshotMatchesRun || snapshotHasRevisions;
  const snapshotRunData = keepSnapshotRevisionEvidence ? snapshot : {};
  const snapshotRowData = keepSnapshotRevisionEvidence ? snapshotRow : {};
  const liveChannelSwitch = {
    ...snapshot,
    stable_revision: snapshotRunData.stable_revision || "",
    edge_revision: snapshotRunData.edge_revision || "",
    status: rowStatus,
    conclusion:
      job?.conclusion || (run.status === "completed" ? run.conclusion || "unknown" : run.status),
    run_number: run.run_number ?? snapshot.run_number,
    run_id: run.id ?? snapshot.run_id,
    html_url: run.html_url || snapshot.html_url || "",
    updated_at: job?.completed_at || job?.started_at || run.updated_at || snapshot.updated_at || "",
    duration_seconds: durationSeconds,
    duration_label: humanDuration(durationSeconds),
    rows: [
      {
        ...snapshotRowData,
        arch: "arm64",
        status: rowStatus,
        conclusion:
          job?.conclusion ||
          (run.status === "completed" ? run.conclusion || "unknown" : run.status),
        path: snapshotRowData.path || snapshotRunData.path || "roundtrip",
        summary: snapshotRowData.summary || snapshotRunData.summary || "stable -> edge -> stable",
        updated_at:
          job?.completed_at ||
          job?.started_at ||
          run.updated_at ||
          snapshotRowData.updated_at ||
          snapshotRunData.updated_at ||
          "",
        duration_seconds: durationSeconds,
        duration_label: humanDuration(durationSeconds),
        url: job?.html_url || run.html_url || snapshotRowData.url || snapshotRunData.html_url || "",
        reason: snapshotRowData.reason || snapshotRunData.reason || "",
        evidence:
          snapshotMatchesRun && hasChannelSwitchEvidence(snapshotRow) ? snapshotRow.evidence : [],
      },
    ],
  };

  renderChannelSwitch(liveChannelSwitch);
  return isBuildingStatus(rowStatus);
}

// Reconstructs and redraws the main CI/CD build status block metrics
function applyLiveBuildStatus(runs) {
  const branchName = "main";
  const cicdRuns = runs.filter(
    (run) => (run.path || "").endsWith("/cicd.yml") && run.head_branch === branchName,
  );
  if (!cicdRuns.length) return false;

  const latest = cicdRuns[0];
  const latestStatus =
    latest.status === "completed" ? latest.conclusion || "unknown" : latest.status || "queued";
  const trend = cicdRuns.slice(0, 12).map((run) => {
    const duration = liveRunDurationSeconds(run);
    return {
      run_number: run.run_number,
      conclusion: run.conclusion || "unknown",
      duration_seconds: run.status === "completed" ? duration : null,
      duration_label: humanDuration(duration),
      updated_at: run.updated_at || "",
      url: run.html_url || "",
    };
  });

  const completed = cicdRuns.filter((run) => run.status === "completed");
  const recent = completed
    .slice(1, 6)
    .map(liveRunDurationSeconds)
    .filter((value) => value !== null);
  const baseline = recent.length
    ? Math.round((recent.reduce((a, b) => a + b, 0) / recent.length) * 10) / 10
    : null;
  let regression = null;
  if (completed.length && baseline !== null) {
    const latestCompletedDuration = liveRunDurationSeconds(completed[0]);
    if (latestCompletedDuration !== null)
      regression = Math.round((latestCompletedDuration - baseline) * 10) / 10;
  }

  const frequencyDays = liveUpdateFrequencyDays(cicdRuns);
  if (frequencyDays !== null) setText("snap-update-frequency", `${frequencyDays} days`);

  renderBuildStatus({
    latest_run: {
      number: latest.run_number,
      status: latestStatus,
      conclusion: latest.conclusion || latestStatus,
      url: latest.html_url || "",
      updated_at: latest.updated_at || "",
      duration_seconds: liveRunDurationSeconds(latest),
      duration_label: humanDuration(liveRunDurationSeconds(latest)),
    },
    duration_trend: trend,
    duration_baseline_seconds: baseline,
    duration_regression_seconds: regression,
  });

  const covDuration = humanDuration(liveRunDurationSeconds(latest));
  const covText = isBuildingStatus(latestStatus)
    ? `Latest CI/CD run #${latest.run_number || "?"} is currently ${(latestStatus || "running").replace("_", " ")} (running for ${covDuration}).`
    : `Latest CI/CD run #${latest.run_number || "?"} finished with ${latestStatus} status in ${covDuration}.`;
  setText("report-coverage-summary", covText);

  return isBuildingStatus(latestStatus);
}

// Updates track-upstream status timestamps and workflows with live values
function trackUpstreamJobFromJobs(jobs) {
  if (!jobs || !jobs.length) return null;
  return (
    jobs.find((job) => (job.name || "") === "update-sources") ||
    jobs.find((job) => (job.name || "") === "update-tags") ||
    jobs[0]
  );
}

async function resolveTrackUpstreamJob(run) {
  if (!run) return { url: "", durationSeconds: null, status: "" };
  const needsFetch =
    liveState.trackUpstreamRunId !== run.id ||
    !liveState.trackUpstreamJobUrl ||
    run.status !== "completed";
  if (!needsFetch) {
    return {
      url: liveState.trackUpstreamJobUrl,
      durationSeconds: liveState.trackUpstreamJobDurationSeconds,
      status: liveState.trackUpstreamJobStatus,
    };
  }
  const jobs = await fetchRunJobs(run.id);
  const job = trackUpstreamJobFromJobs(jobs);
  const url = (job && job.html_url) || run.html_url || "";
  const durationSeconds = (job ? liveJobDurationSeconds(job) : null) ?? liveRunDurationSeconds(run);
  const status = normalizedLiveStatus(job || run);
  liveState.trackUpstreamRunId = run.id;
  liveState.trackUpstreamJobUrl = url;
  liveState.trackUpstreamJobDurationSeconds = durationSeconds;
  liveState.trackUpstreamJobStatus = status;
  return { url, durationSeconds, status };
}

async function applyLiveTrackUpstream(latestByWorkflow) {
  const run = latestByWorkflow["track-upstream-releases.yml"];
  const stableStatusEl = document.getElementById("stable-track-status");
  const edgeStatusEl = document.getElementById("edge-track-status");
  const stableWorkflowEl = document.getElementById("stable-track-workflow");
  const edgeWorkflowEl = document.getElementById("edge-track-workflow");

  if (!stableStatusEl || !edgeStatusEl) return;

  let isBuilding = false;
  let jobUrl = "";
  let durationSeconds = null;

  if (run) {
    const status = normalizedLiveStatus(run);
    isBuilding = isBuildingStatus(status);
    const jobDetails = await resolveTrackUpstreamJob(run);
    jobUrl = jobDetails.url || run.html_url || "";
    durationSeconds = jobDetails.durationSeconds;
    if (jobDetails.status) {
      isBuilding = isBuildingStatus(jobDetails.status);
    }
  }

  if (isBuilding) {
    const buildingHtml = `<span class="status-chip status-building is-building" aria-label="Status: checking">${statusIconSvg("building")}<span class="status-text-full" aria-hidden="true">checking</span><span class="status-text-short" aria-hidden="true">checking</span></span>`;
    stableStatusEl.parentElement.innerHTML = `<span id="stable-track-status">${buildingHtml}</span>`;
    edgeStatusEl.parentElement.innerHTML = `<span id="edge-track-status">${buildingHtml}</span>`;
  } else {
    // Restore standard status chips
    // Stable
    const stableComponents = dependencyRows.length
      ? dependencyRows
      : globalDashboardData?.release_info?.components || [];
    const stableUpdateAvailable = stableComponents.some((c) => c.update_available);
    const stableClass = stableUpdateAvailable
      ? "status-chip status-caution"
      : "status-chip status-success";
    const stableIcon = stableUpdateAvailable ? warningIconSvg : checkIconSvg;
    const stableText = stableUpdateAvailable ? "Update pending" : "Up to date";
    const stableShort = stableUpdateAvailable ? "pending" : "current";
    stableStatusEl.parentElement.innerHTML = `<span id="stable-track-status" class="${stableClass}" aria-label="Status: ${stableText}">${stableIcon}<span class="status-text-full" aria-hidden="true">${stableText}</span><span class="status-text-short" aria-hidden="true">${stableShort}</span></span>`;

    // Edge
    const edgeComponents = globalDashboardData?.auto_update?.edge_releases || [];
    const edgeUpdateAvailable = edgeComponents.some((c) => c.update_available);
    const edgeClass = edgeUpdateAvailable
      ? "status-chip status-caution"
      : "status-chip status-success";
    const edgeIcon = edgeUpdateAvailable ? warningIconSvg : checkIconSvg;
    const edgeText = edgeUpdateAvailable ? "Update pending" : "Up to date";
    const edgeShort = edgeUpdateAvailable ? "pending" : "current";
    edgeStatusEl.parentElement.innerHTML = `<span id="edge-track-status" class="${edgeClass}" aria-label="Status: ${edgeText}">${edgeIcon}<span class="status-text-full" aria-hidden="true">${edgeText}</span><span class="status-text-short" aria-hidden="true">${edgeShort}</span></span>`;

    // Also update the timestamps if completed
    if (run && run.status === "completed" && run.conclusion === "success") {
      const lastCheck = run.updated_at;
      const nextCheckDate = getNextCronTime();
      const nextCheck = nextCheckDate.toISOString();
      setText("stable-track-updated", formatDate(lastCheck));
      setText("edge-track-updated", formatDate(lastCheck));
      setText("stable-track-next", formatDate(nextCheck));
      setText("edge-track-next", formatDate(nextCheck));
      releaseTrackingNextCheckMs = nextCheckDate.getTime();
      renderReleaseTrackingScheduleNote();
    }
  }

  // Update workflows column
  let workflowHtml = "N/A";
  if (jobUrl) {
    workflowHtml = workflowButtonHtml(jobUrl, durationSeconds, "Upstream sync job", isBuilding);

    // Also update the components/dependencies status and workflow cells with live job data.
    renderDependencies();
  }

  if (stableWorkflowEl) stableWorkflowEl.innerHTML = workflowHtml;
  if (edgeWorkflowEl) edgeWorkflowEl.innerHTML = workflowHtml;

  // Equalize button widths for sync tracking table
  const containerTable = stableStatusEl.closest("table");
  if (containerTable) {
    setTimeout(() => {
      const buttons = containerTable.querySelectorAll(".workflow-btn");
      if (buttons.length === 0) return;
      let maxWidth = 0;
      buttons.forEach((btn) => {
        btn.style.width = "auto";
        maxWidth = Math.max(maxWidth, btn.offsetWidth);
      });
      buttons.forEach((btn) => {
        btn.style.width = maxWidth + "px";
      });
    }, 0);
  }
}

// Updates state of the top header live indicator pill (active, building)
// Sets up the poll timeout clock
function scheduleLivePoll(building) {
  if (liveState.pollTimer) {
    clearTimeout(liveState.pollTimer);
    liveState.pollTimer = null;
  }
  if (document.hidden) {
    freshnessState.live.nextAt = null;
    return;
  }
  const budgetOk = liveState.rateRemaining === null || liveState.rateRemaining > LIVE_RATE_FLOOR;
  const interval = !budgetOk
    ? LIVE_POLL_MS_BACKOFF
    : building
      ? LIVE_POLL_MS_BUILDING
      : LIVE_POLL_MS_IDLE;
  freshnessState.live.nextAt = Date.now() + interval;
  liveState.pollTimer = setTimeout(refreshLiveData, interval);
}

// High level orchestrator for synchronizing live GitHub API states
async function refreshLiveData() {
  try {
    const snapshot = await loadDashboardData();
    globalDashboardData = snapshot;
    renderBakedSections(snapshot, {
      renderChannelSwitchSection: false,
    });
  } catch (error) {
    // Fallback to screen state if offline
  }

  const runs = await fetchRecentRuns();
  if (!runs) {
    freshnessState.live.status = "stale";
    scheduleLivePoll(false);
    renderFreshnessChips();
    return;
  }
  freshnessState.live.updatedAt = new Date().toISOString();
  const latestByWorkflow = latestRunByWorkflow(runs);

  const branchName = "main";
  const cicdRuns = runs.filter(
    (run) => (run.path || "").endsWith("/cicd.yml") && run.head_branch === branchName,
  );
  const lpRuns = runs.filter(
    (run) => (run.path || "").endsWith("/launchpad-builds.yml") && run.head_branch === branchName,
  );

  let matrixBuilding = false;
  let cicdJobs = liveState.cicdJobs;
  const latestCicd = cicdRuns[0] || null;
  let cicdRun = liveState.cicdRun || latestCicd;

  if (latestCicd) {
    const effective =
      latestCicd.status === "completed" ? latestCicd.conclusion || "" : latestCicd.status || "";
    const cicdBuilding = BUILDING_STATES.has(effective.toLowerCase());
    const cicdChanged = latestCicd.id !== liveState.lastCicdRunId;
    if (cicdChanged || cicdBuilding || liveState.lastCicdRunId === null || !liveState.cicdJobs) {
      const { jobs, run } = await liveMatrixJobsAndRun(cicdRuns);
      const result = applyLiveMatrixFromJobs(jobs, run);
      matrixBuilding = result.building;
      liveState.lastCicdRunId = latestCicd.id;
      liveState.releaseLagDue = true;
    } else {
      matrixBuilding = matrixState.rows.some((row) => isBuildingStatus(row.status));
    }

    const latestCicdBuilding = BUILDING_STATES.has((latestCicd.status || "").toLowerCase());
    const latestChanged =
      latestCicd.id !== liveState.lastCicdRunId ||
      !liveState.cicdJobs ||
      (liveState.cicdRun && liveState.cicdRun.id !== latestCicd.id);
    if (latestChanged || latestCicdBuilding) {
      cicdJobs = await fetchRunJobs(latestCicd.id);
      cicdRun = latestCicd;
      liveState.cicdJobs = cicdJobs;
      liveState.cicdRun = cicdRun;
    } else {
      cicdJobs = liveState.cicdJobs;
      cicdRun = liveState.cicdRun;
    }
  }

  // Fetch launchpad build jobs if the latest run is building or not fetched yet
  let lpJobs = null;
  let lpRun = null;
  const latestLp = lpRuns[0] || null;
  if (latestLp) {
    lpRun = latestLp;
    const lpBuilding = BUILDING_STATES.has((latestLp.status || "").toLowerCase());
    if (
      lpBuilding ||
      !liveState.lastLpRunId ||
      latestLp.id !== liveState.lastLpRunId ||
      !liveState.lpJobs
    ) {
      lpJobs = await fetchRunJobs(latestLp.id);
      liveState.lastLpRunId = latestLp.id;
      liveState.lpJobs = lpJobs;
      liveState.lpRun = latestLp;
    } else {
      lpJobs = liveState.lpJobs;
      lpRun = liveState.lpRun || latestLp;
    }
  }

  applyLiveSnapStatus(cicdJobs, cicdRun, lpJobs, lpRun);

  let buildBuilding = false;
  try {
    buildBuilding = applyLiveBuildStatus(runs);
  } catch (error) {
    buildBuilding = false;
  }

  try {
    await applyLiveTrackUpstream(latestByWorkflow);
  } catch (error) {
    // Keep the package table live even if upstream tracking rendering fails.
  }

  let channelSwitchBuilding = false;
  try {
    channelSwitchBuilding = await applyLiveChannelSwitch(latestByWorkflow);
  } catch (error) {
    channelSwitchBuilding = false;
  }

  const lpBuildingStatus = latestLp && BUILDING_STATES.has((latestLp.status || "").toLowerCase());
  const trackBuildingStatus =
    latestByWorkflow["track-upstream-releases.yml"] &&
    BUILDING_STATES.has(
      (latestByWorkflow["track-upstream-releases.yml"].status || "").toLowerCase(),
    );

  const building =
    matrixBuilding ||
    buildBuilding ||
    lpBuildingStatus ||
    trackBuildingStatus ||
    channelSwitchBuilding;
  const anyRunning = runs.some((run) => BUILDING_STATES.has((run.status || "").toLowerCase()));
  freshnessState.live.status = building ? "building" : anyRunning ? "active" : "idle";

  if (!liveState.releaseLagDone || liveState.releaseLagDue) {
    liveState.releaseLagDone = true;
    liveState.releaseLagDue = false;
    // Moved to build-time: we don't query github API client-side to stay within 60 queries/hr limit
    // refreshReleaseLag();
    // refreshEdgeCommits();
  }

  scheduleLivePoll(building);
  renderFreshnessChips();
}

// Pulls upstream branch heads to refresh stable source-lag metrics live from the client
async function refreshReleaseLag() {
  if (!dependencyRows.length) return;
  if (liveState.rateRemaining !== null && liveState.rateRemaining <= 20) return;

  let changed = false;
  for (const item of dependencyRows) {
    if (!item.repository) continue;
    let release;
    try {
      const response = await fetch(`${GITHUB_API_BASE}/repos/${item.repository}/releases/latest`, {
        headers: {
          Accept: "application/vnd.github+json",
        },
        cache: "no-store",
      });
      const remaining = Number(response.headers.get("X-RateLimit-Remaining"));
      if (!Number.isNaN(remaining)) liveState.rateRemaining = remaining;
      if (!response.ok) continue;
      release = await response.json();
    } catch (error) {
      continue;
    }
    const upstreamTag = release.tag_name;
    if (!upstreamTag) continue;
    const upstreamDate = release.published_at || item.upstream_release_date;
    let lagDays = item.lag_days;
    const localDate = new Date(item.local_release_date);
    const upDate = new Date(upstreamDate);
    if (!Number.isNaN(localDate.getTime()) && !Number.isNaN(upDate.getTime())) {
      lagDays = Math.max(0, Math.floor((upDate - localDate) / 86400000));
    }
    item.upstream_tag = upstreamTag;
    item.upstream_release_date = upstreamDate;
    item.lag_days = lagDays;
    if (release.html_url) item.release_notes_url = release.html_url;

    // Fetch the branch head SHA. Stable builds pin this commit; tags are labels.
    try {
      const upstreamRef = item.upstream_ref || "master";
      const commitResponse = await fetch(
        `${GITHUB_API_BASE}/repos/${item.repository}/commits/${upstreamRef}`,
        {
          headers: {
            Accept: "application/vnd.github+json",
          },
          cache: "no-store",
        },
      );
      if (commitResponse.ok) {
        const commitData = await commitResponse.json();
        if (commitData && commitData.sha) {
          item.upstream_commit = commitData.sha;
          item.update_available = Boolean(
            item.local_commit && item.upstream_commit && item.local_commit !== item.upstream_commit,
          );
        }
      }
    } catch (e) {
      // ignore
    }

    changed = true;
  }
  if (changed && selectedBranch === "stable") {
    renderDependencies();
  }
}

async function refreshEdgeCommits() {
  const edgeComponents = globalDashboardData?.auto_update?.edge_releases || [];
  if (!edgeComponents.length) return;
  if (liveState.rateRemaining !== null && liveState.rateRemaining <= 20) return;

  let changed = false;
  for (const item of edgeComponents) {
    if (!item.repository) continue;
    try {
      const response = await fetch(
        `${GITHUB_API_BASE}/repos/${item.repository}/commits/${item.upstream_ref || "development"}`,
        {
          headers: {
            Accept: "application/vnd.github+json",
          },
          cache: "no-store",
        },
      );
      if (response.ok) {
        const commitData = await response.json();
        if (commitData && commitData.sha && item.upstream_commit !== commitData.sha) {
          item.upstream_commit = commitData.sha;
          item.update_available = Boolean(
            item.local_commit && item.local_commit !== commitData.sha,
          );
          changed = true;
        }
      }
    } catch (error) {
      // ignore
    }
    try {
      const releaseResponse = await fetch(
        `${GITHUB_API_BASE}/repos/${item.repository}/releases/latest`,
        {
          headers: {
            Accept: "application/vnd.github+json",
          },
          cache: "no-store",
        },
      );
      if (releaseResponse.ok) {
        const releaseData = await releaseResponse.json();
        if (releaseData && releaseData.tag_name && item.upstream_tag !== releaseData.tag_name) {
          item.upstream_tag = releaseData.tag_name;
          changed = true;
        }
      }
    } catch (error) {
      // ignore
    }
  }
  if (changed && selectedBranch === "edge") {
    renderDependencies();
  }
}

// 6. HOURLY SNAP STORE GIST METADATA SYNCHRONIZATION

// Searches the target user's gists to find the auto-published raw url path
async function discoverSnapGist() {
  if (snapState.rawUrl) return snapState.rawUrl;
  const owner = REPO_SLUG.split("/")[0];
  try {
    const response = await fetch(`${GITHUB_API_BASE}/users/${owner}/gists?per_page=100`, {
      headers: { Accept: "application/vnd.github+json" },
      cache: "no-store",
    });
    const remaining = Number(response.headers.get("X-RateLimit-Remaining"));
    if (!Number.isNaN(remaining)) liveState.rateRemaining = remaining;
    if (!response.ok) return null;
    const gists = await response.json();
    const list = Array.isArray(gists) ? gists : [];
    const match =
      list.find(
        (gist) =>
          gist &&
          gist.files &&
          gist.files[SNAP_GIST_FILENAME] &&
          (gist.description || "") === SNAP_GIST_DESCRIPTION,
      ) || list.find((gist) => gist && gist.files && gist.files[SNAP_GIST_FILENAME]);
    if (!match) return null;
    snapState.gistId = match.id;
    snapState.rawUrl = `https://gist.githubusercontent.com/${owner}/${match.id}/raw/${SNAP_GIST_FILENAME}`;
    return snapState.rawUrl;
  } catch (error) {
    return null;
  }
}

// Fetches the snapcraft JSON payload from the discovered Gist endpoint
async function fetchSnapcraftData() {
  const url = await discoverSnapGist();
  if (!url) return null;
  try {
    const response = await fetch(url, { cache: "no-store" });
    if (!response.ok) return null;
    const payload = await response.json();
    if (!payload || !payload.snap_package) return null;
    return payload;
  } catch (error) {
    return null;
  }
}

// Compares dashboard snap payload freshness. The gist is usually the best
// live source, but directly after a Pages deploy it can lag behind the
// deploy-time snapshot. In that case, keep the newer snapshot until the gist
// catches up.
function shouldApplySnapPayload(currentGeneratedAt, incomingPayload) {
  const incomingGeneratedAt = incomingPayload && incomingPayload.generated_at;
  if (!currentGeneratedAt || !incomingGeneratedAt) return true;
  const currentMs = new Date(currentGeneratedAt).getTime();
  const incomingMs = new Date(incomingGeneratedAt).getTime();
  if (Number.isNaN(currentMs) || Number.isNaN(incomingMs)) return true;
  return incomingMs >= currentMs;
}

function hasChannelSwitchEvidence(row) {
  return Array.isArray(row?.evidence) && row.evidence.length > 0;
}

function mergeChannelSwitchData(current, incoming) {
  if (!incoming) return current;
  if (!current) return incoming;
  const sameRun =
    current.run_id && incoming.run_id && String(current.run_id) === String(incoming.run_id);
  if (!sameRun) return incoming;

  const currentRows = Array.isArray(current.rows) ? current.rows : [];
  const incomingRows = Array.isArray(incoming.rows) ? incoming.rows : [];
  const rows = incomingRows.length
    ? incomingRows.map((row) => {
        const previous = currentRows.find(
          (candidate) => String(candidate.arch || "") === String(row.arch || ""),
        );
        if (!previous || hasChannelSwitchEvidence(row)) {
          return row;
        }
        if (!hasChannelSwitchEvidence(previous)) {
          return row;
        }
        return {
          ...previous,
          ...row,
          evidence: previous.evidence,
        };
      })
    : currentRows;

  return {
    ...current,
    ...incoming,
    rows,
  };
}

// Resolves and displays gist snap-store and channel-switch data
function applySnapData(payload) {
  if (!shouldApplySnapPayload(snapState.generatedAt, payload)) {
    renderFreshnessChips();
    return false;
  }
  renderSnapPackage(payload.snap_package || {});
  if (payload.channel_switch) {
    const channelSwitch = mergeChannelSwitchData(
      globalDashboardData.channel_switch,
      payload.channel_switch,
    );
    globalDashboardData.channel_switch = channelSwitch;
    renderChannelSwitch(channelSwitch);
  }
  applyLiveSnapStatus(liveState.cicdJobs, liveState.cicdRun, liveState.lpJobs, liveState.lpRun);
  snapState.hasGistData = true;
  snapState.generatedAt = payload.generated_at || snapState.generatedAt;
  setSnapClock(payload.data_last_updated || (payload.snap_package || {}).last_updated, true);
  renderFreshnessChips();
  return true;
}

// Triggers hourly snap-data refresh
async function maybeRefreshSnap() {
  const now = Date.now();
  if (snapState.inFlight) return;
  if (snapState.nextAt && now < snapState.nextAt) return;
  if (snapState.lastFetch && now - snapState.lastFetch < SNAP_MIN_REFETCH_MS) return;

  snapState.inFlight = true;
  let payload = null;
  try {
    payload = await fetchSnapcraftData();
  } finally {
    snapState.inFlight = false;
    snapState.lastFetch = Date.now();
  }

  const boundary = nextHourBoundary(Date.now());
  if (payload) {
    snapState.nextAt = boundary;
    const applied = applySnapData(payload);
    if (!applied) {
      snapState.nextAt = Math.min(Date.now() + SNAP_MIN_REFETCH_MS, boundary);
      freshnessState.snap.nextAt = boundary;
    }
  } else {
    snapState.nextAt = boundary;
    freshnessState.snap.nextAt = boundary;
    renderFreshnessChips();
  }
}

// 7. INITIALIZATION / BOOTSTRAP

let globalDashboardData = null;
let selectedBranch = "stable";

// Loads local dashboard-data.json
async function loadDashboardData() {
  const response = await fetch("./dashboard-data.json", {
    cache: "no-store",
  });
  if (!response.ok) {
    throw new Error(`Failed to load dashboard-data.json (${response.status})`);
  }
  return response.json();
}

function renderBranchData() {
  if (!globalDashboardData) return;
  updateChannelScopeSummary();
  const buildStatus = globalDashboardData.build_status?.[selectedBranch] || {};
  const testMatrix = globalDashboardData.test_matrix?.[selectedBranch] || {};

  const snapPackagesTitle = document.getElementById("snap-packages-title");
  if (snapPackagesTitle) {
    snapPackagesTitle.textContent =
      selectedBranch === "stable" ? "Stable channel snap packages" : "Edge channel snap packages";
  }

  renderBuildStatus(buildStatus);
  renderFailedLogs(testMatrix);
  matrixState.rows = testMatrix.rows || [];
  matrixState.failedLinks = testMatrix.failed_links || [];
  renderMatrixRows();
  renderDependencies();
  if (globalDashboardData.security) {
    renderSecurity(globalDashboardData.security);
  }
  if (snapState.snapPackage) {
    renderSnapPackage(snapState.snapPackage);
  }
}

function resetLiveWorkflowCache() {
  liveState.lastCicdRunId = null;
  liveState.lastLpRunId = null;
  liveState.lastChannelSwitchRunId = null;
  liveState.lastChannelSwitchRunUpdatedAt = null;
  liveState.channelSwitchJobs = null;
  liveState.cicdJobs = null;
  liveState.cicdRun = null;
  liveState.lpJobs = null;
  liveState.lpRun = null;
}

function setupBranchSelector() {
  const btnStable = document.getElementById("btn-stable");
  const btnEdge = document.getElementById("btn-edge");

  if (btnStable && btnEdge) {
    btnStable.addEventListener("click", () => {
      if (selectedBranch === "stable") return;
      selectedBranch = "stable";
      btnStable.classList.add("is-active");
      btnStable.setAttribute("aria-selected", "true");
      btnStable.removeAttribute("tabindex");
      btnEdge.classList.remove("is-active");
      btnEdge.setAttribute("aria-selected", "false");
      btnEdge.setAttribute("tabindex", "-1");
      renderBranchData();
      resetLiveWorkflowCache();
      refreshLiveData();
    });

    btnEdge.addEventListener("click", () => {
      if (selectedBranch === "edge") return;
      selectedBranch = "edge";
      btnStable.classList.remove("is-active");
      btnStable.setAttribute("aria-selected", "false");
      btnStable.setAttribute("tabindex", "-1");
      btnEdge.classList.add("is-active");
      btnEdge.setAttribute("aria-selected", "true");
      btnEdge.removeAttribute("tabindex");
      renderBranchData();
      resetLiveWorkflowCache();
      refreshLiveData();
    });
  }
}

// Renders baked/snapshot data sections
function renderBakedSections(data, options = {}) {
  const renderChannelSwitchSection = options.renderChannelSwitchSection !== false;
  freshnessState.build.updatedAt = data.generated_at || data.data_last_updated || null;
  const freq = data.auto_update?.frequency || {};
  setText("stable-track-cadence", freq.label || "Every 3 hours");
  setText("edge-track-cadence", freq.label || "Every 3 hours");
  renderSecurity(data.security || {});
  renderReleaseInfo(data);
  renderReportSummaries(data);
  if (renderChannelSwitchSection) {
    renderChannelSwitch(data.channel_switch);
  }
  dependencyRows = data.release_info?.components || [];
  renderDependencies();
  renderFreshnessChips();
}

// Primary entry point to boot the reports page UI dashboard
async function initDashboard() {
  startFreshnessTicker();
  setupBranchSelector();
  document.addEventListener("visibilitychange", () => {
    if (document.hidden) {
      if (liveState.pollTimer) {
        clearTimeout(liveState.pollTimer);
        liveState.pollTimer = null;
      }
      freshnessState.live.nextAt = null;
      freshnessState.live.status = "paused";
      renderFreshnessChips();
    } else {
      if (freshnessState.live.status === "paused") {
        freshnessState.live.status = "idle";
        refreshLiveData();
      }
    }
  });
  try {
    globalDashboardData = await loadDashboardData();

    renderBranchData();
    dependencyRows = globalDashboardData.release_info?.components || [];
    renderDependencies();
    renderBakedSections(globalDashboardData);
    maybeRefreshSnap();
    refreshLiveData();
  } catch (error) {
    freshnessState.build.updatedAt = null;
    setText("stable-track-cadence", "Unavailable");
    setText("edge-track-cadence", "Unavailable");
    renderFreshnessChips();
    const matrixBody = document.getElementById("compatibility-matrix-body");
    if (matrixBody) {
      matrixBody.innerHTML = `<tr><td colspan="5">Unable to load dashboard data: ${error.message}</td></tr>`;
    }
  }
}

initDashboard();
