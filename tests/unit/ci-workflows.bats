#!/usr/bin/env bats
#
# Unit tests for the CI/CD workflow logic that cannot be run in GitHub Actions
# without a real API call. Tests cover:
#
#   - track-upstream-releases.yml: snapcraft.yaml-only upstream tag bumps
#   - cicd.yml: port-53 timeout guard logic (both success and failure paths)
#   - cicd.yml: Snap Store channel mapping logic based on Pi-hole tags
#
# Run locally:  bats tests/unit/ci-workflows.bats
# In CI:        see .github/workflows/cicd.yml (lint+unit job)

setup() {
    REPO_ROOT="$(git rev-parse --show-toplevel)"
    TEST_WORKDIR="$(mktemp -d "${REPO_ROOT}/.tmp-ci-workflows.XXXXXX")"
    cp "${REPO_ROOT}/snap/snapcraft.yaml" "${TEST_WORKDIR}/snapcraft.yaml"
}

teardown() {
    rm -rf "${TEST_WORKDIR}"
}

# ---------------------------------------------------------------------------
# track-upstream-releases.yml
# ---------------------------------------------------------------------------

@test "track-upstream workflow updates only snapcraft source-tag fields" {
    local workflow="${REPO_ROOT}/.github/workflows/track-upstream-releases.yml"
    grep -q 'yq -i ".parts.ftl.source-tag' "$workflow"
    grep -q 'yq -i ".parts.pi_hole.source-tag' "$workflow"
    grep -q 'yq -i ".parts.web.source-tag' "$workflow"
    ! grep -q "README.md" "$workflow"
    ! grep -q "sed -i" "$workflow"
}

@test "track-upstream workflow does not use opaque inline scripts for README mutation" {
    local workflow="${REPO_ROOT}/.github/workflows/track-upstream-releases.yml"
    ! grep -q "python3 -c" "$workflow"
    ! grep -q "re.sub" "$workflow"
}

@test "track-upstream yq source-tag updates mutate the expected snapcraft parts" {
    if ! command -v yq >/dev/null 2>&1; then
        skip "yq is not installed"
    fi

    local target="${TEST_WORKDIR}/snapcraft.yaml"
    yq -i '.parts.ftl.source-tag = "v9.1.0"' "$target"
    yq -i '.parts.pi_hole.source-tag = "v9.2.0"' "$target"
    yq -i '.parts.web.source-tag = "v9.3.0"' "$target"

    run yq -r '[.parts.ftl.source-tag, .parts.pi_hole.source-tag, .parts.web.source-tag] | @tsv' "$target"
    [ "$status" -eq 0 ]
    [ "$output" = $'v9.1.0\tv9.2.0\tv9.3.0' ]
}

# ---------------------------------------------------------------------------
# Port-53 timeout guard logic (from cicd.yml smoke test)
# ---------------------------------------------------------------------------

_run_port53_guard() {
    local port_open="$1"   # 'yes' | 'no'
    bash <<BASH
bound=0
for i in \$(seq 1 3); do
    if [ "${port_open}" = "yes" ]; then
        bound=1; break
    fi
    sleep 0
done
if [ "\$bound" -eq 0 ]; then
    echo "::error::FTL failed to bind port 53 within 30 seconds" >&2
    exit 1
fi
echo "FTL bound to port 53"
BASH
}

@test "port-53 guard succeeds when port binds immediately" {
    run _run_port53_guard "yes"
    [ "$status" -eq 0 ]
    [[ "$output" == *"FTL bound"* ]]
}

@test "port-53 guard fails with error message when port never binds" {
    run _run_port53_guard "no"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FTL failed to bind"* ]]
}

@test "port-53 guard error message includes GitHub Actions annotation syntax" {
    run _run_port53_guard "no"
    [[ "$output" == *"::error::"* ]]
}

# ---------------------------------------------------------------------------
# Channel mapping logic (from cicd.yml)
# ---------------------------------------------------------------------------

