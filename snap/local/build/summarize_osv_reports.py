#!/usr/bin/env python3
import html
import json
import math
import pathlib
import sys
from datetime import datetime, timezone


SEVERITY_ICONS = {
    "critical": "https://assets.ubuntu.com/v1/c96f27b9-CVE-Priority-icon-Critical.svg",
    "high": "https://assets.ubuntu.com/v1/3887354e-CVE-Priority-icon-High.svg",
    "medium": "https://assets.ubuntu.com/v1/8010f9e0-CVE-Priority-icon-Medium.svg",
    "low": "https://assets.ubuntu.com/v1/03ac6f86-CVE-Priority-icon-Low.svg",
    "negligible": "https://assets.ubuntu.com/v1/f6820eae-CVE-Priority-icon-Negligible.svg",
    "unknown": "https://assets.ubuntu.com/v1/e85d00c8-CVE-Priority-icon-Unknown.svg",
}


CVSS3_METRICS = {
    "AV": {"N": 0.85, "A": 0.62, "L": 0.55, "P": 0.2},
    "AC": {"L": 0.77, "H": 0.44},
    "UI": {"N": 0.85, "R": 0.62},
    "S": {"U": "U", "C": "C"},
    "C": {"H": 0.56, "L": 0.22, "N": 0.0},
    "I": {"H": 0.56, "L": 0.22, "N": 0.0},
    "A": {"H": 0.56, "L": 0.22, "N": 0.0},
}


CVSS3_PR = {
    "U": {"N": 0.85, "L": 0.62, "H": 0.27},
    "C": {"N": 0.85, "L": 0.68, "H": 0.5},
}


def vuln_url(vulnerability):
    references = vulnerability.get("references", [])
    for ref in references:
        url = ref.get("url")
        if url:
            return url
    vuln_id = vulnerability.get("id")
    if vuln_id:
        return f"https://osv.dev/vulnerability/{vuln_id}"
    return ""


def cvss3_round_up(score):
    return math.ceil(score * 10) / 10


def cvss3_base_score(vector):
    metrics = {}
    for part in vector.split("/"):
        if part.startswith("CVSS:"):
            continue
        if ":" in part:
            key, value = part.split(":", 1)
            metrics[key] = value

    try:
        scope = CVSS3_METRICS["S"][metrics["S"]]
        iss = 1 - (
            (1 - CVSS3_METRICS["C"][metrics["C"]])
            * (1 - CVSS3_METRICS["I"][metrics["I"]])
            * (1 - CVSS3_METRICS["A"][metrics["A"]])
        )
        impact = (
            6.42 * iss
            if scope == "U"
            else 7.52 * (iss - 0.029) - 3.25 * ((iss - 0.02) ** 15)
        )
        exploitability = (
            8.22
            * CVSS3_METRICS["AV"][metrics["AV"]]
            * CVSS3_METRICS["AC"][metrics["AC"]]
            * CVSS3_PR[scope][metrics["PR"]]
            * CVSS3_METRICS["UI"][metrics["UI"]]
        )
    except KeyError:
        return None

    if impact <= 0:
        return 0.0

    if scope == "U":
        score = min(impact + exploitability, 10)
    else:
        score = min(1.08 * (impact + exploitability), 10)

    return cvss3_round_up(score)


def cvss3_rating(score):
    if score is None:
        return "Unknown"
    if score == 0:
        return "None"
    if score < 4.0:
        return "Low"
    if score < 7.0:
        return "Medium"
    if score < 9.0:
        return "High"
    return "Critical"


def cvss3_severity_text(vulnerability):
    scored_vectors = []
    for severity in vulnerability.get("severity", []):
        if severity.get("type") != "CVSS_V3":
            continue
        vector = severity.get("score", "")
        score = cvss3_base_score(vector)
        if score is not None:
            scored_vectors.append((score, vector))

    if not scored_vectors:
        return "Unknown"

    score, _vector = max(scored_vectors)
    return f"{score:.1f} · {cvss3_rating(score)}"


def ubuntu_priority(vulnerability):
    for severity in vulnerability.get("severity", []):
        if severity.get("type") == "Ubuntu" and severity.get("score"):
            return severity["score"].lower()

    database_specific = vulnerability.get("database_specific", {})
    severity_value = database_specific.get("severity")
    if severity_value:
        return str(severity_value).lower()

    return "unknown"


