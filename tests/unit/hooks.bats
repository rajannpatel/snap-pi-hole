#!/usr/bin/env bats
#
# Unit tests for snap hooks: install, configure, pre-refresh, remove.
#
# Hooks run inside snapd's confined environment with `snapctl` available.
# These tests stub `snapctl` and `pihole-FTL` to test the hook logic
# without a real snap installation.
#
# Run locally:  bats tests/unit/hooks.bats
# In CI:        see .github/workflows/build.yml (lint+unit job)

setup() {
    REPO_ROOT="$(git rev-parse --show-toplevel)"
    TEST_TMPDIR="$(mktemp -d)"

    export SNAP="${TEST_TMPDIR}/snap"
    export SNAP_DATA="${TEST_TMPDIR}/data"
    export SNAP_COMMON="${TEST_TMPDIR}/common"
    export SNAP_NAME="pihole"
    mkdir -p "${SNAP}/usr/bin" "${SNAP_DATA}" "${SNAP_COMMON}" "${SNAP}/bin"

    # Seed the mock template layout directory and versions stub file 
    # to satisfy the file copying phase of the install hook logic.
    mkdir -p "${SNAP}/opt/pihole/templates"
    cat > "${SNAP}/opt/pihole/templates/versions" << 'EOF'
CORE_VERSION=v6.4.2
CORE_BRANCH=snap
WEB_VERSION=v6.5
WEB_BRANCH=snap
FTL_VERSION=v6.6.2
FTL_BRANCH=snap
EOF

    # Stub snapctl: records calls and returns per-key values from env vars.
    # Now dynamically handles `set` and `unset` for the 'ftl' config namespace using a file.
    SNAPCTL="${TEST_TMPDIR}/snapctl"
    cat > "${SNAPCTL}" <<'STUB'
#!/bin/bash
TEST_TMPDIR="MOCK_TMPDIR"
LOG="${TEST_TMPDIR}/snapctl.log"
echo "SNAPCTL:$*" >> "$LOG"
case "$1" in
    get)
        if [ "$2" = "-d" ] && [ "$3" = "timer" ]; then
            # Defaults to empty (unset) so the configure hook's timer-rejection
            # branch is a no-op unless a test sets SNAPCTL_GET_D_TIMER.
            echo "${SNAPCTL_GET_D_TIMER:-}"
            exit 0
        fi
        if [ "$2" = "-d" ] && [ "$3" = "ftl" ]; then
            current_env="${SNAPCTL_GET_D_FTL:-{}}"
            last_env=""
            if [ -f "${TEST_TMPDIR}/last_snapctl_get_d_ftl.json" ]; then
                last_env=$(cat "${TEST_TMPDIR}/last_snapctl_get_d_ftl.json")
            fi
            if [ "$current_env" != "$last_env" ]; then
                echo "$current_env" > "${TEST_TMPDIR}/snapctl_ftl.json"
                echo "$current_env" > "${TEST_TMPDIR}/last_snapctl_get_d_ftl.json"
            fi
            if [ ! -f "${TEST_TMPDIR}/snapctl_ftl.json" ]; then
                echo "{}" > "${TEST_TMPDIR}/snapctl_ftl.json"
            fi
            cat "${TEST_TMPDIR}/snapctl_ftl.json"
            exit 0
        fi
        key="${2:-}"
        if [ "$key" = "-q" ]; then key="${3:-}"; fi
        if [ -z "$key" ]; then exit 0; fi
        var="SNAPCTL_GET_$(echo "$key" | tr '.-' '_')"
        echo "${!var:-}"
        ;;
    set)
        if [ "$2" = "ftl" ]; then
            echo "$3" > "${TEST_TMPDIR}/snapctl_ftl.json"
            echo "$3" > "${TEST_TMPDIR}/last_snapctl_get_d_ftl.json"
            exit 0
        elif [[ "$2" =~ ^ftl=(.*)$ ]]; then
            val="${BASH_REMATCH[1]}"
            echo "$val" > "${TEST_TMPDIR}/snapctl_ftl.json"
            echo "$val" > "${TEST_TMPDIR}/last_snapctl_get_d_ftl.json"
            exit 0
        fi
        if [ ! -f "${TEST_TMPDIR}/snapctl_ftl.json" ]; then
            echo "${SNAPCTL_GET_D_FTL:-{}}" > "${TEST_TMPDIR}/snapctl_ftl.json"
        fi
        arg="$2"
        if [[ "$arg" =~ ^ftl\.(.+)=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            val="${BASH_REMATCH[2]}"
            jq --arg val "$val" --arg key "$key" '
              (try ($val | fromjson) catch $val) as $parsed_val |
              setpath($key | split("."); $parsed_val)
            ' "${TEST_TMPDIR}/snapctl_ftl.json" > "${TEST_TMPDIR}/snapctl_ftl.json.tmp"
            mv "${TEST_TMPDIR}/snapctl_ftl.json.tmp" "${TEST_TMPDIR}/snapctl_ftl.json"
        fi
        ;;
    unset)
        if [ "$2" = "ftl" ]; then
            echo "{}" > "${TEST_TMPDIR}/snapctl_ftl.json"
            echo "{}" > "${TEST_TMPDIR}/last_snapctl_get_d_ftl.json"
            exit 0
        fi
        if [ ! -f "${TEST_TMPDIR}/snapctl_ftl.json" ]; then
            echo "${SNAPCTL_GET_D_FTL:-{}}" > "${TEST_TMPDIR}/snapctl_ftl.json"
        fi
        arg="$2"
        if [[ "$arg" =~ ^ftl\.(.+)$ ]]; then
            key="${BASH_REMATCH[1]}"
            jq --arg key "$key" 'delpaths([[$key | split(".")[]]])' "${TEST_TMPDIR}/snapctl_ftl.json" > "${TEST_TMPDIR}/snapctl_ftl.json.tmp"
            mv "${TEST_TMPDIR}/snapctl_ftl.json.tmp" "${TEST_TMPDIR}/snapctl_ftl.json"
        fi
        ;;
    services)
        printf 'Service         Startup  Current  Notes\n'
        printf 'pihole-ftl      enabled  %s        -\n' "${SNAPCTL_SERVICE_STATUS:-inactive}"
        ;;
    *) exit 0 ;;
