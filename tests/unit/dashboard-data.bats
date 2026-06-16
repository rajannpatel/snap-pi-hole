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

@test "dashboard data: track-upstream status includes latest run duration" {
    python3 - <<PYEOF
import sys
sys.path.insert(0, "${REPO_ROOT}/snap/local/build")
import generate_dashboard_data as dashboard

class FakeClient:
    def get_json_or_empty(self, url, headers=None, params=None):
        assert url.endswith("/actions/workflows/track-upstream-releases.yml/runs"), url
        return {
            "workflow_runs": [
                {
                    "status": "completed",
                    "conclusion": "success",
                    "run_number": 12,
                    "run_started_at": "2026-06-14T02:14:33Z",
                    "updated_at": "2026-06-14T02:14:48Z",
                    "html_url": "https://example.test/run/12",
                }
            ]
        }

result = dashboard.collect_track_upstream_status(FakeClient())
latest = result["latest_success_run"]
assert latest["run_number"] == 12, latest
assert latest["duration_seconds"] == 15, latest
assert latest["duration_label"] == "15s", latest
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

@test "dashboard data: snap package build status is scoped to each channel" {
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
        if url == dashboard.SNAPCRAFT_INFO_URL:
            return {
                "channel-map": [
                    # Stable has a newer release than edge.
                    ch("latest", "stable", "amd64", "v6.4.2+git.newstable.1781499977", 410, "2026-06-15T05:14:44Z", 100),
                    ch("latest", "stable", "arm64", "v6.4.2+git.newstable.1781499977", 411, "2026-06-15T05:15:17Z", 110),
                    # Edge is older than stable, but internally current for GitHub arches.
                    ch("latest", "edge", "amd64", "v6.4.2+git.edgehead.1781062076", 390, "2026-06-10T17:00:00Z", 100),
                    ch("latest", "edge", "arm64", "v6.4.2+git.edgehead.1781062076", 391, "2026-06-10T17:00:00Z", 110),
                    # A genuinely older edge-only arch should still be marked stale.
                    ch("latest", "edge", "s390x", "v6.4.2+git.oldedge.1780975672", 137, "2026-06-09T14:47:52Z", 120),
                ]
            }
        return {}

result = dashboard.collect_snap_package_data(FakeClient(), pathlib.Path("${TEST_TMPDIR}"))
all_rows = {
    (row["channel"], row["architecture"]): row
    for row in result["all_channels"]
}

assert all_rows[("stable", "AMD64")]["build_status"] == "current", all_rows[("stable", "AMD64")]
assert all_rows[("stable", "ARM64")]["build_status"] == "current", all_rows[("stable", "ARM64")]

# Regression guard: edge rows must be compared to latest/edge, not latest/stable.
assert all_rows[("edge", "AMD64")]["build_status"] == "current", all_rows[("edge", "AMD64")]
assert all_rows[("edge", "ARM64")]["build_status"] == "current", all_rows[("edge", "ARM64")]
assert all_rows[("edge", "S390X")]["build_status"] == "stale", all_rows[("edge", "S390X")]
PYEOF
}

@test "dashboard data: snap package includes baked build and publish job links" {
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
        if url == dashboard.SNAPCRAFT_INFO_URL:
            return {
                "channel-map": [
                    ch("latest", "stable", "amd64", "v6.4.2", 1, "2026-06-10T17:00:00Z", 100),
                    ch("latest", "stable", "s390x", "v6.4.2", 2, "2026-06-10T17:00:00Z", 100),
                ]
            }
        if url.endswith("/actions/workflows/cicd.yml/runs"):
            return {"workflow_runs": [{
                "id": 101,
                "run_number": 55,
                "status": "completed",
                "conclusion": "success",
                "run_started_at": "2026-06-10T17:00:00Z",
                "updated_at": "2026-06-10T17:05:00Z",
                "html_url": "https://example.test/run/cicd",
            }]}
        if url.endswith("/actions/runs/101/jobs"):
            return {"jobs": [{
                "name": "publish github (stable, amd64)",
                "status": "completed",
                "conclusion": "success",
                "started_at": "2026-06-10T17:01:00Z",
                "completed_at": "2026-06-10T17:02:05Z",
                "html_url": "https://example.test/job/amd64",
            }]}
        if url.endswith("/actions/workflows/launchpad-builds.yml/runs"):
            return {"workflow_runs": [{
                "id": 202,
                "run_number": 9,
                "status": "completed",
                "conclusion": "success",
                "run_started_at": "2026-06-10T17:00:00Z",
                "updated_at": "2026-06-10T17:10:00Z",
                "html_url": "https://example.test/run/launchpad",
            }]}
        if url.endswith("/actions/runs/202/jobs"):
            return {"jobs": [{
                "name": "build and publish launchpad (stable, s390x)",
                "status": "completed",
                "conclusion": "success",
                "started_at": "2026-06-10T17:03:00Z",
                "completed_at": "2026-06-10T17:05:30Z",
                "html_url": "https://example.test/job/s390x",
            }]}
        return {}

result = dashboard.collect_snap_package_data(FakeClient(), pathlib.Path("${TEST_TMPDIR}"))
by_arch = {c["architecture"]: c for c in result["channels"]}

amd = by_arch["AMD64"]["workflow_runs"]["stable"]
assert amd["url"] == "https://example.test/job/amd64", amd
assert amd["duration_seconds"] == 65, amd
assert amd["duration_label"] == "1m 5s", amd
assert amd["job_name"] == "publish github (stable, amd64)", amd

s390x = by_arch["S390X"]["workflow_runs"]["stable"]
assert s390x["url"] == "https://example.test/job/s390x", s390x
assert s390x["duration_seconds"] == 150, s390x
assert s390x["duration_label"] == "2m 30s", s390x
assert s390x["job_name"] == "build and publish launchpad (stable, s390x)", s390x
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
            "channel": "stable",
            "build_source": "github",
            "full_version": "v6.4.2",
            "revision": 123
        }
    ],
    "all_channels": [
        {
            "architecture": "ARM64",
            "channel": "stable",
            "revision": 867
        },
        {
            "architecture": "ARM64",
            "channel": "edge",
            "revision": 869
        }
    ]
}