def severity_priority(severity):
    severity_lower = severity.lower()
    for priority in ("critical", "high", "medium", "low", "negligible"):
        if priority in severity_lower:
            return priority
    return "unknown"


def status_chip(text, priority, alt):
    icon_priority = priority if priority in SEVERITY_ICONS else "unknown"
    visible_text = text.upper()
    return (
        '<span class="p-chip vulnerability-severity">'
        '<span class="p-chip__value">'
        f'<img src="{SEVERITY_ICONS[icon_priority]}" '
        f'alt="{html.escape(alt)}" '
        f'title="{html.escape(text)}" '
        'style="height: 14px; width: 14px; vertical-align: text-bottom; margin-right: 0.25rem;">'
        f'{html.escape(visible_text)}'
        '</span>'
        '</span>'
    )


def severity_icon(severity):
    priority = severity_priority(severity)
    return status_chip(severity, priority, f"{severity} severity")


def priority_icon(priority):
    priority_value = priority.lower()
    return status_chip(priority_value, priority_value, f"{priority_value} priority")


def display_vulnerability_id(vulnerability_id):
    return vulnerability_id.removeprefix("UBUNTU-")


def normalize_architecture_label(architecture):
    arch = str(architecture).strip().lower()
    if arch == "amd64":
        return "AMD64"
    if arch == "arm64":
        return "ARM64"
    return arch.upper()


def format_publication_date(value):
    text_value = str(value or "").strip()
    if not text_value:
        return "", "Unknown"

    normalized = text_value.replace("Z", "+00:00")
    try:
        published_at = datetime.fromisoformat(normalized)
    except ValueError:
        return text_value, text_value

    if published_at.tzinfo is None:
        published_at = published_at.replace(tzinfo=timezone.utc)

    published_utc = published_at.astimezone(timezone.utc)
    return (
        published_utc.isoformat(timespec="seconds").replace("+00:00", "Z"),
        published_utc.strftime("%Y-%m-%d"),
    )


def architecture_chip(architecture):
    return (
        '<span class="p-chip vulnerability-architecture">'
        f'<span class="p-chip__value">{html.escape(normalize_architecture_label(architecture))}</span>'
        "</span>"
    )


def vulnerability_entry(vulnerability):
    aliases = vulnerability.get("aliases", [])
    return {
        "id": vulnerability.get("id", "unknown"),
        "aliases": aliases,
        "summary": vulnerability.get("summary", ""),
        "details": vulnerability.get("details", ""),
        "severity": cvss3_severity_text(vulnerability),
        "priority": ubuntu_priority(vulnerability),
        "published": vulnerability.get("published", ""),
        "modified": vulnerability.get("modified", ""),
        "url": vuln_url(vulnerability),
    }


def markdown_cell(value):
    return str(value).replace("|", "\\|").replace("\n", " ").strip()


def generated_time(report_path):
    generated_at = datetime.fromtimestamp(report_path.stat().st_mtime, timezone.utc)
    return {
        "datetime": generated_at.isoformat(timespec="seconds").replace("+00:00", "Z"),
        "label": generated_at.strftime("%Y-%m-%d %H:%M UTC"),
    }


def collect_reports(reports_dir):
    summary = {"reports": [], "totalVulnerabilities": 0, "affectedPackages": 0}

    for report_path in sorted(reports_dir.glob("osv-*.json")):
        if report_path.name == "osv-summary.json":
            continue
        arch = report_path.stem.removeprefix("osv-")
        data = json.loads(report_path.read_text(encoding="utf-8"))
        vulnerabilities = 0
        affected_packages = 0
        entries = []

        for result in data.get("results", []):
            for package in result.get("packages", []):
                vulns = package.get("vulnerabilities", [])
                if not vulns:
                    continue

                # Only keep vulnerabilities that have a corresponding USN (found in ID, aliases, related, or references)
                filtered_vulns = []
                for v in vulns:
                    vuln_id = v.get("id", "")
                    aliases = v.get("aliases", [])
                    related = v.get("related", [])
                    references = v.get("references", [])
                    has_usn = (
                        vuln_id.startswith("USN-")
                        or any(a.startswith("USN-") for a in aliases)
                        or any(r.startswith("USN-") for r in related)
                        or any("/USN-" in ref.get("url", "") or "/notices/USN-" in ref.get("url", "") for ref in references)
                    )
                    if has_usn:
                        filtered_vulns.append(v)

                if not filtered_vulns:
                    continue

                affected_packages += 1
                vulnerabilities += len(filtered_vulns)
                pkg = package.get("package", {})
                entries.append({
                    "name": pkg.get("name", "unknown"),
                    "version": pkg.get("version", ""),
                    "ecosystem": pkg.get("ecosystem", ""),
                    "vulnerabilities": [vulnerability_entry(v) for v in filtered_vulns],
                })

        summary["reports"].append({
            "architecture": arch,
            "report": report_path.name,
            "generatedAt": generated_time(report_path),
            "affectedPackages": affected_packages,
            "vulnerabilities": vulnerabilities,
            "packages": entries,
        })

    # Calculate unique global counts across all architectures
    unique_vulns = set()
    unique_packages = set()
    for report in summary["reports"]:
        for package in report["packages"]:
            unique_packages.add(package["name"])
            for vuln in package["vulnerabilities"]:
                unique_vulns.add(vuln["id"])
    summary["totalVulnerabilities"] = len(unique_vulns)
    summary["affectedPackages"] = len(unique_packages)

    return summary