_run_channel_mapping() {
    local SNAP_VERSION="$1"
    local ENABLE_TRACKS="$2"
    bash <<BASH
    SNAP_VERSION="${SNAP_VERSION}"
    ENABLE_TRACKS="${ENABLE_TRACKS}"
    MAJOR_VERSION=\$(echo "\${SNAP_VERSION#v}" | cut -d'.' -f1)
    
    if [[ "\$SNAP_VERSION" == *"-alpha"* ]] || [[ "\$SNAP_VERSION" =~ -g[0-9a-f]+ ]]; then
      CHANNELS="latest/edge"
      [[ "\$ENABLE_TRACKS" == "true" ]] && CHANNELS="\${CHANNELS},\${MAJOR_VERSION}/edge"
    elif [[ "\$SNAP_VERSION" == *"-beta"* ]]; then
      CHANNELS="latest/beta,latest/edge"
      [[ "\$ENABLE_TRACKS" == "true" ]] && CHANNELS="\${CHANNELS},\${MAJOR_VERSION}/beta,\${MAJOR_VERSION}/edge"
    elif [[ "\$SNAP_VERSION" == *"-rc"* ]]; then
      CHANNELS="latest/candidate,latest/beta,latest/edge"
      [[ "\$ENABLE_TRACKS" == "true" ]] && CHANNELS="\${CHANNELS},\${MAJOR_VERSION}/candidate,\${MAJOR_VERSION}/beta,\${MAJOR_VERSION}/edge"
    else
      CHANNELS="latest/stable,latest/candidate,latest/beta,latest/edge"
      [[ "\$ENABLE_TRACKS" == "true" ]] && CHANNELS="\${CHANNELS},\${MAJOR_VERSION}/stable,\${MAJOR_VERSION}/candidate,\${MAJOR_VERSION}/beta,\${MAJOR_VERSION}/edge"
    fi
    echo "\$CHANNELS"
BASH
}

@test "publish mapping clean tag goes to all channels" {
    run _run_channel_mapping "v6.4.2" "false"
    [ "$status" -eq 0 ]
    [ "$output" = "latest/stable,latest/candidate,latest/beta,latest/edge" ]
}

@test "publish mapping clean tag with -dirty goes to all channels" {
    run _run_channel_mapping "v6.4.2-dirty" "false"
    [ "$status" -eq 0 ]
    [ "$output" = "latest/stable,latest/candidate,latest/beta,latest/edge" ]
}

@test "publish mapping -beta goes to beta and edge" {
    run _run_channel_mapping "v6.4.2-beta.1" "false"
    [ "$status" -eq 0 ]
    [ "$output" = "latest/beta,latest/edge" ]
}

@test "publish mapping -rc goes to candidate, beta, and edge" {
    run _run_channel_mapping "v6.4.2-rc.1" "false"
    [ "$status" -eq 0 ]
    [ "$output" = "latest/candidate,latest/beta,latest/edge" ]
}

@test "publish mapping -alpha goes to edge" {
    run _run_channel_mapping "v7.0.0-alpha.1" "false"
    [ "$status" -eq 0 ]
    [ "$output" = "latest/edge" ]
}

@test "publish mapping post-tag commit (-gXXX) goes to edge" {
    run _run_channel_mapping "v6.4.2-12-g12345" "false"
    [ "$status" -eq 0 ]
    [ "$output" = "latest/edge" ]
}

@test "publish mapping tracks enabled mirrors channels to major version" {
    run _run_channel_mapping "v6.4.2" "true"
    [ "$status" -eq 0 ]
    [ "$output" = "latest/stable,latest/candidate,latest/beta,latest/edge,6/stable,6/candidate,6/beta,6/edge" ]
}

@test "cicd workflow scans SBOM artifacts with OSV-Scanner" {
    local workflow="${REPO_ROOT}/.github/workflows/cicd.yml"
    grep -q "vulnerability-scan:" "$workflow"
    grep -q "github.com/google/osv-scanner/v2/cmd/osv-scanner@v2.3.8" "$workflow"
    grep -q "osv-scanner scan --format json -L" "$workflow"
}

