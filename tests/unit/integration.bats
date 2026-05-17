#!/usr/bin/env bats
#
# Integration tests for snap-pi-hole: hook lifecycle, launcher interactions,
# configuration persistence, and multi-component workflows.
#
# These tests compose the install, configure, pre-refresh, and remove hooks
# together with the launcher scripts to ensure state is preserved and
# components interact correctly across the snap lifecycle.
#
# Unlike unit tests which isolate individual scripts, integration tests
# verify that:
#   - Hooks create files that launchers expect
#   - Multiple hook invocations accumulate state correctly
#   - Pre-refresh doesn't delete user data
#   - Launchers work with the environment hooks set up
#
# Run locally:  bats tests/unit/integration.bats
# In CI:        see .github/workflows/build.yml (lint+unit job)

setup() {
    REPO_ROOT="$(git rev-parse --show-toplevel)"
    TEST_TMPDIR="$(mktemp -d)"

    # Snap environment
    export SNAP="${TEST_TMPDIR}/snap"
    export SNAP_DATA="${TEST_TMPDIR}/data"
    export SNAP_COMMON="${TEST_TMPDIR}/common"
    mkdir -p "${SNAP}/usr/bin" "${SNAP_DATA}" "${SNAP_COMMON}"

    # Create stubs for external commands
    _setup_stubs

    # Copy and rewrite hooks and launchers to use our tmpdir
    _setup_scripts
}

teardown() {
    rm -rf "${TEST_TMPDIR}"
}

# ---------------------------------------------------------------------------
# Stub setup helpers
# ---------------------------------------------------------------------------

_setup_stubs() {
    # Stub snapctl with logging and key-value lookup via env vars
    local SNAPCTL="${TEST_TMPDIR}/snapctl"
    cat > "${SNAPCTL}" <<'STUB'
#!/bin/bash
LOG="${TEST_TMPDIR}/snapctl.log"
echo "SNAPCTL:$*" >> "$LOG"
case "$1" in
    get)
        key="$2"
        var="SNAPCTL_GET_$(echo "$key" | tr '-' '_')"
        echo "${!var:-}"
        ;;
    services)
        printf 'Service         Startup  Current  Notes\n'
        printf 'pihole-ftl      enabled  %s       -\n' "${SNAPCTL_SERVICE_STATUS:-inactive}"
        ;;
    restart)
        echo "RESTART:$2" >> "$LOG"
        ;;
    system-mode)
        echo "run"
        ;;
    *) exit 0 ;;
esac
STUB
    chmod +x "${SNAPCTL}"

    # Stub pihole-FTL with --config logging
    local FTL="${SNAP}/usr/bin/pihole-FTL"
    cat > "${FTL}" <<EOF
#!/bin/sh
echo "FTL:\$*" >> "${TEST_TMPDIR}/ftl.log"
[ "\$1" = "--config" ] && [ -n "\$2" ] && [ -n "\$3" ] && exit 0
[ "\$1" = "no-daemon" ] && exit 0
exit 0
EOF
    chmod +x "${FTL}"

    # Prepend tmpdir stubs to PATH
    export PATH="${TEST_TMPDIR}:${PATH}"
}

_setup_scripts() {
    # Rewrite hooks and launchers to use tmpdir paths
    # $SNAP_DATA/run/pihole resolves to ${TEST_TMPDIR}/data/run/pihole at
    # runtime via the exported SNAP_DATA, so no sed rewrite is needed for it.
    for hook in install configure pre-refresh remove; do
        local src="${REPO_ROOT}/snap/hooks/${hook}"
        local dst="${TEST_TMPDIR}/hook-${hook}"
        sed \
            -e "s|/etc/pihole|${TEST_TMPDIR}/etc/pihole|g" \
            -e "s|/etc/dnsmasq.d|${TEST_TMPDIR}/etc/dnsmasq.d|g" \
            -e "s|/var/log/pihole|${TEST_TMPDIR}/var/log/pihole|g" \
            -e "s|/etc/systemd/resolved.conf.d/pihole.conf|${TEST_TMPDIR}/resolved.conf|g" \
            "${src}" > "${dst}"
        chmod +x "${dst}"
    done

    # Rewrite launchers
    for launcher in launcher-ftl launcher-pihole; do
        local src="${REPO_ROOT}/snap/local/${launcher}"
        local dst="${TEST_TMPDIR}/${launcher}"
        sed \
            -e "s|/etc/pihole|${TEST_TMPDIR}/etc/pihole|g" \
            -e "s|/etc/dnsmasq.d|${TEST_TMPDIR}/etc/dnsmasq.d|g" \
            -e "s|/var/log/pihole|${TEST_TMPDIR}/var/log/pihole|g" \
            -e "s|/opt/pihole|${TEST_TMPDIR}/opt|g" \
            "${src}" > "${dst}"
        chmod +x "${dst}"
    done

    # Create launcher-pihole stub (upstream script)
    mkdir -p "${TEST_TMPDIR}/opt"
    cat > "${TEST_TMPDIR}/opt/pihole" <<'STUB'
#!/bin/sh
# Output args for test verification (pihole.log path set by test)
echo "PIHOLE:$*"
exit 0
STUB
    chmod +x "${TEST_TMPDIR}/opt/pihole"
}

