#!/bin/bash
# A system configuration and repair wizard for Pi-hole strictly confined within a snap.
# Exposed via `pihole -r` or `pihole repair`.

set -eu

# Enable color if running in a TTY and NO_COLOR is not set
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    NC='\033[0m'
    BOLD='\033[1m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    CYAN=''
    NC=''
    BOLD=''
fi

# Prepend snap staged paths to PATH to ensure we use our staged GNU coreutils, jq, etc.
export PATH="${SNAP:-}/usr/sbin:${SNAP:-}/usr/bin:${SNAP:-}/sbin:${SNAP:-}/bin:${PATH:-}"

echo "PI-HOLE SNAP CONFIGURATION WIZARD"
echo ""
echo "This wizard will guide you through setting up or repairing"
echo "your Pi-hole snap installation."
echo ""

# Check root privileges
if [ "${EUID}" -ne 0 ] && [ "${MOCK_ROOT_CHECK:-}" != "true" ]; then
    echo "Error: This configuration wizard must be run with root privileges (sudo)." >&2
    echo "Please run: sudo pihole -r" >&2
    exit 1
fi

# 1. PREREQUISITES CHECK (Port 53 & Plugs)
echo "Step 1: System Prerequisite Checks"
echo ""

ALIAS_SET=true
# Check if the command alias exists on the host
if [ ! -e "/snap/bin/pihole" ] && [ "${MOCK_ALIAS_CHECK:-}" != "true" ]; then
    ALIAS_SET=false
    printf "${YELLOW}[WARN]${NC} Command alias 'pihole' has not been enabled on your host.\n"
    printf "Remediation: Run the following command on your host to enable the 'pihole' alias:\n\n"
    printf "${BOLD}${CYAN}sudo snap alias ${SNAP_NAME:-pihole-by-rajannpatel}.pihole pihole${NC}\n\n"
fi

if [ "$ALIAS_SET" = "true" ]; then
    REENTER_CMD="sudo pihole -r"
else
    REENTER_CMD="sudo ${SNAP_NAME:-pihole-by-rajannpatel}.pihole -r"
fi

prompt_fail_exit() {
    if [ "${NON_INTERACTIVE:-}" != "true" ]; then
        printf "Do you want to exit the wizard and run these commands? (Y/n): "
        read -r choice
        choice="${choice:-y}"
        case "$choice" in
            [nN][oO]|[nN])
                echo "Continuing setup anyway..."
                echo ""
                ;;
            *)
                echo "Aborting setup."
                exit 1
                ;;
        esac
    fi
}

