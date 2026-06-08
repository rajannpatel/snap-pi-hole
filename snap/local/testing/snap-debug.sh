#!/bin/bash
# A system diagnostic tool for Pi-hole strictly confined within a snap.
# Exposed as `pihole snap-debug`.

set -eu

echo "PI-HOLE SNAP DIAGNOSTIC DUMP"
echo ""
echo "Purpose: This tool captures a snapshot of the snap's runtime"
echo "environment, including network interfaces, port conflicts,"
echo "confinement logs, and daemon configuration."
echo ""
echo "Usage: Run this when experiencing deployment issues, DNS"
echo "failures, or crashes. Copy the ENTIRE output of this command"
echo "and provide it when opening a bug report."
echo ""
echo "Date: $(date)"
echo "Snap Version: $(snapctl get version || echo 'Unknown')"
echo ""

SOURCE_DIR="$(dirname "$(readlink -f "$0")")"
PIHOLE_CONFIG_HELPER="${SOURCE_DIR}/pihole-config.sh"
if [ ! -r "$PIHOLE_CONFIG_HELPER" ] && [ -r "${SOURCE_DIR}/../runtime/pihole-config.sh" ]; then
    PIHOLE_CONFIG_HELPER="${SOURCE_DIR}/../runtime/pihole-config.sh"
fi
# shellcheck source=snap/local/runtime/pihole-config.sh
source "$PIHOLE_CONFIG_HELPER"

# --- INTERFACE CONNECTION STATE ---
echo "--- INTERFACES ---"
# Required for core DNS and web UI functionality:

check_required_interface() {
    local plug=$1
    if snapctl is-connected "$plug"; then
        echo "  [OK]   $plug"
    else
        echo "  [FAIL] $plug (disconnected - core functionality affected)"
    fi
}
# Optional: enable non-core features; snap operates correctly without them.
check_optional_interface() {
    local plug=$1
    local desc=$2
    if snapctl is-connected "$plug"; then
        echo "  [OK]   $plug"
    else
        echo "  [INFO] $plug (disconnected - optional: $desc)"
    fi
}
check_required_interface "network"
check_required_interface "network-bind"
check_required_interface "network-observe"
check_optional_interface "network-control"  "DHCP server mode only"
check_optional_interface "system-observe"   "per-process DNS attribution in network table"
check_optional_interface "hardware-observe" "hardware info in Pi-hole diagnosis page"
check_optional_interface "mount-observe"    "filesystem info in Pi-hole diagnosis page"
echo ""

# --- PORT CONFLICTS ---
echo "--- PORTS ---"
# shellcheck source=snap/local/testing/port-utils.sh
source "${SOURCE_DIR}/port-utils.sh"

FTL_RUNNING=false
if pihole_ftl_is_active; then
    FTL_RUNNING=true
fi

if [ "$FTL_RUNNING" = "true" ]; then
    echo "  [OK] pihole-FTL is active. Port conflict checks skipped."
else
    if check_tcp "127.0.0.53" "53"; then
        echo "  [FAIL] Port 53 (TCP) - systemd-resolved conflict on 127.0.0.53"
    elif check_tcp "127.0.0.1" "53" || check_tcp "0.0.0.0" "53" || check_udp "0035"; then
        echo "  [FAIL] Port 53 - Another DNS server is binding port 53"
    else
        echo "  [OK] Port 53 (DNS) is free."
    fi

    if check_tcp "127.0.0.1" "80" || check_tcp "0.0.0.0" "80"; then
        echo "  [FAIL] Port 80 (HTTP) - Another web server is binding port 80"
    else
        echo "  [OK] Port 80 (HTTP) is free."
    fi

    if check_udp "0043" || check_udp "0222"; then
        echo "  [WARN] Port 67/546 (DHCP) is in use by another process."
    else
        echo "  [OK] Ports 67/546 (DHCP) are free."
    fi
fi
echo ""

