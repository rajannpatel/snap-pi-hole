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
    printf '%s' "$1" | tr -d '[:space:]' | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//"
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
