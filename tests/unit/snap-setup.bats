#!/usr/bin/env bats
#
# Unit tests for snap/local/testing/snap-setup.sh

setup() {
    REPO_ROOT="$(git rev-parse --show-toplevel)"
    TMPDIR="$(mktemp -d)"
    export SNAP_DATA="${TMPDIR}/data"
    export SNAP_COMMON="${TMPDIR}/common"
    export SNAP_NAME="pihole"
    export SNAP="${TMPDIR}/snap"
    
    mkdir -p "${SNAP_DATA}/etc/pihole"
    mkdir -p "${SNAP_COMMON}"
    mkdir -p "${SNAP}/bin"

    # Create mock snapctl script to monitor interactions
    export MOCK_BIN="${TMPDIR}/bin"
    mkdir -p "${MOCK_BIN}"
    export PATH="${MOCK_BIN}:${PATH}"

    # Set up snapctl log
    export SNAPCTL_LOG="${TMPDIR}/snapctl_log"
    touch "${SNAPCTL_LOG}"

    cat > "${MOCK_BIN}/snapctl" <<'EOF'
#!/bin/bash
echo "$*" >> "${SNAPCTL_LOG}"
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

    # Set default setup environment
    export NON_INTERACTIVE="true"
    export MOCK_ROOT_CHECK="true"
    export MOCK_TCP_CHECK="true"
    export MOCK_TCP_PORTS_IN_USE=""
    
    export SETUP_SCRIPT="${REPO_ROOT}/snap/local/testing/snap-setup.sh"
}

teardown() {
    rm -rf "${TMPDIR}"
}

# Root privilege gate

@test "snap-setup rejects non-root execution" {
    export MOCK_ROOT_CHECK="false"
    run "${SETUP_SCRIPT}"
    [ "$status" -eq 1 ]
    [[ "$output" == *"must be run with root privileges"* ]]
}

# Prerequisite checks

@test "snap-setup warns when alias 'pihole' is not enabled" {
    export MOCK_FTL_ACTIVE="true"
    export MOCK_ALIAS_CHECK="false"
    run "${SETUP_SCRIPT}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Command alias 'pihole' has not been enabled on your host."* ]]
    [[ "$output" == *"sudo snap alias "* ]]
}

@test "snap-setup does not warn when alias 'pihole' is enabled" {
    export MOCK_FTL_ACTIVE="true"
    export MOCK_ALIAS_CHECK="true"
    run "${SETUP_SCRIPT}"
    [ "$status" -eq 0 ]
    [[ "$output" != *"Command alias 'pihole' has not been enabled on your host."* ]]
}

@test "snap-setup reports OK when FTL is running and ports/plugs are connected" {
    export MOCK_FTL_ACTIVE="true"
    run "${SETUP_SCRIPT}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"pihole-FTL service is currently active"* ]]
    [[ "$output" == *"Interface plug 'network-bind' is connected"* ]]
}

@test "snap-setup detects port 53 conflict and prints systemd-resolved solution" {
    export MOCK_FTL_ACTIVE="false"
    export MOCK_TCP_PORTS_IN_USE="127.0.0.53:53"
    run "${SETUP_SCRIPT}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Port 53 (TCP) conflict detected"* ]]
    [[ "$output" == *"printf '[Resolve]\\nDNS=127.0.0.1\\nDNSStubListener=no\\n'"* ]]
}

@test "snap-setup detects generic port 53 conflict and warns user" {
    export MOCK_FTL_ACTIVE="false"
    export MOCK_TCP_PORTS_IN_USE="127.0.0.1:53"
    run "${SETUP_SCRIPT}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Another process is binding port 53"* ]]
    [[ "$output" == *"sudo ss -tulpn | grep :53"* ]]
}

@test "snap-setup detects disconnected plugs and prints connection instructions" {
    export MOCK_DISCONNECT_network_bind="true"
    export MOCK_DISCONNECT_network_observe="true"
    export MOCK_FTL_ACTIVE="true"
    run "${SETUP_SCRIPT}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Interface plug 'network-bind' is disconnected (REQUIRED)"* ]]
    [[ "$output" == *"sudo snap connect pihole:network-bind"* ]]
}

@test "snap-setup handles disconnected optional plugs as INFO and does not fail" {
    export MOCK_DISCONNECT_system_observe="true"
    export MOCK_FTL_ACTIVE="true"
    run "${SETUP_SCRIPT}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[INFO] Interface plug 'system-observe' is disconnected (optional"* ]]
    [[ "$output" != *"Do you want to exit the wizard"* ]]
}

