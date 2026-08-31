#!/bin/sh
# Shared pihole.toml helpers for hooks and runtime scripts.

pihole_toml_file() {
    printf '%s/etc/pihole/pihole.toml\n' "${SNAP_DATA:-}"
}

pihole_seed_default_toml() {
    pihole_toml="${1:-$(pihole_toml_file)}"

    [ -f "$pihole_toml" ] && return 0

    mkdir -p "${pihole_toml%/*}"
    cat > "$pihole_toml" <<EOF
[dns]
  upstreams = [
    "8.8.8.8",
    "8.8.4.4"
  ]
EOF
}

pihole_versions_template_file() {
    pihole_root="${1:-${SNAP:-}}"
    printf '%s/opt/pihole/templates/versions\n' "$pihole_root"
}

pihole_advanced_versions_template_file() {
    pihole_root="${1:-${SNAP:-}}"
    printf '%s/etc/.pihole/advanced/Scripts/templates/versions\n' "$pihole_root"
}

pihole_versions_file() {
    pihole_root="${1:-${SNAP_DATA:-}}"
    printf '%s/etc/pihole/versions\n' "$pihole_root"
}

pihole_seed_versions_file() {
    pihole_versions_template="${1:-$(pihole_versions_template_file "${SNAP:-}")}"
    pihole_versions_file="${2:-$(pihole_versions_file "${SNAP_DATA:-}")}"

    [ -f "$pihole_versions_template" ] || return 0

    mkdir -p "${pihole_versions_file%/*}"
    cp "$pihole_versions_template" "$pihole_versions_file"
}

pihole_snap_name() {
    printf '%s\n' "${SNAP_NAME:-pihole-by-rajannpatel}"
}

pihole_cli_command() {
    printf '%s\n' "${PIHOLE_CLI:-pihole}"
}

pihole_ftl_service_name() {
    printf '%s.pihole-ftl\n' "$(pihole_snap_name)"
}

pihole_ftl_is_active() {
    pihole_service="${1:-$(pihole_ftl_service_name)}"

    snapctl services "$pihole_service" 2>/dev/null | awk '
$1 == "Service" {
    next;
}
NF >= 3 {
    if ($3 == "active") {
        found = 1;
    }
    next;
}
NF >= 2 {
    if ($2 == "active") {
        found = 1;
    }
}
END {
    exit found ? 0 : 1;
}
'
}

# Convert TOML to flat key-value pairs.
# NOTE: uses only POSIX awk features (no gawk-only 3-arg match()) so it
# behaves identically under the base snap's mawk and under gawk in CI.
pihole_toml_flat() {
    awk '
function clean_comments(s) {
    clean = "";
    in_quotes = 0;
    quote_char = "";
    len = length(s);
    for (i = 1; i <= len; i++) {
        ch = substr(s, i, 1);
        if ((ch == "\"" || ch == "\047") && (i == 1 || substr(s, i - 1, 1) != "\\")) {
            if (!in_quotes) {
                in_quotes = 1;
                quote_char = ch;
            } else if (ch == quote_char) {
                in_quotes = 0;
            }
        }
        if (ch == "#" && !in_quotes) {
            break;
        }
        clean = clean ch;
    }
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", clean);
    return clean;
}
/^[[:space:]]*\[[^\]]+\]/ {
    section = $0;
    sub(/^[[:space:]]*\[/, "", section);
    sub(/\].*$/, "", section);
    next;
}
/^[[:space:]]*[A-Za-z0-9_\.-]+[[:space:]]*=/ {
    idx = index($0, "=");
    key = substr($0, 1, idx - 1);
    val = substr($0, idx + 1);
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", key);
    val = clean_comments(val);
    if (val ~ /^\[/) {
        while (val !~ /\]$/ && (getline line) > 0) {
            line = clean_comments(line);
            val = val line;
        }
    }
    gsub(/,[[:space:]]*\]/, "]", val);
    full_key = (section ? section "." key : key);
    print full_key "=" val;
}
' "$1"
}

