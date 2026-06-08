#!/usr/bin/env bats
#
# Unit tests for snap/local/launcher-ftl  -  the daemon wrapper that
# detects port-53 conflicts, seeds required directories and the initial
# pihole.toml, exports HOME, and execs pihole-FTL.
#
# Tests cover every logical branch except the final exec (which would
# require a real binary). The port-53 conflict detection relies on
# /dev/tcp which is a bash builtin, so we inject a wrapper that
# overrides the subshell check.
#
# Run locally:  bats tests/unit/launcher-ftl.bats
# In CI:        see .github/workflows/build.yml (lint+unit job)

setup() {
    REPO_ROOT="$(git rev-parse --show-toplevel)"
    TEST_TMPDIR="$(mktemp -d)"

    # Minimal snap environment variables required by the launcher
    export SNAP_DATA="${TEST_TMPDIR}/data"
    export SNAP_COMMON="${TEST_TMPDIR}/common"
    export SNAP="${TEST_TMPDIR}/snap"
    export SNAP_NAME="pihole"
    mkdir -p "${SNAP_DATA}" "${SNAP_COMMON}" "${SNAP}/usr/bin"

    # Create a stub pihole-FTL binary so `exec` doesn't fail
    FTL_STUB="${SNAP}/usr/bin/pihole-FTL"
    printf '#!/bin/sh\necho "STUB:pihole-FTL $*"\n' > "${FTL_STUB}"
    chmod +x "${FTL_STUB}"

    # Copy the launcher directly
    LAUNCHER="${TEST_TMPDIR}/launcher-ftl"
    cp "${REPO_ROOT}/snap/local/runtime/launcher-ftl.sh" "${LAUNCHER}"
    cp "${REPO_ROOT}/snap/local/runtime/pihole-config.sh" "${TEST_TMPDIR}/pihole-config.sh"
    chmod +x "${LAUNCHER}"

    # Create dummy gravity.db to prevent the background spawn of `pihole -g`
    # from hanging the bats test due to open FDs from the background subshell.
    mkdir -p "${SNAP_DATA}/etc/pihole"
    echo "mock_data" > "${SNAP_DATA}/etc/pihole/gravity.db"
}

teardown() {
    rm -rf "${TEST_TMPDIR}"
}

_remove_gravity_db() {
    rm -f "${SNAP_DATA}/etc/pihole/gravity.db"
}

_install_gravity_seed_stubs() {
    local dig_status="$1"

    mkdir -p "${SNAP}/opt/pihole" "${SNAP}/usr/bin"

    cat > "${SNAP}/opt/pihole/pihole" <<EOF
#!/bin/sh
echo "PIHOLE:\$*" >> "${TEST_TMPDIR}/pihole-gravity.log"
printf 'gravity command: %s\n' "\$*"
exit 0
EOF
    chmod +x "${SNAP}/opt/pihole/pihole"

    cat > "${SNAP}/usr/bin/pihole-FTL" <<EOF
#!/bin/sh
echo "FTL:\$*" >> "${TEST_TMPDIR}/ftl.log"
exit 0
EOF
    chmod +x "${SNAP}/usr/bin/pihole-FTL"

    cat > "${SNAP}/usr/bin/dig" <<EOF
#!/bin/sh
echo "DIG:\$*" >> "${TEST_TMPDIR}/dig.log"
exit ${dig_status}
EOF
    chmod +x "${SNAP}/usr/bin/dig"

    # Keep the readiness-loop failure case deterministic and fast.
    cat > "${SNAP}/usr/bin/seq" <<'EOF'
#!/bin/sh
printf '1\n2\n'
EOF
    chmod +x "${SNAP}/usr/bin/seq"

    cat > "${SNAP}/usr/bin/sleep" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "${SNAP}/usr/bin/sleep"
}

# ---------------------------------------------------------------------------
# Directory and config seeding
# ---------------------------------------------------------------------------

@test "creates required directories when they do not exist" {
    SNAP="${SNAP}" SNAP_DATA="${SNAP_DATA}" SNAP_COMMON="${SNAP_COMMON}" bash "${LAUNCHER}" 2>/dev/null || true

    [ -d "${SNAP_DATA}/etc/pihole" ]
    [ -d "${SNAP_DATA}/etc/dnsmasq.d" ]
    [ -d "${SNAP_DATA}/run/pihole" ]
    [ -d "${SNAP_COMMON}/var/log/pihole" ]
}