# --- DATABASES ---
echo "--- DATABASES ---"
GRAVITY_DB="$SNAP_DATA/etc/pihole/gravity.db"
if [ -s "$GRAVITY_DB" ]; then
    echo "  [OK] gravity.db is present and populated ($(stat -c%s "$GRAVITY_DB") bytes)."
    if [ -x "$SNAP/usr/bin/pihole-FTL" ]; then
        ADLIST_COUNT=$("$SNAP/usr/bin/pihole-FTL" sqlite3 "$GRAVITY_DB" "SELECT count(*) FROM adlist WHERE enabled=1;" 2>/dev/null || echo "0")
        if [ "$ADLIST_COUNT" -gt 0 ]; then
            echo "  [OK] Found $ADLIST_COUNT enabled adlist(s)."
        else
            echo "  [WARN] No enabled adlists found in gravity.db. Ad-blocking will not work!"
        fi
    fi
elif [ -e "$GRAVITY_DB" ]; then
    echo "  [FAIL] gravity.db exists but is 0 bytes."
    echo "    -> Remediation: Run 'sudo pihole -g' to build the adlist database."
else
    echo "  [FAIL] gravity.db is missing. The web interface will show 'Database not available' errors."
    echo "    -> Remediation: Run 'sudo pihole -g' to build the adlist database."
fi

FTL_DB="$SNAP_DATA/etc/pihole/pihole-FTL.db"
if [ -s "$FTL_DB" ]; then
    echo "  [OK] pihole-FTL.db is present and populated ($(stat -c%s "$FTL_DB") bytes)."
else
    echo "  [WARN] pihole-FTL.db is missing or empty (normal on fresh installs)."
fi
echo ""

# --- CONFINEMENT FAILURES ---
# Only denials that break core functionality are flagged as warnings.
# The following are EXPECTED and non-fatal in LXC/VM environments and are
# always filtered out:
#   /sys/devices/virtual/dmi/id/*  – DMI hardware info; absent in containers;
#                                    civetweb probes this for system detection
#                                    but degrades gracefully.
#   /proc/<pid>/comm               – per-process names for the network table;
#                                    requires system-observe (optional plug);
#                                    FTL falls back to IP-only attribution.
#   /etc/ldap/ldap.conf            – curl probes this for SASL/LDAP plugin
#                                    discovery on every invocation; non-fatal,
#                                    HTTPS downloads work normally without it.
echo "--- CONFINEMENT ---"
if snapctl is-connected "system-observe"; then
    FATAL=$(dmesg 2>/dev/null \
        | grep -F 'apparmor="DENIED"' \
        | grep "snap.${SNAP_NAME}" \
        | grep -vE '/sys/devices/virtual/dmi/id/|/proc/[0-9]+/comm|/etc/ldap/ldap\.conf' \
        || true)
    if [ -n "$FATAL" ]; then
        echo "  [WARN] Unexpected AppArmor denials (may affect functionality):"
        echo "$FATAL" | tail -n 5 | sed 's/^/         /'
    else
        echo "  [OK] No unexpected AppArmor denials (benign DMI/proc denials filtered)."
    fi
else
    echo "  [INFO] system-observe not connected; AppArmor denial check skipped."
    echo "         This is fine — system-observe is optional and only enables"
    echo "         per-process DNS attribution in Pi-hole's network table."
fi
echo ""

# --- CONFIGURATION ---
echo "--- PIHOLE.TOML CONFIGURATION ---"
if [ -f "$SNAP_DATA/etc/pihole/pihole.toml" ]; then
    if grep -q "upstreams" "$SNAP_DATA/etc/pihole/pihole.toml"; then
        echo "  [OK] Upstream DNS servers are configured."
    else
        echo "  [FAIL] No upstream DNS servers found in pihole.toml! FTL will not resolve external domains."
    fi
    echo ""
    sed 's/password = .*/password = "[REDACTED]"/' "$SNAP_DATA/etc/pihole/pihole.toml" | sed 's/^/  /'
else
    echo "  [WARN] pihole.toml not found."
fi
echo ""

# --- LOG SCANNER ---
echo "--- LOG SCAN FOR CRITICAL PATTERNS ---"
FTL_LOG_PATH=""
for path in "/var/log/pihole/FTL.log" "$SNAP_COMMON/var/log/pihole/FTL.log" "/var/log/pihole/pihole-FTL.log" "$SNAP_COMMON/var/log/pihole/pihole-FTL.log"; do
    if [ -f "$path" ]; then
        FTL_LOG_PATH="$path"
        break
    fi
done

