#!/usr/bin/env bats
#
# Unit tests for snap/local/runtime/config-sync.sh  -  the script that parses
# pihole.toml into flat key/value pairs and pushes them into the snapctl `ftl`
# config namespace so the TOML file remains the single source of truth.
#
# The TOML->flat parser is hand-rolled in awk. It MUST stick to POSIX awk
# features: the base snap resolves `awk` to mawk, which does NOT support the
# gawk-only 3-argument match($0, re, arr) form. These tests run the real
# script both under the host's default awk (gawk in CI) and, when available,
# forced through mawk, so a future gawk-only regression fails loudly here
# instead of silently breaking config sync on a real device.
#
# Run locally:  bats tests/unit/config-sync.bats
# In CI:        see .github/workflows/publish.yml (lint+unit job)

setup() {
    REPO_ROOT="$(git rev-parse --show-toplevel)"
    TEST_TMPDIR="$(mktemp -d)"

    export SNAP="${TEST_TMPDIR}/snap"
    export SNAP_DATA="${TEST_TMPDIR}/data"
    export SNAP_COMMON="${TEST_TMPDIR}/common"
    export SNAP_NAME="pihole"
    mkdir -p "${SNAP}/usr/bin" "${SNAP}/usr/sbin" "${SNAP}/bin" "${SNAP}/sbin" \
             "${SNAP_DATA}/etc/pihole" "${SNAP_COMMON}"

    TOML_FILE="${SNAP_DATA}/etc/pihole/pihole.toml"

    # Stub snapctl. Captures the JSON handed to `set ftl=<json>` and records
    # whether `unset ftl` was called. Placed under $SNAP/usr/bin so it wins
    # over any host snapctl (the script prepends $SNAP paths to PATH).
    CAPTURED_JSON="${TEST_TMPDIR}/captured_ftl.json"
    UNSET_MARKER="${TEST_TMPDIR}/unset.marker"
    cat > "${SNAP}/usr/bin/snapctl" <<EOF
#!/bin/sh
echo "SNAPCTL:\$*" >> "${TEST_TMPDIR}/snapctl.log"
case "\$1" in
    set)
        # \$2 is the literal "ftl=<json>" argument
        printf '%s' "\${2#ftl=}" > "${CAPTURED_JSON}"
        ;;
    unset)
        [ "\$2" = "ftl" ] && echo "UNSET" > "${UNSET_MARKER}"
        ;;
esac
exit 0
EOF
    chmod +x "${SNAP}/usr/bin/snapctl"

    CONFIG_SYNC="${REPO_ROOT}/snap/local/runtime/config-sync.sh"
}

teardown() {
    rm -rf "${TEST_TMPDIR}"
}

# Force `awk` to resolve to a specific implementation by dropping a shim into
# $SNAP/usr/bin (first on the script's PATH). Skips the test if the requested
# implementation is not installed on the runner.
_force_awk() {
    local impl="$1"
    local impl_path
    impl_path="$(command -v "$impl" 2>/dev/null)" \
        || skip "${impl} not installed on this runner"
    cat > "${SNAP}/usr/bin/awk" <<EOF
#!/bin/sh
exec "${impl_path}" "\$@"
EOF
    chmod +x "${SNAP}/usr/bin/awk"
}

# ---------------------------------------------------------------------------
# Missing / empty input
# ---------------------------------------------------------------------------

@test "config-sync exits 0 and warns when pihole.toml is absent" {
    run "${CONFIG_SYNC}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"No pihole.toml found to sync."* ]]
    [ ! -f "${CAPTURED_JSON}" ]
}

@test "config-sync unsets the ftl namespace when pihole.toml has no keys" {
    printf '# just a comment\n\n' > "${TOML_FILE}"
    run "${CONFIG_SYNC}"
    [ "$status" -eq 0 ]
    [ -f "${UNSET_MARKER}" ]
    [ ! -f "${CAPTURED_JSON}" ]
}

# ---------------------------------------------------------------------------
# Parsing correctness (host default awk)
# ---------------------------------------------------------------------------

@test "config-sync flattens scalars, arrays, and nested sections into snapctl JSON" {
    cat > "${TOML_FILE}" <<'EOF'
[dns]
  upstreams = [
    "8.8.8.8",
    "8.8.4.4"
  ]
  dnssec = true

[dns.rateLimit]
  count = 1000

[webserver]
  port = "80"
EOF
    run "${CONFIG_SYNC}"
    [ "$status" -eq 0 ]
    [ -f "${CAPTURED_JSON}" ]

    # Validate the structure the script handed to snapctl.
    run jq -e '.dns.upstreams == ["8.8.8.8","8.8.4.4"]' "${CAPTURED_JSON}"
    [ "$status" -eq 0 ]
    run jq -e '.dns.dnssec == true' "${CAPTURED_JSON}"
    [ "$status" -eq 0 ]
    run jq -e '.dns.rateLimit.count == 1000' "${CAPTURED_JSON}"
    [ "$status" -eq 0 ]
    run jq -e '.webserver.port == "80"' "${CAPTURED_JSON}"
    [ "$status" -eq 0 ]
}

@test "config-sync strips a trailing inline comment from a section header" {
    cat > "${TOML_FILE}" <<'EOF'
[dns] # primary resolver settings
  dnssec = true
EOF
    run "${CONFIG_SYNC}"
    [ "$status" -eq 0 ]
    # Must land under .dns, not a mangled ".dns] # ..." key.
    run jq -e '.dns.dnssec == true' "${CAPTURED_JSON}"
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Portability guard: the parser must work under mawk (the base snap's awk),
# not just gawk. A gawk-only feature (e.g. 3-arg match) would error here.
# ---------------------------------------------------------------------------

@test "config-sync parser is mawk-compatible (no gawk-only awk extensions)" {
    _force_awk mawk
    cat > "${TOML_FILE}" <<'EOF'
[dns]
  upstreams = [
    "8.8.8.8",
    "8.8.4.4"
  ]

[dns.rateLimit]
  count = 1000
EOF
    run "${CONFIG_SYNC}"
    [ "$status" -eq 0 ]
    # mawk must produce the same structure gawk does.
    run jq -e '.dns.upstreams == ["8.8.8.8","8.8.4.4"]' "${CAPTURED_JSON}"
    [ "$status" -eq 0 ]
    run jq -e '.dns.rateLimit.count == 1000' "${CAPTURED_JSON}"
    [ "$status" -eq 0 ]
}