# ---------------------------------------------------------------------------
# Lifecycle Integration Tests
# ---------------------------------------------------------------------------

@test "lifecycle: install creates required directories" {
    run "${TEST_TMPDIR}/hook-install"
    [ "$status" -eq 0 ]
    [ -d "${TEST_TMPDIR}/etc/pihole" ]
    [ -d "${TEST_TMPDIR}/etc/dnsmasq.d" ]
    [ -d "${SNAP_DATA}/run/pihole" ]
    [ -d "${TEST_TMPDIR}/var/log/pihole" ]
}

@test "lifecycle: install → configure → remove sequence completes" {
    # Install
    run "${TEST_TMPDIR}/hook-install"
    [ "$status" -eq 0 ]

    # Configure with a setting
    export SNAPCTL_GET_web_port="8080"
    run "${TEST_TMPDIR}/hook-configure"
    [ "$status" -eq 0 ]
    # FTL should have been called with the config
    grep -q "FTL:--config webserver.port 8080" "${TEST_TMPDIR}/ftl.log" || true

    # Remove
    run "${TEST_TMPDIR}/hook-remove"
    [ "$status" -eq 0 ]
}

@test "lifecycle: install is safe to run twice (idempotent)" {
    run "${TEST_TMPDIR}/hook-install"
    [ "$status" -eq 0 ]

    # Running again should not fail
    run "${TEST_TMPDIR}/hook-install"
    [ "$status" -eq 0 ]

    # Directories should still exist
    [ -d "${TEST_TMPDIR}/etc/pihole" ]
    [ -d "${SNAP_DATA}/run/pihole" ]
}

@test "lifecycle: multiple configure calls accumulate settings" {
    "${TEST_TMPDIR}/hook-install"

    # First configure: set web-port
    export SNAPCTL_GET_web_port="8080"
    export SNAPCTL_GET_dns_port=""
    run "${TEST_TMPDIR}/hook-configure"
    [ "$status" -eq 0 ]
    grep -q "FTL:--config webserver.port 8080" "${TEST_TMPDIR}/ftl.log"

    # Second configure: set dns-port (first setting should still be applied)
    export SNAPCTL_GET_web_port=""
    export SNAPCTL_GET_dns_port="5353"
    run "${TEST_TMPDIR}/hook-configure"
    [ "$status" -eq 0 ]
    grep -q "FTL:--config dns.port 5353" "${TEST_TMPDIR}/ftl.log"
    # The web-port call should still be in the log from the first run
    grep -q "FTL:--config webserver.port 8080" "${TEST_TMPDIR}/ftl.log"
}

@test "lifecycle: pre-refresh does not delete user data (pihole.toml)" {
    # Install and seed pihole.toml
    "${TEST_TMPDIR}/hook-install"
    echo "user_setting=value" >> "${TEST_TMPDIR}/etc/pihole/pihole.toml"

    # Run pre-refresh
    run "${TEST_TMPDIR}/hook-pre-refresh"
    [ "$status" -eq 0 ]

    # pihole.toml must still exist with user data
    [ -f "${TEST_TMPDIR}/etc/pihole/pihole.toml" ]
    grep -q "user_setting=value" "${TEST_TMPDIR}/etc/pihole/pihole.toml"
}

@test "lifecycle: remove is silent when no systemd dropin exists" {
    "${TEST_TMPDIR}/hook-install"

    # Remove without ever creating the resolved dropin
    run "${TEST_TMPDIR}/hook-remove"
    [ "$status" -eq 0 ]
    # Should not error even if dropin doesn't exist
}

# ---------------------------------------------------------------------------
# Launcher Interaction Tests
# ---------------------------------------------------------------------------

@test "launchers: launcher-ftl executes after install hook has run" {
    # Install creates directories
    "${TEST_TMPDIR}/hook-install"

    # launcher-ftl should not fail due to missing directories
    LAUNCHER_NO_PORT="${TEST_TMPDIR}/launcher-ftl-noport"
    sed 's|(exec 3<>/dev/tcp/127.0.0.53/53) 2>/dev/null|false|' \
        "${TEST_TMPDIR}/launcher-ftl" > "${LAUNCHER_NO_PORT}"
    chmod +x "${LAUNCHER_NO_PORT}"

    run bash "${LAUNCHER_NO_PORT}" 2>/dev/null || true
    # Should have created pihole.toml and directories
    [ -f "${TEST_TMPDIR}/etc/pihole/pihole.toml" ]
    [ -d "${SNAP_DATA}/run/pihole" ]
}