PIHOLE_LOG_PATH=""
for path in "/var/log/pihole/pihole.log" "$SNAP_COMMON/var/log/pihole/pihole.log"; do
    if [ -f "$path" ]; then
        PIHOLE_LOG_PATH="$path"
        break
    fi
done

FOUND_ISSUES=0

if [ -n "$FTL_LOG_PATH" ]; then
    # 1. Database Locking / Corruption
    if grep -qEi "database is locked|database disk image is malformed" "$FTL_LOG_PATH"; then
        FOUND_ISSUES=1
        echo "  [FAIL] SQLite database locking/corruption detected!"
        echo "         -> Remediation:"
        echo "            1. Stop the FTL service:"
        echo "               'sudo snap stop ${SNAP_NAME}.pihole-ftl'"
        echo "            2. Run sqlite3 integrity checks or vacuum on the database:"
        echo "               'sudo ${SNAP_NAME}.pihole-ftl sqlite3 ${SNAP_DATA}/etc/pihole/gravity.db \"PRAGMA integrity_check;\"'"
        echo "            3. If corrupted, restore from a snapshot or run 'sudo pihole -g' to recreate gravity.db."
    fi

    # 2. DNS Loops
    if grep -qEi "DNS mascot loop|Possible DNS loop detected|maximum number of concurrent DNS queries" "$FTL_LOG_PATH"; then
        FOUND_ISSUES=1
        echo "  [WARN] Potential DNS Loop detected!"
        echo "         -> Remediation: Check that your router or clients do not have circular DNS references"
        echo "            (e.g., Pi-hole pointing to the router for DNS and the router pointing to Pi-hole)."
        echo "            Verify 'Conditional Forwarding' settings in the Pi-hole web UI."
    fi

    # 3. Upstream Timeouts
    if grep -qEi "lost query|reply from .* is lost|timed out|reducing DNSSEC validation trust" "$FTL_LOG_PATH"; then
        FOUND_ISSUES=1
        echo "  [WARN] Upstream DNS timeouts detected!"
        echo "         -> Remediation: Verify host outbound network connectivity to upstream resolvers."
        echo "            Check for local firewall restrictions or clock drift/skew causing DNSSEC validation failures."
    fi
fi

if [ -n "$PIHOLE_LOG_PATH" ]; then
    # Scan pihole.log for similar loops/timeouts if FTL log didn't catch them or to supplement
    # DNS Loops in pihole.log
    if grep -qEi "maximum number of concurrent DNS queries" "$PIHOLE_LOG_PATH"; then
        # Check if we already logged a DNS Loop warning to avoid duplicate messages
        if [ -n "$FTL_LOG_PATH" ] && grep -qEi "DNS mascot loop|Possible DNS loop detected|maximum number of concurrent DNS queries" "$FTL_LOG_PATH" >/dev/null 2>&1; then
            :
        else
            FOUND_ISSUES=1
            echo "  [WARN] Potential DNS Loop detected in pihole.log!"
            echo "         -> Remediation: Check circular DNS references between Pi-hole and router."
        fi
    fi
fi

if [ "$FOUND_ISSUES" -eq 0 ]; then
    echo "  [OK] No critical error patterns detected in logs."
fi
echo ""

# --- DAEMON LOGS ---
echo "--- TAIL OF FTL LOG ---"
if [ -f "/var/log/pihole/FTL.log" ]; then
    tail -n 30 "/var/log/pihole/FTL.log" | sed 's/^/  /'
elif [ -f "$SNAP_COMMON/var/log/pihole/FTL.log" ]; then
    tail -n 30 "$SNAP_COMMON/var/log/pihole/FTL.log" | sed 's/^/  /'
elif [ -f "/var/log/pihole/pihole-FTL.log" ]; then
    tail -n 30 "/var/log/pihole/pihole-FTL.log" | sed 's/^/  /'
elif [ -f "$SNAP_COMMON/var/log/pihole/pihole-FTL.log" ]; then
    tail -n 30 "$SNAP_COMMON/var/log/pihole/pihole-FTL.log" | sed 's/^/  /'
else
    echo "  [WARN] FTL.log or pihole-FTL.log not found."
fi
echo ""

echo "END OF DIAGNOSTIC DUMP"
echo ""
echo "Please copy the output above and submit it along with your"
echo "issue description to the GitHub repository:"
echo "https://github.com/rajannpatel/snap-pi-hole/issues"
