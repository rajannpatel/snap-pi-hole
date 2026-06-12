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

# GitHub-hosted runners only build amd64 and arm64 (see the build matrix in
# .github/workflows/cicd.yml). The other four architectures (armhf, ppc64el,
# riscv64, s390x) are built on Launchpad's build farm via `snapcraft
# remote-build`, driven by the same CI run, and published to stable alongside
# the GitHub-built ones. build_source records where each arch is built.
GITHUB_BUILD_ARCHES = {"AMD64", "ARM64"}
RISK_RANK = {"stable": 4, "candidate": 3, "beta": 2, "edge": 1}

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


def get_status_badge_url(status):
    if status == "success":
        color = "success"
        label = "passed"
    elif status in {"failure", "timed_out", "startup_failure", "action_required"}:
        color = "critical"
        label = "failed"
    elif status in {"in_progress", "running"}:
        color = "blue"
        label = "running"
    elif status in {"queued", "waiting", "no_data", "unknown"}:
        color = "lightgrey"
        label = "no--data" if status == "no_data" else "queued"
    else:
        color = "lightgrey"
        label = status
    return f"https://img.shields.io/badge/status-{label}-{color}?style=flat-square"


def job_duration_seconds(job):
    started = parse_iso(job.get("started_at"))
    ended = parse_iso(job.get("completed_at"))
    if not started or not ended:
        return None
    return max(0, int((ended - started).total_seconds()))


def distro_job_key(workflow_file):
    """Map a test-<distro>.yml workflow to its cicd.yml matrix job key.

    The cicd.yml pipeline runs each distribution as a matrix job named
    ``distro test (<key>)`` where <key> matches the workflow file stem, e.g.
    test-rockylinux.yml -> rockylinux -> "distro test (rockylinux)".
    """
    base = workflow_file
    if base.startswith("test-"):
        base = base[len("test-"):]
    if base.endswith(".yml"):
        base = base[: -len(".yml")]
    return base


def latest_cicd_run_with_distro_jobs(client):
    """Return (run, jobs) for the newest cicd.yml run that contains the
    per-distribution ``distro test (...)`` matrix jobs."""
    runs_url = f"{GITHUB_API}/repos/{OWNER}/{REPO}/actions/workflows/cicd.yml/runs"
    runs_data = client.get_json_or_empty(
        runs_url,
        params={"per_page": 10, "branch": "main", "event": "push"},
    )
    for run in runs_data.get("workflow_runs", []):
        jobs_url = f"{GITHUB_API}/repos/{OWNER}/{REPO}/actions/runs/{run.get('id')}/jobs"
        jobs = client.get_json_or_empty(jobs_url, params={"per_page": 100}).get("jobs", [])
        if any(job.get("name", "").startswith("distro test (") for job in jobs):
            return run, jobs
    return None, []