esac
STUB
    sed -i "s|MOCK_TMPDIR|${TEST_TMPDIR}|g" "${SNAPCTL}"
    chmod +x "${SNAPCTL}"

    # Stub launcher-pihole: records calls, exits non-zero if LAUNCHER_PIHOLE_FAIL is 1.
    LAUNCHER_PIHOLE="${SNAP}/bin/launcher-pihole"
    cat > "${LAUNCHER_PIHOLE}" <<EOF
#!/bin/sh
echo "LAUNCHER_PIHOLE:\$*" >> "${TEST_TMPDIR}/pihole.log"
if [ "\${LAUNCHER_PIHOLE_FAIL:-}" = "1" ]; then
    exit 1
fi
exit 0
EOF
    chmod +x "${LAUNCHER_PIHOLE}"

    # Stub config-sync
    CONFIG_SYNC="${SNAP}/bin/config-sync"
    cat > "${CONFIG_SYNC}" <<EOF
#!/bin/sh
echo "CONFIG_SYNC_RUN" >> "${TEST_TMPDIR}/config_sync.log"
exit 0
EOF
    chmod +x "${CONFIG_SYNC}"

    # Stub pihole-FTL: records --config calls. Use a double-quoted heredoc so
    # TEST_TMPDIR is expanded and baked into the stub script at creation time.
    FTL="${SNAP}/usr/bin/pihole-FTL"
    cat > "${FTL}" <<EOF
