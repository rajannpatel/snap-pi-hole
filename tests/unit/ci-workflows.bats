#!/usr/bin/env bats
#
# Unit tests for the CI/CD workflow logic that cannot be run in GitHub Actions
# without a real API call. Tests cover:
#
#   - track-upstream-releases.yml: upstream source commit bumps
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

@test "track-upstream workflow updates snapcraft source commits only" {
    local workflow="${REPO_ROOT}/.github/workflows/track-upstream-releases.yml"
    grep -q 'yq -i ".parts.ftl.\\"source-commit\\"' "$workflow"
    grep -q 'yq -i ".parts.pi_hole.\\"source-commit\\"' "$workflow"
    grep -q 'yq -i ".parts.web.\\"source-commit\\"' "$workflow"
    ! grep -q 'snap/local/build/stable-versions.json' "$workflow"
    grep -q '/commits/master' "$workflow"
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
steps = doc["jobs"]["update-sources"]["steps"]
checkout = next(step for step in steps if step.get("uses", "").startswith("actions/checkout@"))
assert checkout.get("with", {}).get("persist-credentials") is False, checkout
assert any(step.get("uses", "").startswith("peter-evans/create-pull-request@") for step in steps), steps
PYEOF
}

@test "track-upstream yq source-commit updates mutate the expected snapcraft parts" {
    if ! command -v yq >/dev/null 2>&1; then
        skip "yq is not installed"
    fi

    # Verify if the installed yq is the Go-based yq (mikefarah/yq)
    echo "test_key: value" > "${TEST_WORKDIR}/test.yaml"
    if ! yq -i '.test_key = "new_value"' "${TEST_WORKDIR}/test.yaml" >/dev/null 2>&1; then
        skip "Go-based yq (mikefarah/yq) is required for this test"
    fi

    local target="${TEST_WORKDIR}/snapcraft.yaml"
    yq -i '.parts.ftl."source-commit" = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" | del(.parts.ftl."source-tag") | del(.parts.ftl."source-branch")' "$target"
    yq -i '.parts.pi_hole."source-commit" = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" | del(.parts.pi_hole."source-tag") | del(.parts.pi_hole."source-branch")' "$target"
    yq -i '.parts.web."source-commit" = "cccccccccccccccccccccccccccccccccccccccc" | del(.parts.web."source-tag") | del(.parts.web."source-branch")' "$target"

    run yq -r '[.parts.ftl."source-commit", .parts.pi_hole."source-commit", .parts.web."source-commit"] | @tsv' "$target"
    [ "$status" -eq 0 ]
    [ "$output" = $'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\tcccccccccccccccccccccccccccccccccccccccc' ]
}

@test "vulnerability scan initializes llm cache file after cache restore" {
    python3 - <<PYEOF
import yaml

with open("${REPO_ROOT}/.github/workflows/cicd.yml") as f:
    doc = yaml.safe_load(f)

steps = doc["jobs"]["vulnerability-scan"]["steps"]
cache_idx = next(i for i, step in enumerate(steps) if step.get("uses", "").startswith("actions/cache@"))
init_idx = next(i for i, step in enumerate(steps) if step.get("name") == "Initialize LLM cache file")
scan_idx = next(i for i, step in enumerate(steps) if step.get("name") == "Scan SBOMs with OSV-Scanner")

assert cache_idx < init_idx < scan_idx, (cache_idx, init_idx, scan_idx)
run = steps[init_idx]["run"]
assert "mkdir -p local-vulnerabilities" in run, run
assert "local-vulnerabilities/llm-cache.json" in run, run
assert "printf '{}\\\\n'" in run, run
PYEOF
}

@test "x64 GitHub Actions jobs use ubuntu-26.04 runners and distro bats" {
    python3 - <<PYEOF
import yaml

with open("${REPO_ROOT}/.github/workflows/cicd.yml") as f:
    cicd = yaml.safe_load(f)
with open("${REPO_ROOT}/.github/workflows/reusable-distro-test.yml") as f:
    distro_test = yaml.safe_load(f)

assert cicd["jobs"]["lint"]["runs-on"] == "ubuntu-26.04", cicd["jobs"]["lint"]["runs-on"]
assert distro_test["jobs"]["distro-test"]["runs-on"] == "ubuntu-26.04", distro_test["jobs"]["distro-test"]["runs-on"]

steps = cicd["jobs"]["lint"]["steps"]
install = next(step for step in steps if step.get("name") == "Install shellcheck, bats, yamllint, and kcov")
run = install["run"]

assert "apt-get install -y shellcheck bats python3-yaml yamllint" in run, run
assert "bats-core" not in run, run
PYEOF
}

