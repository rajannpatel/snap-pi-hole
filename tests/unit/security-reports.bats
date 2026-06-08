#!/usr/bin/env bats

setup() {
    REPO_ROOT="$(git rev-parse --show-toplevel)"
    TEST_TMPDIR="$(mktemp -d)"
    REPORT_DIR="${TEST_TMPDIR}/vulnerability-reports"
    mkdir -p "$REPORT_DIR"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

write_osv_report() {
    local path="$1"
    cat > "$path" <<'EOF'
{
  "results": [
    {
      "packages": [
        {
          "package": {
            "name": "curl",
            "version": "7.88.1-10+deb12u1",
            "ecosystem": "Ubuntu"
          },
          "vulnerabilities": [
            {
              "id": "CVE-2023-38545",
              "aliases": ["USN-6425-1"],
              "summary": "USN-backed curl vulnerability",
              "published": "2023-10-11T12:00:00Z"
            },
            {
              "id": "CVE-2023-99999",
              "aliases": [],
              "summary": "Non-USN OSV finding",
              "published": "2023-12-01T12:00:00Z"
            }
          ]
        }
      ]
    }
  ]
}
EOF
}

@test "OSV summary separates unique actionable USN counts from raw architecture matches" {
    write_osv_report "${REPORT_DIR}/osv-amd64.json"
    write_osv_report "${REPORT_DIR}/osv-arm64.json"

    python3 "${REPO_ROOT}/snap/local/build/summarize_osv_reports.py" "$REPORT_DIR"

    run jq -e '
      .totalVulnerabilities == 2 and
      .affectedPackages == 1 and
      .actionableVulnerabilities == 1 and
      .actionableAffectedPackages == 1 and
      .confinedMitigationVulnerabilities == 1 and
      ([.reports[].vulnerabilities] == [2, 2]) and
      ([.reports[].actionableVulnerabilities] == [1, 1]) and
      ([.reports[].confinedMitigationVulnerabilities] == [1, 1])
    ' "${REPORT_DIR}/osv-summary.json"
    [ "$status" -eq 0 ]
}

@test "dashboard security summary uses actionable USN counts, not raw OSV matches" {
    write_osv_report "${REPORT_DIR}/osv-amd64.json"
    write_osv_report "${REPORT_DIR}/osv-arm64.json"
    python3 "${REPO_ROOT}/snap/local/build/summarize_osv_reports.py" "$REPORT_DIR"

    python3 - <<PYEOF
import pathlib
import sys
sys.path.insert(0, "${REPO_ROOT}/snap/local/build")
from generate_dashboard_data import collect_security_summary

security = collect_security_summary(pathlib.Path("${REPORT_DIR}/osv-summary.json"))
assert security["total_vulnerabilities"] == 1, security
assert security["affected_packages"] == 1, security
assert security["raw_vulnerability_matches"] == 2, security
assert security["raw_affected_packages"] == 1, security
assert security["confined_mitigation_vulnerabilities"] == 1, security
assert security["gate_policy"] == "report_only", security
for row in security["architectures"]:
    assert row["vulnerabilities"] == 1, row
    assert row["affected_packages"] == 1, row
    assert row["raw_vulnerability_matches"] == 2, row
PYEOF
}

@test "dashboard security summary is zero when OSV findings have no USN" {
    cat > "${REPORT_DIR}/osv-amd64.json" <<'EOF'
{
  "results": [
    {
      "packages": [
        {
          "package": {"name": "curl", "version": "7.88.1", "ecosystem": "Ubuntu"},
          "vulnerabilities": [
            {"id": "CVE-2023-99999", "aliases": [], "summary": "No USN"}
          ]
        }
      ]
    }
  ]
}
EOF
    python3 "${REPO_ROOT}/snap/local/build/summarize_osv_reports.py" "$REPORT_DIR"

    python3 - <<PYEOF
import pathlib
import sys
sys.path.insert(0, "${REPO_ROOT}/snap/local/build")
from generate_dashboard_data import collect_security_summary

security = collect_security_summary(pathlib.Path("${REPORT_DIR}/osv-summary.json"))
assert security["total_vulnerabilities"] == 0, security
assert security["affected_packages"] == 0, security
assert security["raw_vulnerability_matches"] == 1, security
assert security["raw_affected_packages"] == 1, security
assert security["confined_mitigation_vulnerabilities"] == 1, security
PYEOF
}

@test "OSV summary detects USNs from related IDs and reference URLs" {
    cat > "${REPORT_DIR}/osv-amd64.json" <<'EOF'
{
  "results": [
    {
      "packages": [
        {
          "package": {"name": "openssl", "version": "3.0.13", "ecosystem": "Ubuntu"},
          "vulnerabilities": [
            {
              "id": "CVE-2026-0001",
              "related": ["USN-7001-1"],
              "aliases": [],
              "summary": "Related USN marks this actionable"
            },
            {
              "id": "CVE-2026-0002",
              "aliases": [],
              "references": [
                {"url": "https://ubuntu.com/security/notices/USN-7002-1"}
              ],
              "summary": "Reference URL marks this actionable"
            },
            {
              "id": "CVE-2026-0003",
              "aliases": [],
              "related": [],
              "references": [{"url": "https://example.test/advisory"}],
              "summary": "No USN stays report-only"
            }
          ]
        }
      ]
    }
  ]
}
EOF

    python3 "${REPO_ROOT}/snap/local/build/summarize_osv_reports.py" "$REPORT_DIR"

    python3 - <<PYEOF
import json
from pathlib import Path

summary = json.loads(Path("${REPORT_DIR}/osv-summary.json").read_text())
report = summary["reports"][0]
patchable = {
    vulnerability["id"]: vulnerability["patchable"]
    for package in report["packages"]
    for vulnerability in package["vulnerabilities"]
}

assert patchable == {
    "CVE-2026-0001": True,
    "CVE-2026-0002": True,
    "CVE-2026-0003": False,
}, patchable
assert report["actionableVulnerabilities"] == 2, report
assert report["confinedMitigationVulnerabilities"] == 1, report
assert summary["actionableVulnerabilities"] == 2, summary
assert summary["confinedMitigationVulnerabilities"] == 1, summary
PYEOF
}

@test "OSV summary emits empty reports and generated artifacts for empty directory" {
    python3 "${REPO_ROOT}/snap/local/build/summarize_osv_reports.py" "$REPORT_DIR"

    run jq -e '
      .reports == [] and
      .totalVulnerabilities == 0 and
      .affectedPackages == 0 and
      .actionableVulnerabilities == 0 and
      .confinedMitigationVulnerabilities == 0
    ' "${REPORT_DIR}/osv-summary.json"
    [ "$status" -eq 0 ]

    [ -s "${REPORT_DIR}/vuln-summary.md" ]
    [ -s "${REPORT_DIR}/index.html" ]
}