@test "cicd vulnerability-scan job validates LLM API key before scanning" {
    python3 - <<PYEOF
import yaml
with open("${REPO_ROOT}/.github/workflows/cicd.yml") as f:
    doc = yaml.safe_load(f)
steps = doc["jobs"]["vulnerability-scan"]["steps"]
names = [s.get("name", "") for s in steps]
validate_idx = next((i for i, n in enumerate(names) if "Validate LLM API key" in n), None)
scan_idx     = next((i for i, n in enumerate(names) if "Scan SBOMs with OSV-Scanner" in n), None)
assert validate_idx is not None, f"'Validate LLM API key' step not found: {names}"
assert scan_idx is not None, f"'Scan SBOMs with OSV-Scanner' step not found: {names}"
assert validate_idx < scan_idx, f"Validate step ({validate_idx}) must come before Scan step ({scan_idx})"
validate_step = steps[validate_idx]
assert validate_step.get("env", {}).get("LLM_API_KEY") is not None, validate_step
assert "validate_gemini_key.py" in validate_step.get("run", ""), validate_step
PYEOF
}

@test "cicd vulnerability scan treats known vulnerabilities as warnings and scanner errors as failures" {
    local workflow="${REPO_ROOT}/.github/workflows/cicd.yml"
    grep -q '1)' "$workflow"
    grep -q "Known vulnerabilities found" "$workflow"
    grep -q "scanner_error=1" "$workflow"
    grep -q 'if \[ "$scanner_error" -ne 0 \]' "$workflow"
}

@test "cicd workflow publishes vulnerability reports to Pages" {
    local workflow="${REPO_ROOT}/.github/workflows/cicd.yml"
    grep -q "name: vulnerability-reports" "$workflow"
    grep -q "docs/vulnerabilities" "$workflow"
    grep -q "cp -r vulnerability-reports/\\* docs/vulnerabilities/" "$workflow"
}

@test "cicd deploy-pages waits for smoke tests" {
    python3 - <<PYEOF
import yaml
with open("${REPO_ROOT}/.github/workflows/cicd.yml") as f:
    doc = yaml.safe_load(f)
needs = doc["jobs"]["deploy-pages"]["needs"]
assert "smoke" in needs, f"deploy-pages needs does not include smoke: {needs}"
PYEOF
}

@test "cicd deploy-pages waits for publish so reports see the newest revision" {
    python3 - <<PYEOF
import yaml
with open("${REPO_ROOT}/.github/workflows/cicd.yml") as f:
    doc = yaml.safe_load(f)
deploy = doc["jobs"]["deploy-pages"]
needs = deploy["needs"]
assert "publish" in needs, f"deploy-pages needs does not include publish: {needs}"
# Option B: still deploy if publish flakes, but only when real deps succeeded.
condition = deploy["if"]
assert "always()" in condition, condition
for dep in ("lint", "build", "smoke", "vulnerability-scan"):
    assert f"needs.{dep}.result == 'success'" in condition, (dep, condition)
assert "needs.publish.result == 'success'" not in condition, condition
PYEOF
}

@test "cicd workflow distro tests reuse the main amd64 snap artifact" {
    local workflow="${REPO_ROOT}/.github/workflows/cicd.yml"
    grep -q "^  distro-test:" "$workflow"
    grep -q "uses: ./.github/workflows/reusable-distro-test.yml" "$workflow"
    grep -q "snap_artifact_name: pihole-snap-amd64" "$workflow"
}

@test "cicd distro reusable-workflow caller grants required token permissions" {
    python3 - <<PYEOF
import yaml
with open("${REPO_ROOT}/.github/workflows/cicd.yml") as f:
    doc = yaml.safe_load(f)
permissions = doc["jobs"]["distro-test"].get("permissions", {})
assert permissions.get("actions") == "read", permissions
assert permissions.get("contents") == "read", permissions
PYEOF
}