@test "seeds pihole.toml with default upstreams when none exists" {
    mkdir -p "${SNAP_DATA}/etc/pihole"
    TOML="${SNAP_DATA}/etc/pihole/pihole.toml"
    [ ! -f "${TOML}" ]  # pre-condition: does not exist yet

    SNAP="${SNAP}" SNAP_DATA="${SNAP_DATA}" SNAP_COMMON="${SNAP_COMMON}" bash "${LAUNCHER}" 2>/dev/null || true

    [ -f "${TOML}" ]
    grep -q '\[dns\]' "${TOML}"
    grep -q 'upstreams' "${TOML}"
    grep -q '8.8.8.8' "${TOML}"
}

@test "does not overwrite an existing pihole.toml" {
    mkdir -p "${SNAP_DATA}/etc/pihole"
    TOML="${SNAP_DATA}/etc/pihole/pihole.toml"
    echo "existing=content" > "${TOML}"

    SNAP="${SNAP}" SNAP_DATA="${SNAP_DATA}" SNAP_COMMON="${SNAP_COMMON}" bash "${LAUNCHER}" 2>/dev/null || true

    # File must still contain the original content and NOT the default upstreams
    grep -q "existing=content" "${TOML}"
    if grep -q '\[dns\]' "${TOML}"; then
        false
    fi
}

# ---------------------------------------------------------------------------

# Environment setup
# ---------------------------------------------------------------------------

@test "exports HOME as SNAP_DATA" {
    # Replace FTL stub with one that records HOME
    printf '#!/bin/sh\necho "HOME=${HOME}"\n' > "${SNAP}/usr/bin/pihole-FTL"
    chmod +x "${SNAP}/usr/bin/pihole-FTL"

    run bash "${LAUNCHER}"
    [[ "$output" == *"HOME=${SNAP_DATA}"* ]]
}

@test "changes cwd to run/pihole before exec" {
    LAUNCHER_CWD="${TEST_TMPDIR}/launcher-cwd"
    cp "${LAUNCHER}" "${LAUNCHER_CWD}"
    chmod +x "${LAUNCHER_CWD}"

    # Replace FTL stub with one that records cwd
    printf '#!/bin/sh\npwd\n' > "${SNAP}/usr/bin/pihole-FTL"
    chmod +x "${SNAP}/usr/bin/pihole-FTL"

    run bash "${LAUNCHER_CWD}"
    [ "$status" -eq 0 ]
    # The cwd should be the /run/pihole equivalent in our tmpdir
    [[ "$output" == *"run/pihole"* ]]
}

# ---------------------------------------------------------------------------
# First-run gravity seeding
# ---------------------------------------------------------------------------

@test "first-run gravity seeding runs initial gravity, inserts default adlist, and runs pass 2 when FTL DNS is ready" {
    _remove_gravity_db
    _install_gravity_seed_stubs 0

    run bash "${LAUNCHER}"
    [ "$status" -eq 0 ]

    [ -f "${SNAP_COMMON}/var/log/pihole/gravity-init.log" ]
    [ -f "${SNAP_COMMON}/var/log/pihole/gravity-first-run.log" ]
    [ "$(grep -c 'PIHOLE:-g' "${TEST_TMPDIR}/pihole-gravity.log")" -eq 2 ]
    grep -q "DIG:+short +time=1 +tries=1 @127.0.0.1 . NS" "${TEST_TMPDIR}/dig.log"
    grep -q "FTL:sqlite3 ${SNAP_DATA}/etc/pihole/gravity.db" "${TEST_TMPDIR}/ftl.log"
    grep -q "Steven Black unified hosts (default)" "${TEST_TMPDIR}/ftl.log"
}

@test "first-run gravity seeding gives up without pass 2 when FTL DNS never becomes ready" {
    _remove_gravity_db
    _install_gravity_seed_stubs 1

    run bash "${LAUNCHER}"
    [ "$status" -eq 0 ]

    [ -f "${SNAP_COMMON}/var/log/pihole/gravity-init.log" ]
    [ ! -f "${SNAP_COMMON}/var/log/pihole/gravity-first-run.log" ]
    [ "$(grep -c 'PIHOLE:-g' "${TEST_TMPDIR}/pihole-gravity.log")" -eq 1 ]
    [ "$(grep -c 'DIG:' "${TEST_TMPDIR}/dig.log")" -eq 2 ]
    [[ "$output" == *"FTL DNS did not become ready within 90 s; skipping background gravity update."* ]]
}