#!/bin/sh
echo "FTL:\$*" >> "${TEST_TMPDIR}/ftl.log"
EOF
    chmod +x "${FTL}"

    # Inject stubs by prepending TMPDIR to PATH
    export PATH="${TEST_TMPDIR}:${PATH}"
}

teardown() {
    rm -rf "${TEST_TMPDIR}"
}

# ---------------------------------------------------------------------------
# install hook
# ---------------------------------------------------------------------------

@test "install hook creates required data directories" {
    HOOK="${TEST_TMPDIR}/install"
    cp "${REPO_ROOT}/snap/hooks/install" "${HOOK}"
    chmod +x "${HOOK}"

    run "${HOOK}"
    [ "$status" -eq 0 ]
    [ -d "${SNAP_DATA}/etc/pihole" ]
    [ -d "${SNAP_DATA}/etc/dnsmasq.d" ]
    [ -d "${SNAP_DATA}/run/pihole" ]
    [ -d "${SNAP_COMMON}/var/log/pihole" ]
    [ -f "${SNAP_DATA}/etc/pihole/versions" ]
}

@test "install hook is idempotent (safe to run twice)" {
    HOOK="${TEST_TMPDIR}/install"
    cp "${REPO_ROOT}/snap/hooks/install" "${HOOK}"
    chmod +x "${HOOK}"

    run "${HOOK}"
    [ "$status" -eq 0 ]
    run "${HOOK}"
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# pre-refresh hook
# ---------------------------------------------------------------------------

@test "pre-refresh hook always exits 0 (never blocks an upgrade)" {
    run "${REPO_ROOT}/snap/hooks/pre-refresh"
    [ "$status" -eq 0 ]
}

@test "pre-refresh hook prints a DNS hand-off notice" {
    run "${REPO_ROOT}/snap/hooks/pre-refresh"
    [[ "$output" == *"DNS"* ]]
    [[ "$output" == *"refresh-mode"* ]]
}

@test "pre-refresh hook mentions verification commands" {
    run "${REPO_ROOT}/snap/hooks/pre-refresh"
    [[ "$output" == *"snap logs"* ]]
    [[ "$output" == *"dig"* ]]
}

# ---------------------------------------------------------------------------
# remove hook
# ---------------------------------------------------------------------------

@test "remove hook does not delete the resolved dropin when it exists" {
    DROPIN="${TEST_TMPDIR}/pihole.conf"
    printf '[Resolve]\nDNSStubListener=no\n' > "${DROPIN}"

    HOOK="${TEST_TMPDIR}/remove"
    sed "s|/etc/systemd/resolved.conf.d/pihole.conf|${DROPIN}|g" \
        "${REPO_ROOT}/snap/hooks/remove" > "${HOOK}"
    chmod +x "${HOOK}"

    run "${HOOK}"
    [ "$status" -eq 0 ]
    [ -f "${DROPIN}" ]
}

@test "remove hook is silent when the dropin does not exist" {
    DROPIN="${TEST_TMPDIR}/pihole.conf"
    [ ! -f "${DROPIN}" ]  # pre-condition

    HOOK="${TEST_TMPDIR}/remove"
    sed "s|/etc/systemd/resolved.conf.d/pihole.conf|${DROPIN}|g" \
        "${REPO_ROOT}/snap/hooks/remove" > "${HOOK}"
    chmod +x "${HOOK}"

    run "${HOOK}"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "remove hook prints remediation instructions when the dropin exists" {
    DROPIN="${TEST_TMPDIR}/pihole.conf"
    printf '[Resolve]\nDNSStubListener=no\n' > "${DROPIN}"

    HOOK="${TEST_TMPDIR}/remove"
    sed "s|/etc/systemd/resolved.conf.d/pihole.conf|${DROPIN}|g" \
        "${REPO_ROOT}/snap/hooks/remove" > "${HOOK}"
    chmod +x "${HOOK}"

    run "${HOOK}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Strict snap confinement prevents the snap from modifying host systemd settings"* ]]
    [[ "$output" == *"sudo rm -f ${DROPIN}"* ]]
    [[ "$output" == *"systemctl restart systemd-resolved"* ]]
}