@test "reusable distro test workflow requires a prebuilt snap artifact and does not build" {
    python3 - <<PYEOF
import yaml
with open("${REPO_ROOT}/.github/workflows/reusable-distro-test.yml") as f:
    doc = yaml.safe_load(f)
on = doc.get("on", doc.get(True, {}))
inputs = on["workflow_call"]["inputs"]
assert inputs["snap_artifact_name"].get("required") is True, inputs["snap_artifact_name"]
jobs = doc["jobs"]
assert "build" not in jobs, f"reusable-distro-test must not build: {list(jobs)}"
assert "distro-test" in jobs, list(jobs)
PYEOF
}

@test "ubuntu core reusable workflow uses shared Multipass snapd stability helper" {
    local workflow="${REPO_ROOT}/.github/workflows/reusable-distro-test.yml"
    local helper="tests/scripts/multipass-wait-snapd-stable.sh test-instance"

    grep -q "sudo ${helper}" "$workflow"
    [ "$(grep -c "sudo ${helper}" "$workflow")" -eq 3 ]
    ! grep -q "wait_for_snapd_stability()" "$workflow"
}

@test "reusable distro build workflow builds and uploads a snap artifact" {
    python3 - <<PYEOF
import yaml
with open("${REPO_ROOT}/.github/workflows/reusable-distro-build.yml") as f:
    doc = yaml.safe_load(f)
on = doc.get("on", doc.get(True, {}))
assert "workflow_call" in on, on
steps = doc["jobs"]["build"]["steps"]
uses = [s.get("uses", "") for s in steps]
assert any(u.startswith("snapcore/action-build") for u in uses), uses
assert any(u.startswith("actions/upload-artifact") for u in uses), uses
PYEOF
}

@test "standalone distro workflows build then test with the built artifact" {
    python3 - <<PYEOF
import glob, yaml
paths = sorted(glob.glob("${REPO_ROOT}/.github/workflows/test-*.yml"))
assert paths, "no standalone distro workflows found"
for path in paths:
    with open(path) as f:
        doc = yaml.safe_load(f)
    jobs = doc["jobs"]
    assert jobs["build"]["uses"] == "./.github/workflows/reusable-distro-build.yml", (path, jobs.get("build"))
    test = jobs["test"]
    assert test["uses"] == "./.github/workflows/reusable-distro-test.yml", (path, test)
    assert test["needs"] == "build", (path, test.get("needs"))
    assert test["with"]["snap_artifact_name"] == "built-snap", (path, test.get("with"))
PYEOF
}

@test "standalone distro workflows are manual only" {
    local workflow
    for workflow in "${REPO_ROOT}"/.github/workflows/test-*.yml; do
        grep -q "workflow_dispatch:" "$workflow"
        ! grep -q "pull_request:" "$workflow"
        ! grep -q "push:" "$workflow"
    done
}

@test "standalone distro reusable-workflow callers grant required token permissions" {
    python3 - <<PYEOF
import glob, pathlib, yaml
for path in sorted(glob.glob("${REPO_ROOT}/.github/workflows/test-*.yml")):
    with open(path) as f:
        doc = yaml.safe_load(f)
    permissions = doc.get("permissions", {})
    assert permissions.get("actions") == "read", f"{path}: {permissions}"
    assert permissions.get("contents") == "read", f"{path}: {permissions}"
PYEOF
}

@test "promote workflow validates request before releasing a revision" {
    local workflow="${REPO_ROOT}/.github/workflows/promote.yml"
    grep -q "validation_run_id:" "$workflow"
    grep -q "confirmation:" "$workflow"
    grep -q "Verify validation workflow succeeded" "$workflow"
    grep -q "gh run view" "$workflow"
    grep -q "snapcraft list-revisions" "$workflow"
    grep -q "snap install.*--channel" "$workflow"
    grep -q "snapcraft release" "$workflow"
}

@test "promote workflow keeps snap-publishing environment approval gate" {
    local workflow="${REPO_ROOT}/.github/workflows/promote.yml"
    grep -q "environment: snap-publishing" "$workflow"
    grep -q "actions: read" "$workflow"
}
