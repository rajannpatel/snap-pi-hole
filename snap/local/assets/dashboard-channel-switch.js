(function (root, factory) {
  const moduleApi = factory();
  if (typeof module !== "undefined" && module.exports) {
    module.exports = moduleApi;
  }
  root.DashboardChannelSwitch = moduleApi;
})(typeof globalThis !== "undefined" ? globalThis : this, function () {
  const BUILDING_STATES = new Set([
    "queued",
    "in_progress",
    "requested",
    "waiting",
    "pending",
    "running",
    "building",
  ]);
  const FAILURE_STATES = new Set(["failure", "timed_out", "action_required", "startup_failure"]);
  const checkIconSvg = `<svg class="status-chip-logo" viewBox="0 0 16 16" width="12" height="12" fill="currentColor"><path d="M13.78 4.22a.75.75 0 0 1 0 1.06l-7.25 7.25a.75.75 0 0 1-1.06 0L2.22 9.28a.75.75 0 0 1 1.06-1.06L6 10.94l6.72-6.72a.75.75 0 0 1 1.06 0z"/></svg>`;
  const warningIconSvg = `<svg class="status-chip-logo" viewBox="0 0 16 16" width="12" height="12" fill="currentColor"><path d="M8 15A7 7 0 1 1 8 1a7 7 0 0 1 0 14zm0 1A8 8 0 1 0 8 0a8 8 0 0 0 0 16z"/><path d="M7.002 11a1 1 0 1 1 2 0 1 1 0 0 1-2 0zM7.1 4.995a.905.905 0 1 1 1.8 0l-.35 3.5a.552.552 0 0 1-1.1 0l-.35-3.5z"/></svg>`;
  const errorIconSvg = `<svg class="status-chip-logo" viewBox="0 0 16 16" width="12" height="12" fill="currentColor"><path d="M4.646 4.646a.5.5 0 0 1 .708 0L8 7.293l2.646-2.647a.5.5 0 0 1 .708.708L8.707 8l2.647 2.646a.5.5 0 0 1-.708.708L8 8.707l-2.646 2.647a.5.5 0 0 1-.708-.708L7.293 8 4.646 5.354a.5.5 0 0 1 0-.708z"/></svg>`;
  const clockIconSvg = `<svg class="status-chip-logo" viewBox="0 0 16 16" width="12" height="12" fill="currentColor"><path d="M8 15A7 7 0 1 1 8 1a7 7 0 0 1 0 14zm0 1A8 8 0 1 0 8 0a8 8 0 0 0 0 16z"/><path d="M8 3.5a.75.75 0 0 1 .75.75v3.25h3.25a.75.75 0 0 1 0 1.5h-4a.75.75 0 0 1-.75-.75v-4A.75.75 0 0 1 8 3.5z"/></svg>`;
  const skippedIconSvg = `<svg class="status-chip-logo" viewBox="0 0 16 16" width="12" height="12" fill="currentColor"><path d="M8 15A7 7 0 1 1 8 1a7 7 0 0 1 0 14zm0 1A8 8 0 1 0 8 0a8 8 0 0 0 0 16z"/><path d="M4.25 7.25h7.5a.75.75 0 0 1 0 1.5h-7.5a.75.75 0 0 1 0-1.5z"/></svg>`;

  function escapeHtml(value) {
    return String(value ?? "").replace(
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

  function isBuildingStatus(status) {
    return BUILDING_STATES.has(String(status || "").toLowerCase());
  }

  function statusIconSvg(status) {
    const normalized = String(status || "unknown").toLowerCase();
    if (normalized === "success") return checkIconSvg;
    if (FAILURE_STATES.has(normalized)) return errorIconSvg;
    if (BUILDING_STATES.has(normalized)) return clockIconSvg;
    if (normalized === "skipped" || normalized === "cancelled") return skippedIconSvg;
    return warningIconSvg;
  }

  function channelSwitchDetailsText(row) {
    if (!row) return "No details available";
    if (row.reason) return row.reason;
    if (row.status === "success") return "Health checks passed";
    if (row.status === "skipped") return "No channel delta to test";
    if (row.status === "in_progress" || row.status === "queued") return "Workflow running";
    return row.summary || "No details available";
  }

  function channelSwitchEvidenceHtml(row) {
    const evidence = Array.isArray(row?.evidence) ? row.evidence : [];
    const detailText = channelSwitchDetailsText(row);
    const summary = row?.summary && row.summary !== detailText ? row.summary : "";
    const summaryHtml = summary
      ? `<p class="channel-switch-explanation__body channel-switch-explanation__body--secondary">${escapeHtml(summary)}</p>`
      : "";
    const intro = `<p class="channel-switch-explanation__body">${escapeHtml(detailText)}</p>${summaryHtml}`;

    if (!evidence.length) {
      return intro;
    }
    const blocks = evidence
      .map((item) => {
        const title = item?.title || "Check";
        const status = String(item?.status || "unknown").toLowerCase();
        const command = item?.command || "";
        const output = item?.output || "";
        const chipClass =
          status === "success"
            ? "status-success"
            : status === "failure"
              ? "status-failure"
              : isBuildingStatus(status)
                ? "status-building is-building"
                : "status-neutral";
        const statusLabel = status === "failure" ? "fail" : status.replace(/_/g, " ");
        return `
        <div class="channel-switch-evidence">
          <div class="channel-switch-evidence__header">
            <span class="channel-switch-evidence__title">${escapeHtml(title)}</span>
            <span class="status-chip ${chipClass}" aria-label="Status: ${escapeHtml(statusLabel)}">${statusIconSvg(status)}<span class="status-text-full" aria-hidden="true">${escapeHtml(statusLabel)}</span><span class="status-text-short" aria-hidden="true">${escapeHtml(statusLabel)}</span></span>
          </div>
          ${command ? `<div class="p-code-snippet"><pre class="p-code-snippet__block--icon is-wrapped"><code>${escapeHtml(command)}</code></pre></div>` : ""}
          ${output ? `<div class="p-code-snippet"><pre class="p-code-snippet__block is-wrapped"><code>${escapeHtml(output)}</code></pre></div>` : ""}
        </div>
      `;
      })
      .join("");
    return intro + blocks;
  }

  function channelSwitchPathSteps(cs) {
    const state = cs || {};
    const path = state.path || "roundtrip";
    const snapName = state.snap_name || "pihole-by-rajannpatel";
    const stableToEdgeCommand = `sudo snap refresh ${snapName} --channel=latest/edge`;
    const edgeToStableCommand = `sudo snap refresh ${snapName} --channel=latest/stable`;
    const stableRevision = state.stable_revision || state.channels?.stable?.revision || "";
    const edgeRevision = state.edge_revision || state.channels?.edge?.revision || "";
    if (!stableRevision || !edgeRevision) {
      const waiting = isBuildingStatus(state.status) || state.status === "no_data";
      const succeeded = state.status === "success";
      return [
        {
          title: waiting
            ? "Waiting for runner result"
            : succeeded
              ? "Refresh path verified"
              : "Runner result missing revisions",
          meta: [],
          description: waiting
            ? "Channel revisions will appear after the GitHub runner uploads the channel-switch result artifact."
            : succeeded
              ? "The GitHub runner completed successfully; channel revision evidence will appear after the dashboard data refresh reads the result artifact."
              : "The GitHub runner result did not include stable and edge revision evidence for the refresh path.",
        },
      ];
    }

    const stablePoint = { channel: "stable", revision: stableRevision };
    const edgePoint = { channel: "edge", revision: edgeRevision };
    if (state.status === "skipped") {
      return [
        {
          title: "No channel transition required",
          meta: [stablePoint, edgePoint],
          description:
            state.reason || "The workflow skipped because there is no channel delta to test.",
        },
      ];
    }
    if (path === "stable-to-edge") {
      return [
        {
          title: stableToEdgeCommand,
          meta: [stablePoint, edgePoint],
          description:
            state.status === "failure"
              ? `Stable to edge: ${state.reason || "transition failed"}.`
              : "Stable to edge: edge refresh completed and health checks passed.",
        },
      ];
    }
    if (path === "edge-to-stable") {
      return [
        {
          title: edgeToStableCommand,
          meta: [edgePoint, stablePoint],
          description:
            state.status === "failure"
              ? `Edge to stable: ${state.reason || "transition failed"}.`
              : "Edge to stable: stable rollback completed and health checks passed.",
        },
      ];
    }
    return [
      {
        title: stableToEdgeCommand,
        meta: [stablePoint, edgePoint],
        description:
          state.status === "failure"
            ? `Stable to edge: ${state.reason || "transition failed before round trip completed"}.`
            : "Stable to edge: edge refresh completed and health checks passed.",
      },
      {
        title: edgeToStableCommand,
        meta: [edgePoint, stablePoint],
        description:
          state.status === "failure"
            ? `Edge to stable: ${state.summary || "stable rollback did not complete cleanly"}.`
            : "Edge to stable: stable rollback completed and health checks passed.",
      },
    ];
  }

  function channelRevisionChipHtml(point) {
    const channel = point?.channel || "channel";
    const revision = point?.revision || "?";
    return `<span class="p-chip channel-switch-revision-chip"><span class="p-chip__value">${escapeHtml(channel)}</span><span class="channel-switch-revision-badge">r${escapeHtml(revision)}</span></span>`;
  }

  function channelSwitchMetaHtml(points) {
    const list = Array.isArray(points) ? points : [];
    if (!list.length) return "";
    return list
      .map(channelRevisionChipHtml)
      .join('<i class="p-icon--chevron-right channel-switch-chevron" aria-hidden="true"></i>');
  }

  function codeSnippetHtml(command) {
    return `<div class="p-code-snippet"><pre class="p-code-snippet__block--icon is-wrapped"><code>${escapeHtml(command)}</code></pre></div>`;
  }

  function channelSwitchTimelineHtml(cs) {
    return channelSwitchPathSteps(cs)
      .map((step) => {
        const command = step.title?.startsWith("sudo snap refresh ") ? step.title : "";
        const title = command ? codeSnippetHtml(command) : escapeHtml(step.title);
        return `
        <li class="p-list-timeline__item">
          <div class="p-list-timeline__node"></div>
          <div class="p-list-timeline__content">
            ${title}
            <div class="p-list-timeline__meta channel-switch-path">${channelSwitchMetaHtml(step.meta)}</div>
            <p class="p-list-timeline__description">${escapeHtml(step.description)}</p>
          </div>
        </li>
      `;
      })
      .join("");
  }

  return {
    channelRevisionChipHtml,
    channelSwitchEvidenceHtml,
    channelSwitchDetailsText,
    channelSwitchMetaHtml,
    channelSwitchPathSteps,
    channelSwitchTimelineHtml,
    escapeHtml,
  };
});