get_local_ips() {
    local ips=""
    if command -v ip >/dev/null 2>&1; then
        ips=$(ip -4 -o addr show up 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -v '^127\.' | paste -sd ',' - | sed 's/,/, /g')
    fi
    if [ -z "$ips" ] && command -v hostname >/dev/null 2>&1; then
        ips=$(hostname -I 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/[[:space:]][[:space:]]*/, /g')
    fi
    echo "${ips:-}"
}

FTL_RUNNING=false
if snapctl services "${SNAP_NAME:-pihole}.pihole-ftl" 2>/dev/null | grep -qw "active"; then
    FTL_RUNNING=true
fi

PORT_53_CONFLICT=false
# Pure bash TCP socket check with 1-second timeout
check_tcp() {
    local ip=$1
    local port=$2
    if [ "${MOCK_TCP_CHECK:-}" = "true" ]; then
        if [[ ",${MOCK_TCP_PORTS_IN_USE:-}," == *",$ip:$port,"* ]]; then
            return 0
        fi
        return 1
    fi
    (
        bash -c "exec 3<>/dev/tcp/$ip/$port" &
        pid=$!
        (sleep 1; kill $pid 2>/dev/null) &
        killer_pid=$!
        wait $pid 2>/dev/null
        rc=$?
        kill $killer_pid 2>/dev/null
        exit $rc
    )
}

check_udp() {
    local hex_port=$1
    if [ "${MOCK_TCP_CHECK:-}" = "true" ]; then
        if [[ ",${MOCK_UDP_PORTS_IN_USE:-}," == *",$hex_port,"* ]]; then
            return 0
        fi
        return 1
    fi
    grep -qi ":$hex_port " /proc/net/udp 2>/dev/null || grep -qi ":$hex_port " /proc/net/udp6 2>/dev/null
}

if [ "$FTL_RUNNING" = "true" ]; then
    printf "${GREEN}[OK]${NC} pihole-FTL service is currently active.\n\n"
else
    # Check for systemd-resolved conflict on 127.0.0.53:53
    if check_tcp "127.0.0.53" "53"; then
        PORT_53_CONFLICT=true
        printf "${RED}[FAIL]${NC} Port 53 (TCP) conflict detected (systemd-resolved on 127.0.0.53).\n"
        printf "Remediation: Run the following commands on your host:\n\n"
        printf "${BOLD}${CYAN}sudo mkdir -p /etc/systemd/resolved.conf.d\n"
        printf "printf '[Resolve]\\\\nDNS=127.0.0.1\\\\nDNSStubListener=no\\\\n' | sudo tee /etc/systemd/resolved.conf.d/pihole.conf\n"
        printf "sudo systemctl restart systemd-resolved\n"
        printf "${REENTER_CMD}${NC}\n\n"
        prompt_fail_exit
    elif check_tcp "127.0.0.1" "53" || check_tcp "0.0.0.0" "53" || check_udp "0035"; then
        PORT_53_CONFLICT=true
        printf "${RED}[FAIL]${NC} Port 53 conflict detected. Another process is binding port 53.\n"
        printf "Remediation: Run the following commands on your host:\n\n"
        printf "${BOLD}${CYAN}sudo ss -tulpn | grep :53\n"
        printf "${REENTER_CMD}${NC}\n\n"
        prompt_fail_exit
    else
        printf "${GREEN}[OK]${NC} Port 53 (DNS) is free.\n\n"
    fi
fi

# Check plugs
DISCONNECTED_PLUGS=""
check_plug() {
    local plug=$1
    local required=$2
    local desc=$3
    if ! snapctl is-connected "$plug"; then
        if [ "$required" = "true" ]; then
            DISCONNECTED_PLUGS="${DISCONNECTED_PLUGS} ${plug}"
            printf "${RED}[FAIL]${NC} Interface plug '${plug}' is disconnected (REQUIRED).\n"
            printf "Remediation: Run the following commands on your host:\n\n"
            printf "${BOLD}${CYAN}sudo snap connect ${SNAP_NAME:-pihole}:${plug}\n"
            printf "${REENTER_CMD}${NC}\n\n"
            prompt_fail_exit
        else
            printf "${BLUE}[INFO]${NC} Interface plug '${plug}' is disconnected (optional: ${desc}).\n"
            printf "Remediation: Run the following command on your host to connect the plug:\n\n"
            printf "${BOLD}${CYAN}sudo snap connect ${SNAP_NAME:-pihole}:${plug}${NC}\n\n"
        fi
    else
        printf "${GREEN}[OK]${NC} Interface plug '${plug}' is connected.\n\n"
    fi
}


check_plug "network-bind" "true" ""
check_plug "network" "true" ""
check_plug "network-observe" "true" ""
check_plug "network-control" "false" "DHCP server mode only"
check_plug "system-observe" "false" "per-process DNS attribution in network table"
check_plug "hardware-observe" "false" "hardware info in Pi-hole diagnosis page"
check_plug "mount-observe" "false" "filesystem info in Pi-hole diagnosis page"

# Offer to pause or abort if there are issues
echo ""

# 2. UPSTREAM DNS CONFIGURATION
echo "Step 2: Upstream DNS Configuration"
echo ""
echo "Select upstream DNS providers for Pi-hole to forward queries to:"
echo "1) Cloudflare (1.1.1.1, 1.0.0.1)"
echo "2) Quad9 (9.9.9.9, 149.112.112.112)"
echo "3) Google (8.8.8.8, 8.8.4.4)"
echo "4) AdGuard (94.140.14.14, 94.140.15.15)"
echo "5) Custom (Specify comma-separated IPs)"
echo ""

DNS_CHOICE=""
if [ "${NON_INTERACTIVE:-}" = "true" ]; then
    DNS_CHOICE="${MOCK_DNS_CHOICE:-1}"
else
    while true; do
        read -r -p "Enter choice [1-5] (Default: 1): " dns_in
        dns_in="${dns_in:-1}"
        if [[ "$dns_in" =~ ^[1-5]$ ]]; then
            DNS_CHOICE="$dns_in"
            break
        fi
        echo "Invalid choice. Please enter a number between 1 and 5."
    done
fi

UPSTREAMS=""
case "$DNS_CHOICE" in
    1) UPSTREAMS='["1.1.1.1","1.0.0.1"]' ;;
    2) UPSTREAMS='["9.9.9.9","149.112.112.112"]' ;;
    3) UPSTREAMS='["8.8.8.8","8.8.4.4"]' ;;
    4) UPSTREAMS='["94.140.14.14","94.140.15.15"]' ;;
    5)
        if [ "${NON_INTERACTIVE:-}" = "true" ]; then
            UPSTREAMS="${MOCK_CUSTOM_DNS:-[\"8.8.8.8\"]}"
        else
            while true; do
                read -r -p "Enter custom upstream DNS IPs (comma-separated): " custom_ips
                custom_ips=$(echo "$custom_ips" | tr -d '[:space:]')
                if [ -n "$custom_ips" ]; then
                    UPSTREAMS=$(echo "$custom_ips" | jq -c -R 'split(",")' 2>/dev/null || echo "")
                    if [ -n "$UPSTREAMS" ] && [ "$UPSTREAMS" != "null" ]; then
                        break
                    fi
                fi
                echo "Invalid input. Please enter valid IP addresses separated by commas."
            done
        fi
        ;;
