#!/usr/bin/env python3
import json
import os
import pathlib
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone


OWNER = "rajannpatel"
REPO = "snap-pi-hole"
GITHUB_API = "https://api.github.com"
SNAP_NAME = "pihole-by-rajannpatel"
SNAPCRAFT_INFO_URL = f"https://api.snapcraft.io/v2/snaps/info/{SNAP_NAME}"

DISTRO_WORKFLOWS = [
    {"id": "ubuntu", "label": "Ubuntu 26.04", "workflow": "test-ubuntu.yml", "family": "Ubuntu"},
    {"id": "ubuntu-daily", "label": "Ubuntu Daily 26.04", "workflow": "test-ubuntu-daily.yml", "family": "Ubuntu"},
    {"id": "ubuntu-core", "label": "Ubuntu Core 26", "workflow": "test-ubuntu-core.yml", "family": "Ubuntu"},
    {"id": "debian-stable", "label": "Debian Stable 13", "workflow": "test-debian-stable.yml", "family": "Debian"},
    {"id": "debian", "label": "Debian Rolling", "workflow": "test-debian.yml", "family": "Debian"},
    {"id": "fedora", "label": "Fedora 44", "workflow": "test-fedora.yml", "family": "Fedora"},
    {"id": "rocky", "label": "Rocky Linux 9.8", "workflow": "test-rockylinux.yml", "family": "Rocky"},
    {"id": "alma", "label": "AlmaLinux 9.8", "workflow": "test-almalinux.yml", "family": "AlmaLinux"},
    {"id": "opensuse-leap", "label": "openSUSE Leap 16.0", "workflow": "test-opensuse-leap.yml", "family": "openSUSE"},
    {"id": "opensuse-tumbleweed", "label": "openSUSE Tumbleweed", "workflow": "test-opensuse-tumbleweed.yml", "family": "openSUSE"},
    {"id": "arch", "label": "Arch Linux Rolling", "workflow": "test-archlinux.yml", "family": "Arch"},
]


def utc_now_iso():
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def parse_iso(value):
    if not value:
        return None
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def human_duration(seconds):
    if seconds is None:
        return "Unknown"
    if seconds < 60:
        return f"{seconds}s"
    minutes, sec = divmod(int(seconds), 60)
    if minutes < 60:
        return f"{minutes}m {sec}s"
    hours, minutes = divmod(minutes, 60)
    return f"{hours}h {minutes}m"


def summarize_state(run):
    if not run:
        return "no_data"
    status = run.get("status")
    conclusion = run.get("conclusion")
    if status != "completed":
        return status or "queued"
    return conclusion or "unknown"


class HTTPClient:
    def __init__(self, token=""):
        self.token = token

    def get_json(self, url, headers=None, params=None):
        query = ""
        if params:
            query = "?" + urllib.parse.urlencode(params)
        request_headers = {
            "Accept": "application/vnd.github+json",
            "User-Agent": "snap-pi-hole-dashboard-builder",
        }
        if headers:
            request_headers.update(headers)
        if self.token:
            request_headers["Authorization"] = f"Bearer {self.token}"
        req = urllib.request.Request(url + query, headers=request_headers)
        with urllib.request.urlopen(req, timeout=30) as response:
            return json.loads(response.read().decode("utf-8"))

    def get_json_or_empty(self, url, headers=None, params=None):
        try:
            return self.get_json(url, headers=headers, params=params)
        except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, json.JSONDecodeError):
            return {}


def extract_snapcraft_versions(snapcraft_path):
    versions = {"ftl": "", "pi_hole": "", "web": ""}
    in_parts = False
    current_part = None

    for raw in snapcraft_path.read_text(encoding="utf-8").splitlines():
        if raw.startswith("parts:"):
            in_parts = True
            current_part = None
            continue
        if in_parts and re.match(r"^[^\s]", raw):
            break
        if not in_parts:
            continue

        part_match = re.match(r"^\s{2}([a-zA-Z0-9_]+):\s*$", raw)
        if part_match:
            candidate = part_match.group(1)
            current_part = candidate if candidate in versions else None
            continue

        tag_match = re.match(r"^\s{4}source-tag:\s*(\S+)\s*$", raw)
        if current_part and tag_match:
            versions[current_part] = tag_match.group(1).strip("'\"")

    return versions


