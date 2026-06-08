#!/usr/bin/env bats
#
# Unit tests for snap/local/testing/snap-check.sh

setup() {
    REPO_ROOT="$(git rev-parse --show-toplevel)"
    TMPDIR="$(mktemp -d)"
    export SNAP_DATA="${TMPDIR}/data"
    export SNAP_COMMON="${TMPDIR}/common"
    export SNAP_NAME="pihole"
    export SNAP="${TMPDIR}/snap"
    
    mkdir -p "${SNAP_DATA}" "${SNAP_COMMON}" "${SNAP}/bin"

    # Create mock snapctl script to monitor/control plug and service states
    export MOCK_BIN="${TMPDIR}/bin"
    mkdir -p "${MOCK_BIN}"
    export PATH="${MOCK_BIN}:${PATH}"

    cat > "${MOCK_BIN}/snapctl" <<'EOF'
#!/bin/bash
if [ "$1" = "is-connected" ]; then
    plug_var=$(echo "$2" | tr '-' '_')
    var_name="MOCK_DISCONNECT_${plug_var}"
    if [ "${!var_name:-}" = "true" ]; then
        exit 1
    fi
    exit 0
elif [ "$1" = "services" ]; then
    if [ "${MOCK_FTL_ACTIVE:-true}" = "true" ]; then
        echo "pihole-ftl active"
    else
        echo "pihole-ftl inactive"
    fi
fi
exit 0
EOF
    chmod +x "${MOCK_BIN}/snapctl"

    # Default mock env vars
    export MOCK_TCP_CHECK="true"
    export MOCK_TCP_PORTS_IN_USE=""
    export MOCK_UDP_PORTS_IN_USE=""
    export MOCK_FTL_ACTIVE="true"

    export CHECK_SCRIPT="${REPO_ROOT}/snap/local/testing/snap-check.sh"
}

teardown() {
    rm -rf "${TMPDIR}"
}

@test "snap-check exits 0 when FTL is active and plugs are connected" {
    run "${CHECK_SCRIPT}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"--- INTERFACES ---"* ]]
    [[ "$output" == *"network-bind (Connected)"* ]]
    [[ "$output" == *"[OK] pihole-FTL is active. Port conflict checks skipped."* ]]
    [[ "$output" == *"Diagnostics complete."* ]]
}

@test "snap-check exits 1 when a required plug is disconnected" {
    export MOCK_DISCONNECT_network_bind="true"
    run "${CHECK_SCRIPT}"
    [ "$status" -eq 1 ]
    [[ "$output" == *"[FAIL] network-bind (Disconnected)"* ]]
}

@test "snap-check defaults remediation snap commands to the store snap name" {
    unset SNAP_NAME
    export MOCK_DISCONNECT_network_bind="true"
    run "${CHECK_SCRIPT}"
    [ "$status" -eq 1 ]
    [[ "$output" == *"sudo snap connect pihole-by-rajannpatel:network-bind"* ]]
}

@test "snap-check exits 0 (success) when an optional plug is disconnected" {
    export MOCK_DISCONNECT_system_observe="true"
    run "${CHECK_SCRIPT}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[INFO] system-observe (Disconnected - optional:"* ]]
}

@test "snap-check exits 2 when port 53 conflict is detected" {
    export MOCK_FTL_ACTIVE="false"
    export MOCK_TCP_PORTS_IN_USE="127.0.0.53:53"
    run "${CHECK_SCRIPT}"
    [ "$status" -eq 2 ]
    [[ "$output" == *"[FAIL] Port 53 (TCP) - systemd-resolved conflict"* ]]
}

@test "snap-check exits 2 when port 80 conflict is detected" {
    export MOCK_FTL_ACTIVE="false"
    export MOCK_TCP_PORTS_IN_USE="0.0.0.0:80"
    run "${CHECK_SCRIPT}"
    [ "$status" -eq 2 ]
    [[ "$output" == *"[FAIL] Port 80 (HTTP) - Another web server is binding port 80"* ]]
}

@test "snap-check exits 0 when DHCP port is in use (only prints WARN)" {
    export MOCK_FTL_ACTIVE="false"
    export MOCK_UDP_PORTS_IN_USE="0043"
    run "${CHECK_SCRIPT}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[WARN] Port 67/546 (DHCP) is in use"* ]]
}