# ---------------------------------------------------------------------------
# configure hook
# ---------------------------------------------------------------------------

@test "configure hook calls pihole-FTL --config for a set key" {
    # Only set webserver.port via JSON
    export SNAPCTL_GET_D_FTL='{"webserver": {"port": 8080}}'
    HOOK="${TEST_TMPDIR}/configure"
    sed \
        -e "s|snapctl get|${SNAPCTL} get|g" \
        -e "s|snapctl services|${SNAPCTL} services|g" \
        -e "s|snapctl restart|${SNAPCTL} restart|g" \
        "${REPO_ROOT}/snap/hooks/configure" > "${HOOK}"
    chmod +x "${HOOK}"

    run "${HOOK}"
    [ "$status" -eq 0 ]
    grep -q "FTL:--config webserver.port 8080" "${TEST_TMPDIR}/ftl.log"
}

@test "configure hook rejects a timer.* key and points at the systemd override" {
    # A user attempting `snap set ... timer.gravity-sync.schedule=...`
    export SNAPCTL_GET_D_TIMER='{"gravity-sync":{"schedule":"mon,02:00"}}'
    export SNAPCTL_GET_D_FTL='{"webserver": {"port": 8080}}'
    HOOK="${TEST_TMPDIR}/configure"
    sed \
        -e "s|snapctl get|${SNAPCTL} get|g" \
        -e "s|snapctl services|${SNAPCTL} services|g" \
        -e "s|snapctl restart|${SNAPCTL} restart|g" \
        "${REPO_ROOT}/snap/hooks/configure" > "${HOOK}"
    chmod +x "${HOOK}"

    run "${HOOK}"
    # Non-zero exit rolls back the whole `snap set` transaction.
    [ "$status" -eq 1 ]
    # Clear, actionable guidance pointing at the real (host-side) mechanism.
    [[ "$output" == *"cannot be changed with 'snap set'"* ]]
    [[ "$output" == *"snap.${SNAP_NAME}.gravity-sync.timer.d"* ]]
    [[ "$output" == *"OnCalendar="* ]]
    # The \n in the printf command must be shown literally, not expanded.
    [[ "$output" == *'[Timer]\nOnCalendar='* ]]
    # Rejection must short-circuit before any FTL config is applied.
    [ ! -f "${TEST_TMPDIR}/ftl.log" ]
    ! grep -q "restart" "${TEST_TMPDIR}/snapctl.log" 2>/dev/null
}

@test "configure hook ignores an empty timer namespace and still applies ftl config" {
    # snapctl returns {} for the timer namespace (no keys) -> not a rejection.
    export SNAPCTL_GET_D_TIMER='{}'
    export SNAPCTL_GET_D_FTL='{"webserver": {"port": 8080}}'
    HOOK="${TEST_TMPDIR}/configure"
    sed \
        -e "s|snapctl get|${SNAPCTL} get|g" \
        -e "s|snapctl services|${SNAPCTL} services|g" \
        -e "s|snapctl restart|${SNAPCTL} restart|g" \
        "${REPO_ROOT}/snap/hooks/configure" > "${HOOK}"
    chmod +x "${HOOK}"

    run "${HOOK}"
    [ "$status" -eq 0 ]
    grep -q "FTL:--config webserver.port 8080" "${TEST_TMPDIR}/ftl.log"
}

@test "configure hook does not call pihole-FTL when no keys are set" {
    # All keys return empty
    HOOK="${TEST_TMPDIR}/configure"
    sed \
        -e "s|snapctl get|${SNAPCTL} get|g" \
        -e "s|snapctl services|${SNAPCTL} services|g" \
        -e "s|snapctl restart|${SNAPCTL} restart|g" \
        "${REPO_ROOT}/snap/hooks/configure" > "${HOOK}"
    chmod +x "${HOOK}"

    run "${HOOK}"
    [ "$status" -eq 0 ]
    [ ! -f "${TEST_TMPDIR}/ftl.log" ]
}

