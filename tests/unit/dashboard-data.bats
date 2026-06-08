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

@test "dashboard data: distro matrix records failed job links and no-data rows" {
    python3 - <<PYEOF
import sys
sys.path.insert(0, "${REPO_ROOT}/snap/local/build")
import generate_dashboard_data as dashboard

class FakeClient:
    def get_json_or_empty(self, url, headers=None, params=None):
        if url.endswith("/actions/workflows/test-failing.yml/runs"):
            return {
                "workflow_runs": [
                    {
                        "id": 123,
                        "status": "completed",
                        "conclusion": "failure",
                        "run_number": 42,
                        "run_started_at": "2026-06-08T10:00:00Z",
                        "updated_at": "2026-06-08T10:03:05Z",
                        "html_url": "https://example.test/run/123",
                    }
                ]
            }
        if url.endswith("/actions/runs/123/jobs"):
            return {
                "jobs": [
                    {"name": "setup", "conclusion": "success", "html_url": ""},
                    {
                        "name": "distro test (failing)",
                        "conclusion": "timed_out",
                        "html_url": "https://example.test/job/456",
                    },
                ]
            }
        if url.endswith("/actions/workflows/test-missing.yml/runs"):
            return {"workflow_runs": []}
        raise AssertionError(f"unexpected URL: {url}")

original = dashboard.DISTRO_WORKFLOWS
try:
    dashboard.DISTRO_WORKFLOWS = [
        {"id": "failing", "label": "Failing OS", "workflow": "test-failing.yml", "family": "Test"},
        {"id": "missing", "label": "Missing OS", "workflow": "test-missing.yml", "family": "Test"},
    ]
    matrix = dashboard.collect_distro_matrix(FakeClient())
finally:
    dashboard.DISTRO_WORKFLOWS = original

rows = {row["id"]: row for row in matrix["rows"]}
assert rows["failing"]["status"] == "failure", rows["failing"]
assert rows["failing"]["duration_seconds"] == 185, rows["failing"]
assert rows["failing"]["duration_label"] == "3m 5s", rows["failing"]
assert rows["failing"]["failed_job_url"] == "https://example.test/job/456", rows["failing"]
assert rows["missing"]["status"] == "no_data", rows["missing"]
assert rows["missing"]["conclusion"] == "no_data", rows["missing"]
assert rows["missing"]["duration_label"] == "Unknown", rows["missing"]
assert matrix["failed_links"] == [
    {
        "distro": "Failing OS",
        "workflow": "test-failing.yml",
        "run_number": 42,
        "job_name": "distro test (failing)",
        "url": "https://example.test/job/456",
    }
], matrix["failed_links"]
assert matrix["last_updated"].isoformat() == "2026-06-08T10:03:05+00:00", matrix["last_updated"]
PYEOF
}