def extract_track_upstream_cron(track_workflow_path):
    content = track_workflow_path.read_text(encoding="utf-8")
    match = re.search(r"cron:\s*'([^']+)'", content)
    if not match:
        return {"cron": "", "label": "Unknown"}
    cron = match.group(1)
    label = "Scheduled"
    if cron == "0 0 * * *":
        label = "Daily at 00:00 UTC"
    return {"cron": cron, "label": label}


def run_duration_seconds(run):
    started = parse_iso(run.get("run_started_at") or run.get("created_at"))
    ended = parse_iso(run.get("updated_at"))
    if not started or not ended:
        return None
    return max(0, int((ended - started).total_seconds()))


def find_failed_job_link(client, run_id):
    jobs_url = f"{GITHUB_API}/repos/{OWNER}/{REPO}/actions/runs/{run_id}/jobs"
    jobs_data = client.get_json_or_empty(jobs_url, params={"per_page": 100})
    for job in jobs_data.get("jobs", []):
        if job.get("conclusion") in {"failure", "timed_out", "cancelled", "action_required", "startup_failure"}:
            return {
                "job_name": job.get("name", "Failed job"),
                "url": job.get("html_url", ""),
                "conclusion": job.get("conclusion", "failure"),
            }
    return None


def latest_workflow_run(client, workflow_file):
    url = f"{GITHUB_API}/repos/{OWNER}/{REPO}/actions/workflows/{workflow_file}/runs"
    data = client.get_json_or_empty(url, params={"per_page": 1})
    runs = data.get("workflow_runs", [])
    return runs[0] if runs else None


def calculate_update_frequency_days(timestamps):
    ordered = sorted([t for t in timestamps if t], reverse=True)
    if len(ordered) < 2:
        return None
    gaps = []
    for first, second in zip(ordered, ordered[1:]):
        gaps.append((first - second).total_seconds() / 86400)
    if not gaps:
        return None
    return round(sum(gaps) / len(gaps), 2)


def collect_build_status(client):
    runs_url = f"{GITHUB_API}/repos/{OWNER}/{REPO}/actions/workflows/cicd.yml/runs"
    runs_data = client.get_json_or_empty(
        runs_url,
        params={"per_page": 20, "branch": "main", "event": "push", "status": "completed"},
    )
    runs = runs_data.get("workflow_runs", [])
    latest = runs[0] if runs else None

    trend = []
    timestamps = []
    for run in runs[:12]:
        duration = run_duration_seconds(run)
        updated = parse_iso(run.get("updated_at"))
        timestamps.append(updated)
        trend.append(
            {
                "run_number": run.get("run_number"),
                "conclusion": run.get("conclusion", "unknown"),
                "duration_seconds": duration,
                "duration_label": human_duration(duration),
                "updated_at": run.get("updated_at", ""),
                "url": run.get("html_url", ""),
            }
        )

    update_frequency_days = calculate_update_frequency_days(timestamps)
    latest_duration = run_duration_seconds(latest) if latest else None
    recent_durations = [item["duration_seconds"] for item in trend[1:6] if item["duration_seconds"] is not None]
    baseline = round(sum(recent_durations) / len(recent_durations), 1) if recent_durations else None
    regression = None
    if latest_duration is not None and baseline:
        regression = round(latest_duration - baseline, 1)

    return {
        "latest_run": {
            "name": latest.get("name") if latest else "No runs",
            "number": latest.get("run_number") if latest else None,
            "status": summarize_state(latest),
            "conclusion": latest.get("conclusion") if latest else "no_data",
            "url": latest.get("html_url") if latest else "",
            "updated_at": latest.get("updated_at") if latest else "",
            "duration_seconds": latest_duration,
            "duration_label": human_duration(latest_duration),
        },
        "duration_trend": trend,
        "duration_baseline_seconds": baseline,
        "duration_regression_seconds": regression,
        "update_frequency_days": update_frequency_days,
    }


