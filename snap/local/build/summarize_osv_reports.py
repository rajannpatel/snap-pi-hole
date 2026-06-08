#!/usr/bin/env python3
import html
import json
import math
import pathlib
import sys
import os
import urllib.request
from datetime import datetime, timezone

from report_assets import vanilla_framework_css_link


def load_cache():
    repo_root = pathlib.Path(__file__).resolve().parent.parent.parent.parent
    cache_file = repo_root / "local-vulnerabilities" / "gemini-cache.json"
    if cache_file.exists():
        try:
            return json.loads(cache_file.read_text(encoding="utf-8"))
        except Exception as e:
            print(f"Error loading cache: {e}", file=sys.stderr)
    return {}


def save_cache(cache):
    repo_root = pathlib.Path(__file__).resolve().parent.parent.parent.parent
    cache_file = repo_root / "local-vulnerabilities" / "gemini-cache.json"
    cache_file.parent.mkdir(parents=True, exist_ok=True)
    try:
        cache_file.write_text(json.dumps(cache, indent=2) + "\n", encoding="utf-8")
    except Exception as e:
        print(f"Error saving cache: {e}", file=sys.stderr)


def query_gemini_vulnerability_info(cve_id, package_name, version):
    api_key = os.environ.get("GEMINI_API_KEY")
    if not api_key:
        print(f"GEMINI_API_KEY not set. Using fallback placeholders for {cve_id}.", file=sys.stderr)
        return {
            "appropriate": f"Snap confinement restricts process access, ensuring {cve_id} is contained within the sandbox.",
            "not_appropriate": f"If {cve_id} enables local execution or sandbox escape, confinement boundaries might be bypassed."
        }

    prompt = f"""
For the vulnerability {cve_id} in package {package_name} (version {version}), which is packaged as a strictly confined Ubuntu snap (using AppArmor, seccomp filters, and a read-only SquashFS filesystem):
1. Explain how/why a "confined mitigation" label is appropriate (i.e., how snap's security boundaries and sandbox mitigate the vulnerability).
2. Explain why a "confined mitigation" label might NOT be appropriate (i.e., how the vulnerability could still be exploited or cause harm despite the sandbox).

Provide your response in JSON format with exactly the following two keys:
- "appropriate": a concise explanation (1-3 sentences)
- "not_appropriate": a concise explanation (1-3 sentences)

Do not include any markdown formatting, code blocks, or leading/trailing text outside the JSON object.
"""
    url = f"https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key={api_key}"
    headers = {"Content-Type": "application/json"}
    body = {
        "contents": [{"parts": [{"text": prompt}]}],
        "generationConfig": {
            "responseMimeType": "application/json"
        }
    }
    try:
        req = urllib.request.Request(url, data=json.dumps(body).encode("utf-8"), headers=headers, method="POST")
        with urllib.request.urlopen(req, timeout=15) as response:
            res_data = json.loads(response.read().decode("utf-8"))
            text_content = res_data["candidates"][0]["content"]["parts"][0]["text"]
            parsed_res = json.loads(text_content.strip())
            if "appropriate" in parsed_res and "not_appropriate" in parsed_res:
                return parsed_res
            else:
                raise ValueError("Missing required keys in Gemini API response")
    except Exception as e:
        print(f"Error querying Gemini API for {cve_id}: {e}", file=sys.stderr)
        return {
            "appropriate": f"Confinement provides isolation via AppArmor and seccomp, mitigating unauthorized access to host resources (error during Gemini lookup).",
            "not_appropriate": f"A compromised process could potentially disrupt local services or corrupt local writable data inside the snap (error during Gemini lookup)."
        }



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


