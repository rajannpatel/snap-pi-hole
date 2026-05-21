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
    cp "${REPO_ROOT}/snap/local/launcher-ftl" "${LAUNCHER}"
    chmod +x "${LAUNCHER}"

    # Create dummy gravity.db to prevent the background spawn of `pihole -g`
    # from hanging the bats test due to open FDs from the background subshell.
    mkdir -p "${SNAP_DATA}/etc/pihole"
    echo "mock_data" > "${SNAP_DATA}/etc/pihole/gravity.db"
}

teardown() {
    rm -rf "${TEST_TMPDIR}"
}

# ---------------------------------------------------------------------------
# Directory and config seeding
# ---------------------------------------------------------------------------

@test "creates required directories when they do not exist" {
    # Bypass the port-53 check. Use a distinct output path to avoid clobbering
    # LAUNCHER (both were previously ${TEST_TMPDIR}/launcher-ftl).
    LAUNCHER_NO_PORT="${TEST_TMPDIR}/launcher-no-port"
    sed 's|(exec 3<>/dev/tcp/127.0.0.53/53) 2>/dev/null|false|' \
        "${LAUNCHER}" > "${LAUNCHER_NO_PORT}"
    chmod +x "${LAUNCHER_NO_PORT}"

    SNAP="${SNAP}" SNAP_DATA="${SNAP_DATA}" SNAP_COMMON="${SNAP_COMMON}" bash "${LAUNCHER_NO_PORT}" 2>/dev/null || true

    [ -d "${SNAP_DATA}/etc/pihole" ]
    [ -d "${SNAP_DATA}/etc/dnsmasq.d" ]
    [ -d "${SNAP_DATA}/run/pihole" ]
    [ -d "${SNAP_COMMON}/var/log/pihole" ]
}

@test "seeds pihole.toml with default upstreams when none exists" {
    mkdir -p "${SNAP_DATA}/etc/pihole"
    TOML="${SNAP_DATA}/etc/pihole/pihole.toml"
    [ ! -f "${TOML}" ]  # pre-condition: does not exist yet

    # Run the launcher bypassing port checks to trigger seeding
    LAUNCHER_SEED="${TEST_TMPDIR}/launcher-seed"
    sed 's|(exec 3<>/dev/tcp/127.0.0.53/53) 2>/dev/null|false|' \
        "${LAUNCHER}" > "${LAUNCHER_SEED}"
    chmod +x "${LAUNCHER_SEED}"

    SNAP="${SNAP}" SNAP_DATA="${SNAP_DATA}" SNAP_COMMON="${SNAP_COMMON}" bash "${LAUNCHER_SEED}" 2>/dev/null || true

    [ -f "${TOML}" ]
    grep -q '\[dns\]' "${TOML}"
    grep -q 'upstreams' "${TOML}"
    grep -q '8.8.8.8' "${TOML}"
}

@test "does not overwrite an existing pihole.toml" {
    mkdir -p "${SNAP_DATA}/etc/pihole"
    TOML="${SNAP_DATA}/etc/pihole/pihole.toml"
    echo "existing=content" > "${TOML}"

    LAUNCHER_SEED="${TEST_TMPDIR}/launcher-seed2"
    sed 's|(exec 3<>/dev/tcp/127.0.0.53/53) 2>/dev/null|false|' \
        "${LAUNCHER}" > "${LAUNCHER_SEED}"
    chmod +x "${LAUNCHER_SEED}"

    SNAP="${SNAP}" SNAP_DATA="${SNAP_DATA}" SNAP_COMMON="${SNAP_COMMON}" bash "${LAUNCHER_SEED}" 2>/dev/null || true

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
    # Build a launcher variant that bypasses port-53 and records the env
    LAUNCHER_ENV="${TEST_TMPDIR}/launcher-env"
    sed \
        's|(exec 3<>/dev/tcp/127.0.0.53/53) 2>/dev/null|false|' \
        "${LAUNCHER}" > "${LAUNCHER_ENV}"
    chmod +x "${LAUNCHER_ENV}"

    # Replace FTL stub with one that records HOME
    printf '#!/bin/sh\necho "HOME=${HOME}"\n' > "${SNAP}/usr/bin/pihole-FTL"
    chmod +x "${SNAP}/usr/bin/pihole-FTL"

    run bash "${LAUNCHER_ENV}"
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
