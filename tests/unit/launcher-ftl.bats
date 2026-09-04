#!/usr/bin/env bats
#
# Unit tests for snap/local/launcher-ftl  -  the daemon wrapper that
# detects port-53 conflicts, seeds required directories and the initial
# pihole.toml, exports HOME, and execs pihole-FTL.
#
# Tests cover every logical branch except the final exec (which would
# require a real binary). The port-53 conflict detection relies on
# /dev/tcp which is a bash builtin, so we inject a wrapper that
# overrides the subshell check.
#
# Run locally:  bats tests/unit/launcher-ftl.bats
# In CI:        see .github/workflows/cicd.yml (lint+unit job)

setup() {
    REPO_ROOT="$(git rev-parse --show-toplevel)"
    TEST_TMPDIR="$(mktemp -d)"

    # Minimal snap environment variables required by the launcher
    export SNAP_DATA="${TEST_TMPDIR}/data"
    export SNAP_COMMON="${TEST_TMPDIR}/common"
    export SNAP="${TEST_TMPDIR}/snap"
    export SNAP_NAME="pihole"
    mkdir -p "${SNAP_DATA}" "${SNAP_COMMON}" "${SNAP}/usr/bin"

    # Create a stub pihole-FTL binary so `exec` doesn't fail. The TLS
    # bootstrap probe succeeds and creates the certificate so unrelated
    # tests exercise the quiet code path.
    FTL_STUB="${SNAP}/usr/bin/pihole-FTL"
    printf '#!/bin/sh\nif [ "$1" = "--gen-x509" ]; then printf cert > "$2"; exit 0; fi\necho "STUB:pihole-FTL $*"\n' > "${FTL_STUB}"
    chmod +x "${FTL_STUB}"

    # Copy the launcher directly
    LAUNCHER="${TEST_TMPDIR}/launcher-ftl"
    cp "${REPO_ROOT}/snap/local/runtime/launcher-ftl.sh" "${LAUNCHER}"
    cp "${REPO_ROOT}/snap/local/runtime/pihole-config.sh" "${TEST_TMPDIR}/pihole-config.sh"
    chmod +x "${LAUNCHER}"

    # Create dummy gravity.db to prevent the background spawn of `pihole -g`
    # from hanging the bats test due to open FDs from the background subshell.
    mkdir -p "${SNAP_DATA}/etc/pihole"
    echo "mock_data" > "${SNAP_DATA}/etc/pihole/gravity.db"
}

teardown() {
    rm -rf "${TEST_TMPDIR}"
}

_remove_gravity_db() {
    rm -f "${SNAP_DATA}/etc/pihole/gravity.db"
}

_install_gravity_seed_stubs() {
    local dig_status="$1"

    mkdir -p "${SNAP}/opt/pihole" "${SNAP}/usr/bin"

    cat > "${SNAP}/opt/pihole/pihole" <<EOF
#!/bin/sh
echo "PIHOLE:\$*" >> "${TEST_TMPDIR}/pihole-gravity.log"
printf 'gravity command: %s\n' "\$*"
exit 0
EOF
    chmod +x "${SNAP}/opt/pihole/pihole"

    cat > "${SNAP}/usr/bin/pihole-FTL" <<EOF
#!/bin/sh
echo "FTL:\$*" >> "${TEST_TMPDIR}/ftl.log"
if [ "\$1" = "--gen-x509" ]; then
    printf 'cert' > "\$2"
    exit 0
fi
exit 0
EOF
    chmod +x "${SNAP}/usr/bin/pihole-FTL"

    cat > "${SNAP}/usr/bin/dig" <<EOF
#!/bin/sh
echo "DIG:\$*" >> "${TEST_TMPDIR}/dig.log"
exit ${dig_status}
EOF
    chmod +x "${SNAP}/usr/bin/dig"

    # Keep the readiness-loop failure case deterministic and fast.
    cat > "${SNAP}/usr/bin/seq" <<'EOF'
#!/bin/sh
printf '1\n2\n'
EOF
    chmod +x "${SNAP}/usr/bin/seq"

    cat > "${SNAP}/usr/bin/sleep" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "${SNAP}/usr/bin/sleep"
}

