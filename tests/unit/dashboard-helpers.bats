#!/usr/bin/env bats

# Unit tests for the pure/standalone helpers in generate_dashboard_data.py that
# were previously uncovered: formatting helpers, duration math, parsing, the
# status-badge mapping, snapcraft.yaml version extraction, and upstream release
# comparison.

setup() {
    REPO_ROOT="$(git rev-parse --show-toplevel)"
    TEST_TMPDIR="$(mktemp -d)"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

@test "dashboard helpers: parse_iso, dt_to_iso and summarize_state handle edges" {
    python3 - <<PYEOF
import sys
sys.path.insert(0, "${REPO_ROOT}/snap/local/build")
from datetime import datetime, timezone
from generate_dashboard_data import parse_iso, dt_to_iso, summarize_state

assert parse_iso("") is None
assert parse_iso(None) is None
dt = parse_iso("2026-06-10T17:00:00Z")
assert dt == datetime(2026, 6, 10, 17, 0, 0, tzinfo=timezone.utc), dt

assert dt_to_iso(None) == ""
assert dt_to_iso(dt) == "2026-06-10T17:00:00Z", dt_to_iso(dt)

assert summarize_state(None) == "no_data"
assert summarize_state({"status": "in_progress"}) == "in_progress"
assert summarize_state({"status": "queued"}) == "queued"
assert summarize_state({"status": None}) == "queued"
assert summarize_state({"status": "completed", "conclusion": "success"}) == "success"
assert summarize_state({"status": "completed", "conclusion": None}) == "unknown"
PYEOF
}

@test "dashboard helpers: human_duration formats seconds, minutes and hours" {
    python3 - <<PYEOF
import sys
sys.path.insert(0, "${REPO_ROOT}/snap/local/build")
from generate_dashboard_data import human_duration

assert human_duration(None) == "Unknown"
assert human_duration(0) == "0s"
assert human_duration(45) == "45s"
assert human_duration(90) == "1m 30s"
assert human_duration(3661) == "1h 1m", human_duration(3661)
PYEOF
}

@test "dashboard helpers: run/job duration clamps to zero and tolerates missing timestamps" {
    python3 - <<PYEOF
import sys
sys.path.insert(0, "${REPO_ROOT}/snap/local/build")
from generate_dashboard_data import run_duration_seconds, job_duration_seconds

assert run_duration_seconds({}) is None
assert run_duration_seconds({"run_started_at": "2026-06-10T00:00:00Z"}) is None
assert run_duration_seconds({
    "run_started_at": "2026-06-10T00:00:00Z",
    "updated_at": "2026-06-10T00:02:30Z",
}) == 150
# created_at is used when run_started_at is absent.
assert run_duration_seconds({
    "created_at": "2026-06-10T00:00:00Z",
    "updated_at": "2026-06-10T00:00:10Z",
}) == 10
# Negative spans clamp to zero rather than going negative.
assert run_duration_seconds({
    "run_started_at": "2026-06-10T00:05:00Z",
    "updated_at": "2026-06-10T00:00:00Z",
}) == 0

assert job_duration_seconds({}) is None
assert job_duration_seconds({
    "started_at": "2026-06-10T00:00:00Z",
    "completed_at": "2026-06-10T00:01:00Z",
}) == 60
PYEOF
}

@test "dashboard helpers: calculate_update_frequency_days averages gaps and needs two points" {
    python3 - <<PYEOF
import sys
sys.path.insert(0, "${REPO_ROOT}/snap/local/build")
from generate_dashboard_data import calculate_update_frequency_days, parse_iso

assert calculate_update_frequency_days([]) is None
assert calculate_update_frequency_days([parse_iso("2026-06-10T00:00:00Z")]) is None
# None entries are ignored; fewer than two real points -> None.
assert calculate_update_frequency_days([None, parse_iso("2026-06-10T00:00:00Z")]) is None

stamps = [
    parse_iso("2026-06-10T00:00:00Z"),
    parse_iso("2026-06-08T00:00:00Z"),
    parse_iso("2026-06-06T00:00:00Z"),
]
assert calculate_update_frequency_days(stamps) == 2.0, calculate_update_frequency_days(stamps)
PYEOF
}

@test "dashboard helpers: get_status_badge_url maps statuses to shields labels and colors" {
    python3 - <<PYEOF
import sys
sys.path.insert(0, "${REPO_ROOT}/snap/local/build")
from generate_dashboard_data import get_status_badge_url

def parts(status):
    url = get_status_badge_url(status)
    assert url.startswith("https://img.shields.io/badge/status-"), url
    return url

assert "status-passed-success" in parts("success")
for failing in ("failure", "timed_out", "startup_failure", "action_required"):
    assert "status-failed-critical" in parts(failing), failing
# A cancelled run means no new build was produced, not a broken one: neutral, not failed.
assert "status-cancelled-lightgrey" in parts("cancelled"), "cancelled"
for running in ("in_progress", "running"):
    assert "status-running-blue" in parts(running), running
assert "status-no--data-lightgrey" in parts("no_data")
for queued in ("queued", "waiting", "unknown"):
    assert "status-queued-lightgrey" in parts(queued), queued
# Unknown values fall through using the raw status as the label.
assert "status-weird-lightgrey" in parts("weird")
PYEOF
}

@test "dashboard helpers: distro_job_key and extract_track_upstream_cron parse identifiers" {
    cat > "${TEST_TMPDIR}/track.yml" <<'EOF'
on:
  schedule:
    - cron: '0 0 * * *'
EOF
    cat > "${TEST_TMPDIR}/track-weekly.yml" <<'EOF'
on:
  schedule:
    - cron: '0 6 * * 1'
EOF
    cat > "${TEST_TMPDIR}/track-none.yml" <<'EOF'
on:
  push:
    branches: [main]
EOF

    python3 - <<PYEOF
import pathlib
import sys
sys.path.insert(0, "${REPO_ROOT}/snap/local/build")
from generate_dashboard_data import distro_job_key, extract_track_upstream_cron

assert distro_job_key("test-rockylinux.yml") == "rockylinux"
assert distro_job_key("test-ubuntu-daily.yml") == "ubuntu-daily"
assert distro_job_key("plain.yml") == "plain"
assert distro_job_key("test-arch") == "arch"

daily = extract_track_upstream_cron(pathlib.Path("${TEST_TMPDIR}/track.yml"))
assert daily == {"cron": "0 0 * * *", "label": "Daily at 00:00 UTC"}, daily

weekly = extract_track_upstream_cron(pathlib.Path("${TEST_TMPDIR}/track-weekly.yml"))
assert weekly == {"cron": "0 6 * * 1", "label": "Scheduled"}, weekly

missing = extract_track_upstream_cron(pathlib.Path("${TEST_TMPDIR}/track-none.yml"))
assert missing == {"cron": "", "label": "Unknown"}, missing
PYEOF
}

@test "dashboard helpers: extract_snapcraft_versions reads release labels for tracked parts" {
    cat > "${TEST_TMPDIR}/snapcraft.yaml" <<'EOF'
name: pihole-by-rajannpatel
base: core24
parts:
  ftl:
    plugin: nil
    source-commit: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  pi_hole:
    plugin: dump
    source-commit: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  web:
    source-commit: cccccccccccccccccccccccccccccccccccccccc
  unrelated:
    source-tag: v9.9.9
apps:
  pihole:
    command: bin/pihole
EOF
    mkdir -p "${TEST_TMPDIR}/snap/local/build"
    cat > "${TEST_TMPDIR}/snap/local/build/stable-versions.json" <<'EOF'
{"ftl": "v6.6.2", "pi_hole": "v6.4.2", "web": "v6.5.1"}
EOF

    python3 - <<PYEOF
import pathlib
import sys
sys.path.insert(0, "${REPO_ROOT}/snap/local/build")
from generate_dashboard_data import extract_snapcraft_sources, extract_snapcraft_versions

path = pathlib.Path("${TEST_TMPDIR}/snapcraft.yaml")
versions = extract_snapcraft_versions(path)
assert versions == {"ftl": "v6.6.2", "pi_hole": "v6.4.2", "web": "v6.5.1"}, versions
sources = extract_snapcraft_sources(path)
assert sources["ftl"]["commit"] == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", sources
assert sources["pi_hole"]["commit"] == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", sources
assert sources["web"]["commit"] == "cccccccccccccccccccccccccccccccccccccccc", sources
PYEOF
}

@test "dashboard helpers: collect_release_data computes lag, update flags and compare urls" {
    python3 - <<PYEOF
import sys
sys.path.insert(0, "${REPO_ROOT}/snap/local/build")
import generate_dashboard_data as dashboard

LATEST = {
    "pi-hole/FTL": {"tag_name": "v6.5", "published_at": "2026-06-10T00:00:00Z",
                    "html_url": "https://github.com/pi-hole/FTL/releases/v6.5"},
    "pi-hole/pi-hole": {"tag_name": "v6.4", "published_at": "2026-06-05T00:00:00Z",
                        "html_url": "https://github.com/pi-hole/pi-hole/releases/v6.4"},
    "pi-hole/web": {"tag_name": "v6.1", "published_at": "2026-06-09T00:00:00Z",
                    "html_url": "https://github.com/pi-hole/web/releases/v6.1"},
}
TAGS = {
    ("pi-hole/FTL", "v6.4"): {"published_at": "2026-06-01T00:00:00Z"},
    ("pi-hole/pi-hole", "v6.4"): {"published_at": "2026-06-05T00:00:00Z"},
}

class FakeClient:
    def get_json_or_empty(self, url, headers=None, params=None):
        if url.endswith("/releases/latest"):
            repo = url.split("/repos/", 1)[1].rsplit("/releases/latest", 1)[0]
            return LATEST[repo]
        if "/releases/tags/" in url:
            repo, tag = url.split("/repos/", 1)[1].split("/releases/tags/")
            return TAGS.get((repo, tag), {})
        if "/commits/" in url:
            ref = url.split("/commits/", 1)[1]
            return {"sha": f"mocksha_{ref}"}
        raise AssertionError(f"unexpected url {url}")

versions = {"ftl": "v6.4", "pi_hole": "v6.4", "web": ""}
result = dashboard.collect_release_data(FakeClient(), versions)
by_key = {c["key"]: c for c in result["components"]}

# FTL: behind upstream -> update available, 9 day lag, compare pinned commit to master.
ftl = by_key["ftl"]
assert ftl["update_available"] is True, ftl
assert ftl["lag_days"] == 9, ftl
assert ftl["compare_url"] == "https://github.com/pi-hole/FTL/compare/mocksha_v6.4...master", ftl

# Core: local tag == upstream tag, but the pinned source commit differs from master.
core = by_key["pi_hole"]
assert core["update_available"] is True, core
assert core["lag_days"] == 0, core
assert core["compare_url"] == "https://github.com/pi-hole/pi-hole/compare/mocksha_v6.4...master", core

# Web: no local tag -> no update, lag unknown, compare falls back to release page.
web = by_key["web"]
assert web["update_available"] is False, web
assert web["lag_days"] is None, web
assert web["compare_url"] == "https://github.com/pi-hole/web/releases/v6.1", web

# Verify commit SHAs are populated
assert ftl["local_commit"] == "mocksha_v6.4", ftl["local_commit"]
assert ftl["upstream_commit"] == "mocksha_master", ftl["upstream_commit"]

# Aggregate last_updated tracks the newest upstream release.
assert result["last_updated"] == "2026-06-10T00:00:00Z", result["last_updated"]
PYEOF
}

@test "dashboard helpers: collect_edge_release_data keeps version labels alongside commit pins" {
    python3 - <<PYEOF
import sys
sys.path.insert(0, "${REPO_ROOT}/snap/local/build")
import generate_dashboard_data as dashboard

LATEST = {
    "pi-hole/FTL": {"tag_name": "v6.6.2"},
    "pi-hole/pi-hole": {"tag_name": "v6.4.2"},
    "pi-hole/web": {"tag_name": "v6.5.1"},
}

class FakeClient:
    def get_json_or_empty(self, url, headers=None, params=None):
        if url.endswith("/releases/latest"):
            repo = url.split("/repos/", 1)[1].rsplit("/releases/latest", 1)[0]
            return LATEST[repo]
        if "/commits/development" in url:
            repo = url.split("/repos/", 1)[1].rsplit("/commits/development", 1)[0]
            return {"sha": f"devsha_{repo.rsplit('/', 1)[1]}"}
        raise AssertionError(f"unexpected url {url}")

versions = {"ftl": "local-ftl", "pi_hole": "local-core", "web": "local-web"}
display_versions = {"ftl": "v6.6.2", "pi_hole": "v6.4.2", "web": "v6.5.1"}
rows = dashboard.collect_edge_release_data(FakeClient(), versions, display_versions)
by_key = {row["key"]: row for row in rows}

assert by_key["ftl"]["local_tag"] == "v6.6.2", by_key["ftl"]
assert by_key["ftl"]["upstream_tag"] == "v6.6.2", by_key["ftl"]
assert by_key["pi_hole"]["local_tag"] == "v6.4.2", by_key["pi_hole"]
assert by_key["pi_hole"]["upstream_tag"] == "v6.4.2", by_key["pi_hole"]
assert by_key["web"]["local_tag"] == "v6.5.1", by_key["web"]
assert by_key["web"]["upstream_tag"] == "v6.5.1", by_key["web"]
assert by_key["web"]["local_commit"] == "local-web", by_key["web"]
assert by_key["web"]["upstream_commit"] == "devsha_web", by_key["web"]
PYEOF
}
