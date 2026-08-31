#!/usr/bin/env bats
#
# Unit tests for the pihole-config.sh shared helper library, focused on
# pihole_webserver_exposure: the classification of FTL's webserver.port
# listening specs into reachable / loopback / disabled.
#
# Run locally:  bats tests/unit/pihole-config.bats

setup() {
    REPO_ROOT="$(git rev-parse --show-toplevel)"
    # shellcheck source=../../snap/local/runtime/pihole-config.sh
    # shellcheck disable=SC1090
    . "${REPO_ROOT}/snap/local/runtime/pihole-config.sh"
}

@test "classifies raw webserver.port values into exposure states" {
    # Each row: <raw flat value>|<expected exposure>. The raw values are
    # formatted exactly as pihole_flat_value emits them (TOML string quotes
    # included) so the helper contract is exercised verbatim. Comment and
    # blank rows keep the table readable and are skipped by the case guard.
    while IFS='|' read -r raw_spec expected; do
        case "${raw_spec}" in ''|'#'*) continue ;; esac
        result="$(pihole_webserver_exposure "$raw_spec")"
        if [ "$result" != "$expected" ]; then
            echo "spec [${raw_spec}] classified as [${result}], expected [${expected}]"
            false
        fi
    done <<'EOF'
# Bare ports, with and without civetweb option suffixes: all interfaces
"80o"|reachable
"8080"|reachable
"+80"|reachable
"80r,443s"|reachable
"80or,443os,8080,4443s"|reachable
"80O,443OS"|reachable
# Address-prefixed entries
"127.0.0.1:80"|loopback
"127.0.0.1:8080s"|loopback
"localhost:80"|loopback
"10.0.0.5:443os"|reachable
"0.0.0.0:80"|reachable
# Bracketed IPv6 entries
"[::1]:8080s"|loopback
"[::]:80o"|reachable
"[fe80::1]:80"|reachable
# Mixed specs: any non-loopback entry wins
"127.0.0.1:80,[::]:80o"|reachable
"127.0.0.1:80,[::1]:8080s"|loopback
"[::1]:80,127.0.0.1:80"|loopback
"127.0.0.1:80,0.0.0.0:443s"|reachable
# Whitespace around entries is trimmed
" 127.0.0.1:80 , [::1]:8080 "|loopback
# Explicit empty string: the webserver is disabled
""|disabled
EOF
}

@test "missing webserver.port key falls back to FTL's all-interfaces default" {
    [ "$(pihole_webserver_exposure "")" = "reachable" ]
    [ "$(pihole_webserver_exposure)" = "reachable" ]
}

@test "normalize strips TOML and JSON quoting safely" {
    [ "$(pihole_normalize_config_value '"80o"')" = "80o" ]
    [ "$(pihole_normalize_config_value "'localhost:80'")" = "localhost:80" ]
    [ "$(pihole_normalize_config_value '  443os  ')" = "443os" ]
    [ -z "$(pihole_normalize_config_value '""')" ]
    [ -z "$(pihole_normalize_config_value "")" ]
}
