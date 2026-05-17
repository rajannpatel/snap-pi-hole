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
    mkdir -p "${SNAP}/usr/bin" "${SNAP_DATA}" "${SNAP_COMMON}"

    # Stub snapctl: records calls and returns per-key values from env vars.
    # e.g. SNAPCTL_GET_web_port=8080 will be returned for `snapctl get web-port`
    # (hyphens in key names are replaced with underscores for env var lookup).
    SNAPCTL="${TEST_TMPDIR}/snapctl"
    cat > "${SNAPCTL}" <<STUB
#!/bin/bash
LOG="${TEST_TMPDIR}/snapctl.log"
echo "SNAPCTL:\$*" >> "\$LOG"
case "\$1" in
    get)
        key="\$2"
        var="SNAPCTL_GET_\$(echo "\$key" | tr '-' '_')"
        echo "\${!var:-}"
        ;;
    services)
        printf 'Service         Startup  Current  Notes\n'
        printf 'pihole-ftl      enabled  %s       -\n' "\${SNAPCTL_SERVICE_STATUS:-inactive}"
        ;;
    *) exit 0 ;;
esac
STUB
    chmod +x "${SNAPCTL}"

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

@test "install hook creates all required data directories" {
    # Rewrite hook paths to use TMPDIR so we don't touch real /etc
    HOOK="${TEST_TMPDIR}/install"
    sed \
        -e "s|/etc/pihole|${TEST_TMPDIR}/etc/pihole|g" \
        -e "s|/etc/dnsmasq.d|${TEST_TMPDIR}/etc/dnsmasq.d|g" \
        -e "s|/run/pihole|${TEST_TMPDIR}/run/pihole|g" \
        -e "s|/var/log/pihole|${TEST_TMPDIR}/var/log/pihole|g" \
        "${REPO_ROOT}/snap/hooks/install" > "${HOOK}"
    chmod +x "${HOOK}"

    run "${HOOK}"
    [ "$status" -eq 0 ]
    [ -d "${TEST_TMPDIR}/etc/pihole" ]
    [ -d "${TEST_TMPDIR}/etc/dnsmasq.d" ]
    [ -d "${TEST_TMPDIR}/run/pihole" ]
    [ -d "${TEST_TMPDIR}/var/log/pihole" ]
}

@test "install hook is idempotent (safe to run twice)" {
    HOOK="${TEST_TMPDIR}/install"
    sed \
        -e "s|/etc/pihole|${TEST_TMPDIR}/etc/pihole|g" \
        -e "s|/etc/dnsmasq.d|${TEST_TMPDIR}/etc/dnsmasq.d|g" \
        -e "s|/run/pihole|${TEST_TMPDIR}/run/pihole|g" \
        -e "s|/var/log/pihole|${TEST_TMPDIR}/var/log/pihole|g" \
        "${REPO_ROOT}/snap/hooks/install" > "${HOOK}"
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

@test "remove hook deletes the resolved dropin when it exists" {
    DROPIN="${TEST_TMPDIR}/pihole.conf"
    printf '[Resolve]\nDNSStubListener=no\n' > "${DROPIN}"

    HOOK="${TEST_TMPDIR}/remove"
    sed "s|/etc/systemd/resolved.conf.d/pihole.conf|${DROPIN}|g" \
        "${REPO_ROOT}/snap/hooks/remove" > "${HOOK}"
    chmod +x "${HOOK}"

    run "${HOOK}"
    [ "$status" -eq 0 ]
    [ ! -f "${DROPIN}" ]
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
}

@test "remove hook prints remediation instructions after cleanup" {
    DROPIN="${TEST_TMPDIR}/pihole.conf"
    printf '[Resolve]\nDNSStubListener=no\n' > "${DROPIN}"

    HOOK="${TEST_TMPDIR}/remove"
    sed "s|/etc/systemd/resolved.conf.d/pihole.conf|${DROPIN}|g" \
        "${REPO_ROOT}/snap/hooks/remove" > "${HOOK}"
    chmod +x "${HOOK}"

    run "${HOOK}"
    [[ "$output" == *"systemctl restart systemd-resolved"* ]]
}

# ---------------------------------------------------------------------------
# configure hook
# ---------------------------------------------------------------------------

@test "configure hook calls pihole-FTL --config for a set key" {
    # Only set web-port; all other keys return empty from the stub
    export SNAPCTL_GET_web_port="8080"
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
    export SNAPCTL_GET_web_port="8080"
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
    export SNAPCTL_GET_dns_port="5353"
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
    export SNAPCTL_GET_dhcp_enabled="true"
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

@test "configure hook restarts daemon when it is active and a key is set" {
    export SNAPCTL_GET_web_port="9090"
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