def collect_distro_matrix(client):
    matrix = []
    failed_links = []
    latest_timestamps = []

    for item in DISTRO_WORKFLOWS:
        run = latest_workflow_run(client, item["workflow"])
        duration = run_duration_seconds(run) if run else None
        failed_job = None
        if run and summarize_state(run) in {"failure", "timed_out", "cancelled", "action_required", "startup_failure"}:
            failed_job = find_failed_job_link(client, run.get("id"))
            if failed_job and failed_job.get("url"):
                failed_links.append(
                    {
                        "distro": item["label"],
                        "workflow": item["workflow"],
                        "run_number": run.get("run_number"),
                        "job_name": failed_job.get("job_name", "Failed job"),
                        "url": failed_job["url"],
                    }
                )
        updated = run.get("updated_at") if run else ""
        latest_timestamps.append(parse_iso(updated))
        matrix.append(
            {
                "id": item["id"],
                "label": item["label"],
                "family": item["family"],
                "workflow": item["workflow"],
                "status_badge_url": f"https://img.shields.io/github/actions/workflow/status/{OWNER}/{REPO}/{item['workflow']}?style=flat-square&label=",
                "status": summarize_state(run),
                "conclusion": run.get("conclusion") if run else "no_data",
                "run_number": run.get("run_number") if run else None,
                "updated_at": updated,
                "duration_seconds": duration,
                "duration_label": human_duration(duration),
                "run_url": run.get("html_url") if run else "",
                "failed_job_url": (failed_job or {}).get("url", ""),
            }
        )

    return {
        "rows": matrix,
        "failed_links": failed_links,
        "last_updated": max([t for t in latest_timestamps if t], default=None),
    }


def collect_security_summary(vulnerability_summary_path):
    if not vulnerability_summary_path.exists():
        return {
            "total_vulnerabilities": 0,
            "affected_packages": 0,
            "raw_vulnerability_matches": 0,
            "raw_affected_packages": 0,
            "confined_mitigation_vulnerabilities": 0,
            "gate_policy": "report_only",
            "architectures": [],
        }
    summary = json.loads(vulnerability_summary_path.read_text(encoding="utf-8"))
    actionable_vulnerabilities = summary.get("actionableVulnerabilities", summary.get("totalVulnerabilities", 0))
    actionable_packages = summary.get("actionableAffectedPackages", summary.get("affectedPackages", 0))
    architectures = []
    for report in summary.get("reports", []):
        architectures.append(
            {
                "architecture": report.get("architecture", "unknown"),
                "affected_packages": report.get("actionableAffectedPackages", report.get("affectedPackages", 0)),
                "vulnerabilities": report.get("actionableVulnerabilities", report.get("vulnerabilities", 0)),
                "raw_affected_packages": report.get("affectedPackages", 0),
                "raw_vulnerability_matches": report.get("vulnerabilities", 0),
                "confined_mitigation_vulnerabilities": report.get("confinedMitigationVulnerabilities", 0),
                "report": report.get("report", ""),
                "generated_at": report.get("generatedAt", {}).get("datetime", ""),
            }
        )
    return {
        "total_vulnerabilities": actionable_vulnerabilities,
        "affected_packages": actionable_packages,
        "raw_vulnerability_matches": summary.get("totalVulnerabilities", 0),
        "raw_affected_packages": summary.get("affectedPackages", 0),
        "confined_mitigation_vulnerabilities": summary.get("confinedMitigationVulnerabilities", 0),
        "gate_policy": "report_only",
        "architectures": architectures,
    }


def collect_release_data(client, versions):
    components = [
        {"key": "ftl", "name": "FTL", "repo": "pi-hole/FTL", "local": versions.get("ftl", "")},
        {"key": "pi_hole", "name": "Pi-hole Core", "repo": "pi-hole/pi-hole", "local": versions.get("pi_hole", "")},
        {"key": "web", "name": "Web UI", "repo": "pi-hole/web", "local": versions.get("web", "")},
    ]

    results = []
    latest_dates = []
    for component in components:
        latest_release = client.get_json_or_empty(f"{GITHUB_API}/repos/{component['repo']}/releases/latest")
        local_release = {}
        if component["local"]:
            local_release = client.get_json_or_empty(
                f"{GITHUB_API}/repos/{component['repo']}/releases/tags/{component['local']}"
            )

        latest_tag = latest_release.get("tag_name", "")
        latest_date = latest_release.get("published_at", "")
        local_date = local_release.get("published_at", "")
        lag_days = None
        local_dt = parse_iso(local_date)
        latest_dt = parse_iso(latest_date)
        if local_dt and latest_dt:
            lag_days = max(0, (latest_dt - local_dt).days)
        compare_url = ""
        if component["local"] and latest_tag and component["local"] != latest_tag:
            compare_url = f"https://github.com/{component['repo']}/compare/{component['local']}...{latest_tag}"
        elif latest_release.get("html_url"):
            compare_url = latest_release["html_url"]

        results.append(
            {
                "key": component["key"],
                "name": component["name"],
                "repository": component["repo"],
                "local_tag": component["local"],
                "local_release_date": local_date,
                "upstream_tag": latest_tag,
                "upstream_release_date": latest_date,
                "update_available": bool(component["local"] and latest_tag and component["local"] != latest_tag),
                "lag_days": lag_days,
                "compare_url": compare_url,
                "release_notes_url": latest_release.get("html_url", ""),
            }
        )
        latest_dates.append(parse_iso(latest_date))
    return {"components": results, "last_updated": dt_to_iso(max([d for d in latest_dates if d], default=None))}


