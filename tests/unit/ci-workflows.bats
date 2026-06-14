#!/usr/bin/env bats
#
# Unit tests for the CI/CD workflow logic that cannot be run in GitHub Actions
# without a real API call. Tests cover:
#
#   - track-upstream-releases.yml: snapcraft.yaml-only upstream tag bumps
#   - cicd.yml: port-53 timeout guard logic (both success and failure paths)
#   - cicd.yml / launchpad-builds.yml: Snap Store publishing channel policy
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

# track-upstream-releases.yml

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

@test "track-upstream checkout does not persist credentials before create-pull-request" {
    python3 - <<PYEOF
import yaml
with open("${REPO_ROOT}/.github/workflows/track-upstream-releases.yml") as f:
    doc = yaml.safe_load(f)
steps = doc["jobs"]["update-tags"]["steps"]
checkout = next(step for step in steps if step.get("uses", "").startswith("actions/checkout@"))
assert checkout.get("with", {}).get("persist-credentials") is False, checkout
assert any(step.get("uses", "").startswith("peter-evans/create-pull-request@") for step in steps), steps
PYEOF
}

@test "track-upstream yq source-tag updates mutate the expected snapcraft parts" {
    if ! command -v yq >/dev/null 2>&1; then
        skip "yq is not installed"
    fi

    # Verify if the installed yq is the Go-based yq (mikefarah/yq)
    echo "test_key: value" > "${TEST_WORKDIR}/test.yaml"
    if ! yq -i '.test_key = "new_value"' "${TEST_WORKDIR}/test.yaml" >/dev/null 2>&1; then
        skip "Go-based yq (mikefarah/yq) is required for this test"
    fi

    local target="${TEST_WORKDIR}/snapcraft.yaml"
    yq -i '.parts.ftl.source-tag = "v9.1.0"' "$target"
    yq -i '.parts.pi_hole.source-tag = "v9.2.0"' "$target"
    yq -i '.parts.web.source-tag = "v9.3.0"' "$target"

    run yq -r '[.parts.ftl.source-tag, .parts.pi_hole.source-tag, .parts.web.source-tag] | @tsv' "$target"
    [ "$status" -eq 0 ]
    [ "$output" = $'v9.1.0\tv9.2.0\tv9.3.0' ]
}

@test "edge upstream selector pins commits with source-commit, not source-tag" {
    python3 - <<PYEOF
import importlib.util
import pathlib
import yaml

selector_path = pathlib.Path("${REPO_ROOT}/snap/local/build/select_snapcraft_upstream.py")
spec = importlib.util.spec_from_file_location("select_snapcraft_upstream", selector_path)
selector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(selector)

snapcraft_path = pathlib.Path("${TEST_WORKDIR}/snapcraft.yaml")
versions = {
    "ftl": "a" * 40,
    "pi_hole": "b" * 40,
    "web": "c" * 40,
}

selector.update_source_commits(snapcraft_path, versions)

with snapcraft_path.open() as f:
    doc = yaml.safe_load(f)

for part, commit in versions.items():
    part_doc = doc["parts"][part]
    assert part_doc.get("source-commit") == commit, part_doc
    assert "source-tag" not in part_doc, part_doc

assert doc["parts"]["ftl"].get("source-depth") == 1, doc["parts"]["ftl"]
PYEOF
}

# Port-53 timeout guard logic (from cicd.yml smoke test)

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

@test "cicd workflow only runs on the snap-pi-hole main branch" {
    python3 - <<PYEOF
import yaml
with open("${REPO_ROOT}/.github/workflows/cicd.yml") as f:
    doc = yaml.safe_load(f)
on = doc.get("on", doc.get(True, {}))
assert on["push"]["branches"] == ["main"], on
assert on["pull_request"]["branches"] == ["main"], on
for workflow in ("${REPO_ROOT}/.github/workflows/cicd.yml", "${REPO_ROOT}/.github/workflows/launchpad-builds.yml"):
    text = open(workflow).read()
    assert "refs/heads/dev" not in text, workflow
    assert "head_branch == 'dev'" not in text, workflow
PYEOF
}