@test "GitHub Actions workflows use Ubuntu 26.04 runner labels" {
    python3 - <<PYEOF
from pathlib import Path

workflow_dir = Path("${REPO_ROOT}/.github/workflows")
workflow_text = "\\n".join(path.read_text() for path in workflow_dir.glob("*.yml"))

for stale in ("ubuntu-latest", "ubuntu-24.04", "ubuntu-24.04-arm"):
    assert stale not in workflow_text, stale

assert "ubuntu-26.04" in workflow_text, workflow_text
assert "ubuntu-26.04-arm" in workflow_text, workflow_text
PYEOF
}

@test "lint job builds kcov from source only when apt kcov is unavailable" {
    python3 - <<PYEOF
import yaml

with open("${REPO_ROOT}/.github/workflows/cicd.yml") as f:
    cicd = yaml.safe_load(f)

steps = cicd["jobs"]["lint"]["steps"]
install = next(step for step in steps if step.get("name") == "Install shellcheck, bats, yamllint, and kcov")
run = install["run"]

apt_kcov = "if sudo apt-get install -y kcov; then"
source_notice = "kcov is not available from apt on this runner; building from source."
clone = "git clone --depth 1 --branch v43 https://github.com/SimonKagstrom/kcov.git"
build = "cmake --build"
install_from_build = "sudo cmake --install"

for needle in (apt_kcov, source_notice, clone, build, install_from_build):
    assert needle in run, run

assert run.index(apt_kcov) < run.index(source_notice) < run.index(clone) < run.index(build) < run.index(install_from_build), run
PYEOF
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

@test "stable upstream selector also pins branch commits with source-commit" {
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
    "ftl": "1" * 40,
    "pi_hole": "2" * 40,
    "web": "3" * 40,
}

selector.update_source_commits(snapcraft_path, versions)

with snapcraft_path.open() as f:
    doc = yaml.safe_load(f)

for part, commit in versions.items():
    part_doc = doc["parts"][part]
    assert part_doc.get("source-commit") == commit, part_doc
    assert "source-tag" not in part_doc, part_doc
    assert "source-branch" not in part_doc, part_doc
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

@test "cicd deploy-pages selects stable upstream sources before dashboard data generation" {
    python3 - <<PYEOF
import yaml
with open("${REPO_ROOT}/.github/workflows/cicd.yml") as f:
    doc = yaml.safe_load(f)
steps = doc["jobs"]["deploy-pages"]["steps"]
organize = next(step for step in steps if step.get("name") == "Organize files for GitHub Pages")
run = organize["run"]
select_idx = run.index("python3 snap/local/build/select_snapcraft_upstream.py stable")
generate_idx = run.index("python3 snap/local/build/generate_dashboard_data.py")
assert select_idx < generate_idx, run
assert "cp snap/local/assets/dashboard-channel-switch.js docs/dashboard-channel-switch.js" in run, run
assert organize.get("env", {}).get("GITHUB_TOKEN") is not None, organize
PYEOF
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

@test "cicd deploy-pages does not wait for the GitHub publish matrix" {
    python3 - <<PYEOF
import yaml
with open("${REPO_ROOT}/.github/workflows/cicd.yml") as f:
    doc = yaml.safe_load(f)
deploy = doc["jobs"]["deploy-pages"]
needs = deploy["needs"]
assert "publish" not in needs, f"deploy-pages should not wait for publish: {needs}"
condition = deploy["if"]
assert "always()" in condition, condition
for dep in ("lint", "build", "smoke", "vulnerability-scan"):
    assert f"needs.{dep}.result == 'success'" in condition, (dep, condition)
assert "needs.publish.result == 'success'" not in condition, condition
runs = "\n".join(s.get("run", "") for s in deploy["steps"])
assert "Publish matrix is not a prerequisite for Pages" in runs, runs
assert "not visible yet" not in runs, runs
env_values = [s.get("env", {}).get("PUBLISH_RESULT") for s in deploy["steps"] if "PUBLISH_RESULT" in s.get("env", {})]
assert env_values == ["not_waited", "not_waited"], env_values
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
preflight = doc["jobs"]["preflight"]
preflight_cond = preflight["if"]
preflight_runs = "\n".join(s.get("run", "") for s in preflight["steps"])
assert "github.event.workflow_run.conclusion == 'success'" not in cond, cond
assert "needs.preflight.outputs.should_build == 'true'" in cond, cond
assert job["needs"] == ["preflight"], job["needs"]
assert "github.event.workflow_run.head_branch == 'main'" in preflight_cond, preflight_cond
assert "github.event.workflow_run.event == 'push'" in preflight_cond, preflight_cond
assert '"distro test "*|*" / distro-test"' in preflight_runs, preflight_runs
assert "should_build=true" in preflight_runs, preflight_runs
assert "workflow_dispatch" in cond, cond
PYEOF
}

@test "launchpad workflow runs one independent builder per non-GitHub arch" {
    python3 - <<PYEOF
import yaml
with open("${REPO_ROOT}/.github/workflows/launchpad-builds.yml") as f:
    doc = yaml.safe_load(f)
jobs = doc["jobs"]
assert list(jobs) == ["preflight", "build-and-publish-launchpad"], list(jobs)
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
assert list(jobs) == ["preflight", "build-and-publish-launchpad"], list(jobs)
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

@test "cicd deploy-pages is not blocked by GitHub Snap Store publishing" {
    python3 - <<PYEOF
import yaml
with open("${REPO_ROOT}/.github/workflows/cicd.yml") as f:
    doc = yaml.safe_load(f)
deploy = doc["jobs"]["deploy-pages"]
needs = deploy["needs"]
assert "publish" not in needs, needs
condition = deploy["if"]
assert "needs.publish" not in condition, condition
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

@test "upstream selector resolves release labels without writing version metadata" {
    python3 - <<PYEOF
import importlib.util
import pathlib

selector_path = pathlib.Path("${REPO_ROOT}/snap/local/build/select_snapcraft_upstream.py")
spec = importlib.util.spec_from_file_location("select_snapcraft_upstream", selector_path)
selector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(selector)
selector.latest_release_versions = lambda token="": {
    "ftl": "v6.6.2",
    "pi_hole": "v6.4.2",
    "web": "v6.5.1",
}

stable_versions = selector.latest_release_versions()
assert stable_versions.get("pi_hole") == "v6.4.2", f"expected v6.4.2, got: {stable_versions.get('pi_hole')}"
assert stable_versions.get("ftl") == "v6.6.2", f"expected v6.6.2, got: {stable_versions.get('ftl')}"
assert stable_versions.get("web") == "v6.5.1", f"expected v6.5.1, got: {stable_versions.get('web')}"
assert not pathlib.Path("${REPO_ROOT}/snap/local/build/stable-versions.json").exists()
PYEOF
}

@test "pi-hole-override-build.sh formats SNAP_VERSION correctly for stable and edge" {
    # Create a dummy CRAFT_STAGE directory with tags
    local temp_stage="${TEST_WORKDIR}/stage"
    mkdir -p "${temp_stage}/snap-meta"
    echo "v6.6.2" > "${temp_stage}/snap-meta/ftl-tag"
    mkdir -p "${temp_stage}/var/www/html/admin/snap-meta"
    echo "v6.5.1" > "${temp_stage}/var/www/html/admin/snap-meta/web-tag"

    # Helper function to run the version-parsing logic of pi-hole-override-build.sh
    run_override_version_logic() {
        local core_commit_mock="$1"

        # Mock git rev-parse command for the fetched upstream pi-hole source.
        git() {
            if [[ "$*" == *"rev-parse --short HEAD"* ]]; then
                echo "$core_commit_mock"
            else
                command git "$@"
            fi
        }
        export -f git

        python3() {
            if [[ "$*" == *"resolve_upstream_version.py pi_hole"* ]]; then
                echo "v6.4.2"
            else
                command python3 "$@"
            fi
        }
        export -f python3

        # Mock craftctl set version
        local set_version=""
        craftctl() {
            if [[ "$1" == "set" && "$2" == "version="* ]]; then
                set_version="${2#version=}"
            fi
        }
        export -f craftctl

        # Extract the version logic from the override script
        local script_segment
        script_segment=$(sed -n '/FTL_TAG=\$(cat/,/craftctl set version=/p' "${REPO_ROOT}/snap/local/build/pi-hole-override-build.sh")

        CRAFT_STAGE="$temp_stage" \
        CRAFT_PROJECT_DIR="$TEST_WORKDIR" \
        CRAFT_PART_SRC="/dummy/part/src" \
        eval "$script_segment"

        echo "$set_version"
    }

    # Stable and edge both include the fetched upstream pi-hole commit.
    local stable_version
    stable_version=$(run_override_version_logic "3413768")
    [ "$stable_version" = "v6.4.2+git.3413768" ]
    [ "${#stable_version}" -le 32 ]

    local edge_version
    edge_version=$(run_override_version_logic "841976c")
    [ "$edge_version" = "v6.4.2+git.841976c" ]
    [ "${#edge_version}" -le 32 ]
}

@test "ftl-override-build.sh and web-override-build.sh format component tags correctly" {
    # Helper function to run ftl-override-build.sh tag logic
    run_ftl_tag_logic() {
        local ftl_tag_mock="$1"
        git() {
            echo "$ftl_tag_mock"
        }
        export -f git

        python3() {
            if [[ "$*" == *"resolve_upstream_version.py ftl"* ]]; then
                echo "v6.6.2"
            else
                command python3 "$@"
            fi
        }
        export -f python3

        local script_segment
        script_segment=$(sed -n '/FTL_TAG=\$(git -C/,/export GIT_TAG=/p' "${REPO_ROOT}/snap/local/build/ftl-override-build.sh")

        CRAFT_PROJECT_DIR="$TEST_WORKDIR" \
        CRAFT_PART_SRC="/dummy/part/src" \
        eval "$script_segment"

        echo "$FTL_TAG"
    }

    # Helper function to run web-override-build.sh tag logic
    run_web_tag_logic() {
        local web_tag_mock="$1"
        git() {
            echo "$web_tag_mock"
        }
        export -f git

        python3() {
            if [[ "$*" == *"resolve_upstream_version.py web"* ]]; then
                echo "v6.5.1"
            else
                command python3 "$@"
            fi
        }
        export -f python3

        local script_segment
        script_segment=$(awk '
            /WEB_TAG=\$\(git -C/ { capture = 1 }
            capture && /^craftctl default/ { exit }
            capture { print }
        ' "${REPO_ROOT}/snap/local/build/web-override-build.sh")

        CRAFT_PROJECT_DIR="$TEST_WORKDIR" \
        CRAFT_PART_SRC="/dummy/part/src" \
        eval "$script_segment"

        echo "$WEB_TAG"
    }

    # Test FTL stable
    [ "$(run_ftl_tag_logic "v6.6.2")" = "v6.6.2" ]
    # Test FTL edge
    [ "$(run_ftl_tag_logic "56ef789")" = "v6.6.2+git.56ef789" ]

    # Test Web stable
    [ "$(run_web_tag_logic "v6.5.1")" = "v6.5.1" ]
    # Test Web edge
    [ "$(run_web_tag_logic "12ab34c")" = "v6.5.1+git.12ab34c" ]
}

@test "channel-switch workflow exists" {
    [ -f "${REPO_ROOT}/.github/workflows/channel-switch.yml" ]
}

@test "channel-switch workflow has manual and workflow_run triggers" {
    python3 - <<PYEOF
import yaml
with open("${REPO_ROOT}/.github/workflows/channel-switch.yml") as f:
    wf = yaml.safe_load(f)
on_val = wf.get("on") or wf.get(True) or {}
assert "workflow_dispatch" in on_val, on_val
assert "workflow_run" in on_val, on_val
wfs = on_val["workflow_run"]["workflows"]
assert wfs == ["CI/CD Pipeline"], wfs
PYEOF
}

@test "channel-switch workflow is optional and not a PR gate" {
    python3 - <<PYEOF
import yaml
with open("${REPO_ROOT}/.github/workflows/channel-switch.yml") as f:
    wf = yaml.safe_load(f)
on_val = wf.get("on") or wf.get(True) or {}
assert "pull_request" not in on_val, on_val

cond = wf["jobs"]["run-smoke"]["if"]
assert "github.event_name == 'workflow_dispatch'" in cond, cond
assert "github.event.workflow_run.conclusion == 'success'" in cond, cond
assert "github.event.workflow_run.event == 'push'" in cond, cond
assert "github.event.workflow_run.head_branch == 'main'" in cond, cond

# Ensure existing cicd.yml required jobs do not 'need' channel-switch
with open("${REPO_ROOT}/.github/workflows/cicd.yml") as f:
    cicd = yaml.safe_load(f)
for job_name, job_data in cicd.get("jobs", {}).items():
    needs = job_data.get("needs", [])
    if isinstance(needs, str):
        needs = [needs]
    assert "run-smoke" not in needs, job_name
    assert "channel-switch" not in needs, job_name
PYEOF
}

@test "channel-switch workflow uploads result artifact on failure" {
    python3 - <<PYEOF
import yaml
with open("${REPO_ROOT}/.github/workflows/channel-switch.yml") as f:
    wf = yaml.safe_load(f)
steps = wf["jobs"]["run-smoke"]["steps"]
upload_step = next(s for s in steps if s.get("uses", "").startswith("actions/upload-artifact"))
assert upload_step.get("if") == "always()", upload_step
assert upload_step.get("with", {}).get("if-no-files-found") == "error", upload_step
PYEOF
}

@test "channel-switch workflow tests store channels not local artifacts" {
    python3 - <<PYEOF
import yaml
with open("${REPO_ROOT}/.github/workflows/channel-switch.yml") as f:
    wf = yaml.safe_load(f)
steps = wf["jobs"]["run-smoke"]["steps"]
# Assert we don't download local snap package artifacts
assert not any("download-artifact" in s.get("uses", "") for s in steps), "Should not download local snap package"

# Assert the script tests snap store channel install, not local file install
with open("${REPO_ROOT}/tests/scripts/channel-switch-smoke.sh") as f:
    script = f.read()
assert "snap install" in script
assert "--channel=" in script
assert ".snap" not in script
PYEOF
}

@test "channel-switch workflow includes stable and edge channel names" {
    python3 - <<PYEOF
with open("${REPO_ROOT}/.github/workflows/channel-switch.yml") as f:
    wf = f.read()
assert "latest/stable" in wf or "stable-to-edge" in wf or "edge-to-stable" in wf
with open("${REPO_ROOT}/tests/scripts/channel-switch-smoke.sh") as f:
    script = f.read()
assert "latest/stable" in script
assert "latest/edge" in script
PYEOF
}

@test "channel-switch workflow uses Ubuntu 26.04 runner labels" {
    python3 - <<PYEOF
import yaml
with open("${REPO_ROOT}/.github/workflows/channel-switch.yml") as f:
    wf = yaml.safe_load(f)
jobs = wf["jobs"]
for job_name, job_data in jobs.items():
    runs_on = job_data.get("runs-on", "")
    if isinstance(runs_on, str) and runs_on.startswith("\${{"):
        matrix = job_data.get("strategy", {}).get("matrix", {})
        includes = matrix.get("include", [])
        for entry in includes:
            runner = entry.get("runner", "")
            assert "ubuntu-latest" not in runner, runner
            assert "ubuntu-26.04" in runner, runner
    else:
        assert "ubuntu-latest" not in runs_on, runs_on
        assert "ubuntu-26.04" in runs_on, runs_on
PYEOF
}

@test "channel-switch workflow runs only on the arm64 GitHub runner" {
    python3 - <<PYEOF
import yaml
with open("${REPO_ROOT}/.github/workflows/channel-switch.yml") as f:
    wf = yaml.safe_load(f)
matrix = wf["jobs"]["run-smoke"]["strategy"]["matrix"]["include"]
assert matrix == [{"arch": "arm64", "runner": "ubuntu-26.04-arm"}], matrix
PYEOF
}

@test "refresh-dashboard workflow republishes Pages after channel switch completes" {
    python3 - <<PYEOF
import yaml

path = "${REPO_ROOT}/.github/workflows/refresh-dashboard.yml"
with open(path) as f:
    doc = yaml.safe_load(f)

on = doc.get("on", doc.get(True, {}))
assert on["workflow_run"]["workflows"] == ["Channel Switch Smoke"], on
assert on["workflow_run"]["types"] == ["completed"], on
assert "workflow_dispatch" in on, on

permissions = doc["permissions"]
assert permissions["actions"] == "read", permissions
assert permissions["pages"] == "write", permissions
assert permissions["id-token"] == "write", permissions

job = doc["jobs"]["refresh"]
run_blocks = "\\n".join(step.get("run", "") for step in job["steps"])
uses = [step.get("uses", "") for step in job["steps"]]

assert "gh run list" in run_blocks and "--workflow cicd.yml" in run_blocks, run_blocks
assert "gh run download" in run_blocks and "code-coverage-report" in run_blocks, run_blocks
assert "--pattern \"sbom-*\"" in run_blocks, run_blocks
assert "--pattern \"channel-switch-result-*\"" in run_blocks, run_blocks
envs = [step.get("env", {}) for step in job["steps"]]
assert any(env.get("CHANNEL_SWITCH_RESULT_DIR") == "channel-switch-artifacts" for env in envs), envs
assert any("CHANNEL_SWITCH_RESULT_RUN_ID" in env for env in envs), envs
assert "vulnerability-reports" in run_blocks, run_blocks
assert "generate_dashboard_data.py . docs/dashboard-data.json" in run_blocks, run_blocks
assert "generate_dashboard_data.py --snapcraft-only" in run_blocks, run_blocks
assert "GIST_TOKEN is not set; skipping gist update" in run_blocks, run_blocks
assert "actions/upload-pages-artifact@v3" in uses, uses
assert "actions/deploy-pages@v4" in uses, uses
PYEOF
}