def vulnerability_entry(vulnerability, patchable):
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
        "patchable": patchable,
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
    summary = {
        "reports": [],
        "totalVulnerabilities": 0,
        "affectedPackages": 0,
        "actionableVulnerabilities": 0,
        "actionableAffectedPackages": 0,
        "confinedMitigationVulnerabilities": 0,
    }

    cache = load_cache()
    cache_updated = False

    for report_path in sorted(reports_dir.glob("osv-*.json")):
        if report_path.name == "osv-summary.json":
            continue
        arch = report_path.stem.removeprefix("osv-")
        data = json.loads(report_path.read_text(encoding="utf-8"))
        vulnerabilities = 0
        affected_packages = 0
        actionable_vulnerabilities = 0
        actionable_affected_packages = 0
        confined_mitigation_vulnerabilities = 0
        entries = []

        for result in data.get("results", []):
            for package in result.get("packages", []):
                vulns = package.get("vulnerabilities", [])
                if not vulns:
                    continue
                pkg = package.get("package", {})
                package_name = pkg.get("name", "unknown")
                package_version = pkg.get("version", "")

                package_vulns = []
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
                    
                    if vuln_id not in cache:
                        explanations = query_gemini_vulnerability_info(vuln_id, package_name, package_version)
                        cache[vuln_id] = explanations
                        cache_updated = True
                    
                    v_entry = vulnerability_entry(v, has_usn)
                    v_entry["appropriate"] = cache[vuln_id]["appropriate"]
                    v_entry["not_appropriate"] = cache[vuln_id]["not_appropriate"]
                    package_vulns.append(v_entry)

                affected_packages += 1
                vulnerabilities += len(package_vulns)
                package_actionable_vulnerabilities = sum(1 for vuln in package_vulns if vuln["patchable"])
                actionable_vulnerabilities += package_actionable_vulnerabilities
                confined_mitigation_vulnerabilities += len(package_vulns) - package_actionable_vulnerabilities
                if package_actionable_vulnerabilities:
                    actionable_affected_packages += 1
                entries.append({
                    "name": package_name,
                    "version": package_version,
                    "ecosystem": pkg.get("ecosystem", ""),
                    "vulnerabilities": package_vulns,
                })

        summary["reports"].append({
            "architecture": arch,
            "report": report_path.name,
            "generatedAt": generated_time(report_path),
            "affectedPackages": affected_packages,
            "vulnerabilities": vulnerabilities,
            "actionableAffectedPackages": actionable_affected_packages,
            "actionableVulnerabilities": actionable_vulnerabilities,
            "confinedMitigationVulnerabilities": confined_mitigation_vulnerabilities,
            "packages": entries,
        })

    # Calculate unique global counts across all architectures
    unique_vulns = set()
    unique_packages = set()
    unique_actionable_vulns = set()
    unique_actionable_packages = set()
    for report in summary["reports"]:
        for package in report["packages"]:
            unique_packages.add(package["name"])
            for vuln in package["vulnerabilities"]:
                unique_vulns.add(vuln["id"])
                if vuln["patchable"]:
                    unique_actionable_vulns.add(vuln["id"])
                    unique_actionable_packages.add(package["name"])
    summary["totalVulnerabilities"] = len(unique_vulns)
    summary["affectedPackages"] = len(unique_packages)
    summary["actionableVulnerabilities"] = len(unique_actionable_vulns)
    summary["actionableAffectedPackages"] = len(unique_actionable_packages)
    summary["confinedMitigationVulnerabilities"] = max(
        0,
        summary["totalVulnerabilities"] - summary["actionableVulnerabilities"],
    )

    if cache_updated:
        save_cache(cache)

    return summary