esac

echo "Applying upstream DNS: $UPSTREAMS"
snapctl set ftl.dns.upstreams="$UPSTREAMS"
echo "Upstream DNS configured successfully."
echo ""

# 3. SECURITY / ADMIN PASSWORD
echo "Step 3: Web Admin Password"
echo ""
SET_PASSWORD="n"
if [ "${NON_INTERACTIVE:-}" = "true" ]; then
    SET_PASSWORD="${MOCK_SET_PASSWORD:-n}"
else
    read -r -p "Do you want to set/change the Web Admin password? (y/N): " pw_choice
    case "$pw_choice" in
        [yY][eE][sS]|[yY])
            SET_PASSWORD="y"
            ;;
    esac
fi

if [ "$SET_PASSWORD" = "y" ]; then
    if [ "${NON_INTERACTIVE:-}" = "true" ]; then
        echo "Setting mock password..."
        mkdir -p "${SNAP_DATA:-}/etc/pihole"
        echo 'password = "mocked_password_hash"' >> "${SNAP_DATA:-}/etc/pihole/pihole.toml"
    else
        export HOME="${SNAP_DATA:-}"
        /opt/pihole/pihole setpassword
    fi
    echo "Web Admin password updated."
else
    echo "Skipping password configuration."
fi
echo ""

# 4. AUTO-START ACTIVATION
echo "Step 4: Auto-Start Activation"
echo ""
if [ "$FTL_RUNNING" = "true" ]; then
    echo "pihole-FTL service is already active and running."
else
    START_FTL="n"
    if [ "${NON_INTERACTIVE:-}" = "true" ]; then
        START_FTL="${MOCK_START_FTL:-n}"
    else
        read -r -p "Do you want to enable and start the pihole-ftl service now? (y/N): " start_choice
        case "$start_choice" in
            [yY][eE][sS]|[yY])
                START_FTL="y"
                ;;
        esac
    fi

    if [ "$START_FTL" = "y" ]; then
        echo "Enabling and starting pihole-ftl service..."
        snapctl start --enable "${SNAP_NAME:-pihole}.pihole-ftl"
        echo "Service started successfully."
    else
        echo "To start the service manually later, run:"
        echo "  sudo snap start --enable ${SNAP_NAME:-pihole}.pihole-ftl"
    fi
fi
echo ""

echo "CONFIGURATION WIZARD COMPLETE"
echo ""
echo "Pi-hole snap setup/repair has completed successfully."
echo ""
echo "in a web browser, go to http://<Pi-hole-IP>/admin"
local_ips=$(get_local_ips)
if [ -n "$local_ips" ]; then
    echo "  (Detected local IP(s): ${local_ips})"
fi
echo ""