_install_ftl_tls_stub() {
    local gen_status="$1"
    local openssl_status="${2:-1}"

    cat > "${SNAP}/usr/bin/pihole-FTL" <<EOF
#!/bin/sh
echo "FTL:\$*" >> "${TEST_TMPDIR}/ftl.log"
if [ "\$1" = "--gen-x509" ]; then
    if [ "${gen_status}" -eq 0 ]; then
        printf 'cert' > "\$2"
    fi
    exit ${gen_status}
fi
exit 0
EOF
    chmod +x "${SNAP}/usr/bin/pihole-FTL"

    cat > "${SNAP}/usr/bin/openssl" <<EOF
#!/bin/sh
echo "OPENSSL:\$*" >> "${TEST_TMPDIR}/openssl.log"
prev=
for arg in "\$@"; do
    case "\$prev" in
        -keyout) printf 'key' > "\$arg" ;;
        -out) printf 'crt' > "\$arg" ;;
    esac
    prev="\$arg"
done
exit ${openssl_status}
EOF
    chmod +x "${SNAP}/usr/bin/openssl"
}

# Directory and config seeding

@test "creates required directories when they do not exist" {
    SNAP="${SNAP}" SNAP_DATA="${SNAP_DATA}" SNAP_COMMON="${SNAP_COMMON}" bash "${LAUNCHER}" 2>/dev/null || true

    [ -d "${SNAP_DATA}/etc/pihole" ]
    [ -d "${SNAP_DATA}/etc/dnsmasq.d" ]
    [ -d "${SNAP_DATA}/run/pihole" ]
    [ -d "${SNAP_COMMON}/var/log/pihole" ]
}

@test "seeds pihole.toml with default upstreams when none exists" {
    mkdir -p "${SNAP_DATA}/etc/pihole"
    TOML="${SNAP_DATA}/etc/pihole/pihole.toml"
    [ ! -f "${TOML}" ]  # pre-condition: does not exist yet

    SNAP="${SNAP}" SNAP_DATA="${SNAP_DATA}" SNAP_COMMON="${SNAP_COMMON}" bash "${LAUNCHER}" 2>/dev/null || true

    [ -f "${TOML}" ]
    grep -q '\[dns\]' "${TOML}"
    grep -q 'upstreams' "${TOML}"
    grep -q '8.8.8.8' "${TOML}"
}

@test "does not overwrite an existing pihole.toml" {
    mkdir -p "${SNAP_DATA}/etc/pihole"
    TOML="${SNAP_DATA}/etc/pihole/pihole.toml"
    echo "existing=content" > "${TOML}"

    SNAP="${SNAP}" SNAP_DATA="${SNAP_DATA}" SNAP_COMMON="${SNAP_COMMON}" bash "${LAUNCHER}" 2>/dev/null || true

    # File must still contain the original content and NOT the default upstreams
    grep -q "existing=content" "${TOML}"
    if grep -q '\[dns\]' "${TOML}"; then
        false
    fi
}

# Environment setup

@test "exports HOME as SNAP_DATA" {
    # Replace FTL stub with one that records HOME
    printf '#!/bin/sh\necho "HOME=${HOME}"\n' > "${SNAP}/usr/bin/pihole-FTL"
    chmod +x "${SNAP}/usr/bin/pihole-FTL"

    run bash "${LAUNCHER}"
    [[ "$output" == *"HOME=${SNAP_DATA}"* ]]
}

@test "changes cwd to run/pihole before exec" {
    LAUNCHER_CWD="${TEST_TMPDIR}/launcher-cwd"
    cp "${LAUNCHER}" "${LAUNCHER_CWD}"
    chmod +x "${LAUNCHER_CWD}"

    # Replace FTL stub with one that records cwd
    printf '#!/bin/sh\npwd\n' > "${SNAP}/usr/bin/pihole-FTL"
    chmod +x "${SNAP}/usr/bin/pihole-FTL"

    run bash "${LAUNCHER_CWD}"
    [ "$status" -eq 0 ]
    # The cwd should be the /run/pihole equivalent in our tmpdir
    [[ "$output" == *"run/pihole"* ]]
}

