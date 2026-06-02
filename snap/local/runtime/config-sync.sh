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

# Convert TOML to flat key-value pairs.
# NOTE: uses only POSIX awk features (no gawk-only 3-arg match()) so it
# behaves identically under the base snap's mawk and under gawk in CI.
flat_config=$(awk '
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
    sub(/^[[:space:]]*\[/, "", section);  # strip leading whitespace + [
    sub(/\].*$/, "", section);            # strip from first ] to EOL (drops any trailing comment)
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
' "$TOML_FILE")

# Convert flat key-value pairs to JSON using jq.
# `select(length > 0)` drops blank lines so a keyless or comment-only
# pihole.toml yields {} (handled below) instead of a `null | fromjson` error.
json_config=$(echo "$flat_config" | jq -n -R '
  [ inputs | select(length > 0) | split("=") | {key: .[0], value: (.[1] | fromjson)} ] |
  reduce .[] as $item ({}; setpath($item.key | split("."); $item.value))
')

# Set the entire ftl namespace in snapctl
if [ -n "$json_config" ] && [ "$json_config" != "{}" ]; then
    snapctl set ftl="$json_config"
else
    # If the file is empty/has no keys, clear ftl config in snapctl
    snapctl unset ftl
fi