@test "cicd publish releases GitHub builds to stable or edge" {
    python3 - <<PYEOF
import yaml
with open("${REPO_ROOT}/.github/workflows/cicd.yml") as f:
    doc = yaml.safe_load(f)
publish = doc["jobs"]["publish"]
assert sorted(publish["strategy"]["matrix"]["channel"]) == ["edge", "stable"], publish["strategy"]
runs = "\n".join(s.get("run", "") for s in doc["jobs"]["publish"]["steps"])
assert "channels=latest/stable" in runs, runs
assert "channels=latest/edge" in runs, runs
for channel in ("latest/beta", "latest/candidate"):
    assert channel not in runs, (channel, runs)
assert "ENABLE_TRACKS" not in runs, runs
PYEOF
}

@test "launchpad publish releases Launchpad builds to stable or edge" {
    python3 - <<PYEOF
import yaml
with open("${REPO_ROOT}/.github/workflows/launchpad-builds.yml") as f:
    doc = yaml.safe_load(f)
job = doc["jobs"]["build-and-publish-launchpad"]
assert sorted(job["strategy"]["matrix"]["channel"]) == ["edge", "stable"], job["strategy"]
runs = "\n".join(s.get("run", "") for s in job["steps"])
assert "channels=latest/stable" in runs, runs
assert "channels=latest/edge" in runs, runs
for channel in ("latest/beta", "latest/candidate"):
    assert channel not in runs, (channel, runs)
assert "ENABLE_TRACKS" not in runs, runs
PYEOF
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
assert validate_step.get("env", {}).get("LLM_GEMINI_KEY") is not None or validate_step.get("env", {}).get("LLM_GITHUB_KEY") is not None, validate_step
assert "validate_llm_key.py" in validate_step.get("run", ""), validate_step
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

@test "cicd workflow does not wait for Launchpad builders" {
    python3 - <<PYEOF
import yaml
with open("${REPO_ROOT}/.github/workflows/cicd.yml") as f:
    doc = yaml.safe_load(f)
jobs = doc["jobs"]
assert "remote-build" not in jobs, list(jobs)
assert "publish-remote" not in jobs, list(jobs)
for job_name in ("vulnerability-scan", "deploy-pages"):
    needs = jobs[job_name]["needs"]
    assert "remote-build" not in needs, (job_name, needs)
    assert "publish-remote" not in needs, (job_name, needs)
PYEOF
}

@test "launchpad workflow is decoupled from the main CI workflow" {
    python3 - <<PYEOF
import yaml
with open("${REPO_ROOT}/.github/workflows/launchpad-builds.yml") as f:
    doc = yaml.safe_load(f)
assert doc["name"] == "Launchpad Builds", doc["name"]
on = doc.get("on", doc.get(True, {}))
assert "workflow_run" in on, on
assert "workflow_dispatch" in on, on
wr = on["workflow_run"]
assert wr["workflows"] == ["CI/CD Pipeline"], wr
assert wr["types"] == ["completed"], wr
job = doc["jobs"]["build-and-publish-launchpad"]
cond = job["if"]
assert "github.event.workflow_run.conclusion == 'success'" in cond, cond
assert "github.event.workflow_run.head_branch == 'main'" in cond, cond
assert "workflow_dispatch" in cond, cond
PYEOF
}

@test "launchpad workflow runs one independent builder per non-GitHub arch" {
    python3 - <<PYEOF
import yaml
with open("${REPO_ROOT}/.github/workflows/launchpad-builds.yml") as f:
    doc = yaml.safe_load(f)
jobs = doc["jobs"]
assert list(jobs) == ["build-and-publish-launchpad"], list(jobs)
job = jobs["build-and-publish-launchpad"]
assert job["name"] == "build and publish launchpad (\${{ matrix.channel }}, \${{ matrix.arch }})", job["name"]
arches = job["strategy"]["matrix"]["arch"]
channels = job["strategy"]["matrix"]["channel"]
assert sorted(arches) == ["armhf", "ppc64el", "riscv64", "s390x"], arches
assert sorted(channels) == ["edge", "stable"], channels
assert job["strategy"].get("fail-fast") is False, job["strategy"]
steps = job["steps"]
# remote-build rejects shallow clones, so a full-history checkout is required.
checkout = next(s for s in steps if str(s.get("uses", "")).startswith("actions/checkout"))
assert checkout.get("with", {}).get("fetch-depth") == 0, checkout
assert "github.event.workflow_run.head_sha" in checkout.get("with", {}).get("ref"), checkout
runs = "\n".join(s.get("run", "") for s in steps)
assert "launchpad-credentials" in runs, "credentials must be restored to the snapcraft path"
assert "base64 -d" in runs, runs
assert "snapcraft remote-build" in runs, runs
assert "--build-for \${{ matrix.arch }}" in runs, runs
assert "--build-for armhf,ppc64el,riscv64,s390x" not in runs, runs
assert "--launchpad-accept-public-upload" in runs, runs
assert "--launchpad-timeout" in runs, runs
assert "select_snapcraft_upstream.py \${{ matrix.channel }}" in runs, runs
PYEOF
}

@test "launchpad workflow uploads per-arch snaps and SBOMs" {
    python3 - <<PYEOF
import yaml
with open("${REPO_ROOT}/.github/workflows/launchpad-builds.yml") as f:
    doc = yaml.safe_load(f)
steps = doc["jobs"]["build-and-publish-launchpad"]["steps"]
runs = "\n".join(s.get("run", "") for s in steps)
assert "syft scan" in runs, runs
assert "enrich_sbom.py" in runs, runs
assert "sbom-\${{ matrix.arch }}.json" in runs, runs
uploads = [s for s in steps if str(s.get("uses", "")).startswith("actions/upload-artifact")]
names = [s.get("with", {}).get("name") for s in uploads]
assert "pihole-snap-launchpad-\${{ matrix.channel }}-\${{ matrix.arch }}" in names, names
assert "sbom-launchpad-\${{ matrix.channel }}-\${{ matrix.arch }}" in names, names
# A sbom-* artifact name keeps Launchpad outputs consistent with GitHub builder
# artifacts for manual download and later report-refresh workflows.
assert any(str(n).startswith("sbom-") for n in names), names
PYEOF
}

@test "launchpad workflow publishes the four Launchpad arches to stable and edge from main" {
    python3 - <<PYEOF
import yaml
with open("${REPO_ROOT}/.github/workflows/launchpad-builds.yml") as f:
    doc = yaml.safe_load(f)
jobs = doc["jobs"]
assert list(jobs) == ["build-and-publish-launchpad"], list(jobs)
job = jobs["build-and-publish-launchpad"]
arches = job["strategy"]["matrix"]["arch"]
assert sorted(arches) == ["armhf", "ppc64el", "riscv64", "s390x"], arches
runs = "\n".join(s.get("run", "") for s in job["steps"])
assert "channels=latest/stable" in runs, runs
assert "channels=latest/edge" in runs, runs
assert "snapcraft upload" in runs, runs
PYEOF
}

@test "cicd github build and publish jobs use explicit GitHub builder naming" {
    python3 - <<PYEOF
import yaml
with open("${REPO_ROOT}/.github/workflows/cicd.yml") as f:
    doc = yaml.safe_load(f)
jobs = doc["jobs"]
build = jobs["build"]
publish = jobs["publish"]
assert build["name"] == "build github (\${{ matrix.channel }}, \${{ matrix.arch }})", build["name"]
assert publish["name"] == "publish github (\${{ matrix.channel }}, \${{ matrix.arch }})", publish["name"]
assert sorted(build["strategy"]["matrix"]["channel"]) == ["edge", "stable"], build["strategy"]
assert sorted(publish["strategy"]["matrix"]["channel"]) == ["edge", "stable"], publish["strategy"]
build_uploads = [s for s in build["steps"] if str(s.get("uses", "")).startswith("actions/upload-artifact")]
build_names = [s.get("with", {}).get("name") for s in build_uploads]
assert "pihole-snap-github-\${{ matrix.channel }}-\${{ matrix.arch }}" in build_names, build_names
assert "sbom-github-\${{ matrix.channel }}-\${{ matrix.arch }}" in build_names, build_names
publish_downloads = [s for s in publish["steps"] if str(s.get("uses", "")).startswith("actions/download-artifact")]
publish_names = [s.get("with", {}).get("name") for s in publish_downloads]
assert "pihole-snap-github-\${{ matrix.channel }}-\${{ matrix.arch }}" in publish_names, publish_names
runs = "\n".join(s.get("run", "") for s in build["steps"])
assert "select_snapcraft_upstream.py \${{ matrix.channel }}" in runs, runs
PYEOF
}

@test "cicd vulnerability-scan is not blocked by Launchpad builders" {
    python3 - <<PYEOF
import yaml
with open("${REPO_ROOT}/.github/workflows/cicd.yml") as f:
    doc = yaml.safe_load(f)
vs = doc["jobs"]["vulnerability-scan"]
assert vs["needs"] == ["build"], vs["needs"]
cond = vs["if"]
assert "always()" in cond, cond
assert "needs.build.result == 'success'" in cond, cond
assert "remote-build" not in cond, cond
assert "needs.remote-build.result == 'success'" not in cond, cond
PYEOF
}

@test "cicd deploy-pages is not blocked by Launchpad builders" {
    python3 - <<PYEOF
import yaml
with open("${REPO_ROOT}/.github/workflows/cicd.yml") as f:
    doc = yaml.safe_load(f)
deploy = doc["jobs"]["deploy-pages"]
needs = deploy["needs"]
assert "remote-build" not in needs, needs
assert "publish-remote" not in needs, needs
condition = deploy["if"]
assert "remote-build" not in condition, condition
assert "publish-remote" not in condition, condition
PYEOF
}

@test "cicd workflow distro tests reuse the matching channel amd64 snap artifact" {
    local workflow="${REPO_ROOT}/.github/workflows/cicd.yml"
    grep -q "^  distro-test:" "$workflow"
    grep -q "uses: ./.github/workflows/reusable-distro-test.yml" "$workflow"
    grep -q 'snap_artifact_name: pihole-snap-github-${{ matrix.channel }}-amd64' "$workflow"
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

@test "cicd distro matrix covers every supported distro" {
    python3 - <<PYEOF
import yaml
with open("${REPO_ROOT}/.github/workflows/cicd.yml") as f:
    doc = yaml.safe_load(f)
include = doc["jobs"]["distro-test"]["strategy"]["matrix"]["include"]
distros = sorted({row["distro"] for row in include})
channels = sorted({row["channel"] for row in include})
expected = sorted([
    "almalinux",
    "archlinux",
    "debian",
    "debian-stable",
    "fedora",
    "opensuse-leap",
    "opensuse-tumbleweed",
    "rockylinux",
    "ubuntu",
    "ubuntu-core",
    "ubuntu-daily",
])
assert distros == expected, distros
assert channels == ["edge", "stable"], channels
for distro in expected:
    assert sum(1 for row in include if row["distro"] == distro) == 2, distro
PYEOF
}

@test "standalone distro workflows have been retired" {
    python3 - <<PYEOF
import glob, yaml
paths = sorted(glob.glob("${REPO_ROOT}/.github/workflows/test-*.yml"))
assert paths == [], f"unused standalone distro workflows should be removed: {paths}"
PYEOF
}

@test "retired reusable distro build workflow is absent" {
    python3 - <<PYEOF
import os
path = "${REPO_ROOT}/.github/workflows/reusable-distro-build.yml"
assert not os.path.exists(path), path
PYEOF
}

@test "manual promotion workflow is retired because CI publishes directly to target channels" {
    [ ! -e "${REPO_ROOT}/.github/workflows/promote.yml" ]
}

@test "track-upstream cron schedule is set to run every 3 hours" {
    python3 - <<PYEOF
import yaml
with open("${REPO_ROOT}/.github/workflows/track-upstream-releases.yml") as f:
    doc = yaml.safe_load(f)
on = doc.get("on", doc.get(True, {}))
cron = on["schedule"][0]["cron"]
assert cron == "0 */3 * * *", f"Expected cron '0 */3 * * *', got '{cron}'"
PYEOF
}