# First-run gravity seeding

@test "first-run gravity seeding runs initial gravity, inserts default adlist, and runs pass 2 when FTL DNS is ready" {
    _remove_gravity_db
    _install_gravity_seed_stubs 0

    run bash "${LAUNCHER}"
    [ "$status" -eq 0 ]

    [ -f "${SNAP_COMMON}/var/log/pihole/gravity-init.log" ]
    [ -f "${SNAP_COMMON}/var/log/pihole/gravity-first-run.log" ]
    [ "$(grep -c 'PIHOLE:-g' "${TEST_TMPDIR}/pihole-gravity.log")" -eq 2 ]
    grep -q "DIG:+short +time=1 +tries=1 @127.0.0.1 . NS" "${TEST_TMPDIR}/dig.log"
    grep -q "FTL:sqlite3 ${SNAP_DATA}/etc/pihole/gravity.db" "${TEST_TMPDIR}/ftl.log"
    grep -q "Steven Black unified hosts (default)" "${TEST_TMPDIR}/ftl.log"
}

@test "first-run gravity seeding gives up without pass 2 when FTL DNS never becomes ready" {
    _remove_gravity_db
    _install_gravity_seed_stubs 1

    run bash "${LAUNCHER}"
    [ "$status" -eq 0 ]

    [ -f "${SNAP_COMMON}/var/log/pihole/gravity-init.log" ]
    [ ! -f "${SNAP_COMMON}/var/log/pihole/gravity-first-run.log" ]
    [ "$(grep -c 'PIHOLE:-g' "${TEST_TMPDIR}/pihole-gravity.log")" -eq 1 ]
    [ "$(grep -c 'DIG:' "${TEST_TMPDIR}/dig.log")" -eq 2 ]
    [[ "$output" == *"FTL DNS did not become ready within 90 s; skipping background gravity update."* ]]
}

# TLS certificate bootstrap (issue #13)

@test "keeps default TLS-capable webserver ports when certificate generation succeeds" {
    _install_ftl_tls_stub 0

    run bash "${LAUNCHER}"
    [ "$status" -eq 0 ]

    [ -s "${SNAP_DATA}/etc/pihole/tls.pem" ]
    if grep -q "webserver.port" "${TEST_TMPDIR}/ftl.log"; then
        false
    fi
}

@test "falls back to HTTP-only webserver ports when certificate generation fails" {
    _install_ftl_tls_stub 1

    run bash "${LAUNCHER}"
    [ "$status" -eq 0 ]

    [ ! -e "${SNAP_DATA}/etc/pihole/tls.pem" ]
    grep -qF 'FTL:--config webserver.port 80o,[::]:80o' "${TEST_TMPDIR}/ftl.log"
    [[ "$output" == *"TLS certificate generation failed"* ]]
}

@test "repairs a mis-quoted webserver.port artifact when no certificate can be generated" {
    _install_ftl_tls_stub 1
    printf '[webserver]\n  port = "\\"80o,[::]:80o\\""\n' > "${SNAP_DATA}/etc/pihole/pihole.toml"

    run bash "${LAUNCHER}"
    [ "$status" -eq 0 ]

    grep -qF 'FTL:--config webserver.port 80o,[::]:80o' "${TEST_TMPDIR}/ftl.log"
    [[ "$output" == *"Repaired webserver.port"* ]]
}

@test "repairs a mis-quoted webserver.port artifact keeping TLS when a certificate exists" {
    _install_ftl_tls_stub 0
    mkdir -p "${SNAP_DATA}/etc/pihole"
    printf 'cert' > "${SNAP_DATA}/etc/pihole/tls.pem"
    printf '[webserver]\n  port = "\\"80o,[::]:80o\\""\n' > "${SNAP_DATA}/etc/pihole/pihole.toml"

    run bash "${LAUNCHER}"
    [ "$status" -eq 0 ]

    grep -qF 'FTL:--config webserver.port 80o,443os,[::]:80o,[::]:443os' "${TEST_TMPDIR}/ftl.log"
}

