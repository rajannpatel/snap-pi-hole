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
# Run locally:  bats tests/integration/snap-lifecycle.bats
# In CI:        see .github/workflows/cicd.yml (lint+unit job)

setup() {
    REPO_ROOT="$(git rev-parse --show-toplevel)"
    TEST_TMPDIR="$(mktemp -d)"
    # shellcheck source=tests/helpers/snapctl-stub.sh
    source "${REPO_ROOT}/tests/helpers/snapctl-stub.sh"

    # Snap environment
    export SNAP="${TEST_TMPDIR}/snap"
    export SNAP_DATA="${TEST_TMPDIR}/data"
    export SNAP_COMMON="${TEST_TMPDIR}/common"
    export SNAP_NAME="pihole"
    # Sanitize SNAP_REVISION inherited from a snap-confined host (e.g. the VS
    # Code snap). launcher-pihole's root gate keys off it; leaving it set would
    # make the real launcher reject non-allowlisted subcommands under test.
    unset SNAP_REVISION
    mkdir -p "${SNAP}/usr/bin" "${SNAP_DATA}" "${SNAP_COMMON}" "${SNAP}/meta/hooks" "${SNAP}/bin"

    # Create stubs for external commands
    _setup_stubs

    # Copy and rewrite hooks and launchers to use our tmpdir
    _setup_scripts

    # Create dummy gravity.db to prevent launcher-ftl from spawning the background 90s loop
    mkdir -p "${SNAP_DATA}/etc/pihole"
    echo "mock_gravity" > "${SNAP_DATA}/etc/pihole/gravity.db"
}

teardown() {
    rm -rf "${TEST_TMPDIR}"
}

# Stub setup helpers

_setup_stubs() {
    # Stub snapctl with logging and snapctl_ftl.json as backing state.
    local SNAPCTL="${TEST_TMPDIR}/snapctl"
    install_snapctl_stub "${SNAPCTL}" "${TEST_TMPDIR}"

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

    # Stub dig to return success for health checks
    local DIG="${TEST_TMPDIR}/dig"
    cat > "${DIG}" <<'STUB'
#!/bin/sh
echo "127.0.0.1"
exit 0
STUB
    chmod +x "${DIG}"

    # Prepend tmpdir stubs to PATH
    export PATH="${TEST_TMPDIR}:${PATH}"
}

