#!/bin/sh
# config-sync.sh: Syncs pihole.toml configuration back to snapctl database to treat
# pihole.toml as the single source of truth.
set -eu

# Prepend snap staged paths to PATH to ensure we use our staged GNU coreutils & jq
export PATH="${SNAP}/usr/sbin:${SNAP}/usr/bin:${SNAP}/sbin:${SNAP}/bin:${PATH:-}"

TOML_FILE="${SNAP_DATA}/etc/pihole/pihole.toml"

if [ ! -f "$TOML_FILE" ]; then
    echo "No pihole.toml found to sync." >&2
    exit 0
fi

echo "Syncing pihole.toml config to snapctl..." >&2

# Convert TOML to flat key-value pairs
flat_config=$(awk '
/^[[:space:]]*\[([^\]]+)\]/ {
    match($0, /\[([^\]]+)\]/, arr);
    section = arr[1];
    next;
}
/^[[:space:]]*[A-Za-z0-9_\.-]+[[:space:]]*=/ {
    idx = index($0, "=");
    key = substr($0, 1, idx - 1);
    val = substr($0, idx + 1);
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", key);
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", val);
    if (val ~ /^\[/) {
        while (val !~ /\]$/ && (getline line) > 0) {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", line);
            val = val line;
        }
    }
    gsub(/,[[:space:]]*\]/, "]", val);
    full_key = (section ? section "." key : key);
    print full_key "=" val;
}
' "$TOML_FILE")

# Convert flat key-value pairs to JSON using jq
json_config=$(echo "$flat_config" | jq -n -R '
  [ inputs | split("=") | {key: .[0], value: (.[1] | fromjson)} ] |
  reduce .[] as $item ({}; setpath($item.key | split("."); $item.value))
')

# Set the entire ftl namespace in snapctl
if [ -n "$json_config" ] && [ "$json_config" != "{}" ]; then
    snapctl set ftl="$json_config"
else
    # If the file is empty/has no keys, clear ftl config in snapctl
    snapctl unset ftl
fi