@test "generates the TLS certificate with staged OpenSSL when FTL's generator fails" {
    _install_ftl_tls_stub 1 0

    run bash "${LAUNCHER}"
    [ "$status" -eq 0 ]

    [ -s "${SNAP_DATA}/etc/pihole/tls.pem" ]
    if grep -q "webserver.port" "${TEST_TMPDIR}/ftl.log"; then
        false
    fi
    grep -qF 'OPENSSL:req' "${TEST_TMPDIR}/openssl.log"
    [[ "$output" == *"(OpenSSL fallback)"* ]]
}

@test "repairs a mis-quoted webserver.port artifact using an OpenSSL-generated certificate" {
    _install_ftl_tls_stub 1 0
    printf '[webserver]\n  port = "\\"80o,[::]:80o\\""\n' > "${SNAP_DATA}/etc/pihole/pihole.toml"

    run bash "${LAUNCHER}"
    [ "$status" -eq 0 ]

    [ -s "${SNAP_DATA}/etc/pihole/tls.pem" ]
    grep -qF 'FTL:--config webserver.port 80o,443os,[::]:80o,[::]:443os' "${TEST_TMPDIR}/ftl.log"
}

@test "does not touch an operator-configured webserver.port" {
    _install_ftl_tls_stub 1
    printf '[webserver]\n  port = "8080o"\n' > "${SNAP_DATA}/etc/pihole/pihole.toml"

    run bash "${LAUNCHER}"
    [ "$status" -eq 0 ]

    if grep -q "webserver.port" "${TEST_TMPDIR}/ftl.log"; then
        false
    fi
}

# Web password bootstrap (GitHub issue #14)

_write_web_toml() {
    local port_line="$1"
    local pwhash_line="$2"

    mkdir -p "${SNAP_DATA}/etc/pihole"
    {
        echo '[dns]'
        echo '  upstreams = ["8.8.8.8"]'
        echo '[webserver]'
        if [ "$port_line" = "OMIT" ]; then
            :
        else
            echo "  port = \"${port_line}\""
        fi
        echo '[webserver.api]'
        if [ -n "$pwhash_line" ]; then
            echo "  pwhash = \"${pwhash_line}\""
        else
            echo '  pwhash = ""'
        fi
    } > "${SNAP_DATA}/etc/pihole/pihole.toml"
}

@test "generates and announces a web password on first boot when the API is network-reachable" {
    # No pihole.toml: the launcher seeds the minimal [dns] config, which has
    # no webserver keys, i.e. FTL's all-interfaces default applies.
    rm -f "${SNAP_DATA}/etc/pihole/pihole.toml"

    # The launcher redirects the password config call's output, so record
    # invocations in a log file to verify the exact call and argument.
    cat > "${SNAP}/usr/bin/pihole-FTL" <<EOF
#!/bin/sh
echo "FTL:\$*" >> "${TEST_TMPDIR}/ftl-config.log"
echo "STUB:pihole-FTL \$*"
EOF
    chmod +x "${SNAP}/usr/bin/pihole-FTL"

    run bash "${LAUNCHER}"
    [ "$status" -eq 0 ]

    # Password applied through the same FTL config call upstream setpassword uses
    grep -q -- '--config webserver.api.password ' "${TEST_TMPDIR}/ftl-config.log"

    # Root-only password file with a 20-char alphanumeric secret
    [ -f "${SNAP_DATA}/etc/pihole/web_pw" ]
    [ "$(stat -c '%a' "${SNAP_DATA}/etc/pihole/web_pw")" = "600" ]
    grep -Eq '^[A-Za-z0-9]{20}$' "${SNAP_DATA}/etc/pihole/web_pw"

    # The secret applied to FTL must be the same one stored on disk
    stored_pw="$(cat "${SNAP_DATA}/etc/pihole/web_pw")"
    applied_pw="$(awk '$2 == "webserver.api.password" { print $3 }' "${TEST_TMPDIR}/ftl-config.log")"
    [ "${applied_pw}" = "${stored_pw}" ]

    # Prominent banner: the secret, its on-disk location, and how to replace it
    [[ "$output" == *"SECURITY NOTICE (web interface password)"* ]]
    [[ "$output" == *"/var/snap/${SNAP_NAME}/current/etc/pihole/web_pw"* ]]
    [[ "$output" == *"sudo pihole setpassword"* ]]
    [[ "$output" == *"    ${stored_pw}"* ]]
}