def parse_revisions_file(revisions_file_path):
    if not revisions_file_path.exists():
        return []
    
    parsed = []
    try:
        content = revisions_file_path.read_text(encoding="utf-8")
        for line in content.splitlines():
            line = line.strip()
            if not line:
                continue
            parts = line.split()
            if not parts or not parts[0].isdigit():
                continue
            
            rev = int(parts[0])
            uploaded = parts[1]
            arches = [a.strip() for a in parts[2].split(",") if a.strip()]
            version = parts[3]
            
            channels = []
            if len(parts) > 4:
                channels = [c.strip() for c in parts[4].split(",") if c.strip()]
            
            is_stable = False
            for ch in channels:
                if ch.endswith("/stable*") or ch == "stable*":
                    is_stable = True
                    break
            
            parsed.append({
                "revision": rev,
                "uploaded": uploaded,
                "arches": arches,
                "version": version,
                "is_stable": is_stable,
            })
    except Exception as e:
        print(f"Warning: Failed to parse revisions file: {e}", file=sys.stderr)
        return []
    
    return parsed


def resolve_git_metadata_for_version(repo_root, version_str):
    if "+git." in version_str:
        base_version, rest = version_str.split("+git.", 1)
        parts = rest.split(".")
        git_commit = parts[0]
        git_commit_time = ""
        if len(parts) > 1:
            try:
                unix_time = int(parts[1])
                git_commit_time = datetime.fromtimestamp(unix_time, tz=timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
            except ValueError:
                pass
        return base_version, git_commit, git_commit_time

    tag = version_str.strip()
    try:
        commit = subprocess.check_output(
            ["git", "-C", str(repo_root), "rev-parse", "--short", f"{tag}^{{commit}}"],
            stderr=subprocess.DEVNULL
        ).decode("utf-8").strip()
        
        commit_time_raw = subprocess.check_output(
            ["git", "-C", str(repo_root), "log", "-1", "--format=%ct", commit],
            stderr=subprocess.DEVNULL
        ).decode("utf-8").strip()
        
        unix_time = int(commit_time_raw)
        commit_time = datetime.fromtimestamp(unix_time, tz=timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
        return tag, commit, commit_time
    except (subprocess.SubprocessError, ValueError, IndexError):
        pass

    return version_str, "N/A", ""


def collect_snap_package_data(client, repo_root):
    snap_data = client.get_json_or_empty(
        SNAPCRAFT_INFO_URL,
        headers={"Snap-Device-Series": "16", "Accept": "application/json"},
    )
    channel_map = snap_data.get("channel-map", [])
    public_by_arch = {}
    for entry in channel_map:
        channel = entry.get("channel", {})
        if channel.get("track") != "latest" or channel.get("risk") != "stable":
            continue
        arch = channel.get("architecture", "unknown").upper()
        public_by_arch[arch] = {
            "size_bytes": entry.get("download", {}).get("size"),
            "download_url": entry.get("download", {}).get("url", ""),
            "released_at": channel.get("released-at", ""),
        }

    revisions_file = repo_root / "snapcraft-revisions.txt"
    revisions_list = parse_revisions_file(revisions_file)

    latest_by_arch = {}
    newest_timestamp = None

    if revisions_list:
        for entry in revisions_list:
            if not entry["is_stable"]:
                continue
            for arch in entry["arches"]:
                arch_upper = arch.upper()
                if arch_upper not in latest_by_arch:
                    base_version, git_commit, git_commit_time = resolve_git_metadata_for_version(repo_root, entry["version"])
                    pub = public_by_arch.get(arch_upper, {})
                    latest_by_arch[arch_upper] = {
                        "architecture": arch_upper,
                        "version": base_version,
                        "git_commit": git_commit,
                        "git_commit_time": git_commit_time,
                        "revision": entry["revision"],
                        "size_bytes": pub.get("size_bytes"),
                        "released_at": entry["uploaded"],
                        "download_url": pub.get("download_url", ""),
                        "channel": "stable",
                    }
                    dt = parse_iso(entry["uploaded"])
                    if dt and (newest_timestamp is None or dt > newest_timestamp):
                        newest_timestamp = dt
    else:
        for entry in channel_map:
            channel = entry.get("channel", {})
            if channel.get("track") != "latest" or channel.get("risk") != "stable":
                continue
            arch = channel.get("architecture", "unknown")
            released_at = channel.get("released-at", "")
            arch_upper = arch.upper()
            current = latest_by_arch.get(arch_upper)
            version_str = entry.get("version", "")
            base_version, git_commit, git_commit_time = resolve_git_metadata_for_version(repo_root, version_str)
            if not current or (released_at and released_at > current.get("released_at", "")):
                latest_by_arch[arch_upper] = {
                    "architecture": arch_upper,
                    "version": base_version,
                    "git_commit": git_commit,
                    "git_commit_time": git_commit_time,
                    "revision": entry.get("revision", ""),
                    "size_bytes": entry.get("download", {}).get("size"),
                    "released_at": released_at,
                    "download_url": entry.get("download", {}).get("url", ""),
                    "channel": channel.get("name", ""),
                }
            dt = parse_iso(released_at)
            if dt and (newest_timestamp is None or dt > newest_timestamp):
                newest_timestamp = dt

    return {"channels": list(latest_by_arch.values()), "last_updated": dt_to_iso(newest_timestamp)}


def collect_track_upstream_status(client):
    runs_url = f"{GITHUB_API}/repos/{OWNER}/{REPO}/actions/workflows/track-upstream-releases.yml/runs"
    runs = client.get_json_or_empty(runs_url, params={"per_page": 10, "status": "completed"}).get("workflow_runs", [])
    latest_success = next((run for run in runs if run.get("conclusion") == "success"), None)
    return {
        "latest_success_run": {
            "run_number": latest_success.get("run_number") if latest_success else None,
            "updated_at": latest_success.get("updated_at") if latest_success else "",
            "url": latest_success.get("html_url") if latest_success else "",
        }
    }


def dt_to_iso(value):
    if not value:
        return ""
    return value.isoformat(timespec="seconds").replace("+00:00", "Z")


def main():
    repo_root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    output_path = pathlib.Path(sys.argv[2] if len(sys.argv) > 2 else repo_root / "docs" / "dashboard-data.json")
    vuln_summary_path = pathlib.Path(
        sys.argv[3] if len(sys.argv) > 3 else repo_root / "vulnerability-reports" / "osv-summary.json"
    )

    token = os.environ.get("GITHUB_TOKEN", "")
    client = HTTPClient(token=token)

    versions = extract_snapcraft_versions(repo_root / "snap" / "snapcraft.yaml")
    build_status = collect_build_status(client)
    distro_matrix = collect_distro_matrix(client)
    security = collect_security_summary(vuln_summary_path)
    releases = collect_release_data(client, versions)
    snap_package = collect_snap_package_data(client, repo_root)
    auto_update = collect_track_upstream_status(client)
    schedule = extract_track_upstream_cron(repo_root / ".github" / "workflows" / "track-upstream-releases.yml")

    timestamps = [
        parse_iso(build_status["latest_run"].get("updated_at")),
        distro_matrix.get("last_updated"),
        parse_iso(releases.get("last_updated")),
        parse_iso(snap_package.get("last_updated")),
        parse_iso(auto_update["latest_success_run"].get("updated_at")),
    ]
    data_last_updated = max([t for t in timestamps if t], default=None)

    result = {
        "generated_at": utc_now_iso(),
        "data_last_updated": dt_to_iso(data_last_updated),
        "repository": {
            "owner": OWNER,
            "name": REPO,
            "url": f"https://github.com/{OWNER}/{REPO}",
        },
        "build_status": build_status,
        "security": security,
        "dependencies": {"bundled_versions": versions},
        "release_info": releases,
        "test_matrix": {
            "rows": distro_matrix["rows"],
            "failed_links": distro_matrix["failed_links"],
        },
        "snap_package": snap_package,
        "auto_update": {
            "frequency": schedule,
            "latest_success_run": auto_update["latest_success_run"],
        },
    }

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
