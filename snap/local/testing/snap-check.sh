#!/bin/bash
# A system diagnostic tool for Pi-hole to detect conflicts and health.
# Exposed as `pihole snap-check`.

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

echo "Pi-hole System Diagnostics"
echo ""

SOURCE_DIR="$(dirname "$(readlink -f "$0")")"
PIHOLE_CONFIG_HELPER="${SOURCE_DIR}/pihole-config.sh"
if [ ! -r "$PIHOLE_CONFIG_HELPER" ] && [ -r "${SOURCE_DIR}/../runtime/pihole-config.sh" ]; then
    PIHOLE_CONFIG_HELPER="${SOURCE_DIR}/../runtime/pihole-config.sh"
fi
# shellcheck source=snap/local/runtime/pihole-config.sh
source "$PIHOLE_CONFIG_HELPER"
SNAP_INSTANCE="$(pihole_snap_name)"

# Global exit code tracker: 0=success, 1=config error, 2=runtime error
exit_code=0

# --- INTERFACE CONNECTION STATE ---
echo "--- INTERFACES ---"
echo ""
check_interface() {
    local plug=$1
    local required=$2
    local desc=$3
    if snapctl is-connected "$plug"; then
        printf "%b[OK]%b %s (Connected)\n\n" "${GREEN}" "${NC}" "${plug}"
    else
        if [ "$required" = "true" ]; then
            printf "%b[FAIL]%b %s (Disconnected)\n" "${RED}" "${NC}" "${plug}"
            printf "Remediation: Run the following command on your host to connect the plug:\n\n"
            printf "%b%bsudo snap connect %s:%s%b\n\n" "${BOLD}" "${CYAN}" "${SNAP_INSTANCE}" "${plug}" "${NC}"
            exit_code=1
        else
            printf "%b[INFO]%b %s (Disconnected - optional: %s)\n" "${BLUE}" "${NC}" "${plug}" "${desc}"
            printf "Remediation: Run the following command on your host to connect the plug:\n\n"
            printf "%b%bsudo snap connect %s:%s%b\n\n" "${BOLD}" "${CYAN}" "${SNAP_INSTANCE}" "${plug}" "${NC}"
        fi
    fi
}
check_interface "network-bind" "true" ""
check_interface "network-control" "false" "DHCP server mode only"
check_interface "system-observe" "false" "per-process DNS attribution in network table"
check_interface "hardware-observe" "false" "hardware info in Pi-hole diagnosis page"
check_interface "mount-observe" "false" "filesystem info in Pi-hole diagnosis page"

# --- PORT CONFLICTS ---
echo "--- PORTS ---"
echo ""
# shellcheck source=snap/local/testing/port-utils.sh
source "${SOURCE_DIR}/port-utils.sh"

# If FTL is running, we don't want to flag its own ports as external conflicts.
FTL_RUNNING=false
FTL_SERVICE="$(pihole_ftl_service_name)"
if pihole_ftl_is_active "$FTL_SERVICE"; then
    FTL_RUNNING=true
fi

if [ "$FTL_RUNNING" = "true" ]; then
    printf "%b[OK]%b pihole-FTL is active. Port conflict checks skipped.\n\n" "${GREEN}" "${NC}"