@test "does not regenerate or re-announce when a password hash already exists" {
    _write_web_toml "80o,443os,[::]:80o,[::]:443os" '$argon2id$v=19$m=1048576,t=1,p=8$c2FsdA$aGFzaA'

    run bash "${LAUNCHER}"
    [ "$status" -eq 0 ]

    [ ! -f "${SNAP_DATA}/etc/pihole/web_pw" ]
    [[ "$output" != *"SECURITY NOTICE"* ]]
    [[ "$output" != *"--config webserver.api.password"* ]]
}

@test "does not generate a password when the webserver is loopback-only" {
    _write_web_toml "127.0.0.1:8080s,[::1]:8080s" ""

    run bash "${LAUNCHER}"
    [ "$status" -eq 0 ]

    [ ! -f "${SNAP_DATA}/etc/pihole/web_pw" ]
    [[ "$output" == *"loopback only; no password was generated"* ]]
    [[ "$output" != *"SECURITY NOTICE"* ]]
}

@test "does not generate a password when the webserver is disabled" {
    _write_web_toml "" ""

    run bash "${LAUNCHER}"
    [ "$status" -eq 0 ]

    [ ! -f "${SNAP_DATA}/etc/pihole/web_pw" ]
    [[ "$output" == *"webserver/API is disabled (webserver.port is empty)"* ]]
}

@test "warns instead of regenerating after a deliberate password removal" {
    _write_web_toml "80o,[::]:80o" ""
    echo "previously-generated-password" > "${SNAP_DATA}/etc/pihole/web_pw"

    run bash "${LAUNCHER}"
    [ "$status" -eq 0 ]

    [[ "$output" == *"WARNING: the web interface password is disabled"* ]]
    [[ "$output" == *"sudo pihole setpassword"* ]]
    # The stored marker must be left untouched and no new password applied
    [ "$(cat "${SNAP_DATA}/etc/pihole/web_pw")" = "previously-generated-password" ]
    [[ "$output" != *"--config webserver.api.password"* ]]
}

@test "keeps starting the daemon when the generated password cannot be applied" {
    rm -f "${SNAP_DATA}/etc/pihole/pihole.toml"
    mkdir -p "${SNAP_DATA}/etc/pihole"
    printf 'cert' > "${SNAP_DATA}/etc/pihole/tls.pem"

    # FTL stub that fails only for the password config call but still
    # succeeds for the final exec and the gravity sqlite3 call.
    cat > "${SNAP}/usr/bin/pihole-FTL" <<'EOF'
#!/bin/sh
case "$*" in
    *"webserver.api.password"*) exit 1 ;;
    *) exit 0 ;;
esac
EOF
    chmod +x "${SNAP}/usr/bin/pihole-FTL"

    run bash "${LAUNCHER}"
    [ "$status" -eq 0 ]

    [[ "$output" == *"generated web interface password could not be applied"* ]]
    [ ! -f "${SNAP_DATA}/etc/pihole/web_pw" ]
}

@test "skips the web password check when a non-empty pihole.toml cannot be parsed" {
    mkdir -p "${SNAP_DATA}/etc/pihole"
    printf '# a future FTL config syntax the flat parser cannot read\n' > "${SNAP_DATA}/etc/pihole/pihole.toml"

    run bash "${LAUNCHER}"
    [ "$status" -eq 0 ]

    [ ! -f "${SNAP_DATA}/etc/pihole/web_pw" ]
    [[ "$output" == *"could not read key/value pairs"* ]]
    [[ "$output" == *"skipping the web password check"* ]]
    [[ "$output" != *"SECURITY NOTICE"* ]]
    [[ "$output" != *"WARNING: the web interface password is disabled"* ]]
}