def write_markdown(summary, output_path):
    lines = [
        "# Vulnerability Summary",
        "",
        "All available security updates are automatically applied during compilation at build time.",
        "Dashboard totals count only actionable vulnerabilities with a corresponding Ubuntu Security Notice (USN).",
        "Raw OSV matches without a USN are retained as confined-mitigation report-only findings for audit visibility.",
        "The CI workflow currently treats OSV exit code 1 as a warning and fails only if the scan itself errors.",
        "",
    ]

    for report in summary["reports"]:
        lines.extend([
            f"## {report['architecture']}",
            "",
            f"- Actionable USN packages: {report['actionableAffectedPackages']}",
            f"- Actionable USN vulnerabilities: {report['actionableVulnerabilities']}",
            f"- Raw OSV affected packages: {report['affectedPackages']}",
            f"- Raw OSV vulnerability matches: {report['vulnerabilities']}",
            f"- Confined-mitigation report-only matches: {report['confinedMitigationVulnerabilities']}",
            f"- JSON report: `{report['report']}`",
            "",
        ])

        if report["packages"]:
            lines.append("| Package | Version | Vulnerability | CVSS 3 | Priority | Status | Published |")
            lines.append("| --- | --- | --- | --- | --- | --- | --- |")
            for package in report["packages"]:
                for vulnerability in package["vulnerabilities"]:
                    vuln_label = display_vulnerability_id(vulnerability["id"])
                    if vulnerability["url"]:
                        vuln_label = f"[{vuln_label}]({vulnerability['url']})"
                    _iso, pub_label = format_publication_date(
                        vulnerability.get("published") or vulnerability.get("modified")
                    )
                    status_str = "Actionable (USN)" if vulnerability["patchable"] else "Confined Mitigation"
                    lines.append(
                        f"| {markdown_cell(package['name'])} | {markdown_cell(package['version'])} | "
                        f"{markdown_cell(vuln_label)} | "
                        f"{markdown_cell(vulnerability['severity'])} | "
                        f"{markdown_cell(vulnerability['priority'])} | "
                        f"{status_str} | "
                        f"{markdown_cell(pub_label)} |"
                    )
            lines.append("")
        else:
            lines.extend(["No unpatched vulnerabilities reported by OSV-Scanner.", ""])

    # Append Confinement Analysis itemization
    has_vulns = False
    for report in summary["reports"]:
        if report["packages"]:
            has_vulns = True
            break
    
    if has_vulns:
        lines.extend([
            "## Confinement Analysis",
            "",
            "Itemized security analysis of identified vulnerabilities and their exposure inside the strictly confined snap sandbox.",
            ""
        ])
        
        seen_vulns = {}
        for report in summary["reports"]:
            for package in report["packages"]:
                for vulnerability in package["vulnerabilities"]:
                    vuln_id = vulnerability["id"]
                    if vuln_id not in seen_vulns:
                        seen_vulns[vuln_id] = {
                            "package": package["name"],
                            "version": package["version"],
                            "appropriate": vulnerability.get("appropriate", ""),
                            "not_appropriate": vulnerability.get("not_appropriate", "")
                        }
        
        for vuln_id, info in sorted(seen_vulns.items()):
            vuln_label = display_vulnerability_id(vuln_id)
            lines.extend([
                f"### {vuln_label} ({info['package']})",
                "",
                f"- **Why Confined Mitigation is Appropriate**:",
                f"  {info['appropriate']}",
                f"- **Why Confined Mitigation is NOT Appropriate**:",
                f"  {info['not_appropriate']}",
                ""
            ])

    output_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def status_badge(patchable):
    if patchable:
        return (
            '<span class="p-chip" style="background-color: #e6f2ff; border: 1px solid #b3d7ff; color: #004085;">'
            '<span class="p-chip__value">Actionable (USN)</span>'
            '</span>'
        )
    else:
        return (
            '<span class="p-chip" style="background-color: #f3e5f5; border: 1px solid #e1bee7; color: #4a148c;" title="Mitigated by snap confinement">'
            '<span class="p-chip__value">Confined Mitigation</span>'
            '</span>'
        )