@test "configure hook does not restart daemon when it is not running" {
    export SNAPCTL_GET_D_FTL='{"webserver": {"port": 8080}}'
    export SNAPCTL_SERVICE_STATUS="inactive"
    HOOK="${TEST_TMPDIR}/configure"
    sed \
        -e "s|snapctl get|${SNAPCTL} get|g" \
        -e "s|snapctl services|${SNAPCTL} services|g" \
        -e "s|snapctl restart|${SNAPCTL} restart|g" \
        "${REPO_ROOT}/snap/hooks/configure" > "${HOOK}"
    chmod +x "${HOOK}"

    run "${HOOK}"
    [ "$status" -eq 0 ]
    ! grep -q "restart" "${TEST_TMPDIR}/snapctl.log" 2>/dev/null
}

@test "configure hook maps dns-port to dns.port correctly" {
    export SNAPCTL_GET_D_FTL='{"dns": {"port": 5353}}'
    HOOK="${TEST_TMPDIR}/configure"
    sed \
        -e "s|snapctl get|${SNAPCTL} get|g" \
        -e "s|snapctl services|${SNAPCTL} services|g" \
        -e "s|snapctl restart|${SNAPCTL} restart|g" \
        "${REPO_ROOT}/snap/hooks/configure" > "${HOOK}"
    chmod +x "${HOOK}"

    run "${HOOK}"
    [ "$status" -eq 0 ]
    grep -q "FTL:--config dns.port 5353" "${TEST_TMPDIR}/ftl.log"
}

@test "configure hook maps dhcp-enabled to dhcp.active correctly" {
    export SNAPCTL_GET_D_FTL='{"dhcp": {"active": true}}'
    HOOK="${TEST_TMPDIR}/configure"
    sed \
        -e "s|snapctl get|${SNAPCTL} get|g" \
        -e "s|snapctl services|${SNAPCTL} services|g" \
        -e "s|snapctl restart|${SNAPCTL} restart|g" \
        "${REPO_ROOT}/snap/hooks/configure" > "${HOOK}"
    chmod +x "${HOOK}"

    run "${HOOK}"
    [ "$status" -eq 0 ]
    grep -q "FTL:--config dhcp.active true" "${TEST_TMPDIR}/ftl.log"
}

@test "configure hook maps dns.upstreams array correctly" {
    export SNAPCTL_GET_D_FTL='{"dns": {"upstreams": ["8.8.8.8", "8.8.4.4"]}}'
    HOOK="${TEST_TMPDIR}/configure"
    sed \
        -e "s|snapctl get|${SNAPCTL} get|g" \
        -e "s|snapctl services|${SNAPCTL} services|g" \
        -e "s|snapctl restart|${SNAPCTL} restart|g" \
        "${REPO_ROOT}/snap/hooks/configure" > "${HOOK}"
    chmod +x "${HOOK}"

    run "${HOOK}"
    [ "$status" -eq 0 ]
    grep -q 'FTL:--config dns.upstreams \["8.8.8.8","8.8.4.4"\]' "${TEST_TMPDIR}/ftl.log"
}

@test "configure hook restarts daemon when it is active and a key is set" {
    export SNAPCTL_GET_D_FTL='{"webserver": {"port": 9090}}'
    export SNAPCTL_SERVICE_STATUS="active"
    HOOK="${TEST_TMPDIR}/configure"
    sed \
        -e "s|snapctl get|${SNAPCTL} get|g" \
        -e "s|snapctl services|${SNAPCTL} services|g" \
        -e "s|snapctl restart|${SNAPCTL} restart|g" \
        "${REPO_ROOT}/snap/hooks/configure" > "${HOOK}"
    chmod +x "${HOOK}"

    run "${HOOK}"
    [ "$status" -eq 0 ]
    grep -q "restart" "${TEST_TMPDIR}/snapctl.log"
}