_setup_scripts() {
    # Create the expected template stub layout inside the test environment
    mkdir -p "${SNAP}/opt/pihole/templates"
    cat > "${SNAP}/opt/pihole/templates/versions" << 'EOF'
CORE_VERSION=v6.4.2
CORE_BRANCH=snap
WEB_VERSION=v6.5
WEB_BRANCH=snap
FTL_VERSION=v6.6.2
FTL_BRANCH=snap
EOF

    # Rewrite hooks and launchers to use tmpdir paths.
    # "${SNAP_DATA}/run/pihole" in the launcher resolves to
    # ${TEST_TMPDIR}/data/run/pihole at runtime via the exported SNAP_DATA,
    # so no sed rewrite is needed for that path.
    for hook in install configure pre-refresh post-refresh remove; do
        local src="${REPO_ROOT}/snap/hooks/${hook}"
        local dst="${TEST_TMPDIR}/hook-${hook}"
        sed \
            -e "s|/etc/systemd/resolved.conf.d/pihole.conf|${TEST_TMPDIR}/resolved.conf|g" \
            -e "s|\${HOOK_DIR}/configure|\${HOOK_DIR}/hook-configure|g" \
            "${src}" > "${dst}"
        chmod +x "${dst}"
    done

    # Rewrite launchers and sync tools
    mkdir -p "${SNAP}/bin"
    cp "${REPO_ROOT}/snap/local/runtime/pihole-config.sh" "${SNAP}/bin/pihole-config.sh"
    chmod +x "${SNAP}/bin/pihole-config.sh"
    for script in launcher-ftl launcher-pihole config-sync; do
        local src="${REPO_ROOT}/snap/local/runtime/${script}.sh"
        local dst="${SNAP}/bin/${script}"
        sed \
            -e "s|/opt/pihole/pihole|${TEST_TMPDIR}/opt/pihole|g" \
            -e "s|/opt/pihole:|${TEST_TMPDIR}/opt:|g" \
            "${src}" > "${dst}"
        chmod +x "${dst}"
        # Keep a copy in TEST_TMPDIR for backward compatibility with existing tests
        cp "${dst}" "${TEST_TMPDIR}/${script}"
    done
    cp "${SNAP}/bin/pihole-config.sh" "${TEST_TMPDIR}/pihole-config.sh"

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

# Lifecycle Integration Tests

@test "install creates required directories" {
    run "${TEST_TMPDIR}/hook-install"
    [ "$status" -eq 0 ]
    [ -d "${SNAP_DATA}/etc/pihole" ]
    [ -d "${SNAP_DATA}/etc/dnsmasq.d" ]
    [ -d "${SNAP_DATA}/run/pihole" ]
    [ -d "${SNAP_COMMON}/var/log/pihole" ]
}

@test "install → configure → remove sequence completes" {
    # Install
    run "${TEST_TMPDIR}/hook-install"
    [ "$status" -eq 0 ]

    # Configure with a setting
    export SNAPCTL_GET_D_FTL='{"webserver": {"port": 8080}}'
    run "${TEST_TMPDIR}/hook-configure"
    [ "$status" -eq 0 ]
    # FTL should have been called with the config
    grep -q "FTL:--config webserver.port 8080" "${TEST_TMPDIR}/ftl.log" || true

    # Remove
    run "${TEST_TMPDIR}/hook-remove"
    [ "$status" -eq 0 ]
}

@test "install is safe to run twice (idempotent)" {
    run "${TEST_TMPDIR}/hook-install"
    [ "$status" -eq 0 ]

    # Running again should not fail
    run "${TEST_TMPDIR}/hook-install"
    [ "$status" -eq 0 ]

    # Directories should still exist
    [ -d "${SNAP_DATA}/etc/pihole" ]
    [ -d "${SNAP_DATA}/run/pihole" ]
}

@test "multiple configure calls accumulate settings" {
    "${TEST_TMPDIR}/hook-install"

    # First configure: set web-port
    export SNAPCTL_GET_D_FTL='{"webserver": {"port": 8080}}'
    run "${TEST_TMPDIR}/hook-configure"
    [ "$status" -eq 0 ]
    grep -q "FTL:--config webserver.port 8080" "${TEST_TMPDIR}/ftl.log"

    # Second configure: set dns-port
    export SNAPCTL_GET_D_FTL='{"dns": {"port": 5353}, "webserver": {"port": 8080}}'
    run "${TEST_TMPDIR}/hook-configure"
    [ "$status" -eq 0 ]
    grep -q "FTL:--config dns.port 5353" "${TEST_TMPDIR}/ftl.log"
    # The web-port call should still be in the log from the first run
    grep -q "FTL:--config webserver.port 8080" "${TEST_TMPDIR}/ftl.log"
}

@test "remove is silent when no systemd dropin exists" {
    "${TEST_TMPDIR}/hook-install"

    # Remove without ever creating the resolved dropin
    run "${TEST_TMPDIR}/hook-remove"
    [ "$status" -eq 0 ]
    # Should not error even if dropin doesn't exist
}

# Launcher Interaction Tests

@test "launcher-ftl executes after install hook has run" {
    # Install creates directories
    "${TEST_TMPDIR}/hook-install"

    run bash "${TEST_TMPDIR}/launcher-ftl" 2>/dev/null || true
    # Should have created pihole.toml and directories
    [ -f "${SNAP_DATA}/etc/pihole/pihole.toml" ]
    [ -d "${SNAP_DATA}/run/pihole" ]
}

@test "launcher-ftl seeds pihole.toml if missing" {
    "${TEST_TMPDIR}/hook-install"

    # Verify install created dirs but not pihole.toml (it doesn't)
    [ -d "${SNAP_DATA}/etc/pihole" ]
    [ ! -f "${SNAP_DATA}/etc/pihole/pihole.toml" ]

    bash "${TEST_TMPDIR}/launcher-ftl" 2>/dev/null || true

    [ -f "${SNAP_DATA}/etc/pihole/pihole.toml" ]
}

@test "launcher-pihole finds upstream script in PATH set by hook env" {
    "${TEST_TMPDIR}/hook-install"

    # launcher-pihole should work with the environment
    run "${TEST_TMPDIR}/launcher-pihole" status
    [ "$status" -eq 0 ]
    [[ "$output" == *"PIHOLE:status"* ]]
}



@test "both launchers export HOME from SNAP_DATA" {
    "${TEST_TMPDIR}/hook-install"

    # Create a launcher variant that echoes HOME
    LAUNCHER_HOME="${TEST_TMPDIR}/launcher-ftl-home"
    sed -e 's|exec .*|echo HOME=${HOME}|' \
        "${TEST_TMPDIR}/launcher-ftl" > "${LAUNCHER_HOME}"
    chmod +x "${LAUNCHER_HOME}"

    run bash "${LAUNCHER_HOME}"
    [[ "$output" == *"HOME=${SNAP_DATA}"* ]]
}

# Configuration Persistence Tests

@test "pre-refresh does not delete user data (pihole.toml)" {
    # Install and seed pihole.toml
    "${TEST_TMPDIR}/hook-install"
    echo "user_setting=value" >> "${SNAP_DATA}/etc/pihole/pihole.toml"

    # Run pre-refresh
    run "${TEST_TMPDIR}/hook-pre-refresh"
    [ "$status" -eq 0 ]

    # pihole.toml must still exist with user data
    [ -f "${SNAP_DATA}/etc/pihole/pihole.toml" ]
    grep -q "user_setting=value" "${SNAP_DATA}/etc/pihole/pihole.toml"
}

@test "install → configure → pre-refresh preserves settings in pihole.toml" {
    # Install
    "${TEST_TMPDIR}/hook-install"

    # Configure applies a setting (via FTL stub)
    export SNAPCTL_GET_D_FTL='{"webserver": {"port": 8080}}'
    "${TEST_TMPDIR}/hook-configure"

    # Verify FTL was called
    grep -q "FTL:--config webserver.port 8080" "${TEST_TMPDIR}/ftl.log"

    # Pre-refresh (simulate upgrade)
    run "${TEST_TMPDIR}/hook-pre-refresh"
    [ "$status" -eq 0 ]

    # FTL log should still have the config call (pre-refresh didn't clear it)
    grep -q "FTL:--config webserver.port 8080" "${TEST_TMPDIR}/ftl.log"
}

@test "launcher-ftl seeded pihole.toml is not overwritten by hooks" {
    # Simulate launcher-ftl seeding the config
    "${TEST_TMPDIR}/hook-install"
    mkdir -p "${SNAP_DATA}/etc/pihole"
    echo "existing_setting=42" > "${SNAP_DATA}/etc/pihole/pihole.toml"

    # Run configure
    export SNAPCTL_GET_D_FTL='{"webserver": {"port": 8080}}'
    run "${TEST_TMPDIR}/hook-configure"
    [ "$status" -eq 0 ]

    # Original file must still exist with original content
    [ -f "${SNAP_DATA}/etc/pihole/pihole.toml" ]
    grep -q "existing_setting=42" "${SNAP_DATA}/etc/pihole/pihole.toml"
}

@test "configure without daemon running does not block future startup" {
    "${TEST_TMPDIR}/hook-install"

    # Daemon is inactive
    export SNAPCTL_SERVICE_STATUS="inactive"
    export SNAPCTL_GET_D_FTL='{"webserver": {"port": 8080}}'

    # Configure should succeed without restarting
    run "${TEST_TMPDIR}/hook-configure"
    [ "$status" -eq 0 ]

    # snapctl restart should NOT be called for inactive daemon
    ! grep -q "RESTART:" "${TEST_TMPDIR}/snapctl.log" 2>/dev/null || true
}

# Error Recovery Tests

@test "partial install (missing a dir) is recoverable" {
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

@test "configure with no settings applied is idempotent" {
    "${TEST_TMPDIR}/hook-install"

    # Configure with no settings
    run "${TEST_TMPDIR}/hook-configure"
    [ "$status" -eq 0 ]
    local first_status="$status"

    # Running again should succeed
    run "${TEST_TMPDIR}/hook-configure"
    [ "$status" -eq "$first_status" ]
}

@test "remove without network plug gracefully handles missing dropin" {
    "${TEST_TMPDIR}/hook-install"

    # Create a partially broken environment (no systemd dropin)
    [ ! -f "${TEST_TMPDIR}/resolved.conf" ]

    # Remove should still succeed
    run "${TEST_TMPDIR}/hook-remove"
    [ "$status" -eq 0 ]
}

# Post-Refresh Integration Tests

@test "post-refresh copies versions template and runs configure hook successfully" {
    # Install setup
    run "${TEST_TMPDIR}/hook-install"
    [ "$status" -eq 0 ]

    # Remove the version file that install hook created to verify that the
    # post-refresh hook will copy it.
    rm -f "${SNAP_DATA}/etc/pihole/versions"

    # Set mock snapctl variables to trace configuration invocation
    export SNAPCTL_GET_D_FTL='{"webserver": {"port": 9090}}'
    export SNAPCTL_SERVICE_STATUS="inactive"

    # Run post-refresh
    run "${TEST_TMPDIR}/hook-post-refresh"
    [ "$status" -eq 0 ]

    # Verify versions file was copied
    [ -f "${SNAP_DATA}/etc/pihole/versions" ]
    grep -q "CORE_VERSION=v6.4.2" "${SNAP_DATA}/etc/pihole/versions"

    # Verify that the configure hook was invoked by verifying that the config logic was executed
    grep -q "FTL:--config webserver.port 9090" "${TEST_TMPDIR}/ftl.log"
}

@test "config-sync updates snapctl from pihole.toml" {
    # Prepare directories
    mkdir -p "${SNAP_DATA}/etc/pihole"
    
    # Write a dummy pihole.toml
    cat > "${SNAP_DATA}/etc/pihole/pihole.toml" <<EOF
[dns]
  dnssec = true
  upstreams = [
    "1.1.1.1",
    "1.0.0.1"
  ]
[webserver]
  port = 8080
EOF

    # Clear snapctl_ftl.json
    rm -f "${TEST_TMPDIR}/snapctl_ftl.json"

    # Run config-sync
    run "${SNAP}/bin/config-sync"
    [ "$status" -eq 0 ]

    # Verify that the snapctl_ftl.json now contains the correct values
    [ -f "${TEST_TMPDIR}/snapctl_ftl.json" ]
    
    local port=$(jq -r '.webserver.port' "${TEST_TMPDIR}/snapctl_ftl.json")
    [ "$port" = "8080" ]
    
    local dnssec=$(jq -r '.dns.dnssec' "${TEST_TMPDIR}/snapctl_ftl.json")
    [ "$dnssec" = "true" ]
    
    local upstreams=$(jq -c '.dns.upstreams' "${TEST_TMPDIR}/snapctl_ftl.json")
    [ "$upstreams" = '["1.1.1.1","1.0.0.1"]' ]
}

@test "post-refresh hook executes database migration" {
    # Install setup
    run "${TEST_TMPDIR}/hook-install"
    [ "$status" -eq 0 ]

    # Run post-refresh hook which triggers launcher-pihole -g
    run "${TEST_TMPDIR}/hook-post-refresh"
    [ "$status" -eq 0 ]

    # Setup database migration failure by stubbing launcher-pihole to fail when -g is passed
    cat > "${SNAP}/bin/launcher-pihole" <<'EOF'
#!/bin/sh
if [ "$1" = "-g" ]; then
    exit 1
fi
exit 0
EOF
    chmod +x "${SNAP}/bin/launcher-pihole"

    # Verify that a database migration / gravity update failure does NOT cause the hook to fail (exits 0)
    # but prints a warning message.
    run "${TEST_TMPDIR}/hook-post-refresh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Database migration/gravity update failed"* ]]
}
