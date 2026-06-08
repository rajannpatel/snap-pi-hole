#!/bin/sh
# config-sync.sh: Syncs pihole.toml configuration back to snapctl database to treat
# pihole.toml as the single source of truth.
set -eu

# Prepend snap staged paths to PATH to ensure we use our staged GNU coreutils & jq
export PATH="${SNAP}/usr/sbin:${SNAP}/usr/bin:${SNAP}/sbin:${SNAP}/bin:${PATH:-}"

SCRIPT_DIR="$(unset CDPATH; cd -P -- "$(dirname "$0")" && pwd)"
# shellcheck source=snap/local/runtime/pihole-config.sh
. "${SCRIPT_DIR}/pihole-config.sh"

TOML_FILE="${SNAP_DATA}/etc/pihole/pihole.toml"

if [ ! -f "$TOML_FILE" ]; then
    echo "No pihole.toml found to sync." >&2
    exit 0
fi

echo "Syncing pihole.toml config to snapctl..." >&2

flat_config=$(pihole_toml_flat "$TOML_FILE")

# Convert flat key-value pairs to JSON using jq.
# `select(length > 0)` drops blank lines so a keyless or comment-only
# pihole.toml yields {} (handled below) instead of a `null | fromjson` error.
if ! json_config=$(printf '%s\n' "$flat_config" | pihole_flat_to_json); then
    echo "Error: Failed to parse configuration TOML/JSON" >&2
    exit 1
fi

# Set the entire ftl namespace in snapctl
if [ -n "$json_config" ] && [ "$json_config" != "{}" ]; then
    snapctl set ftl="$json_config" || {
        echo "Error: Failed to sync configuration to snapctl" >&2
        exit 2
    }
else
    # If the file is empty/has no keys, clear ftl config in snapctl
    snapctl unset ftl || {
        echo "Error: Failed to clear configuration in snapctl" >&2
        exit 2
    }
fi