pihole_flat_to_json() {
    jq -n -R '
      [ inputs | select(length > 0) | index("=") as $idx | {key: .[0:$idx], value: (.[$idx+1:] | fromjson)} ] |
      reduce .[] as $item ({}; setpath($item.key | split("."); $item.value))
    '
}

pihole_normalize_config_value() {
    printf '%s' "${1:-}" | tr -d '[:space:]' | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//"
}

pihole_flat_value() {
    awk -v wanted="$1" '
index($0, "=") {
    key = substr($0, 1, index($0, "=") - 1);
    if (key == wanted) {
        print substr($0, index($0, "=") + 1);
        exit;
    }
}
'
}

# Classify how far the embedded webserver/API can be reached, based on the
# raw `webserver.port` value exactly as produced by pihole_flat_value:
#   reachable  at least one listening entry binds a non-loopback address
#              (or the key is missing, which is FTL's all-interfaces default)
#   loopback   every entry binds loopback addresses only
#   disabled   webserver.port is an explicit empty string (web/API is off)
# The trailing o/s/r letters are civetweb option flags (optional, TLS,
# redirect), not binding scopes: the scope comes from the address prefix.
# Entries without an address prefix (e.g. "80" or "+80") bind all interfaces.
pihole_webserver_exposure() {
    ws_raw="${1:-}"

    # A missing key (empty raw value) means FTL's default: all interfaces.
    if [ -z "$ws_raw" ]; then
        printf 'reachable\n'
        return 0
    fi

    ws_spec="$(pihole_normalize_config_value "$ws_raw")"
    if [ -z "$ws_spec" ]; then
        printf 'disabled\n'
        return 0
    fi

    printf '%s\n' "$ws_spec" | awk -F, '
    {
        reachable = 0
        for (i = 1; i <= NF; i++) {
            entry = $i
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", entry)
            sub(/[osrOSR]+$/, "", entry)
            if (entry == "") {
                continue
            }
            if (substr(entry, 1, 1) == "[") {
                # Bracketed IPv6 literal, e.g. [::1]:8080s or [::]:80o
                addr = entry
                sub(/^\[/, "", addr)
                sub(/\].*$/, "", addr)
                if (addr != "::1") {
                    reachable = 1
                }
            } else if (index(entry, ":") > 0) {
                # Address-prefixed entry, e.g. 127.0.0.1:80 or 10.0.0.5:80
                addr = substr(entry, 1, index(entry, ":") - 1)
                if (addr !~ /^127\./ && addr != "localhost" && addr != "::1") {
                    reachable = 1
                }
            } else {
                # Bare or "+"-prefixed port: binds all interfaces
                reachable = 1
            }
        }
        print (reachable ? "reachable" : "loopback")
    }
    '
}

pihole_apply_flat_config() {
    pihole_ftl_bin="$1"
    pihole_flat_config="$2"
    pihole_current_toml_flat="${3:-}"
    pihole_changed=0

    if [ -n "$pihole_flat_config" ]; then
        while IFS='=' read -r key val; do
            [ -z "$key" ] && continue

            norm_val=$(pihole_normalize_config_value "$val")
            toml_val=$(printf '%s\n' "$pihole_current_toml_flat" | pihole_flat_value "$key")
            norm_toml_val=$(pihole_normalize_config_value "$toml_val")

            if [ -n "$toml_val" ] && [ "$norm_val" = "$norm_toml_val" ]; then
                continue
            fi

            "$pihole_ftl_bin" --config "$key" "$val" >/dev/null 2>&1 || {
                echo "Error applying ftl.$key=$val" >&2
                return 1
            }
            pihole_changed=1
        done <<EOF
$pihole_flat_config
EOF
    fi

    printf '%s\n' "$pihole_changed"
}
