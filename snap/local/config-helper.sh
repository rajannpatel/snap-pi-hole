#!/bin/sh
# Configuration Helper Library for snap-pi-hole hooks
# Exposes functions for validation, mapping to FTL, and migration.

FTL_BIN="${SNAP}/usr/bin/pihole-FTL"

# Mapping array using a case statement.
# Output: ftl_key type
get_ftl_key_and_type() {
    local snap_key="$1"
    case "$snap_key" in
        dns.upstream)            echo "dns.upstreams string" ;;
        dns.port)                echo "dns.port int" ;;
        dns.dnssec)              echo "dns.dnssec bool" ;;
        dns.interface)           echo "dns.listeningMode enum:local,all,bind" ;;
        web.port)                echo "webserver.port string" ;;
        web.password)            echo "webserver.password string" ;;
        dhcp.enabled)            echo "dhcp.active bool" ;;
        dhcp.range.start)        echo "dhcp.ipv4.start ip" ;;
        dhcp.range.end)          echo "dhcp.ipv4.end ip" ;;
        dhcp.gateway)            echo "dhcp.ipv4.router ip" ;;
        dhcp.lease_time)         echo "dhcp.leaseTime string" ;;
        logging.query)           echo "database.DBimport bool" ;;
        logging.privacy_level)   echo "misc.privacylevel int:0-3" ;;
        gravity.update_interval) echo "system string" ;; # internal snap logic
        system.auto_start)       echo "system bool" ;;   # internal snap logic
        *)                       echo "unknown unknown" ;;
    esac
}

validate_value() {
    local key="$1"
    local val="$2"
    local type="$3"

    case "$type" in
        string)
            return 0
            ;;
        int|int:*)
            if ! echo "$val" | grep -Eq '^[0-9]+$'; then
                echo "Error: Key '$key' requires an integer value." >&2
                return 1
            fi
            if [ "$key" = "dns.port" ]; then
                if [ "$val" -lt 1 ] || [ "$val" -gt 65535 ]; then
                    echo "Error: Key '$key' must be between 1 and 65535." >&2
                    return 1
                fi
            fi
            if [ "$type" = "int:0-3" ]; then
                if [ "$val" -lt 0 ] || [ "$val" -gt 3 ]; then
                    echo "Error: Key '$key' must be between 0 and 3." >&2
                    return 1
                fi
            fi
            ;;
        bool)
            if [ "$val" != "true" ] && [ "$val" != "false" ]; then
                echo "Error: Key '$key' requires a boolean value (true/false)." >&2
                return 1
            fi
            ;;
        enum:*)
            local enum_vals="${type#enum:}"
            local valid=0
            # Split comma separated enum_vals
            OIFS="$IFS"
            IFS=","
            for enum_val in $enum_vals; do
                if [ "$val" = "$enum_val" ]; then
                    valid=1
                    break
                fi
            done
            IFS="$OIFS"
            if [ "$valid" -eq 0 ]; then
                echo "Error: Key '$key' must be one of: $enum_vals." >&2
                return 1
            fi
            ;;
        ip)
            if ! echo "$val" | grep -Eq '^([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])(\.([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])){3}$'; then
                echo "Error: Key '$key' requires a valid IPv4 address." >&2
                return 1
            fi
            ;;
    esac
    return 0
}

apply_to_ftl() {
    local snap_key="$1"
    local val="$2"

    local result
    result="$(get_ftl_key_and_type "$snap_key")"
    local ftl_key="${result%% *}"
    local type="${result#* }"

    if [ "$ftl_key" = "unknown" ]; then
        # Silently ignore unknown keys to allow standard snapctl usage for other things,
        # but if we wanted strictness we could echo a warning. We will ignore.
        return 0
    fi

    if ! validate_value "$snap_key" "$val" "$type"; then
        return 1
    fi

    if [ "$ftl_key" = "system" ]; then
        # Handle system keys (e.g. system.auto_start is handled by the hook itself via snapctl)
        return 0
    fi

    # Apply via pihole-FTL --config
    "$FTL_BIN" --config "$ftl_key" "$val" >/dev/null
    return 0
}

get_all_schema_keys() {
    cat <<EOF
dns.upstream
dns.port
dns.dnssec
dns.interface
web.port
web.password
dhcp.enabled
dhcp.range.start
dhcp.range.end
dhcp.gateway
dhcp.lease_time
logging.query
logging.privacy_level
gravity.update_interval
system.auto_start
EOF
}

migrate_legacy_config() {
    # If the user has an existing pihole.toml, try to populate snapctl 
    # so snapctl becomes the single source of truth.
    # Note: pihole-FTL --config <key> returns the current value.
    if [ ! -f /etc/pihole/pihole.toml ]; then
        return 0
    fi
    
    local keys
    keys="$(get_all_schema_keys)"
    
    for snap_key in $keys; do
        # Only migrate if snapctl is empty for this key
        local current_snap_val
        current_snap_val="$(snapctl get "$snap_key" 2>/dev/null || true)"
        if [ -n "$current_snap_val" ]; then
            continue
        fi

        local result
        result="$(get_ftl_key_and_type "$snap_key")"
        local ftl_key="${result%% *}"
        
        if [ "$ftl_key" != "system" ] && [ "$ftl_key" != "unknown" ]; then
            local ftl_val
            ftl_val="$("$FTL_BIN" --config "$ftl_key" 2>/dev/null || true)"
            
            # Remove any quotes or trailing comments from output if present, though FTL usually outputs cleanly.
            ftl_val="$(echo "$ftl_val" | sed -e 's/^"//' -e 's/"$//')"
            
            if [ -n "$ftl_val" ]; then
                snapctl set "$snap_key"="$ftl_val" || true
            fi
        fi
    done
}