# Define output path
out_path = pathlib.Path("${TEST_TMPDIR}/snapcraft-dashboard-data.json")

# Mock sys.argv and collect_snap_package_data
test_argv = ["generate_dashboard_data.py", "--snapcraft-only", "${REPO_ROOT}", str(out_path)]

mock_channel_switch = {
    "status": "success",
    "updated_at": "2026-06-10T12:05:00Z",
    "path": "roundtrip",
    "stable_revision": "",
    "edge_revision": "",
    "rows": [{"arch": "arm64", "status": "success", "summary": "stable -> edge -> stable"}],
}

with patch("sys.argv", test_argv), \
     patch("generate_dashboard_data.collect_snap_package_data", return_value=mock_snap_package), \
     patch("generate_dashboard_data.collect_channel_switch_status", return_value=mock_channel_switch):
    dashboard.main()

# Verify output file exists and has correct structure
assert out_path.exists(), "Output file was not created"
with open(out_path, "r", encoding="utf-8") as f:
    data = json.load(f)

assert "generated_at" in data
assert data["data_last_updated"] == "2026-06-10T12:05:00Z"
assert data["snap_package"] == mock_snap_package
assert data["channel_switch"]["stable_revision"] == "867", data["channel_switch"]
assert data["channel_switch"]["edge_revision"] == "869", data["channel_switch"]
assert data["channel_switch"]["summary"] == "stable r867 -> edge r869 -> stable r867", data["channel_switch"]
PYEOF
}

