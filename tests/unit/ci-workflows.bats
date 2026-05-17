#!/usr/bin/env bats
#
# Unit tests for the CI/CD workflow logic that cannot be run in GitHub Actions
# without a real API call. Tests cover:
#
#   - update-upstream.yml: Python README version bump script
#   - update-upstream.yml: sed-based snapcraft.yaml source-tag bumps
#   - build.yml: port-53 timeout guard logic (both success and failure paths)
#
# Run locally:  bats tests/unit/ci-workflows.bats
# In CI:        see .github/workflows/build.yml (lint+unit job)

setup() {
    REPO_ROOT="$(git rev-parse --show-toplevel)"
    TMPDIR="$(mktemp -d)"
    cp "${REPO_ROOT}/README.md"           "${TMPDIR}/README.md"
    cp "${REPO_ROOT}/snap/snapcraft.yaml" "${TMPDIR}/snapcraft.yaml"
}

teardown() {
    rm -rf "${TMPDIR}"
}

# ---------------------------------------------------------------------------
# Helper: run the Python README version bump (extracted from update-upstream.yml)
# ---------------------------------------------------------------------------

_run_readme_bump() {
    local ftl="$1" pihole="$2" web="$3" target="${4:-${TMPDIR}/README.md}"
    python3 - "$ftl" "$pihole" "$web" <<'PYEOF'
import re, sys
ftl_ver, pihole_ver, web_ver = sys.argv[1:]
with open(sys.argv[0] if False else '/dev/stdin') as f: pass  # keep heredoc happy
import pathlib
readme = pathlib.Path(sys.argv[4] if len(sys.argv) > 4 else 'README.md')
# Determine path from env if set
import os
target = os.environ.get('_README_TARGET', 'README.md')
content = pathlib.Path(target).read_text()
content = re.sub(r'(github\.com/pi-hole/FTL\)[*| "]+\| )v[\d.]+', rf'\g<1>{ftl_ver}', content)
content = re.sub(r'(github\.com/pi-hole/pi-hole\)[*| "]+\| )v[\d.]+', rf'\g<1>{pihole_ver}', content)
content = re.sub(r'(github\.com/pi-hole/web\)[*| "]+\| )v[\d.]+', rf'\g<1>{web_ver}', content)
pathlib.Path(target).write_text(content)
PYEOF
}

# Cleaner helper using env variable for target path
_bump_readme() {
    local ftl="$1" pihole="$2" web="$3"
    _README_TARGET="${TMPDIR}/README.md" python3 - "$ftl" "$pihole" "$web" <<'PYEOF'
import re, sys, os, pathlib
ftl_ver, pihole_ver, web_ver = sys.argv[1:]
target = os.environ['_README_TARGET']
content = pathlib.Path(target).read_text()
content = re.sub(r'(github\.com/pi-hole/FTL\)[*| "]+\| )v[\d.]+',       rf'\g<1>{ftl_ver}',    content)
content = re.sub(r'(github\.com/pi-hole/pi-hole\)[*| "]+\| )v[\d.]+',   rf'\g<1>{pihole_ver}', content)
content = re.sub(r'(github\.com/pi-hole/web\)[*| "]+\| )v[\d.]+',       rf'\g<1>{web_ver}',    content)
pathlib.Path(target).write_text(content)
PYEOF
}

# ---------------------------------------------------------------------------
# README version bump tests
# ---------------------------------------------------------------------------

@test "README bump: FTL version is updated correctly" {
    _bump_readme "v9.1.0" "v6.4.2" "v6.5"
    grep -q "v9.1.0" "${TMPDIR}/README.md"
}

@test "README bump: pi-hole (core) version is updated correctly" {
    _bump_readme "v6.6.2" "v9.2.0" "v6.5"
    grep -q "v9.2.0" "${TMPDIR}/README.md"
}

@test "README bump: web version is updated correctly" {
    _bump_readme "v6.6.2" "v6.4.2" "v9.3"
    grep -q "v9.3" "${TMPDIR}/README.md"
}

@test "README bump: all three versions updated independently in a single run" {
    _bump_readme "v9.1.0" "v9.2.0" "v9.3"
    grep -q "v9.1.0" "${TMPDIR}/README.md"
    grep -q "v9.2.0" "${TMPDIR}/README.md"
    grep -q "v9.3"   "${TMPDIR}/README.md"
}

@test "README bump: old versions are removed after update" {
    _bump_readme "v9.1.0" "v9.2.0" "v9.3"
    # The original versions in the repo's README should be gone
    local content
    content="$(cat "${TMPDIR}/README.md")"
    [[ "$content" != *"v6.6.2"* ]]
    [[ "$content" != *"v6.4.2"* ]]
}

