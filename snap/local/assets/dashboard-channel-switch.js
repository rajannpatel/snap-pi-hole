(function (root, factory) {
  const moduleApi = factory();
  if (typeof module !== "undefined" && module.exports) {
    module.exports = moduleApi;
  }
  root.DashboardChannelSwitch = moduleApi;
}(typeof globalThis !== "undefined" ? globalThis : this, function () {
  const BUILDING_STATES = new Set(["queued", "in_progress", "requested", "waiting", "pending", "running", "building"]);

  function escapeHtml(value) {
    return String(value ?? "").replace(/[&<>"']/g, (ch) => ({
      "&": "&amp;",
      "<": "&lt;",
      ">": "&gt;",
      "\"": "&quot;",
      "'": "&#39;",
    }[ch]));
  }

  function isBuildingStatus(status) {
    return BUILDING_STATES.has(String(status || "").toLowerCase());
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
    if (!evidence.length) {
      return `<p class="channel-switch-explanation__body">${escapeHtml(channelSwitchDetailsText(row))}</p>`;
    }
    const intro = `<p class="channel-switch-explanation__body">${escapeHtml(channelSwitchDetailsText(row))}</p>`;
    const blocks = evidence.map((item) => {
      const title = item?.title || "Check";
      const status = item?.status || "unknown";
      const command = item?.command || "";
      const output = item?.output || "";
      const chipClass = status === "success" ? "p-chip--positive" : (status === "failure" ? "p-chip--negative" : "");
      const statusLabel = status === "failure" ? "fail" : status;
      return `
        <div class="channel-switch-evidence">
          <div class="channel-switch-evidence__header">
            <span class="channel-switch-evidence__title">${escapeHtml(title)}</span>
            <span class="p-chip ${chipClass}"><span class="p-chip__value">${escapeHtml(statusLabel)}</span></span>
          </div>
          ${command ? `<div class="p-code-snippet"><pre class="p-code-snippet__block--icon"><code>$ ${escapeHtml(command)}</code></pre></div>` : ""}
          ${output ? `<div class="p-code-snippet"><pre class="p-code-snippet__block"><code>${escapeHtml(output)}</code></pre></div>` : ""}
        </div>
      `;
    }).join("");
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
          title: waiting ? "Waiting for runner result" : (succeeded ? "Refresh path verified" : "Runner result missing revisions"),
          meta: [],
          description: waiting
            ? "Channel revisions will appear after the GitHub runner uploads the channel-switch result artifact."
            : (succeeded
              ? "The GitHub runner completed successfully; channel revision evidence will appear after the dashboard data refresh reads the result artifact."
              : "The GitHub runner result did not include stable and edge revision evidence for the refresh path."),
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
          description: state.reason || "The workflow skipped because there is no channel delta to test.",
        },
      ];
    }
    if (path === "stable-to-edge") {
      return [
        {
          title: stableToEdgeCommand,
          meta: [stablePoint, edgePoint],
          description: state.status === "failure" ? `Stable to edge: ${state.reason || "transition failed"}.` : "Stable to edge: edge refresh completed and health checks passed.",
        },
      ];
    }
    if (path === "edge-to-stable") {
      return [
        {
          title: edgeToStableCommand,
          meta: [edgePoint, stablePoint],
          description: state.status === "failure" ? `Edge to stable: ${state.reason || "transition failed"}.` : "Edge to stable: stable rollback completed and health checks passed.",
        },
      ];
    }
    return [
      {
        title: stableToEdgeCommand,
        meta: [stablePoint, edgePoint],
        description: state.status === "failure" ? `Stable to edge: ${state.reason || "transition failed before round trip completed"}.` : "Stable to edge: edge refresh completed and health checks passed.",
      },
      {
        title: edgeToStableCommand,
        meta: [edgePoint, stablePoint],
        description: state.status === "failure" ? `Edge to stable: ${state.summary || "stable rollback did not complete cleanly"}.` : "Edge to stable: stable rollback completed and health checks passed.",
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
    return list.map(channelRevisionChipHtml).join('<i class="p-icon--chevron-right channel-switch-chevron" aria-hidden="true"></i>');
  }

  function channelSwitchTimelineHtml(cs) {
    return channelSwitchPathSteps(cs).map((step) => `
        <li class="p-list-timeline__item">
          <div class="p-list-timeline__node"></div>
          <div class="p-list-timeline__content">
            <h4 class="p-list-timeline__title">${escapeHtml(step.title)}</h4>
            <div class="p-list-timeline__meta channel-switch-path">${channelSwitchMetaHtml(step.meta)}</div>
            <p class="p-list-timeline__description">${escapeHtml(step.description)}</p>
          </div>
        </li>
      `).join("");
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
}));
