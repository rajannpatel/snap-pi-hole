#!/usr/bin/env bats

setup() {
    REPO_ROOT="$(git rev-parse --show-toplevel)"
    TEST_TMPDIR="$(mktemp -d)"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

@test "dashboard data: parse_revisions_file parses snapcraft revisions output correctly" {
    cat > "${TEST_TMPDIR}/snapcraft-revisions.txt" <<'EOF'
Rev.   Uploaded              Arches        Version             Channels
325    2026-06-08T00:55:20Z  amd64         v6.4.2              latest/stable*
324    2026-06-08T00:54:42Z  arm64         v6.4.2              latest/stable*,latest/candidate
323    2026-06-07T12:00:00Z  armhf         v6.4.2-beta         latest/beta*
322    2026-06-07T11:00:00Z  ppc64el       v6.4.2+git.abc.123  latest/edge*
EOF

    python3 - <<PYEOF
import pathlib
import sys
sys.path.insert(0, "${REPO_ROOT}/snap/local/build")
from generate_dashboard_data import parse_revisions_file

revisions = parse_revisions_file(pathlib.Path("${TEST_TMPDIR}/snapcraft-revisions.txt"))
assert len(revisions) == 4, f"Expected 4 revisions, got {len(revisions)}"

# Rev 325
r325 = revisions[0]
assert r325["revision"] == 325
assert r325["uploaded"] == "2026-06-08T00:55:20Z"
assert r325["arches"] == ["amd64"]
assert r325["version"] == "v6.4.2"
assert r325["is_stable"] is True

# Rev 324
r324 = revisions[1]
assert r324["revision"] == 324
assert r324["arches"] == ["arm64"]
assert r324["is_stable"] is True

# Rev 323
r323 = revisions[2]
assert r323["revision"] == 323
assert r323["is_stable"] is False

# Rev 322
r322 = revisions[3]
assert r322["revision"] == 322
assert r322["is_stable"] is False
PYEOF
}

@test "dashboard data: resolve_git_metadata_for_version resolves +git. versions and local tags" {
    python3 - <<PYEOF
import pathlib
import sys
sys.path.insert(0, "${REPO_ROOT}/snap/local/build")
from generate_dashboard_data import resolve_git_metadata_for_version

# Test +git. parsing
ver, commit, time = resolve_git_metadata_for_version(pathlib.Path("${REPO_ROOT}"), "v6.4.2+git.653b0f0.1780880261")
assert ver == "v6.4.2", ver
assert commit == "653b0f0", commit
assert time == "2026-06-08T00:57:41Z", time

# Test non-existent tag fallback
ver2, commit2, time2 = resolve_git_metadata_for_version(pathlib.Path("${REPO_ROOT}"), "non-existent-tag-12345")
assert ver2 == "non-existent-tag-12345"
assert commit2 == "N/A"
assert time2 == ""
PYEOF
}

@test "dashboard data: distro matrix reads cicd.yml distro-test jobs (failed, passed, running, queued, no-data)" {
    python3 - <<PYEOF
import sys
sys.path.insert(0, "${REPO_ROOT}/snap/local/build")
import generate_dashboard_data as dashboard

class FakeClient:
    def get_json_or_empty(self, url, headers=None, params=None):
        if url.endswith("/actions/workflows/cicd.yml/runs"):
            return {
                "workflow_runs": [
                    {
                        "id": 123,
                        "status": "completed",
                        "conclusion": "failure",
                        "run_number": 42,
                        "head_branch": "main",
                        "event": "push",
                        "run_started_at": "2026-06-08T10:00:00Z",
                        "updated_at": "2026-06-08T10:03:05Z",
                        "html_url": "https://example.test/run/123",
                    }
                ]
            }
        if url.endswith("/actions/runs/123/jobs"):
            return {
                "jobs": [
                    {"name": "build (amd64)", "status": "completed", "conclusion": "success", "html_url": ""},
                    {
                        "name": "distro test (failing) / Validate Snap Installation",
                        "status": "completed",
                        "conclusion": "failure",
                        "started_at": "2026-06-08T10:00:00Z",
                        "completed_at": "2026-06-08T10:03:05Z",
                        "html_url": "https://example.test/job/456",
                    },
                    {
                        "name": "distro test (passing) / Validate Snap Installation",
                        "status": "completed",
                        "conclusion": "success",
                        "started_at": "2026-06-08T10:00:00Z",
                        "completed_at": "2026-06-08T10:02:00Z",
                        "html_url": "https://example.test/job/457",
                    },
                    {
                        "name": "distro test (running) / Validate Snap Installation",
                        "status": "in_progress",
                        "conclusion": None,
                        "started_at": "2026-06-08T10:00:00Z",
                        "completed_at": None,
                        "html_url": "https://example.test/job/458",
                    },
                    {
                        "name": "distro test (queued) / Validate Snap Installation",
                        "status": "queued",
                        "conclusion": None,
                        "started_at": None,
                        "completed_at": None,
                        "html_url": "https://example.test/job/459",
                    },
                ]
            }
        raise AssertionError(f"unexpected URL: {url}")

original = dashboard.DISTRO_WORKFLOWS
try:
    dashboard.DISTRO_WORKFLOWS = [
        {"id": "failing", "label": "Failing OS", "workflow": "test-failing.yml", "family": "Test"},
        {"id": "passing", "label": "Passing OS", "workflow": "test-passing.yml", "family": "Test"},
        {"id": "running", "label": "Running OS", "workflow": "test-running.yml", "family": "Test"},
        {"id": "queued", "label": "Queued OS", "workflow": "test-queued.yml", "family": "Test"},
        {"id": "missing", "label": "Missing OS", "workflow": "test-missing.yml", "family": "Test"},
    ]
    matrix = dashboard.collect_distro_matrix(FakeClient())
finally:
    dashboard.DISTRO_WORKFLOWS = original

rows = {row["id"]: row for row in matrix["rows"]}

# Failing distro: status, duration, badge and failed-link all sourced from the job
assert rows["failing"]["status"] == "failure", rows["failing"]
assert rows["failing"]["duration_seconds"] == 185, rows["failing"]
assert rows["failing"]["duration_label"] == "3m 5s", rows["failing"]
assert rows["failing"]["run_number"] == 42, rows["failing"]
assert rows["failing"]["distro"] == "failing", rows["failing"]
assert rows["failing"]["failed_job_url"] == "https://example.test/job/456", rows["failing"]
assert rows["failing"]["status_badge_url"] == (
    "https://img.shields.io/badge/status-failed-critical?style=flat-square"
), rows["failing"]

# Passing distro: success badge, no failed link
assert rows["passing"]["status"] == "success", rows["passing"]
assert rows["passing"]["status_badge_url"] == (
    "https://img.shields.io/badge/status-passed-success?style=flat-square"
), rows["passing"]
assert rows["passing"]["failed_job_url"] == "", rows["passing"]

# Running distro: running badge, status in_progress
assert rows["running"]["status"] == "in_progress", rows["running"]
assert rows["running"]["status_badge_url"] == (
    "https://img.shields.io/badge/status-running-blue?style=flat-square"
), rows["running"]

# Queued distro: queued badge, status queued
assert rows["queued"]["status"] == "queued", rows["queued"]
assert rows["queued"]["status_badge_url"] == (
    "https://img.shields.io/badge/status-queued-lightgrey?style=flat-square"
), rows["queued"]

# Missing distro: no matching job -> no_data row
assert rows["missing"]["status"] == "no_data", rows["missing"]
assert rows["missing"]["conclusion"] == "no_data", rows["missing"]
assert rows["missing"]["duration_label"] == "Unknown", rows["missing"]
assert rows["missing"]["status_badge_url"] == (
    "https://img.shields.io/badge/status-no--data-lightgrey?style=flat-square"
), rows["missing"]

assert matrix["failed_links"] == [
    {
        "distro": "Failing OS",
        "workflow": "test-failing.yml",
        "run_number": 42,
        "job_name": "distro test (failing) / Validate Snap Installation",
        "url": "https://example.test/job/456",
    }
], matrix["failed_links"]
assert matrix["last_updated"].isoformat() == "2026-06-08T10:03:05+00:00", matrix["last_updated"]
PYEOF
}

@test "dashboard data: default distro matrix metadata points at cicd.yml" {
    python3 - <<PYEOF
import sys
sys.path.insert(0, "${REPO_ROOT}/snap/local/build")
import generate_dashboard_data as dashboard

rows = dashboard.DISTRO_WORKFLOWS
assert rows, "DISTRO_WORKFLOWS should not be empty"
for row in rows:
    assert row["workflow"] == "cicd.yml", row
    assert row.get("distro"), row
    assert not row["workflow"].startswith("test-"), row
PYEOF
}

@test "dashboard data: snap package classifies GitHub vs Launchpad builds and keeps full version" {
    python3 - <<PYEOF
import pathlib
import sys
sys.path.insert(0, "${REPO_ROOT}/snap/local/build")
import generate_dashboard_data as dashboard

def ch(track, risk, arch, version, revision, released, size):
    return {
        "channel": {"track": track, "risk": risk, "architecture": arch, "released-at": released},
        "version": version,
        "revision": revision,
        "download": {"size": size, "url": f"https://example.test/{arch}.snap"},
    }

class FakeClient:
    def get_json_or_empty(self, url, headers=None, params=None):
        assert url == dashboard.SNAPCRAFT_INFO_URL, url
        return {
            "channel-map": [
                # GitHub arches promoted all the way to stable, newest version.
                ch("latest", "stable", "amd64", "v6.4.2+git.0ffee9d.1781062076", 382, "2026-06-10T17:00:00Z", 100),
                ch("latest", "edge",   "amd64", "v6.4.2+git.0ffee9d.1781062076", 382, "2026-06-10T17:00:00Z", 100),
                ch("latest", "stable", "arm64", "v6.4.2+git.0ffee9d.1781062076", 383, "2026-06-10T17:00:00Z", 110),
                ch("latest", "edge",   "arm64", "v6.4.2+git.0ffee9d.1781062076", 383, "2026-06-10T17:00:00Z", 110),
                # Launchpad arch lagging on edge with an older revision (behind, not failing).
                ch("latest", "edge",   "s390x", "v6.4.2", 137, "2025-05-22T00:00:00Z", 120),
            ]
        }

# repo_root points at a non-git temp dir so resolve_expected_commit() returns ""
# (freshness "unknown") and no snapcraft-revisions.txt is present.
result = dashboard.collect_snap_package_data(FakeClient(), pathlib.Path("${TEST_TMPDIR}"))
by_arch = {c["architecture"]: c for c in result["channels"]}

# GitHub-built, current, served on stable, full +git version preserved.
amd = by_arch["AMD64"]
assert amd["build_source"] == "github", amd
assert amd["build_status"] == "current", amd
assert amd["on_stable"] is True, amd
assert amd["channel"] == "stable", amd
assert amd["full_version"] == "v6.4.2+git.0ffee9d.1781062076", amd
assert amd["revision"] == 382, amd

assert by_arch["ARM64"]["build_source"] == "github", by_arch["ARM64"]

# Launchpad-built, stale, edge only, older version.
s390x = by_arch["S390X"]
assert s390x["build_source"] == "launchpad", s390x
assert s390x["build_status"] == "stale", s390x
assert s390x["on_stable"] is False, s390x
assert s390x["channel"] == "edge", s390x
assert s390x["full_version"] == "v6.4.2", s390x

# GitHub arches sort ahead of Launchpad arches.
assert [c["architecture"] for c in result["channels"]] == ["AMD64", "ARM64", "S390X"], result["channels"]

# published_channels groups all arches per channel (includes stable, edge, and all architectures present)
published = {ch["channel"]: ch for ch in result.get("published_channels", [])}
assert "stable" in published, f"stable missing from {published}"
assert "edge" in published, f"edge missing from {published}"
assert set(published["stable"]["architectures"]) == {"AMD64", "ARM64"}, f"stable arches: {published['stable']}"
assert set(published["edge"]["architectures"]) == {"AMD64", "ARM64", "S390X"}, f"edge arches: {published['edge']}"
# released_at must be populated from the nested channel["released-at"] field, not empty/unknown
assert published["stable"]["released_at"] == "2026-06-10T17:00:00Z", f"stable released_at: {published['stable']['released_at']}"
assert published["edge"]["released_at"] == "2026-06-10T17:00:00Z", f"edge released_at: {published['edge']['released_at']}"
PYEOF
}

@test "dashboard data: published channels cover candidate/beta, pick newest date, and flag stale arches" {
    python3 - <<PYEOF
import pathlib
import sys
sys.path.insert(0, "${REPO_ROOT}/snap/local/build")
import generate_dashboard_data as dashboard

def ch(track, risk, arch, version, revision, released, size):
    return {
        "channel": {"track": track, "risk": risk, "architecture": arch, "released-at": released},
        "version": version,
        "revision": revision,
        "download": {"size": size, "url": f"https://example.test/{arch}.snap"},
    }

class FakeClient:
    def get_json_or_empty(self, url, headers=None, params=None):
        return {
            "channel-map": [
                # amd64 reaches stable; it carries the newest release date and so
                # defines the reference version used for staleness.
                ch("latest", "stable",    "amd64", "v6.5+git.newest.2", 400, "2026-06-11T00:00:00Z", 100),
                ch("latest", "candidate", "amd64", "v6.5+git.newest.2", 400, "2026-06-11T00:00:00Z", 100),
                ch("latest", "beta",      "amd64", "v6.5+git.newest.2", 400, "2026-06-11T00:00:00Z", 100),
                ch("latest", "edge",      "amd64", "v6.5+git.newest.2", 400, "2026-06-11T00:00:00Z", 100),
                # arm64 only reaches candidate, with an OLDER date and version, so
                # it must be flagged stale even though it is a GitHub arch.
                ch("latest", "candidate", "arm64", "v6.4+git.older.1", 390, "2026-06-01T00:00:00Z", 110),
                ch("latest", "beta",      "arm64", "v6.4+git.older.1", 390, "2026-06-01T00:00:00Z", 110),
                # A non-"latest" track entry must be ignored entirely.
                ch("8.x", "stable", "amd64", "v8.0", 999, "2026-06-12T00:00:00Z", 100),
            ]
        }

result = dashboard.collect_snap_package_data(FakeClient(), pathlib.Path("${TEST_TMPDIR}"))

# Channels are emitted in fixed risk order, skipping the empty "edge"-only arches.
published = {c["channel"]: c for c in result["published_channels"]}
order = [c["channel"] for c in result["published_channels"]]
assert order == ["stable", "candidate", "beta", "edge"], order

assert set(published["stable"]["architectures"]) == {"AMD64"}, published["stable"]
assert set(published["candidate"]["architectures"]) == {"AMD64", "ARM64"}, published["candidate"]
assert set(published["beta"]["architectures"]) == {"AMD64", "ARM64"}, published["beta"]
assert set(published["edge"]["architectures"]) == {"AMD64"}, published["edge"]

# Per-channel released_at is the NEWEST arch date in that channel, and the 8.x
# track entry is excluded (no future 2026-06-12 date leaks in).
assert published["candidate"]["released_at"] == "2026-06-11T00:00:00Z", published["candidate"]

# build_status: amd64 owns the newest date -> "current"; arm64 lags -> "stale".
by_arch = {c["architecture"]: c for c in result["channels"]}
assert by_arch["AMD64"]["build_status"] == "current", by_arch["AMD64"]
assert by_arch["ARM64"]["build_status"] == "stale", by_arch["ARM64"]
# Highest reachable risk per arch is recorded.
assert by_arch["AMD64"]["channel"] == "stable", by_arch["AMD64"]
assert by_arch["ARM64"]["channel"] == "candidate", by_arch["ARM64"]
PYEOF
}

@test "dashboard data: snapcraft-only mode generates payload and writes to output file" {
    python3 - <<PYEOF
import json
import pathlib
import sys
from unittest.mock import patch

sys.path.insert(0, "${REPO_ROOT}/snap/local/build")
import generate_dashboard_data as dashboard

# Setup mock data for snap package
mock_snap_package = {
    "last_updated": "2026-06-10T12:00:00Z",
    "channels": [
        {
            "architecture": "AMD64",
            "build_source": "github",
            "full_version": "v6.4.2",
            "revision": 123
        }
    ]
}

# Define output path
out_path = pathlib.Path("${TEST_TMPDIR}/snapcraft-dashboard-data.json")

# Mock sys.argv and collect_snap_package_data
test_argv = ["generate_dashboard_data.py", "--snapcraft-only", "${REPO_ROOT}", str(out_path)]

with patch("sys.argv", test_argv), \
     patch("generate_dashboard_data.collect_snap_package_data", return_value=mock_snap_package):
    dashboard.main()

# Verify output file exists and has correct structure
assert out_path.exists(), "Output file was not created"
with open(out_path, "r", encoding="utf-8") as f:
    data = json.load(f)

assert "generated_at" in data
assert data["data_last_updated"] == "2026-06-10T12:00:00Z"
assert data["snap_package"] == mock_snap_package
PYEOF
}
