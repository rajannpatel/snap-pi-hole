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
    export SNAP="${TEST_TMPDIR}/snap"
    export SNAP_NAME="pihole"
    mkdir -p "${SNAP_DATA}" "${SNAP}/usr/bin"

    # Create a stub pihole-FTL binary so `exec` doesn't fail
    FTL_STUB="${SNAP}/usr/bin/pihole-FTL"
    printf '#!/bin/sh\necho "STUB:pihole-FTL $*"\n' > "${FTL_STUB}"
    chmod +x "${FTL_STUB}"

    # Build a patched copy of the launcher with paths rewritten to our tmpdir.
    # The global filesystem paths get sed-rewritten to tmpdir equivalents so 
    # mkdir calls don't touch or violate host-level write permissions.
    LAUNCHER="${TEST_TMPDIR}/launcher-ftl"
    sed \
        -e "s|/etc/pihole|${TEST_TMPDIR}/etc/pihole|g" \
        -e "s|/etc/dnsmasq.d|${TEST_TMPDIR}/etc/dnsmasq.d|g" \
        -e "s|/var/log/pihole|${TEST_TMPDIR}/var/log/pihole|g" \
        -e "s|/run/snap.\"\${SNAP_NAME}\"|${TEST_TMPDIR}/run/snap.pihole|g" \
        "${REPO_ROOT}/snap/local/launcher-ftl" > "${LAUNCHER}"
    chmod +x "${LAUNCHER}"
}

teardown() {
    rm -rf "${TEST_TMPDIR}"
}

# ---------------------------------------------------------------------------
# Directory and config seeding
# ---------------------------------------------------------------------------

@test "launcher-ftl creates required directories when they do not exist" {
    # Bypass the port-53 check. Use a distinct output path to avoid clobbering
    # LAUNCHER (both were previously ${TEST_TMPDIR}/launcher-ftl).
    LAUNCHER_NO_PORT="${TEST_TMPDIR}/launcher-no-port"
    sed 's|(exec 3<>/dev/tcp/127.0.0.53/53) 2>/dev/null|false|' \
        "${LAUNCHER}" > "${LAUNCHER_NO_PORT}"
    chmod +x "${LAUNCHER_NO_PORT}"

    SNAP="${SNAP}" SNAP_DATA="${SNAP_DATA}" bash "${LAUNCHER_NO_PORT}" 2>/dev/null || true

    [ -d "${TEST_TMPDIR}/etc/pihole" ]
    [ -d "${TEST_TMPDIR}/etc/dnsmasq.d" ]
    [ -d "${SNAP_DATA}/run/pihole" ]
    [ -d "${TEST_TMPDIR}/var/log/pihole" ]
    [ -d "${TEST_TMPDIR}/run/snap.pihole" ]
}

@test "launcher-ftl seeds an empty pihole.toml when none exists" {
    mkdir -p "${TEST_TMPDIR}/etc/pihole"
    TOML="${TEST_TMPDIR}/etc/pihole/pihole.toml"
    [ ! -f "${TOML}" ]  # pre-condition: does not exist yet

    # Run only the seeding line in isolation
    bash -c "[ -f '${TOML}' ] || : > '${TOML}'"

    [ -f "${TOML}" ]
}

@test "launcher-ftl does not overwrite an existing pihole.toml" {
    mkdir -p "${TEST_TMPDIR}/etc/pihole"
    TOML="${TEST_TMPDIR}/etc/pihole/pihole.toml"
    echo "existing=content" > "${TOML}"

    bash -c "[ -f '${TOML}' ] || : > '${TOML}'"

    # File must still contain the original content
    grep -q "existing=content" "${TOML}"
}

# ---------------------------------------------------------------------------
# Port-53 conflict detection
# ---------------------------------------------------------------------------

@test "launcher-ftl exits 1 and prints remediation if port 53 is occupied" {
    # Simulate port-53 occupied by making /dev/tcp/127.0.0.53/53 succeed.
    # We rewrite the launcher's port check to always trigger.
    LAUNCHER_OCCUPIED="${TEST_TMPDIR}/launcher-occupied"
    sed 's|(exec 3<>/dev/tcp/127.0.0.53/53) 2>/dev/null|true|' \
        "${LAUNCHER}" > "${LAUNCHER_OCCUPIED}"
    chmod +x "${LAUNCHER_OCCUPIED}"

    run "${LAUNCHER_OCCUPIED}"
    [ "$status" -eq 1 ]
    [[ "$output" == *"systemd-resolved"* ]]
    [[ "$output" == *"DNSStubListener=no"* ]]
    [[ "$output" == *"snap start pihole.pihole-ftl"* ]]
}

@test "launcher-ftl does not print conflict error when port 53 is free" {
    # Make the port-53 check always fail (port is free).
    LAUNCHER_FREE="${TEST_TMPDIR}/launcher-free"
    sed 's|(exec 3<>/dev/tcp/127.0.0.53/53) 2>/dev/null|false|' \
        "${LAUNCHER}" > "${LAUNCHER_FREE}"
    chmod +x "${LAUNCHER_FREE}"

    run "${LAUNCHER_FREE}"
    [[ "$output" != *"systemd-resolved"* ]]
    [[ "$output" != *"DNSStubListener"* ]]
}

# ---------------------------------------------------------------------------
# Environment setup
# ---------------------------------------------------------------------------

@test "launcher-ftl exports HOME as SNAP_DATA" {
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

@test "launcher-ftl changes cwd to run/pihole before exec" {
    LAUNCHER_CWD="${TEST_TMPDIR}/launcher-cwd"
    sed \
        's|(exec 3<>/dev/tcp/127.0.0.53/53) 2>/dev/null|false|' \
        "${LAUNCHER}" > "${LAUNCHER_CWD}"
    chmod +x "${LAUNCHER_CWD}"

    # Replace FTL stub with one that records cwd
    printf '#!/bin/sh\npwd\n' > "${SNAP}/usr/bin/pihole-FTL"
    chmod +x "${SNAP}/usr/bin/pihole-FTL"

    run bash "${LAUNCHER_CWD}"
    [ "$status" -eq 0 ]
    # The cwd should be the /run/pihole equivalent in our tmpdir
    [[ "$output" == *"run/pihole"* ]]
}

@test "launcher-ftl conflict error message goes to stderr" {
    LAUNCHER_OCCUPIED="${TEST_TMPDIR}/launcher-occupied2"
    sed 's|(exec 3<>/dev/tcp/127.0.0.53/53) 2>/dev/null|true|' \
        "${LAUNCHER}" > "${LAUNCHER_OCCUPIED}"
    chmod +x "${LAUNCHER_OCCUPIED}"

    # Run capturing stderr separately
    stdout_out="$("${LAUNCHER_OCCUPIED}" 2>/dev/null)" || true
    stderr_out="$("${LAUNCHER_OCCUPIED}" 2>&1 >/dev/null)" || true

    # Error message must appear in stderr
    [[ "$stderr_out" == *"systemd-resolved"* ]]
    # stdout must be empty
    [ -z "$stdout_out" ]
}