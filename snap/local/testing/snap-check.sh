#!/bin/bash
# A system diagnostic tool for Pi-hole to detect conflicts and health.
# Exposed as `pihole snap-check`.

set -eu

echo "Pi-hole System Diagnostics"
echo "=========================="

# --- INTERFACE CONNECTION STATE ---
echo "--- INTERFACES ---"
check_interface() {
    local plug=$1
    local required=$2
    if snapctl is-connected "$plug"; then
        echo "  [OK] $plug (Connected)"
    else
        if [ "$required" = "true" ]; then
            echo "  [FAIL] $plug (Disconnected)"
            echo "    -> Remediation: sudo snap connect ${SNAP_NAME}:$plug"
        else
            echo "  [WARN] $plug (Disconnected)"
            echo "    -> Remediation (Optional): sudo snap connect ${SNAP_NAME}:$plug"
        fi
    fi
}
check_interface "network-bind" "true"
check_interface "network-control" "false"
check_interface "system-observe" "false"
echo ""

# --- PORT CONFLICTS ---
echo "--- PORTS ---"
check_tcp() {
    local ip=$1
    local port=$2
    # Allow unit tests to mock TCP checks
    if [ "${MOCK_TCP_CHECK:-}" = "true" ]; then
        if [[ ",$MOCK_TCP_PORTS_IN_USE," == *",$ip:$port,"* ]]; then
            return 0
        fi
        return 1
    fi
    # Pure bash TCP socket check with 1-second timeout
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

# Hex matching for /proc/net/udp: 53 is 0035, 67 is 0043, 546 is 0222
check_udp() {
    local hex_port=$1
    grep -qi ":$hex_port " /proc/net/udp 2>/dev/null || grep -qi ":$hex_port " /proc/net/udp6 2>/dev/null
}

# If FTL is running, we don't want to flag its own ports as external conflicts.
FTL_RUNNING=false
if snapctl services ${SNAP_NAME}.pihole-ftl 2>/dev/null | grep -qw "active"; then
    FTL_RUNNING=true
fi

if [ "$FTL_RUNNING" = "true" ]; then
    echo "  [OK] pihole-FTL is active. Port conflict checks skipped."
else
    # Check 53 (DNS TCP/UDP)
    if check_tcp "127.0.0.53" "53"; then
        echo "  [FAIL] Port 53 (TCP) - systemd-resolved conflict on 127.0.0.53"
        echo "    -> Remediation: Disable DNSStubListener in /etc/systemd/resolved.conf"
    elif check_tcp "127.0.0.1" "53" || check_tcp "0.0.0.0" "53" || check_udp "0035"; then
        echo "  [FAIL] Port 53 - Another DNS server is binding port 53"
        echo "    -> Remediation: Run 'sudo ss -tulpn | grep :53' on your host to identify it."
    else
        echo "  [OK] Port 53 (DNS) is free."
    fi

    # Check 80 (HTTP)
    if check_tcp "127.0.0.1" "80" || check_tcp "0.0.0.0" "80"; then
        echo "  [FAIL] Port 80 (HTTP) - Another web server is binding port 80"
        echo "    -> Remediation: Stop the server, or change Pi-hole's port: sudo snap set ${SNAP_NAME} webserver.port=8080"
    else
        echo "  [OK] Port 80 (HTTP) is free."
    fi

    # Check 67/546 (DHCP)
    if check_udp "0043" || check_udp "0222"; then
        echo "  [WARN] Port 67/546 (DHCP) is in use by another process."
        echo "    -> Remediation: If enabling Pi-hole DHCP, disable the host's isc-dhcp-server or dnsmasq."
    else
        echo "  [OK] Ports 67/546 (DHCP) are free."
    fi
fi
echo ""

# --- CONFINEMENT FAILURES ---
echo "--- CONFINEMENT ---"
if snapctl is-connected "system-observe"; then
    # Parse dmesg for recent apparmor DENIED logs related to pihole
    if dmesg 2>/dev/null | grep -i "apparmor=\"DENIED\"" | grep -q "snap.${SNAP_NAME}"; then
        echo "  [WARN] AppArmor denials detected in dmesg."
        echo "    -> This indicates strict confinement is blocking a daemon action."
        echo "    -> Remediation: Run 'dmesg | grep DENIED | grep ${SNAP_NAME}' for details."
    else
        echo "  [OK] No recent AppArmor denials detected."
    fi
else
    echo "  [INFO] 'system-observe' is disconnected (expected for production)."
    echo "    -> To enable this check for debugging: sudo snap connect ${SNAP_NAME}:system-observe"
fi
echo ""

echo "Diagnostics complete."