# Upstream DNS configuration

@test "snap-setup configures preset upstream DNS (Cloudflare default)" {
    export MOCK_DNS_CHOICE="1"
    run "${SETUP_SCRIPT}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Applying upstream DNS: [\"1.1.1.1\",\"1.0.0.1\"]"* ]]
    run grep -q "set ftl.dns.upstreams=\[\"1.1.1.1\",\"1.0.0.1\"\]" "${SNAPCTL_LOG}"
    [ "$status" -eq 0 ]
}

@test "snap-setup configures Quad9 preset DNS" {
    export MOCK_DNS_CHOICE="2"
    run "${SETUP_SCRIPT}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Applying upstream DNS: [\"9.9.9.9\",\"149.112.112.112\"]"* ]]
    run grep -q "set ftl.dns.upstreams=\[\"9.9.9.9\",\"149.112.112.112\"\]" "${SNAPCTL_LOG}"
    [ "$status" -eq 0 ]
}

@test "snap-setup configures custom upstream DNS array" {
    export MOCK_DNS_CHOICE="5"
    export MOCK_CUSTOM_DNS='["8.8.8.8","4.2.2.2"]'
    run "${SETUP_SCRIPT}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Applying upstream DNS: [\"8.8.8.8\",\"4.2.2.2\"]"* ]]
    run grep -q "set ftl.dns.upstreams=\[\"8.8.8.8\",\"4.2.2.2\"\]" "${SNAPCTL_LOG}"
    [ "$status" -eq 0 ]
}

# Security / Password configuration

@test "snap-setup updates password when requested" {
    export MOCK_SET_PASSWORD="y"
    run "${SETUP_SCRIPT}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Setting mock password..."* ]]
    [[ "$output" == *"Web Admin password updated"* ]]
    run grep -q "password = \"mocked_password_hash\"" "${SNAP_DATA}/etc/pihole/pihole.toml"
    [ "$status" -eq 0 ]
}

# Service management

@test "snap-setup enables and starts FTL if chosen when stopped" {
    export MOCK_FTL_ACTIVE="false"
    export MOCK_START_FTL="y"
    run "${SETUP_SCRIPT}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Enabling and starting pihole-ftl service"* ]]
    run grep -q "start --enable pihole.pihole-ftl" "${SNAPCTL_LOG}"
    [ "$status" -eq 0 ]
}

# Interactive Fail/Exit Prompts

@test "snap-setup prompts and exits immediately on FAIL when user accepts (Y)" {
    export MOCK_FTL_ACTIVE="false"
    export MOCK_TCP_PORTS_IN_USE="127.0.0.1:53"
    export MOCK_ALIAS_CHECK="false"
    unset NON_INTERACTIVE
    run bash -c "echo 'y' | ${SETUP_SCRIPT}"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Do you want to exit the wizard and run these commands? (Y/n)"* ]]
    [[ "$output" == *"Aborting setup"* ]]
    [[ "$output" == *"sudo pihole.pihole -r"* ]]
}

@test "snap-setup prompts, exits on FAIL, and advises sudo pihole -r when alias is enabled" {
    export MOCK_FTL_ACTIVE="false"
    export MOCK_TCP_PORTS_IN_USE="127.0.0.1:53"
    export MOCK_ALIAS_CHECK="true"
    unset NON_INTERACTIVE
    run bash -c "echo 'y' | ${SETUP_SCRIPT}"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Do you want to exit the wizard and run these commands? (Y/n)"* ]]
    [[ "$output" == *"Aborting setup"* ]]
    [[ "$output" == *"sudo pihole -r"* ]]
}

@test "snap-setup prompts and continues on FAIL when user declines (n)" {
    export MOCK_FTL_ACTIVE="false"
    export MOCK_TCP_PORTS_IN_USE="127.0.0.1:53"
    unset NON_INTERACTIVE
    run bash -c "printf 'n\n1\nn\nn\n' | ${SETUP_SCRIPT}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Do you want to exit the wizard and run these commands? (Y/n)"* ]]
    [[ "$output" == *"Continuing setup anyway..."* ]]
    [[ "$output" == *"Step 2: Upstream DNS Configuration"* ]]
}

# Wizard completion

@test "snap-setup prints web browser administration advice on successful completion" {
    export MOCK_FTL_ACTIVE="true"
    export MOCK_DNS_CHOICE="1"
    run "${SETUP_SCRIPT}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"in a web browser, go to http://<Pi-hole-IP>/admin"* ]]
    [[ "$output" == *"Detected local IP(s):"* ]]
}