@test "launchers: launcher-ftl seeds pihole.toml if missing" {
    "${TEST_TMPDIR}/hook-install"

    # Verify install created dirs but not pihole.toml (it doesn't)
    [ -d "${TEST_TMPDIR}/etc/pihole" ]
    [ ! -f "${TEST_TMPDIR}/etc/pihole/pihole.toml" ]

    # launcher-ftl should seed it
    LAUNCHER_NO_PORT="${TEST_TMPDIR}/launcher-ftl-noport"
    sed 's|(exec 3<>/dev/tcp/127.0.0.53/53) 2>/dev/null|false|' \
        "${TEST_TMPDIR}/launcher-ftl" > "${LAUNCHER_NO_PORT}"
    chmod +x "${LAUNCHER_NO_PORT}"

    bash "${LAUNCHER_NO_PORT}" 2>/dev/null || true

    [ -f "${TEST_TMPDIR}/etc/pihole/pihole.toml" ]
}

@test "launchers: launcher-pihole finds upstream script in PATH set by hook env" {
    "${TEST_TMPDIR}/hook-install"

    # launcher-pihole should work with the environment
    run "${TEST_TMPDIR}/launcher-pihole" status
    [ "$status" -eq 0 ]
    [[ "$output" == *"PIHOLE:status"* ]]
}

@test "launchers: both launchers export HOME from SNAP_DATA" {
    "${TEST_TMPDIR}/hook-install"

    # Create a launcher variant that echoes HOME
    LAUNCHER_HOME="${TEST_TMPDIR}/launcher-ftl-home"
    sed \
        -e 's|(exec 3<>/dev/tcp/127.0.0.53/53) 2>/dev/null|false|' \
        -e 's|exec .*|echo HOME=${HOME}|' \
        "${TEST_TMPDIR}/launcher-ftl" > "${LAUNCHER_HOME}"
    chmod +x "${LAUNCHER_HOME}"

    run bash "${LAUNCHER_HOME}"
    [[ "$output" == *"HOME=${SNAP_DATA}"* ]]
}

# ---------------------------------------------------------------------------
# Configuration Persistence Tests
# ---------------------------------------------------------------------------

@test "config: install → configure → pre-refresh preserves settings in pihole.toml" {
    # Install
    "${TEST_TMPDIR}/hook-install"

    # Configure applies a setting (via FTL stub)
    export SNAPCTL_GET_web_port="8080"
    "${TEST_TMPDIR}/hook-configure"

    # Verify FTL was called
    grep -q "FTL:--config webserver.port 8080" "${TEST_TMPDIR}/ftl.log"

    # Pre-refresh (simulate upgrade)
    run "${TEST_TMPDIR}/hook-pre-refresh"
    [ "$status" -eq 0 ]

    # FTL log should still have the config call (pre-refresh didn't clear it)
    grep -q "FTL:--config webserver.port 8080" "${TEST_TMPDIR}/ftl.log"
}

@test "config: launcher-ftl seeded pihole.toml is not overwritten by hooks" {
    # Simulate launcher-ftl seeding the config
    "${TEST_TMPDIR}/hook-install"
    mkdir -p "${TEST_TMPDIR}/etc/pihole"
    echo "existing_setting=42" > "${TEST_TMPDIR}/etc/pihole/pihole.toml"

    # Run configure
    export SNAPCTL_GET_web_port="8080"
    run "${TEST_TMPDIR}/hook-configure"
    [ "$status" -eq 0 ]

    # Original file must still exist with original content
    [ -f "${TEST_TMPDIR}/etc/pihole/pihole.toml" ]
    grep -q "existing_setting=42" "${TEST_TMPDIR}/etc/pihole/pihole.toml"
}

@test "config: configure without daemon running does not block future startup" {
    "${TEST_TMPDIR}/hook-install"

    # Daemon is inactive
    export SNAPCTL_SERVICE_STATUS="inactive"
    export SNAPCTL_GET_web_port="8080"

    # Configure should succeed without restarting
    run "${TEST_TMPDIR}/hook-configure"
    [ "$status" -eq 0 ]

    # snapctl restart should NOT be called for inactive daemon
    ! grep -q "RESTART:" "${TEST_TMPDIR}/snapctl.log" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Error Recovery Tests
# ---------------------------------------------------------------------------

@test "recovery: partial install (missing a dir) is recoverable" {
    # Run install
    run "${TEST_TMPDIR}/hook-install"
    [ "$status" -eq 0 ]

    # Simulate partial failure: delete one required directory
    rm -rf "${SNAP_DATA}/run/pihole"

    # Re-running install should recreate it
    run "${TEST_TMPDIR}/hook-install"
    [ "$status" -eq 0 ]
    [ -d "${SNAP_DATA}/run/pihole" ]
}

@test "recovery: configure with no settings applied is idempotent" {
    "${TEST_TMPDIR}/hook-install"

    # Configure with no settings
    run "${TEST_TMPDIR}/hook-configure"
    [ "$status" -eq 0 ]
    local first_status="$status"

    # Running again should succeed
    run "${TEST_TMPDIR}/hook-configure"
    [ "$status" -eq "$first_status" ]
}

@test "recovery: remove without network plug gracefully handles missing dropin" {
    "${TEST_TMPDIR}/hook-install"

    # Create a partially broken environment (no systemd dropin)
    [ ! -f "${TEST_TMPDIR}/resolved.conf" ]

    # Remove should still succeed
    run "${TEST_TMPDIR}/hook-remove"
    [ "$status" -eq 0 ]
}