# ---------------------------------------------------------------------------
# post-refresh hook
# ---------------------------------------------------------------------------

@test "post-refresh hook copies versions template if it exists" {
    HOOK="${TEST_TMPDIR}/post-refresh"
    cp "${REPO_ROOT}/snap/hooks/post-refresh" "${HOOK}"
    chmod +x "${HOOK}"

    # Pre-condition: create data directory and remove any existing versions file
    mkdir -p "${SNAP_DATA}/etc/pihole"
    rm -f "${SNAP_DATA}/etc/pihole/versions"

    # Create dummy configure hook to prevent failures
    cat > "${TEST_TMPDIR}/configure" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "${TEST_TMPDIR}/configure"

    # Stub dig to return success
    cat > "${TEST_TMPDIR}/dig" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "${TEST_TMPDIR}/dig"

    run "${HOOK}"
    [ "$status" -eq 0 ]
    [ -f "${SNAP_DATA}/etc/pihole/versions" ]
    grep -q "CORE_VERSION=v6.4.2" "${SNAP_DATA}/etc/pihole/versions"
}

@test "post-refresh hook handles missing versions template gracefully" {
    HOOK="${TEST_TMPDIR}/post-refresh"
    cp "${REPO_ROOT}/snap/hooks/post-refresh" "${HOOK}"
    chmod +x "${HOOK}"

    mkdir -p "${SNAP_DATA}/etc/pihole"
    rm -rf "${SNAP}/opt/pihole/templates"
    rm -f "${SNAP_DATA}/etc/pihole/versions"

    # Create dummy configure hook to prevent failures
    cat > "${TEST_TMPDIR}/configure" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "${TEST_TMPDIR}/configure"

    # Stub dig to return success
    cat > "${TEST_TMPDIR}/dig" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "${TEST_TMPDIR}/dig"

    run "${HOOK}"
    [ "$status" -eq 0 ]
    [ ! -f "${SNAP_DATA}/etc/pihole/versions" ]
}

@test "post-refresh hook fails if configure hook fails" {
    HOOK="${TEST_TMPDIR}/post-refresh"
    cp "${REPO_ROOT}/snap/hooks/post-refresh" "${HOOK}"
    chmod +x "${HOOK}"

    mkdir -p "${SNAP_DATA}/etc/pihole"

    # Create failing configure hook
    cat > "${TEST_TMPDIR}/configure" <<'EOF'
#!/bin/sh
exit 42
EOF
    chmod +x "${TEST_TMPDIR}/configure"

    run "${HOOK}"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Configuration schema migration failed"* ]]
}

@test "post-refresh hook fails if DNS validation fails with dig" {
    HOOK="${TEST_TMPDIR}/post-refresh"
    cp "${REPO_ROOT}/snap/hooks/post-refresh" "${HOOK}"
    chmod +x "${HOOK}"

    mkdir -p "${SNAP_DATA}/etc/pihole"

    # Create dummy configure hook to prevent failures
    cat > "${TEST_TMPDIR}/configure" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "${TEST_TMPDIR}/configure"

    # Stub dig to return failure
    cat > "${TEST_TMPDIR}/dig" <<'EOF'
#!/bin/sh
exit 1
EOF
    chmod +x "${TEST_TMPDIR}/dig"

    # FTL is running, so DNS validation must run (and then fail on the dig stub).
    export SNAPCTL_SERVICE_STATUS="active"

    run "${HOOK}"
    [ "$status" -eq 1 ]
    [[ "$output" == *"DNS validation failed"* ]]
}

