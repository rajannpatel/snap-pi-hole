let currentComponents = [];

async function loadSBOM(arch) {
  document.getElementById("tab-amd64").classList.toggle("is-active", arch === "amd64");
  document.getElementById("tab-arm64").classList.toggle("is-active", arch === "arm64");
  document
    .getElementById("tab-amd64")
    .setAttribute("aria-pressed", arch === "amd64" ? "true" : "false");
  document
    .getElementById("tab-arm64")
    .setAttribute("aria-pressed", arch === "arm64" ? "true" : "false");

  const loading = document.getElementById("sbom-loading");
  const errorDiv = document.getElementById("sbom-error");
  const table = document.getElementById("sbom-table");
  const searchSec = document.getElementById("search-section");
  const metadataSec = document.getElementById("metadata-section");
  const tbody = document.getElementById("sbom-tbody");

  loading.style.display = "block";
  errorDiv.style.display = "none";
  table.style.display = "none";
  searchSec.style.display = "none";
  metadataSec.style.display = "none";
  tbody.innerHTML = "";

  try {
    const response = await fetch(`sbom-${arch}.json`);
    if (!response.ok) {
      throw new Error(
        `Failed to fetch sbom-${arch}.json: ${response.status} ${response.statusText}`,
      );
    }
    const data = await response.json();
    currentComponents = data.components || [];

    // Sort components by name alphabetically
    currentComponents.sort((a, b) => a.name.localeCompare(b.name));

    // Fill metadata
    document.getElementById("meta-total").textContent = currentComponents.length;

    const syftInfo =
      data.metadata && data.metadata.tools && data.metadata.tools.components
        ? data.metadata.tools.components.map((c) => `${c.name} ${c.version}`).join(", ")
        : "Syft";
    document.getElementById("meta-tool").textContent = syftInfo;

    const timestampStr = data.metadata && data.metadata.timestamp ? data.metadata.timestamp : "";
    const timeEl = document.getElementById("meta-time");
    if (timestampStr) {
      timeEl.setAttribute("datetime", timestampStr);
      timeEl.textContent = new Date(timestampStr).toLocaleString();
    } else {
      timeEl.removeAttribute("datetime");
      timeEl.textContent = "N/A";
    }

    loading.style.display = "none";
    searchSec.style.display = "block";
    metadataSec.style.display = "flex";
    table.style.display = "table";

    document.getElementById("sbom-search").value = "";
    document.getElementById("filter-type").value = "all";
    document.getElementById("filter-license").value = "all";
    renderRows(currentComponents);
  } catch (err) {
    loading.style.display = "none";
    errorDiv.style.display = "block";
    document.getElementById("error-message").textContent = err.message;
  }
}

function renderRows(components) {
  const tbody = document.getElementById("sbom-tbody");
  tbody.innerHTML = "";

  if (components.length === 0) {
    tbody.innerHTML = `<tr><td colspan="4" class="u-align--center p-text--muted">No matching components found</td></tr>`;
    return;
  }

  components.forEach((c) => {
    const tr = document.createElement("tr");

    let licensesHtml = "";
    if (c.licenses && c.licenses.length > 0) {
      licensesHtml = c.licenses
        .map((l) => {
          const name = l.license ? l.license.id || l.license.name || "" : "";
          return name ? `<span class="p-chip is-dense is-inline">${escapeHtml(name)}</span>` : "";
        })
        .filter(Boolean)
        .join(" ");
    }
    if (!licensesHtml) {
      licensesHtml = '<span class="p-chip is-dense is-inline">None</span>';
    }

    tr.innerHTML = `
          <td>${escapeHtml(c.name)}</td>
          <td><code>${escapeHtml(c.version)}</code></td>
          <td><span class="p-text--small">${escapeHtml(c.type || "library")}</span></td>
          <td>${licensesHtml}</td>
        `;
    tbody.appendChild(tr);
  });
}

function filterSBOM() {
  const query = document.getElementById("sbom-search").value.toLowerCase().trim();
  const typeFilter = document.getElementById("filter-type").value;
  const licenseFilter = document.getElementById("filter-license").value;

  const filtered = currentComponents.filter((c) => {
    // 1. Search Query Match
    let searchMatch = true;
    if (query) {
      const nameMatch = (c.name || "").toLowerCase().includes(query);
      const verMatch = (c.version || "").toLowerCase().includes(query);
      const typeMatch = (c.type || "").toLowerCase().includes(query);

      let licensesStr = "";
      if (c.licenses && Array.isArray(c.licenses)) {
        licensesStr = c.licenses
          .map((l) => {
            if (!l) return "";
            if (l.license) {
              return l.license.id || l.license.name || "";
            }
            if (l.expression) {
              return l.expression;
            }
            return "";
          })
          .filter(Boolean)
          .join(" ");
      }
      const licenseMatch = licensesStr.toLowerCase().includes(query);
      searchMatch = nameMatch || verMatch || typeMatch || licenseMatch;
    }

    // 2. Type Filter Match
    let typeMatch = true;
    if (typeFilter !== "all") {
      typeMatch = (c.type || "library").toLowerCase() === typeFilter;
    }

    // 3. License Filter Match
    let licenseMatch = true;
    if (licenseFilter !== "all") {
      let licensesStr = "";
      if (c.licenses && Array.isArray(c.licenses)) {
        licensesStr = c.licenses
          .map((l) => {
            if (!l) return "";
            if (l.license) {
              return l.license.id || l.license.name || "";
            }
            if (l.expression) {
              return l.expression;
            }
            return "";
          })
          .filter(Boolean)
          .join(" ")
          .toLowerCase();
      }

      const hasGpl = licensesStr.includes("gpl") || licensesStr.includes("lgpl");
      const hasPermissive =
        licensesStr.includes("mit") ||
        licensesStr.includes("apache") ||
        licensesStr.includes("bsd") ||
        licensesStr.includes("isc") ||
        licensesStr.includes("public-domain") ||
        licensesStr.includes("expat") ||
        licensesStr.includes("openldap");

      if (licenseFilter === "copyleft") {
        licenseMatch = hasGpl;
      } else if (licenseFilter === "permissive") {
        licenseMatch = hasPermissive;
      }
    }

    return searchMatch && typeMatch && licenseMatch;
  });

  renderRows(filtered);
}

function escapeHtml(str) {
  if (!str) return "";
  return str
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#039;");
}

window.addEventListener("DOMContentLoaded", () => {
  loadSBOM("amd64");
});