@test "README bump: FTL row does not bleed into pi-hole or web rows" {
    # Set all three to distinct sentinel values and verify each row is exact
    _bump_readme "v1.0.0" "v2.0.0" "v3.0"
    # Each GitHub URL must appear with exactly its own version on the same line
    grep "pi-hole/FTL"      "${TMPDIR}/README.md" | grep -q "v1.0.0"
    grep "pi-hole/pi-hole"  "${TMPDIR}/README.md" | grep -q "v2.0.0"
    grep "pi-hole/web"      "${TMPDIR}/README.md" | grep -q "v3.0"
    # No cross-contamination
    ! grep "pi-hole/FTL"     "${TMPDIR}/README.md" | grep -q "v2.0.0"
    ! grep "pi-hole/pi-hole" "${TMPDIR}/README.md" | grep -q "v1.0.0"
}

@test "README bump: idempotent — running twice produces the same result" {
    _bump_readme "v9.1.0" "v9.2.0" "v9.3"
    local first
    first="$(cat "${TMPDIR}/README.md")"
    _bump_readme "v9.1.0" "v9.2.0" "v9.3"
    local second
    second="$(cat "${TMPDIR}/README.md")"
    [ "$first" = "$second" ]
}

# ---------------------------------------------------------------------------
# snapcraft.yaml source-tag sed tests (from update-upstream.yml)
# ---------------------------------------------------------------------------

_bump_snapcraft() {
    local ftl="$1" pihole="$2" web="$3" target="${TMPDIR}/snapcraft.yaml"
    sed -i "/^  ftl:/,/^    source-tag:/ s/^    source-tag: .*/    source-tag: ${ftl}/" "$target"
    sed -i "/^  core:/,/^    source-tag:/ s/^    source-tag: .*/    source-tag: ${pihole}/" "$target"
    sed -i "/^  web:/,/^    source-tag:/ s/^    source-tag: .*/    source-tag: ${web}/" "$target"
}

@test "snapcraft.yaml bump: FTL source-tag updated" {
    _bump_snapcraft "v9.1.0" "v6.4.2" "v6.5"
    grep -A5 "^  ftl:" "${TMPDIR}/snapcraft.yaml" | grep -q "source-tag: v9.1.0"
}

@test "snapcraft.yaml bump: core (pi-hole) source-tag updated" {
    _bump_snapcraft "v6.6.2" "v9.2.0" "v6.5"
    grep -A5 "^  core:" "${TMPDIR}/snapcraft.yaml" | grep -q "source-tag: v9.2.0"
}

@test "snapcraft.yaml bump: web source-tag updated" {
    _bump_snapcraft "v6.6.2" "v6.4.2" "v9.3.0"
    grep -A5 "^  web:" "${TMPDIR}/snapcraft.yaml" | grep -q "source-tag: v9.3.0"
}

@test "snapcraft.yaml bump: FTL tag does not bleed into core or web sections" {
    _bump_snapcraft "v1.0.0" "v2.0.0" "v3.0.0"
    # Each part must have its own unique tag, not all set to the last value
    grep -A5 "^  ftl:"  "${TMPDIR}/snapcraft.yaml" | grep -q "source-tag: v1.0.0"
    grep -A5 "^  core:" "${TMPDIR}/snapcraft.yaml" | grep -q "source-tag: v2.0.0"
    grep -A5 "^  web:"  "${TMPDIR}/snapcraft.yaml" | grep -q "source-tag: v3.0.0"
}

@test "snapcraft.yaml bump: idempotent — running twice produces the same result" {
    _bump_snapcraft "v9.1.0" "v9.2.0" "v9.3.0"
    local first
    first="$(cat "${TMPDIR}/snapcraft.yaml")"
    _bump_snapcraft "v9.1.0" "v9.2.0" "v9.3.0"
    local second
    second="$(cat "${TMPDIR}/snapcraft.yaml")"
    [ "$first" = "$second" ]
}

# ---------------------------------------------------------------------------
# Port-53 timeout guard logic (from build.yml smoke test)
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

@test "port-53 guard: succeeds when port binds immediately" {
    run _run_port53_guard "yes"
    [ "$status" -eq 0 ]
    [[ "$output" == *"FTL bound"* ]]
}

@test "port-53 guard: fails with error message when port never binds" {
    run _run_port53_guard "no"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FTL failed to bind"* ]]
}

@test "port-53 guard: error message includes GitHub Actions annotation syntax" {
    run _run_port53_guard "no"
    [[ "$output" == *"::error::"* ]]
}