@test "configure hook migrates dns.dnssec to dns.dnssec_enabled" {
    export SNAPCTL_GET_D_FTL='{"dns": {"dnssec": true}}'
    HOOK="${TEST_TMPDIR}/configure"
    sed \
        -e "s|snapctl get|${SNAPCTL} get|g" \
        -e "s|snapctl services|${SNAPCTL} services|g" \
        -e "s|snapctl restart|${SNAPCTL} restart|g" \
        -e "s|snapctl set|${SNAPCTL} set|g" \
        -e "s|snapctl unset|${SNAPCTL} unset|g" \
        "${REPO_ROOT}/snap/hooks/configure" > "${HOOK}"
    chmod +x "${HOOK}"

    run "${HOOK}"
    [ "$status" -eq 0 ]

    # Check that snapctl set was called for dns.dnssec_enabled and unset for dns.dnssec
    grep -q "SNAPCTL:set ftl.dns.dnssec_enabled=true" "${TEST_TMPDIR}/snapctl.log"
    grep -q "SNAPCTL:unset ftl.dns.dnssec" "${TEST_TMPDIR}/snapctl.log"

    # FTL should have been called with the migrated key
    grep -q "FTL:--config dns.dnssec_enabled true" "${TEST_TMPDIR}/ftl.log"
}

@test "post-refresh hook runs database migration check" {
    HOOK="${TEST_TMPDIR}/post-refresh"
    cp "${REPO_ROOT}/snap/hooks/post-refresh" "${HOOK}"
    chmod +x "${HOOK}"

    mkdir -p "${SNAP_DATA}/etc/pihole"

    # Create dummy configure hook to prevent failures
    cat > "${TEST_TMPDIR}/configure" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "${TEST_TMPDIR}/configure"

    # Stub dig to return success
    cat > "${TEST_TMPDIR}/dig" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "${TEST_TMPDIR}/dig"

    # Normal refresh: FTL is running, so DNS validation runs and passes.
    export SNAPCTL_SERVICE_STATUS="active"

    run "${HOOK}"
    [ "$status" -eq 0 ]
    [ -f "${TEST_TMPDIR}/pihole.log" ]
    grep -q "LAUNCHER_PIHOLE:-g" "${TEST_TMPDIR}/pihole.log"
}

@test "post-refresh hook warns but does not fail if database migration check fails" {
    HOOK="${TEST_TMPDIR}/post-refresh"
    cp "${REPO_ROOT}/snap/hooks/post-refresh" "${HOOK}"
    chmod +x "${HOOK}"

    mkdir -p "${SNAP_DATA}/etc/pihole"

    # Create dummy configure hook to prevent failures
    cat > "${TEST_TMPDIR}/configure" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "${TEST_TMPDIR}/configure"

    # Stub dig to return success
    cat > "${TEST_TMPDIR}/dig" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "${TEST_TMPDIR}/dig"

    export LAUNCHER_PIHOLE_FAIL=1
    # FTL is running; the gravity failure must stay non-fatal (exit 0) even
    # though DNS validation itself runs and passes.
    export SNAPCTL_SERVICE_STATUS="active"

    run "${HOOK}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Database migration/gravity update failed"* ]]
}

@test "post-refresh hook skips DNS validation if FTL service is disabled" {
    HOOK="${TEST_TMPDIR}/post-refresh"
    cp "${REPO_ROOT}/snap/hooks/post-refresh" "${HOOK}"
    chmod +x "${HOOK}"

    mkdir -p "${SNAP_DATA}/etc/pihole"

    # Create dummy configure hook to prevent failures
    cat > "${TEST_TMPDIR}/configure" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "${TEST_TMPDIR}/configure"

    # Overwrite the global snapctl stub to return service startup disabled
    cat > "${TEST_TMPDIR}/snapctl" <<'EOF'
#!/bin/sh
case "$1" in
    services)
        printf 'Service         Startup  Current  Notes\n'
        printf 'pihole-ftl      disabled  inactive -\n'
        ;;
    *) exit 0 ;;