def write_html(summary, output_path):
    summary_rows = []
    detail_rows_by_key = {}

    for report in summary["reports"]:
        arch = html.escape(report["architecture"])
        actionable_pkgs = str(report["actionableAffectedPackages"])
        actionable_vulns = str(report["actionableVulnerabilities"])
        raw_matches = str(report["vulnerabilities"])
        confined_mitigations = str(report["confinedMitigationVulnerabilities"])
        report_time = (
            f'<time datetime="{html.escape(report["generatedAt"]["datetime"])}">'
            f'{html.escape(report["generatedAt"]["label"])}</time>'
        )
        report_link = f'<a class="p-button" href="{html.escape(report["report"])}" download>Download OSV</a>'
        
        report_cell = f'{report_time}<br><div style="margin-top: 0.5rem;">{report_link}</div>'
        
        summary_rows.append(
            f"<tr>"
            f"<td><strong>{arch}</strong></td>"
            f"<td>{actionable_pkgs}</td>"
            f"<td>{actionable_vulns}</td>"
            f"<td>{raw_matches}</td>"
            f"<td>{confined_mitigations}</td>"
            f"<td>{report_cell}</td>"
            f"</tr>"
        )

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
                    vulnerability["patchable"],
                    publication_iso,
                    publication_label,
                    vulnerability.get("appropriate", ""),
                    vulnerability.get("not_appropriate", ""),
                )
                if detail_key not in detail_rows_by_key:
                    detail_rows_by_key[detail_key] = {
                        "package_name": package["name"],
                        "package_version": package["version"],
                        "vulnerability_cell": vuln_cell,
                        "vulnerability_id": vuln_id_text,
                        "severity": vulnerability["severity"],
                        "priority": vulnerability["priority"],
                        "patchable": vulnerability["patchable"],
                        "publication_iso": publication_iso,
                        "publication_label": publication_label,
                        "appropriate": vulnerability.get("appropriate", ""),
                        "not_appropriate": vulnerability.get("not_appropriate", ""),
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
                "actionable" if row_data["patchable"] else "unactionable confined mitigation",
                publication_label,
                " ".join(architecture_labels),
            ]
        ).lower()
        detail_rows.append(
            f'<tr class="vulnerability-row" data-search="{html.escape(row_search)}">'
            f"<td>{html.escape(row_data['package_name'])}</td>"
            f"<td>{html.escape(row_data['package_version'])}</td>"
            f"<td>{row_data['vulnerability_cell']}</td>"
            f"<td>{severity_icon(row_data['severity'])}</td>"
            f"<td>{priority_icon(row_data['priority'])}</td>"
            f"<td>{status_badge(row_data['patchable'])}</td>"
            f"<td>{publication_cell}</td>"
            f"<td>{architecture_cells}</td>"
            "</tr>\n"
            f'<tr class="vulnerability-explanation-row" style="background-color: #fafafa;">'
            f'<td colspan="8" style="padding: 1rem 1.5rem !important; border-bottom: 1px solid #e0e0e0;">'
            f'<div style="display: flex; gap: 2rem; flex-wrap: wrap;">'
            f'<div style="flex: 1; min-width: 280px; border-left: 4px solid #1976d2; padding-left: 1rem;">'
            f'<h4 style="font-size: 0.9rem; font-weight: 600; color: #1976d2; margin-bottom: 0.25rem; text-transform: uppercase; letter-spacing: 0.5px;">Why Confined Mitigation is Appropriate</h4>'
            f'<p style="font-size: 0.875rem; line-height: 1.5; color: #333; margin: 0;">{html.escape(row_data["appropriate"])}</p>'
            f'</div>'
            f'<div style="flex: 1; min-width: 280px; border-left: 4px solid #d32f2f; padding-left: 1rem;">'
            f'<h4 style="font-size: 0.9rem; font-weight: 600; color: #d32f2f; margin-bottom: 0.25rem; text-transform: uppercase; letter-spacing: 0.5px;">Confinement Limitations / Risks</h4>'
            f'<p style="font-size: 0.875rem; line-height: 1.5; color: #333; margin: 0;">{html.escape(row_data["not_appropriate"])}</p>'
            f'</div>'
            f'</div>'
            f'</td>'
            f'</tr>'
        )

    summary_table_rows = "\n".join(summary_rows) or (
        '<tr><td colspan="5">No OSV reports were generated.</td></tr>'
    )
    detail_body_rows = "\n".join(detail_rows) or (
        '<tr><td colspan="8">No unpatched vulnerabilities reported by OSV-Scanner.</td></tr>'
    )
    output_path.write_text(f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Vulnerability Reports - snap Pi-hole</title>
{vanilla_framework_css_link()}
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
      color: #777;
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
      width: 14%;
    }}
    .vulnerability-details th:nth-child(2),
    .vulnerability-details td:nth-child(2) {{
      width: 12%;
    }}
    .vulnerability-details th:nth-child(3),
    .vulnerability-details td:nth-child(3) {{
      width: 14%;
    }}
    .vulnerability-details th:nth-child(4),
    .vulnerability-details td:nth-child(4) {{
      width: 11%;
    }}
    .vulnerability-details th:nth-child(5),
    .vulnerability-details td:nth-child(5) {{
      width: 10%;
    }}
    .vulnerability-details th:nth-child(6),
    .vulnerability-details td:nth-child(6) {{
      width: 15%;
    }}
    .vulnerability-details th:nth-child(7),
    .vulnerability-details td:nth-child(7) {{
      width: 12%;
    }}
    .vulnerability-details th:nth-child(8),
    .vulnerability-details td:nth-child(8) {{
      width: 12%;
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
          <section class="row" style="margin-bottom: 1rem;" aria-labelledby="vulnerability-title">
            <div class="col-12">
              <h1 class="p-heading--2" id="vulnerability-title" style="margin-bottom: 1.5rem;">Vulnerability Reports</h1>
              <p class="p-heading--4">OSV-Scanner findings from the generated SBOMs.</p>
            </div>
          </section>
          
          <div class="p-strip" style="background-color: #f7f7f7; padding: 1.5rem; border-radius: 4px; margin-bottom: 2rem; border-left: 4px solid #772953;">
            <h3 class="p-heading--4" style="margin-bottom: 0.5rem; color: #772953; font-weight: 500;">The value of snap confinement</h3>
            <p style="line-height: 1.6; margin-bottom: 1.25rem;">
              This report contains both <strong>Actionable</strong> (USN available) and <strong>Confined Mitigation</strong> (no USN or official patch available upstream) findings.
            </p>
            <p style="line-height: 1.6; margin-bottom: 0;">
              The CI workflow publishes OSV reports for visibility and fails only when the scanner itself errors. Known-vulnerability exit code 1 is treated as a warning. Unlike conventional deployments, a strictly confined snap executes within a sandbox: process capabilities and host interactions are restricted by <strong>AppArmor profiles, seccomp filters, and a read-only SquashFS filesystem</strong>.
            </p>
          </div>

          <h2 class="p-heading--3">Vulnerability Summary</h2>
          <div style="overflow-x: auto; margin-bottom: 0.5rem;">
            <table class="p-table" id="vulnerability-summary-table">
              <thead>
                <tr>
                  <th>Architecture</th>
                  <th>Actionable USN Packages</th>
                  <th>Actionable USN Vulnerabilities</th>
                  <th>Raw OSV Matches</th>
                  <th>Confined Mitigations</th>
                  <th>Report</th>
                </tr>
              </thead>
              <tbody>
                {summary_table_rows}
              </tbody>
            </table>
          </div>
          <p class="p-text--small" style="margin-bottom: 2rem;">
            Actionable counts include only vulnerability matches with a corresponding Ubuntu Security Notice (USN). Confined mitigations represent report-only matches that are sandboxed by snap confinement.
          </p>
          <h2 class="p-heading--3">Vulnerability Details</h2>
          <div class="row vulnerability-table-controls">
            <div class="col-12">
              <form class="p-search-box" onsubmit="event.preventDefault(); filterVulnerabilities();" style="margin-bottom: 0;">
                <label class="u-off-screen" for="vulnerability-search">Search by package, version, vulnerability, CVSS 3, priority, status, publication date, or architecture</label>
                <input type="search" id="vulnerability-search" class="p-search-box__input" placeholder="Search by package, version, vulnerability, CVSS 3, priority, status, publication date, or architecture..." oninput="filterVulnerabilities()" autocomplete="off">
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
                  <th><button type="button" class="vulnerability-sort-button" data-column="5" aria-sort="none" onclick="sortVulnerabilities(5)">Status</button></th>
                  <th><button type="button" class="vulnerability-sort-button" data-column="6" aria-sort="none" onclick="sortVulnerabilities(6)">Publication Date</button></th>
                  <th><button type="button" class="vulnerability-sort-button" data-column="7" aria-sort="none" onclick="sortVulnerabilities(7)">Architectures</button></th>
                </tr>
              </thead>
              <tbody id="vulnerability-tbody">
                {detail_body_rows}
              </tbody>
            </table>
          </div>
          <p class="p-text--small">Full OSV JSON reports are linked in the summary table.</p>
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
            <li><a href="https://snapcraft.io/pihole-by-rajannpatel" class="is-dark">Snap Store listing</a></li>
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
            Built securely on Ubuntu builders. Packaged as a strictly confined snap, ensuring isolated execution and sandboxed system interactions for Pi-hole Core services.
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
      const rows = document.querySelectorAll('#vulnerability-tbody tr.vulnerability-row');
      rows.forEach(row => {{
        const nextRow = row.nextElementSibling;
        const searchText = row.dataset.search || row.textContent.toLowerCase();
        const matches = !query || searchText.includes(query);
        const displayStyle = matches ? '' : 'none';
        row.style.display = displayStyle;
        if (nextRow && nextRow.classList.contains('vulnerability-explanation-row')) {{
          nextRow.style.display = displayStyle;
        }}
      }});
    }}

    function sortVulnerabilities(column) {{
      const tbody = document.getElementById('vulnerability-tbody');
      const parentRows = Array.from(tbody.querySelectorAll('tr.vulnerability-row'));
      if (vulnerabilitySortColumn === column) {{
        vulnerabilitySortDirection = vulnerabilitySortDirection === 'ascending' ? 'descending' : 'ascending';
      }} else {{
        vulnerabilitySortColumn = column;
        vulnerabilitySortDirection = defaultSortDirection(column);
      }}

      const pairs = parentRows.map(row => {{
        return {{
          parent: row,
          explanation: row.nextElementSibling && row.nextElementSibling.classList.contains('vulnerability-explanation-row') ? row.nextElementSibling : null
        }};
      }});

      pairs.sort((a, b) => compareVulnerabilityRows(a.parent, b.parent, column, vulnerabilitySortDirection));

      pairs.forEach(pair => {{
        tbody.appendChild(pair.parent);
        if (pair.explanation) {{
          tbody.appendChild(pair.explanation);
        }}
      }});

      document.querySelectorAll('.vulnerability-sort-button').forEach(button => {{
        const isActive = Number(button.dataset.column) === column;
        button.setAttribute('aria-sort', isActive ? vulnerabilitySortDirection : 'none');
      }});
      filterVulnerabilities();
    }}
  </script>
</body>
</html>
""")


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