@test "dashboard data: channel switch tests" {
    python3 - <<PYEOF
import sys
import io
import zipfile
import json
import pathlib
sys.path.insert(0, "${REPO_ROOT}/snap/local/build")
import generate_dashboard_data as dashboard

class FakeClient:
    def __init__(self, runs=None, jobs=None, artifacts=None):
        self.runs = runs or {}
        self.jobs = jobs or {}
        self.artifacts = artifacts or {}

    def get_json_or_empty(self, url, headers=None, params=None):
        if url.endswith("/actions/workflows/channel-switch.yml/runs"):
            return self.runs
        if "/actions/runs/" in url and url.endswith("/jobs"):
            parts = url.split("/")
            run_id = int(parts[parts.index("runs") + 1])
            return self.jobs.get(run_id, {"jobs": []})
        if "/actions/runs/" in url and url.endswith("/artifacts"):
            parts = url.split("/")
            run_id = int(parts[parts.index("runs") + 1])
            return self.artifacts.get(run_id, {"artifacts": []})
        raise AssertionError(f"Unexpected url: {url}")

    def get_json(self, url, headers=None, params=None):
        return self.get_json_or_empty(url, headers, params)

# Test 1: no runs returns no_data
client = FakeClient(runs={"workflow_runs": []})
res = dashboard.collect_channel_switch_status(client)
assert res["status"] == "no_data", res

# Test 2: success from artifact
fixture_path = pathlib.Path("${REPO_ROOT}/tests/fixtures/channel-switch-result-roundtrip.json")
artifact_data = json.loads(fixture_path.read_text(encoding="utf-8"))
assert dashboard.validate_channel_switch_artifact(artifact_data)["status"] == "success"

zip_buffer = io.BytesIO()
with zipfile.ZipFile(zip_buffer, "a", zipfile.ZIP_DEFLATED, False) as zip_file:
    zip_file.writestr("result.json", json.dumps(artifact_data))
zip_content = zip_buffer.getvalue()

from unittest.mock import patch, MagicMock

mock_response = MagicMock()
mock_response.__enter__.return_value = mock_response
mock_response.read.return_value = zip_content

with patch("urllib.request.urlopen", return_value=mock_response):
    client = FakeClient(
        runs={"workflow_runs": [{"id": 11, "run_number": 45, "updated_at": "2026-06-15T12:00:00Z"}]},
        jobs={11: {"jobs": [{"name": "Channel Switch Smoke (arm64)", "status": "completed", "conclusion": "success"}]}},
        artifacts={11: {"artifacts": [{"name": "channel-switch-result-arm64", "archive_download_url": "http://download"}]}}
    )
    res = dashboard.collect_channel_switch_status(client)
    assert res["status"] == "success", res
    assert res["summary"] == "stable r840 -> edge r838 -> stable r840", res["summary"]
    assert res["rows"][0]["updated_at"] == "2026-06-16T02:25:17Z", res["rows"][0]
    assert res["stable_revision"] == "840", res
    assert res["edge_revision"] == "838", res
    evidence = res["rows"][0]["evidence"]
    assert any(item["command"] == "sudo snap refresh pihole-by-rajannpatel --channel=latest/edge" for item in evidence), evidence
    assert any("snap list pihole-by-rajannpatel" in item["command"] for item in evidence), evidence
    assert any("0.0.0.0" in item["output"] for item in evidence), evidence

# Test 3: arm64 failure is reported
artifact_data_arm64 = artifact_data.copy()
artifact_data_arm64["status"] = "failure"
artifact_data_arm64["conclusion"] = "failure"
artifact_data_arm64["reason"] = "ftl-not-active"
artifact_data_arm64["arch"] = "arm64"
    
zip_buffer_arm64 = io.BytesIO()
with zipfile.ZipFile(zip_buffer_arm64, "a", zipfile.ZIP_DEFLATED, False) as zip_file:
    zip_file.writestr("result.json", json.dumps(artifact_data_arm64))

mock_response_arm64_failure = MagicMock()
mock_response_arm64_failure.__enter__.return_value = mock_response_arm64_failure
mock_response_arm64_failure.read.return_value = zip_buffer_arm64.getvalue()

with patch("urllib.request.urlopen", return_value=mock_response_arm64_failure):
    client = FakeClient(
        runs={"workflow_runs": [{"id": 12, "run_number": 46, "updated_at": "2026-06-15T12:00:00Z"}]},
        jobs={12: {"jobs": [{"name": "Channel Switch Smoke (arm64)", "status": "completed", "conclusion": "failure"}]}},
        artifacts={12: {"artifacts": [{"name": "channel-switch-result-arm64", "archive_download_url": "http://download/arm64"}]}}
    )
    res = dashboard.collect_channel_switch_status(client)
    assert res["status"] == "failure", res
    assert "failed on arm64" in res["summary"], res["summary"]

# Test 4: skipped returns skipped
import copy
artifact_data_skipped = copy.deepcopy(artifact_data)
artifact_data_skipped["status"] = "skipped"
artifact_data_skipped["conclusion"] = "skipped"
artifact_data_skipped["reason"] = "stable-and-edge-same-revision"
artifact_data_skipped["channels"]["edge"]["revision"] = "840"

zip_buffer_skipped = io.BytesIO()
with zipfile.ZipFile(zip_buffer_skipped, "a", zipfile.ZIP_DEFLATED, False) as zip_file:
    zip_file.writestr("result.json", json.dumps(artifact_data_skipped))

mock_response_skipped = MagicMock()
mock_response_skipped.__enter__.return_value = mock_response_skipped
mock_response_skipped.read.return_value = zip_buffer_skipped.getvalue()

with patch("urllib.request.urlopen", return_value=mock_response_skipped):
    client = FakeClient(
        runs={"workflow_runs": [{"id": 13, "run_number": 47, "updated_at": "2026-06-15T12:00:00Z"}]},
        jobs={13: {"jobs": [{"name": "Channel Switch Smoke (arm64)", "status": "completed", "conclusion": "success"}]}},
        artifacts={13: {"artifacts": [{"name": "channel-switch-result-arm64", "archive_download_url": "http://download"}]}}
    )
    res = dashboard.collect_channel_switch_status(client)
    assert res["status"] == "skipped", res
    assert "both serve r840" in res["summary"], res["summary"]

# Test 5: running run beats older completed run
client = FakeClient(
    runs={"workflow_runs": [
        {"id": 15, "run_number": 49, "status": "in_progress", "updated_at": "2026-06-15T13:00:00Z"},
        {"id": 14, "run_number": 48, "status": "completed", "conclusion": "success", "updated_at": "2026-06-15T12:00:00Z"}
    ]},
    jobs={15: {"jobs": [{"name": "Channel Switch Smoke (arm64)", "status": "in_progress", "conclusion": None}]}},
    artifacts={15: {"artifacts": []}}
)
res = dashboard.collect_channel_switch_status(client)
assert res["status"] == "in_progress", res
assert res["rows"][0]["updated_at"] == "2026-06-15T13:00:00Z", res["rows"][0]

# Test 6: newest completed run without an artifact does not hide latest artifact result
mock_response_latest_artifact = MagicMock()
mock_response_latest_artifact.__enter__.return_value = mock_response_latest_artifact
mock_response_latest_artifact.read.return_value = zip_content

with patch("urllib.request.urlopen", return_value=mock_response_latest_artifact):
    client = FakeClient(
        runs={"workflow_runs": [
            {"id": 18, "run_number": 52, "status": "completed", "conclusion": "failure", "updated_at": "2026-06-15T14:00:00Z"},
            {"id": 17, "run_number": 51, "status": "completed", "conclusion": "success", "updated_at": "2026-06-15T13:30:00Z"}
        ]},
        jobs={
            18: {"jobs": [{"name": "Channel Switch Smoke (arm64)", "status": "completed", "conclusion": "failure"}]},
            17: {"jobs": [{"name": "Channel Switch Smoke (arm64)", "status": "completed", "conclusion": "success"}]},
        },
        artifacts={
            18: {"artifacts": []},
            17: {"artifacts": [{"name": "channel-switch-result-arm64", "archive_download_url": "http://download/latest-success"}]},
        }
    )
    res = dashboard.collect_channel_switch_status(client)
    assert res["status"] == "success", res
    assert res["run_number"] == 51, res

# Test 7: corrupt artifact is ignored
mock_response_corrupt = MagicMock()
mock_response_corrupt.__enter__.return_value = mock_response_corrupt
mock_response_corrupt.read.return_value = b"corrupt zip data"

with patch("urllib.request.urlopen", return_value=mock_response_corrupt):
    client = FakeClient(
        runs={"workflow_runs": [{"id": 16, "run_number": 50, "updated_at": "2026-06-15T12:00:00Z"}]},
        jobs={16: {"jobs": [{"name": "Channel Switch Smoke (arm64)", "status": "completed", "conclusion": "success"}]}},
        artifacts={16: {"artifacts": [{"name": "channel-switch-result-arm64", "archive_download_url": "http://download"}]}}
    )
    res = dashboard.collect_channel_switch_status(client)
    assert res["status"] == "success", res
    assert res["rows"][0]["reason"] == "", res["rows"][0]

# Test 8: semantically invalid artifact is ignored
invalid_artifact = copy.deepcopy(artifact_data)
invalid_artifact["path"] = "bad-path"
try:
    dashboard.validate_channel_switch_artifact(invalid_artifact)
    raise AssertionError("invalid path should fail schema validation")
except ValueError as exc:
    assert "path" in str(exc), str(exc)

zip_buffer_invalid = io.BytesIO()
with zipfile.ZipFile(zip_buffer_invalid, "a", zipfile.ZIP_DEFLATED, False) as zip_file:
    zip_file.writestr("result.json", json.dumps(invalid_artifact))

mock_response_invalid = MagicMock()
mock_response_invalid.__enter__.return_value = mock_response_invalid
mock_response_invalid.read.return_value = zip_buffer_invalid.getvalue()

with patch("urllib.request.urlopen", return_value=mock_response_invalid):
    client = FakeClient(
        runs={"workflow_runs": [{"id": 19, "run_number": 53, "updated_at": "2026-06-15T12:00:00Z"}]},
        jobs={19: {"jobs": [{"name": "Channel Switch Smoke (arm64)", "status": "completed", "conclusion": "success"}]}},
        artifacts={19: {"artifacts": [{"name": "channel-switch-result-arm64", "archive_download_url": "http://download/invalid"}]}}
    )
    res = dashboard.collect_channel_switch_status(client)
    assert res["status"] == "success", res
    assert res["stable_revision"] == "", res
    assert res["edge_revision"] == "", res

# Test 9: duration label is humanized
assert dashboard.human_duration(90) == "1m 30s"
assert dashboard.human_duration(3600) == "1h 0m"

# Test 10: missing channel fields are derived from runner artifact transitions
artifact_without_channels = {
    "transitions": [
        {"from": "latest/stable", "to": "latest/edge", "from_revision": "840", "to_revision": "838"}
    ]
}
stable_rev, edge_rev = dashboard.channel_switch_revisions_from_artifact(artifact_without_channels)
assert stable_rev == "840", stable_rev
assert edge_rev == "838", edge_rev

# Test 11: missing channel switch revisions are filled from ARM64 snap package channel data
filled = dashboard.fill_channel_switch_revisions(
    {
        "status": "success",
        "conclusion": "success",
        "path": "roundtrip",
        "stable_revision": "",
        "edge_revision": "",
        "rows": [{"arch": "arm64", "status": "success", "summary": "stable -> edge -> stable"}],
    },
    {
        "all_channels": [
            {"architecture": "ARM64", "channel": "stable", "revision": 867},
            {"architecture": "ARM64", "channel": "edge", "revision": 869},
        ]
    },
)
assert filled["stable_revision"] == "867", filled
assert filled["edge_revision"] == "869", filled
assert filled["summary"] == "stable r867 -> edge r869 -> stable r867", filled

# Test 12: local channel switch artifacts can be consumed without the GitHub artifact ZIP API
local_dir = pathlib.Path("${TEST_TMPDIR}/channel-switch-artifacts/channel-switch-result-arm64")
local_dir.mkdir(parents=True)
local_artifact = json.loads(fixture_path.read_text(encoding="utf-8"))
(local_dir / "channel-switch-result-arm64.json").write_text(json.dumps(local_artifact), encoding="utf-8")

import os
old_dir = os.environ.get("CHANNEL_SWITCH_RESULT_DIR")
old_run = os.environ.get("CHANNEL_SWITCH_RESULT_RUN_ID")
os.environ["CHANNEL_SWITCH_RESULT_DIR"] = str(local_dir.parent)
os.environ["CHANNEL_SWITCH_RESULT_RUN_ID"] = "123"
try:
    local_results = dashboard.collect_local_channel_switch_artifacts(123)
    assert len(local_results) == 1, local_results
    assert local_results[0]["arch"] == "arm64", local_results
    assert dashboard.collect_local_channel_switch_artifacts(456) == []
finally:
    if old_dir is None:
        os.environ.pop("CHANNEL_SWITCH_RESULT_DIR", None)
    else:
        os.environ["CHANNEL_SWITCH_RESULT_DIR"] = old_dir
    if old_run is None:
        os.environ.pop("CHANNEL_SWITCH_RESULT_RUN_ID", None)
    else:
        os.environ["CHANNEL_SWITCH_RESULT_RUN_ID"] = old_run
PYEOF
}