else
    # Check 53 (DNS TCP/UDP)
    if check_tcp "127.0.0.53" "53"; then
        printf "%b[FAIL]%b Port 53 (TCP) - systemd-resolved conflict on 127.0.0.53\n" "${RED}" "${NC}"
        printf "Remediation: Disable DNSStubListener using a systemd-resolved drop-in:\n\n"
        printf "%b%bsudo mkdir -p /etc/systemd/resolved.conf.d\n" "${BOLD}" "${CYAN}"
        printf "printf '[Resolve]\\\\nDNS=127.0.0.1\\\\nDNSStubListener=no\\\\n' | sudo tee /etc/systemd/resolved.conf.d/pihole.conf\n"
        printf "sudo systemctl restart systemd-resolved%b\n\n" "${NC}"
        [ "$exit_code" -eq 0 ] && exit_code=2
    elif check_tcp "127.0.0.1" "53" || check_tcp "0.0.0.0" "53" || check_udp "0035"; then
        printf "%b[FAIL]%b Port 53 - Another DNS server is binding port 53\n" "${RED}" "${NC}"
        printf "Remediation: Run the following command on your host to identify it:\n\n"
        printf "%b%bsudo ss -tulpn | grep :53%b\n\n" "${BOLD}" "${CYAN}" "${NC}"
        [ "$exit_code" -eq 0 ] && exit_code=2
    else
        printf "%b[OK]%b Port 53 (DNS) is free.\n\n" "${GREEN}" "${NC}"
    fi

    # Check 80 (HTTP)
    if check_tcp "127.0.0.1" "80" || check_tcp "0.0.0.0" "80"; then
        printf "%b[FAIL]%b Port 80 (HTTP) - Another web server is binding port 80\n" "${RED}" "${NC}"
        printf "Remediation: Stop the server, or change Pi-hole's port:\n\n"
        printf "%b%bsudo snap set %s webserver.port=8080%b\n\n" "${BOLD}" "${CYAN}" "${SNAP_INSTANCE}" "${NC}"
        [ "$exit_code" -eq 0 ] && exit_code=2
    else
        printf "%b[OK]%b Port 80 (HTTP) is free.\n\n" "${GREEN}" "${NC}"
    fi

    # Check 67/546 (DHCP)
    if check_udp "0043" || check_udp "0222"; then
        printf "%b[WARN]%b Port 67/546 (DHCP) is in use by another process.\n" "${YELLOW}" "${NC}"
        printf "Remediation: If enabling Pi-hole DHCP, disable the host's isc-dhcp-server or dnsmasq.\n\n"
    else
        printf "%b[OK]%b Ports 67/546 (DHCP) are free.\n\n" "${GREEN}" "${NC}"
    fi
fi

# --- CONFINEMENT FAILURES ---
echo "--- CONFINEMENT ---"
echo ""
if snapctl is-connected "system-observe"; then
    # Parse dmesg for recent apparmor DENIED logs related to pihole, filtering out benign exceptions
    if dmesg 2>/dev/null | grep -i "apparmor=\"DENIED\"" | grep "snap.${SNAP_INSTANCE}" | grep -q -vE 'dac_read_search|dac_override|net_admin|/sys/devices/virtual/dmi/id/|/proc/[0-9]+/comm|/etc/ldap/ldap\.conf|name="/sys/fs/cgroup/system\.slice/snap\.[a-zA-Z0-9.-]+\.(scope|service)/cpu\.max".*comm="(snap-exec|snapctl)"|name="/proc/[0-9]+/mountinfo".*comm="(snap-exec|snapctl)"'; then
        printf "%b[WARN]%b AppArmor denials detected in dmesg.\n" "${YELLOW}" "${NC}"
        printf "This indicates strict confinement is blocking a daemon action.\n"
        printf "Remediation: Run the following command on your host for details:\n\n"
        printf "%b%bdmesg | grep DENIED | grep %s%b\n\n" "${BOLD}" "${CYAN}" "${SNAP_INSTANCE}" "${NC}"
    else
        printf "%b[OK]%b No recent AppArmor denials detected.\n\n" "${GREEN}" "${NC}"
    fi
else
    printf "%b[INFO]%b 'system-observe' is disconnected (expected for production).\n" "${BLUE}" "${NC}"
    printf "Remediation: Run the following command on your host to connect it for debugging:\n\n"
    printf "%b%bsudo snap connect %s:system-observe%b\n\n" "${BOLD}" "${CYAN}" "${SNAP_INSTANCE}" "${NC}"
fi

echo "Diagnostics complete."
exit $exit_code