def collect_distro_matrix(client):
    matrix = []
    failed_links = []
    latest_timestamps = []

    failure_states = {"failure", "timed_out", "action_required", "startup_failure"}

    # Each distribution is exercised as a `distro test (<key>)` matrix job inside
    # the main cicd.yml pipeline, which runs on every push to main, so the newest
    # pipeline run that carries those jobs is the source of truth for the matrix.
    target_run, jobs = latest_cicd_run_with_distro_jobs(client)
    run_number = target_run.get("run_number") if target_run else None

    for item in DISTRO_WORKFLOWS:
        prefix = f"distro test ({distro_job_key(item['workflow'])})"
        job = next((j for j in jobs if j.get("name", "").startswith(prefix)), None)

        status = summarize_state(job)
        conclusion = job.get("conclusion") if job else "no_data"
        duration = job_duration_seconds(job) if job else None
        updated = (job.get("completed_at") or job.get("started_at") or "") if job else ""
        if not updated and target_run:
            updated = target_run.get("updated_at", "")
        run_url = (job.get("html_url", "") if job else "") or (target_run.get("html_url", "") if target_run else "")

        if updated:
            latest_timestamps.append(parse_iso(updated))

        failed_job_url = ""
        if job and status in failure_states:
            failed_job_url = job.get("html_url", "") or run_url
            failed_links.append(
                {
                    "distro": item["label"],
                    "workflow": item["workflow"],
                    "run_number": run_number,
                    "job_name": job.get("name", "Failed job"),
                    "url": failed_job_url,
                }
            )

        matrix.append(
            {
                "id": item["id"],
                "label": item["label"],
                "family": item["family"],
                "workflow": item["workflow"],
                "distro": distro_job_key(item["workflow"]),
                "status_badge_url": get_status_badge_url(status),
                "status": status,
                "conclusion": conclusion,
                "run_number": run_number,
                "updated_at": updated,
                "duration_seconds": duration,
                "duration_label": human_duration(duration),
                "run_url": run_url,
                "failed_job_url": failed_job_url,
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


def _commit_matches(a, b):
    a = (a or "").strip()
    b = (b or "").strip()
    if not a or not b or a == "N/A" or b == "N/A":
        return False
    return a.startswith(b) or b.startswith(a)


def resolve_expected_commit(repo_root):
    ref = os.environ.get("GITHUB_SHA", "").strip() or "HEAD"
    try:
        return subprocess.check_output(
            ["git", "-C", str(repo_root), "rev-parse", "--short", ref],
            stderr=subprocess.DEVNULL,
        ).decode("utf-8").strip()
    except (subprocess.SubprocessError, ValueError):
        return ""


def compute_snap_freshness(channels, revisions_list, expected_commit, publish_result):
    publish_result = (publish_result or "").strip().lower()
    expected_commit = (expected_commit or "").strip()
    freshness = {
        "expected_commit": expected_commit,
        "publish_result": publish_result,
        "expected_commit_published": False,
        "expected_commit_in_store": False,
        "freshness": "unknown",
    }
    if not expected_commit:
        return freshness

    for channel in channels:
        if _commit_matches(channel.get("git_commit", ""), expected_commit):
            freshness["expected_commit_published"] = True
            break

    for entry in revisions_list:
        version = str(entry.get("version", ""))
        if "+git." in version:
            sha = version.split("+git.", 1)[1].split(".")[0]
            if _commit_matches(sha, expected_commit):
                freshness["expected_commit_in_store"] = True
                break

    if freshness["expected_commit_published"]:
        freshness["freshness"] = "current"
    elif freshness["expected_commit_in_store"]:
        freshness["freshness"] = "uploaded_not_selected"
    elif publish_result == "failure":
        freshness["freshness"] = "publish_failed"
    elif publish_result == "success":
        freshness["freshness"] = "pending"
    else:
        freshness["freshness"] = "unknown"

    return freshness


def collect_snap_package_data(client, repo_root):
    snap_data = client.get_json_or_empty(
        SNAPCRAFT_INFO_URL,
        headers={"Snap-Device-Series": "16", "Accept": "application/json"},
    )
    channel_map = snap_data.get("channel-map", [])
 
    # First pass: collect all channel+arch combinations from the channel map
    all_channels_raw = {}  # channel -> {arch -> entry}
    for entry in channel_map:
        channel = entry.get("channel", {})
        if channel.get("track") != "latest":
            continue
        risk = channel.get("risk", "")
        arch_upper = channel.get("architecture", "unknown").upper()
        if risk not in all_channels_raw:
            all_channels_raw[risk] = {}
        all_channels_raw[risk][arch_upper] = entry
 
    # Pick the best (highest-risk, then newest) published revision per architecture
    # in the latest track. amd64/arm64 are promoted all the way to stable (the
    # GitHub builds served on snapcraft.io); the Launchpad architectures only reach
    # edge and can lag behind the newest revision (slower or less frequent rebuilds,
    # or store propagation delay), so they may appear stale without having failed.
    best_by_arch = {}
    stable_arches = set()
    for entry in channel_map:
        channel = entry.get("channel", {})
        if channel.get("track") != "latest":
            continue
        risk = channel.get("risk", "")
        arch_upper = channel.get("architecture", "unknown").upper()
        released_at = channel.get("released-at", "")
        if risk == "stable":
            stable_arches.add(arch_upper)
        rank = RISK_RANK.get(risk, 0)
        current = best_by_arch.get(arch_upper)
        if current is None or rank > current["_rank"] or (
            rank == current["_rank"] and released_at > current.get("released_at", "")
        ):
            version_str = entry.get("version", "")
            base_version, git_commit, git_commit_time = resolve_git_metadata_for_version(repo_root, version_str)
            best_by_arch[arch_upper] = {
                "architecture": arch_upper,
                "full_version": version_str,
                "version": base_version,
                "git_commit": git_commit,
                "git_commit_time": git_commit_time,
                "revision": entry.get("revision", ""),
                "size_bytes": entry.get("download", {}).get("size"),
                "released_at": released_at,
                "download_url": entry.get("download", {}).get("url", ""),
                "channel": risk,
                "_rank": rank,
            }

    # The newest released revision is the version actually being served; use it to
    # flag architectures whose builds have fallen behind.
    reference_version = ""
    newest_timestamp = None
    for info in best_by_arch.values():
        dt = parse_iso(info.get("released_at", ""))
        if dt and (newest_timestamp is None or dt > newest_timestamp):
            newest_timestamp = dt
            reference_version = info.get("full_version", "")

    channels = []
    for arch_upper, info in best_by_arch.items():
        info.pop("_rank", None)
        info["build_source"] = "github" if arch_upper in GITHUB_BUILD_ARCHES else "launchpad"
        info["on_stable"] = arch_upper in stable_arches
        info["build_status"] = (
            "current"
            if reference_version and info.get("full_version", "") == reference_version
            else "stale"
        )
        channels.append(info)

    # GitHub-built architectures first, then Launchpad; alphabetical within groups.
    channels.sort(key=lambda c: (0 if c["build_source"] == "github" else 1, c["architecture"]))
 
    revisions_list = parse_revisions_file(repo_root / "snapcraft-revisions.txt")
    freshness = compute_snap_freshness(
        channels,
        revisions_list,
        resolve_expected_commit(repo_root),
        os.environ.get("PUBLISH_RESULT", ""),
    )
     
    # Build published_channels: all architectures grouped per channel
    # (for UI display of which architectures are available in each channel)
    # Use the raw all_channels_raw which has ALL channel+arch combinations
    published_channels = []
    for channel_name in ["stable", "candidate", "beta", "edge"]:
        if channel_name not in all_channels_raw or not all_channels_raw[channel_name]:
            continue
         
        arches_dict = all_channels_raw[channel_name]
        architectures = list(arches_dict.keys())
         
        # Get newest release date for this channel.
        # arches_dict values are raw channel-map entries; the date is nested
        # under the "channel" sub-key as "released-at".
        newest_date = max(
            (
                e.get("channel", {}).get("released-at", "")
                for e in arches_dict.values()
            ),
            default=""
        )
         
        published_channels.append({
            "channel": channel_name,
            "released_at": newest_date,
            "architectures": sorted(architectures),
        })
      
    return {
        "channels": channels,
        "published_channels": published_channels,
        "last_updated": dt_to_iso(newest_timestamp),
        **freshness,
    }


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


def build_snapcraft_payload(client, repo_root):
    snap_package = collect_snap_package_data(client, repo_root)
    return {
        "generated_at": utc_now_iso(),
        "data_last_updated": snap_package.get("last_updated") or utc_now_iso(),
        "snap_package": snap_package,
    }


def main():
    args = [a for a in sys.argv[1:] if a != "--snapcraft-only"]
    snapcraft_only = "--snapcraft-only" in sys.argv[1:]
    repo_root = pathlib.Path(args[0] if len(args) > 0 else ".").resolve()

    token = os.environ.get("GITHUB_TOKEN", "")
    client = HTTPClient(token=token)

    # Snapcraft-exclusive data (snap-store metadata) has no browser-reachable
    # API and changes independently of code pushes, so it lives in its own file
    # refreshed on an hourly schedule rather than only at deploy time.
    if snapcraft_only:
        output_path = pathlib.Path(
            args[1] if len(args) > 1 else repo_root / "docs" / "snapcraft-dashboard-data.json"
        )
        payload = build_snapcraft_payload(client, repo_root)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
        return

    output_path = pathlib.Path(args[1] if len(args) > 1 else repo_root / "docs" / "dashboard-data.json")
    vuln_summary_path = pathlib.Path(
        args[2] if len(args) > 2 else repo_root / "vulnerability-reports" / "osv-summary.json"
    )

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