esac
EOF
    chmod +x "${TEST_TMPDIR}/snapctl"

    # dig would fail if it ran; proving status 0 means validation was skipped.
    cat > "${TEST_TMPDIR}/dig" <<'EOF'
#!/bin/sh
exit 1
EOF
    chmod +x "${TEST_TMPDIR}/dig"

    run "${HOOK}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"FTL service is not running. Skipping DNS validation"* ]]
}

@test "post-refresh hook skips DNS validation when FTL is enabled but stopped" {
    # Regression guard: a service that is enabled at startup but currently
    # stopped (Startup=enabled, Current=inactive) must NOT trigger DNS
    # validation, or a deliberately-stopped FTL would fail an otherwise-healthy
    # refresh. The gate keys off the Current state, not Startup.
    HOOK="${TEST_TMPDIR}/post-refresh"
    cp "${REPO_ROOT}/snap/hooks/post-refresh" "${HOOK}"
    chmod +x "${HOOK}"

    mkdir -p "${SNAP_DATA}/etc/pihole"

    cat > "${TEST_TMPDIR}/configure" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "${TEST_TMPDIR}/configure"

    cat > "${TEST_TMPDIR}/snapctl" <<'EOF'
#!/bin/sh
case "$1" in
    services)
        printf 'Service         Startup  Current  Notes\n'
        printf 'pihole-ftl      enabled  inactive -\n'
        ;;
    *) exit 0 ;;
esac
EOF
    chmod +x "${TEST_TMPDIR}/snapctl"

    # dig fails if invoked; status 0 proves validation was skipped despite
    # the service being enabled.
    cat > "${TEST_TMPDIR}/dig" <<'EOF'
#!/bin/sh
exit 1
EOF
    chmod +x "${TEST_TMPDIR}/dig"

    run "${HOOK}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"FTL service is not running. Skipping DNS validation"* ]]
}

@test "configure hook skips calling pihole-FTL --config when the value matches pihole.toml" {
    # Prepare the config file with a pre-existing value
    mkdir -p "${SNAP_DATA}/etc/pihole"
    cat > "${SNAP_DATA}/etc/pihole/pihole.toml" << 'EOF'
[webserver]
port = 8080
EOF

    # Set snapctl setting to match
    export SNAPCTL_GET_D_FTL='{"webserver": {"port": 8080}}'
    
    HOOK="${TEST_TMPDIR}/configure"
    sed \
        -e "s|snapctl get|${SNAPCTL} get|g" \
        -e "s|snapctl services|${SNAPCTL} services|g" \
        -e "s|snapctl restart|${SNAPCTL} restart|g" \
        "${REPO_ROOT}/snap/hooks/configure" > "${HOOK}"
    chmod +x "${HOOK}"

    run "${HOOK}"
    [ "$status" -eq 0 ]
    
    # Verify that FTL was NOT called
    [ ! -f "${TEST_TMPDIR}/ftl.log" ]
}

@test "configure hook calls pihole-FTL --config when the value does not match pihole.toml" {
    # Prepare the config file with a different pre-existing value
    mkdir -p "${SNAP_DATA}/etc/pihole"
    cat > "${SNAP_DATA}/etc/pihole/pihole.toml" << 'EOF'
[webserver]
port = 80
EOF

    # Set snapctl setting to a different value
    export SNAPCTL_GET_D_FTL='{"webserver": {"port": 8080}}'
    
    HOOK="${TEST_TMPDIR}/configure"
    sed \
        -e "s|snapctl get|${SNAPCTL} get|g" \
        -e "s|snapctl services|${SNAPCTL} services|g" \
        -e "s|snapctl restart|${SNAPCTL} restart|g" \
        "${REPO_ROOT}/snap/hooks/configure" > "${HOOK}"
    chmod +x "${HOOK}"

    run "${HOOK}"
    [ "$status" -eq 0 ]
    
    # Verify that FTL WAS called
    grep -q "FTL:--config webserver.port 8080" "${TEST_TMPDIR}/ftl.log"
}