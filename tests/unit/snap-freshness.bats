#!/usr/bin/env bats

setup() {
    REPO_ROOT="$(git rev-parse --show-toplevel)"
}

@test "snap freshness reports current when expected commit is the published stable" {
    python3 - <<PYEOF
import sys
sys.path.insert(0, "${REPO_ROOT}/snap/local/build")
from generate_dashboard_data import compute_snap_freshness

channels = [{"git_commit": "5e4037d"}]
revisions = [{"version": "v6.4.2+git.5e4037d.1700000000"}]
result = compute_snap_freshness(channels, revisions, "5e4037d", "success")
assert result["freshness"] == "current", result
assert result["expected_commit"] == "5e4037d", result
assert result["publish_result"] == "success", result
assert result["expected_commit_published"] is True, result
assert result["expected_commit_in_store"] is True, result
PYEOF
}

@test "snap freshness reports uploaded_not_selected when in store but not selected" {
    python3 - <<PYEOF
import sys
sys.path.insert(0, "${REPO_ROOT}/snap/local/build")
from generate_dashboard_data import compute_snap_freshness

channels = [{"git_commit": "47cb700"}]
revisions = [{"version": "v6.4.2+git.5e4037d.1700000000"}]
result = compute_snap_freshness(channels, revisions, "5e4037d", "success")
assert result["freshness"] == "uploaded_not_selected", result
assert result["expected_commit_published"] is False, result
assert result["expected_commit_in_store"] is True, result
PYEOF
}

@test "snap freshness reports pending when publish succeeded but commit is absent" {
    python3 - <<PYEOF
import sys
sys.path.insert(0, "${REPO_ROOT}/snap/local/build")
from generate_dashboard_data import compute_snap_freshness

channels = [{"git_commit": "47cb700"}]
revisions = [{"version": "v6.4.2+git.47cb700.1600000000"}]
result = compute_snap_freshness(channels, revisions, "5e4037d", "success")
assert result["freshness"] == "pending", result
assert result["expected_commit_in_store"] is False, result
PYEOF
}

@test "snap freshness reports publish_failed when the publish job failed and commit is absent" {
    python3 - <<PYEOF
import sys
sys.path.insert(0, "${REPO_ROOT}/snap/local/build")
from generate_dashboard_data import compute_snap_freshness

channels = [{"git_commit": "47cb700"}]
revisions = [{"version": "v6.4.2+git.47cb700.1600000000"}]
for outcome in ("failure", "cancelled"):
    result = compute_snap_freshness(channels, revisions, "5e4037d", outcome)
    assert result["freshness"] == "publish_failed", result
PYEOF
}

@test "snap freshness reports unknown when skipped or no expected commit" {
    python3 - <<PYEOF
import sys
sys.path.insert(0, "${REPO_ROOT}/snap/local/build")
from generate_dashboard_data import compute_snap_freshness

channels = [{"git_commit": "47cb700"}]
revisions = [{"version": "v6.4.2+git.47cb700.1600000000"}]
assert compute_snap_freshness(channels, revisions, "5e4037d", "skipped")["freshness"] == "unknown"
assert compute_snap_freshness(channels, revisions, "5e4037d", "")["freshness"] == "unknown"
assert compute_snap_freshness(channels, revisions, "", "success")["freshness"] == "unknown"
PYEOF
}

@test "snap freshness tolerates differing abbreviated commit lengths" {
    python3 - <<PYEOF
import sys
sys.path.insert(0, "${REPO_ROOT}/snap/local/build")
from generate_dashboard_data import compute_snap_freshness

channels = [{"git_commit": "5e4037d"}]
result = compute_snap_freshness(channels, [], "5e4037de9a", "success")
assert result["freshness"] == "current", result
PYEOF
}