def write_markdown(summary, output_path):
    lines = [
        "# Vulnerability Summary",
        "",
        "All available security updates are automatically applied during compilation at build time.",
        "This report only lists active, unpatched vulnerabilities that have a corresponding Ubuntu Security Notice (USN).",
        "",
    ]

    for report in summary["reports"]:
        lines.extend([
            f"## {report['architecture']}",
            "",
            f"- Unpatched packages: {report['affectedPackages']}",
            f"- Vulnerability matches: {report['vulnerabilities']}",
            f"- JSON report: `{report['report']}`",
            "",
        ])

        if report["packages"]:
            lines.append("| Package | Version | Vulnerability | CVSS 3 | Priority | Published |")
            lines.append("| --- | --- | --- | --- | --- | --- |")
            for package in report["packages"]:
                for vulnerability in package["vulnerabilities"]:
                    vuln_label = display_vulnerability_id(vulnerability["id"])
                    if vulnerability["url"]:
                        vuln_label = f"[{vuln_label}]({vulnerability['url']})"
                    _iso, pub_label = format_publication_date(
                        vulnerability.get("published") or vulnerability.get("modified")
                    )
                    lines.append(
                        f"| {markdown_cell(package['name'])} | {markdown_cell(package['version'])} | "
                        f"{markdown_cell(vuln_label)} | "
                        f"{markdown_cell(vulnerability['severity'])} | "
                        f"{markdown_cell(vulnerability['priority'])} | "
                        f"{markdown_cell(pub_label)} |"
                    )
            lines.append("")
        else:
            lines.extend(["No patchable vulnerabilities reported by OSV-Scanner.", ""])

    output_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def write_html(summary, output_path):
    summary_cards = []
    detail_rows_by_key = {}

    for report in summary["reports"]:
        summary_cards.extend([
            (
                "ARCHITECTURE",
                html.escape(report["architecture"]),
                "SBOM target scanned by OSV-Scanner.",
            ),
            (
                "UNPATCHED PACKAGES",
                str(report["affectedPackages"]),
                "Packages with at least one active unpatched vulnerability.",
            ),
            (
                "VULNERABILITY MATCHES",
                str(report["vulnerabilities"]),
                "Total vulnerability records returned for this architecture.",
            ),
            (
                "REPORT",
                (
                    f'<time datetime="{html.escape(report["generatedAt"]["datetime"])}">'
                    f'{html.escape(report["generatedAt"]["label"])}</time>'
                ),
                f'<a class="p-button" href="{html.escape(report["report"])}" download>Download OSV</a>',
            ),
        ])

        for package in report["packages"]:
            for vulnerability in package["vulnerabilities"]:
                vuln_id_text = display_vulnerability_id(vulnerability["id"])
                vuln_id = html.escape(vuln_id_text)
                if vulnerability["url"]:
                    vuln_cell = (
                        f"<a href=\"{html.escape(vulnerability['url'])}\">{vuln_id}</a>"
                    )
                else:
                    vuln_cell = vuln_id

                publication_iso, publication_label = format_publication_date(
                    vulnerability.get("published") or vulnerability.get("modified")
                )
                detail_key = (
                    package["name"],
                    package["version"],
                    vuln_id_text,
                    vulnerability["url"],
                    vulnerability["severity"],
                    vulnerability["priority"],
                    publication_iso,
                    publication_label,
                )
                if detail_key not in detail_rows_by_key:
                    detail_rows_by_key[detail_key] = {
                        "package_name": package["name"],
                        "package_version": package["version"],
                        "vulnerability_cell": vuln_cell,
                        "vulnerability_id": vuln_id_text,
                        "severity": vulnerability["severity"],
                        "priority": vulnerability["priority"],
                        "publication_iso": publication_iso,
                        "publication_label": publication_label,
                        "architectures": set(),
                    }
                detail_rows_by_key[detail_key]["architectures"].add(report["architecture"])

    detail_rows = []
    architecture_order = {"AMD64": 0, "ARM64": 1}
    for row_data in detail_rows_by_key.values():
        architecture_labels = sorted(
            {normalize_architecture_label(arch) for arch in row_data["architectures"]},
            key=lambda label: (architecture_order.get(label, 99), label),
        )
        architecture_cells = " ".join(
            architecture_chip(architecture) for architecture in architecture_labels
        )
        publication_label = row_data["publication_label"]
        publication_cell = html.escape(publication_label)
        if row_data["publication_iso"]:
            publication_cell = (
                f'<time datetime="{html.escape(row_data["publication_iso"])}">'
                f"{html.escape(publication_label)}</time>"
            )

        row_search = " ".join(
            [
                row_data["package_name"],
                row_data["package_version"],
                row_data["vulnerability_id"],
                row_data["severity"],
                row_data["priority"],
                publication_label,
                " ".join(architecture_labels),
            ]
        ).lower()
        detail_rows.append(
            f'<tr data-search="{html.escape(row_search)}">'
            f"<td>{html.escape(row_data['package_name'])}</td>"
            f"<td>{html.escape(row_data['package_version'])}</td>"
            f"<td>{row_data['vulnerability_cell']}</td>"
            f"<td>{severity_icon(row_data['severity'])}</td>"
            f"<td>{priority_icon(row_data['priority'])}</td>"
            f"<td>{publication_cell}</td>"
            f"<td>{architecture_cells}</td>"
            "</tr>"
        )

    summary_cards_html = "\n".join(
        (
            '<div class="col-3 vulnerability-summary-card-column">'
            '<article class="p-card vulnerability-summary-card">'
            f'<span class="p-text--small-muted">{label}</span>'
            f'<h3 class="p-card__title">{value}</h3>'
            f'<p class="p-card__content">{description}</p>'
            '</article>'
            '</div>'
        )
        for label, value, description in summary_cards
    ) or (
        '<div class="col-3"><article class="p-card">'
        '<h3 class="p-card__title">No OSV reports</h3>'
        '<p class="p-card__content">No OSV reports were generated.</p>'
        '</article></div>'
    )
    detail_body_rows = "\n".join(detail_rows) or (
        '<tr><td colspan="7">No patchable vulnerabilities reported by OSV-Scanner.</td></tr>'
    )
    output_path.write_text(f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Vulnerability Reports - Snap Pi-hole</title>
  <link rel="stylesheet" href="https://assets.ubuntu.com/v1/vanilla_framework_version_4.51.0.min.css" />
    <style>
    .p-breadcrumbs {{
      min-height: 1.5rem;
    }}
    .p-breadcrumbs__item,
    .p-breadcrumbs__item a {{
      font-weight: 400;
      letter-spacing: normal;
      text-transform: none;
    }}
    .p-card__title,
    .p-heading--4 {{
      font-weight: 400;
    }}
    .vulnerability-summary-card-column {{
      display: flex;
    }}
    .vulnerability-summary-card {{
      display: flex;
      flex-direction: column;
      width: 100%;
    }}
    .vulnerability-summary-card .p-card__content {{
      margin-top: auto;
    }}
    .vulnerability-table-controls {{
      margin-bottom: 1.5rem;
    }}
    .vulnerability-sort-button {{
      background: none;
      border: 0;
      color: inherit;
      cursor: pointer;
      font: inherit;
      font-weight: 400;
      margin: 0;
      padding: 0;
      text-align: left;
    }}
    .vulnerability-sort-button::after {{
      content: "↕";
      display: inline-block;
      font-size: 0.8rem;
      margin-left: 0.35rem;
    }}
    .vulnerability-sort-button[aria-sort="ascending"]::after {{
      content: "↑";
    }}
    .vulnerability-sort-button[aria-sort="descending"]::after {{
      content: "↓";
    }}
    .vulnerability-details {{
      table-layout: fixed;
      width: 100%;
    }}
    .vulnerability-details th,
    .vulnerability-details td {{
      line-height: 1.45;
      padding-bottom: 1rem !important;
      padding-top: 1rem !important;
      vertical-align: top;
    }}
    .vulnerability-details th:nth-child(1),
    .vulnerability-details td:nth-child(1) {{
      width: 16%;
    }}
    .vulnerability-details th:nth-child(2),
    .vulnerability-details td:nth-child(2) {{
      width: 15%;
    }}
    .vulnerability-details th:nth-child(3),
    .vulnerability-details td:nth-child(3) {{
      width: 18%;
    }}
    .vulnerability-details th:nth-child(4),
    .vulnerability-details td:nth-child(4) {{
      width: 13%;
    }}
    .vulnerability-details th:nth-child(5),
    .vulnerability-details td:nth-child(5) {{
      width: 12%;
    }}
    .vulnerability-details th:nth-child(6),
    .vulnerability-details td:nth-child(6) {{
      width: 12%;
    }}
    .vulnerability-details th:nth-child(7),
    .vulnerability-details td:nth-child(7) {{
      width: 16%;
    }}
    .vulnerability-details td:nth-child(2),
    .vulnerability-details td:nth-child(3) {{
      font-family: "Ubuntu Mono", monospace;
    }}
    .vulnerability-severity {{
      font-size: 12px;
      margin-bottom: 0;
      white-space: nowrap;
    }}
    .vulnerability-severity .p-chip__value {{
      font-size: 12px;
      font-weight: 400;
    }}
    .vulnerability-architecture {{
      margin-bottom: 0;
      margin-right: 0.3rem;
      white-space: nowrap;
    }}
    .vulnerability-architecture .p-chip__value {{
      font-size: 12px;
      font-weight: 400;
    }}
    footer.p-strip--dark {{
      background-color: #2d2d2d !important;
      color: #b6b6b6 !important;
    }}
    footer.p-strip--dark h2 {{
      color: #eaeaea !important;
      font-weight: 500 !important;
    }}
    footer.p-strip--dark p,
    footer.p-strip--dark li,
    footer.p-strip--dark span {{
      color: #b6b6b6 !important;
    }}
    footer.p-strip--dark a,
    footer.p-strip--dark a.is-dark {{
      color: rgb(102, 153, 204) !important;
      text-decoration: none !important;
      transition: color 0.15s ease !important;
    }}
    footer.p-strip--dark a:hover,
    footer.p-strip--dark a.is-dark:hover {{
      color: #e95420 !important;
      text-decoration: underline !important;
    }}
  </style>
</head>
<body>
  <div class="l-site">
    <header id="navigation" class="p-navigation is-dark">
      <div class="p-navigation__row">
        <div class="p-navigation__banner">
          <a class="p-navigation__link" href="../" style="display: flex; align-items: center; text-decoration: none;">
            <img src="../pihole.png" alt="Pi-hole Logo" style="height: 32px; width: 32px;">
          </a>
        </div>
      </div>
    </header>

    <main class="p-strip" style="background-color: #ffffff; flex-grow: 1; padding-top: 2rem !important; padding-bottom: 2rem !important;">
      <div class="row">
        <div class="col-12">
          <nav class="p-breadcrumbs" aria-label="Breadcrumbs" style="margin-bottom: 1.5rem;">
            <ol class="p-breadcrumbs__items">
              <li class="p-breadcrumbs__item"><a href="../">Reports Dashboard</a></li>
              <li class="p-breadcrumbs__item" aria-current="page">Vulnerability Reports</li>
            </ol>
          </nav>
          <section class="row" style="margin-bottom: 2rem;" aria-labelledby="vulnerability-title">
            <div class="col-12">
              <h1 class="p-heading--2" id="vulnerability-title" style="margin-bottom: 1.5rem;">Vulnerability Reports</h1>
              <p class="p-heading--4">Active unpatched vulnerabilities with corresponding Ubuntu Security Notices (USNs). All available package security updates are automatically applied during snap compilation at build time.</p>
            </div>
          </section>
          <section class="row u-equal-height" style="margin-bottom: 2rem;" aria-label="Vulnerability scan summary">
            {summary_cards_html}
          </section>
          <h2 class="p-heading--3">Vulnerability Details</h2>
          <div class="row vulnerability-table-controls">
            <div class="col-12">
              <form class="p-search-box" onsubmit="event.preventDefault(); filterVulnerabilities();" style="margin-bottom: 0;">
                <label class="u-off-screen" for="vulnerability-search">Search by package, version, vulnerability, CVSS 3, priority, publication date, or architecture</label>
                <input type="search" id="vulnerability-search" class="p-search-box__input" placeholder="Search by package, version, vulnerability, CVSS 3, priority, publication date, or architecture..." oninput="filterVulnerabilities()" autocomplete="off">
                <button type="reset" class="p-search-box__reset" onclick="document.getElementById('vulnerability-search').value=''; filterVulnerabilities();"><i class="p-icon--close">Clear</i></button>
                <button type="submit" class="p-search-box__button"><i class="p-icon--search">Search</i></button>
              </form>
            </div>
          </div>
          <div style="overflow-x: auto;">
            <table class="p-table vulnerability-details" id="vulnerability-table">
              <caption class="u-off-screen">OSV vulnerability details by package</caption>
              <thead>
                <tr>
                  <th><button type="button" class="vulnerability-sort-button" data-column="0" aria-sort="none" onclick="sortVulnerabilities(0)">Package</button></th>
                  <th><button type="button" class="vulnerability-sort-button" data-column="1" aria-sort="none" onclick="sortVulnerabilities(1)">Version</button></th>
                  <th><button type="button" class="vulnerability-sort-button" data-column="2" aria-sort="none" onclick="sortVulnerabilities(2)">Vulnerability</button></th>
                  <th><button type="button" class="vulnerability-sort-button" data-column="3" aria-sort="none" onclick="sortVulnerabilities(3)">CVSS 3</button></th>
                  <th><button type="button" class="vulnerability-sort-button" data-column="4" aria-sort="none" onclick="sortVulnerabilities(4)">Priority</button></th>
                  <th><button type="button" class="vulnerability-sort-button" data-column="5" aria-sort="none" onclick="sortVulnerabilities(5)">Publication Date</button></th>
                  <th><button type="button" class="vulnerability-sort-button" data-column="6" aria-sort="none" onclick="sortVulnerabilities(6)">Architectures</button></th>
                </tr>
              </thead>
              <tbody id="vulnerability-tbody">
                {detail_body_rows}
              </tbody>
            </table>
          </div>
          <p class="p-text--small">Full OSV JSON reports are linked in the summary cards.</p>
        </div>
      </div>
    </main>

    <footer class="p-strip--dark" style="padding-top: 2rem !important; padding-bottom: 2rem !important; margin-top: 3rem;">
      <div class="row">
        <div class="col-4">
          <h2 class="p-heading--5">Project Resources</h2>
          <ul class="p-list">
            <li><a href="https://github.com/rajannpatel/snap-pi-hole" class="is-dark">GitHub Repository</a></li>
            <li><a href="https://github.com/rajannpatel/snap-pi-hole/wiki" class="is-dark">Project Wiki Documentation</a></li>
            <li><a href="https://snapcraft.io/pihole-by-rajannpatel" class="is-dark">Snap Store Listing</a></li>
          </ul>
        </div>
        <div class="col-4">
          <h2 class="p-heading--5">CI/CD Pipeline</h2>
          <ul class="p-list">
            <li><a href="https://github.com/rajannpatel/snap-pi-hole/actions" class="is-dark">Workflow Execution History</a></li>
            <li><a href="https://github.com/rajannpatel/snap-pi-hole/actions/workflows/cicd.yml" class="is-dark">Pipeline Definition (YAML)</a></li>
            <li><a href="../sbom/" class="is-dark">Software Bill of Materials (SBOM)</a></li>
            <li><a href="../vulnerabilities/" class="is-dark">Vulnerability Reports</a></li>
            <li><a href="../coverage/" class="is-dark">Code Coverage Reports</a></li>
          </ul>
        </div>
        <div class="col-4">
          <h2 class="p-heading--5">Security & Confinement</h2>
          <p class="p-text--small">
            Built securely on Ubuntu builders. Packaged as a strictly confined Snap, ensuring isolated execution and sandboxed system interactions for Pi-hole Core services.
          </p>
        </div>
      </div>
    </footer>
  </div>
  <script>
    let vulnerabilitySortColumn = null;
    let vulnerabilitySortDirection = 'ascending';

    function vulnerabilityCellValue(row, column) {{
      const cell = row.cells[column];
      return cell ? cell.textContent.trim().toLowerCase() : '';
    }}

    function vulnerabilityCvssScore(value) {{
      const match = value.match(/\\d+(?:\\.\\d+)?/);
      return match ? Number(match[0]) : null;
    }}

    function vulnerabilityPriorityRank(value) {{
      const normalized = value.toLowerCase();
      if (normalized.includes('critical')) return 5;
      if (normalized.includes('high')) return 4;
      if (normalized.includes('medium')) return 3;
      if (normalized.includes('low')) return 2;
      if (normalized.includes('negligible')) return 1;
      if (normalized.includes('unknown')) return null;
      return null;
    }}

    function vulnerabilityRankValue(row, column) {{
      const value = vulnerabilityCellValue(row, column);
      if (column === 3) {{
        return vulnerabilityCvssScore(value);
      }}
      if (column === 4) {{
        return vulnerabilityPriorityRank(value);
      }}
      return null;
    }}

    function compareVulnerabilityRows(firstRow, secondRow, column, direction) {{
      const firstRank = vulnerabilityRankValue(firstRow, column);
      const secondRank = vulnerabilityRankValue(secondRow, column);
      if (firstRank !== null || secondRank !== null || column === 3 || column === 4) {{
        if (firstRank === null && secondRank === null) {{
          const firstText = vulnerabilityCellValue(firstRow, column);
          const secondText = vulnerabilityCellValue(secondRow, column);
          return firstText.localeCompare(secondText, undefined, {{ numeric: true, sensitivity: 'base' }});
        }}
        if (firstRank === null) {{
          return 1;
        }}
        if (secondRank === null) {{
          return -1;
        }}
        return direction === 'ascending' ? firstRank - secondRank : secondRank - firstRank;
      }}

      const firstText = vulnerabilityCellValue(firstRow, column);
      const secondText = vulnerabilityCellValue(secondRow, column);
      const lexical = firstText.localeCompare(secondText, undefined, {{ numeric: true, sensitivity: 'base' }});
      return direction === 'ascending' ? lexical : -lexical;
    }}

    function defaultSortDirection(column) {{
      if (column === 3 || column === 4) {{
        return 'descending';
      }}
      return 'ascending';
    }}

    function filterVulnerabilities() {{
      const searchInput = document.getElementById('vulnerability-search');
      const query = searchInput ? searchInput.value.toLowerCase().trim() : '';
      document.querySelectorAll('#vulnerability-tbody tr').forEach(row => {{
        const searchText = row.dataset.search || row.textContent.toLowerCase();
        row.style.display = !query || searchText.includes(query) ? '' : 'none';
      }});
    }}

    function sortVulnerabilities(column) {{
      const tbody = document.getElementById('vulnerability-tbody');
      const rows = Array.from(tbody.querySelectorAll('tr'));
      if (vulnerabilitySortColumn === column) {{
        vulnerabilitySortDirection = vulnerabilitySortDirection === 'ascending' ? 'descending' : 'ascending';
      }} else {{
        vulnerabilitySortColumn = column;
        vulnerabilitySortDirection = defaultSortDirection(column);
      }}

      rows.sort((a, b) => compareVulnerabilityRows(a, b, column, vulnerabilitySortDirection));

      rows.forEach(row => tbody.appendChild(row));
      document.querySelectorAll('.vulnerability-sort-button').forEach(button => {{
        const isActive = Number(button.dataset.column) === column;
        button.setAttribute('aria-sort', isActive ? vulnerabilitySortDirection : 'none');
      }});
      filterVulnerabilities();
    }}
  </script>
</body>
</html>
""", encoding="utf-8")


def main():
    reports_dir = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "vulnerability-reports")
    reports_dir.mkdir(parents=True, exist_ok=True)
    summary = collect_reports(reports_dir)
    (reports_dir / "osv-summary.json").write_text(
        json.dumps(summary, indent=2) + "\n",
        encoding="utf-8",
    )
    write_markdown(summary, reports_dir / "vuln-summary.md")
    write_html(summary, reports_dir / "index.html")


if __name__ == "__main__":
    main()
