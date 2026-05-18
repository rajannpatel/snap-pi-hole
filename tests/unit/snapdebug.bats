#!/usr/bin/env bats
#
# Unit tests for snap/local/snapdebug

setup() {
    REPO_ROOT="$(git rev-parse --show-toplevel)"
    TMPDIR="$(mktemp -d)"
    export SNAP_DATA="${TMPDIR}/data"
    export SNAP_COMMON="${TMPDIR}/common"
    export SNAP_NAME="pihole"
    mkdir -p "${SNAP_DATA}/etc/pihole"
    mkdir -p "${SNAP_COMMON}/var/log/pihole"

    # Create fake pihole.toml, logs, and database files
    echo 'password = "secret_password_here"' > "${SNAP_DATA}/etc/pihole/pihole.toml"
    echo 'some_setting = "value"' >> "${SNAP_DATA}/etc/pihole/pihole.toml"
    echo '[dns]' >> "${SNAP_DATA}/etc/pihole/pihole.toml"
    echo '  upstreams = ["8.8.8.8"]' >> "${SNAP_DATA}/etc/pihole/pihole.toml"
    
    echo "Log line 1" > "${SNAP_COMMON}/var/log/pihole/pihole-FTL.log"

    echo "fake db data" > "${SNAP_DATA}/etc/pihole/gravity.db"
    echo "fake db data" > "${SNAP_DATA}/etc/pihole/pihole-FTL.db"

    # Create fake pihole-FTL stub to mock sqlite3 calls
    export SNAP="${TMPDIR}/snap"
    mkdir -p "${SNAP}/usr/bin"
    cat > "${SNAP}/usr/bin/pihole-FTL" <<'EOF'
#!/bin/bash
if [ "$1" = "sqlite3" ]; then
    if [[ "$3" == *"SELECT count(*)"* ]]; then
        echo "1"
    fi
fi
EOF
    chmod +x "${SNAP}/usr/bin/pihole-FTL"

    # Setup a mock bin directory to intercept snapctl, timeout, dmesg
    export MOCK_BIN="${TMPDIR}/bin"
    mkdir -p "${MOCK_BIN}"
    export PATH="${MOCK_BIN}:${PATH}"

    # Default mocks (can be overridden in tests)
    cat > "${MOCK_BIN}/snapctl" <<'EOF'
#!/bin/bash
if [ "$1" = "get" ] && [ "$2" = "version" ]; then
    echo "1.2.3"
elif [ "$1" = "is-connected" ]; then
    exit 0
elif [ "$1" = "services" ]; then
    echo "pihole.pihole-ftl is active"
fi
EOF
    chmod +x "${MOCK_BIN}/snapctl"

    cat > "${MOCK_BIN}/timeout" <<'EOF'
#!/bin/bash
# Mock timeout to fail (port free)
exit 1
EOF
    chmod +x "${MOCK_BIN}/timeout"

    cat > "${MOCK_BIN}/dmesg" <<'EOF'
#!/bin/bash
echo "clean log"
EOF
    chmod +x "${MOCK_BIN}/dmesg"

    # Our script under test
    SCRIPT_UNDER_TEST="${REPO_ROOT}/snap/local/snapdebug"
}

teardown() {
    rm -rf "${TMPDIR}"
}

@test "snapdebug outputs basic diagnostic structure" {
    run "${SCRIPT_UNDER_TEST}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PI-HOLE SNAP DIAGNOSTIC DUMP"* ]]
    [[ "$output" == *"Snap Version: 1.2.3"* ]]
    [[ "$output" == *"--- INTERFACES ---"* ]]
    [[ "$output" == *"--- PORTS ---"* ]]
    [[ "$output" == *"--- DATABASES ---"* ]]
    [[ "$output" == *"--- CONFINEMENT ---"* ]]
    [[ "$output" == *"--- PIHOLE.TOML CONFIGURATION ---"* ]]
    [[ "$output" == *"--- TAIL OF FTL LOG ---"* ]]
    [[ "$output" == *"END OF DIAGNOSTIC DUMP"* ]]
}

@test "snapdebug redacts the pihole.toml password" {
    run "${SCRIPT_UNDER_TEST}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"password = \"[REDACTED]\""* ]]
    [[ "$output" != *"secret_password_here"* ]]
}

@test "snapdebug detects disconnected required interfaces" {
    cat > "${MOCK_BIN}/snapctl" <<'EOF'
#!/bin/bash
if [ "$1" = "is-connected" ]; then
    if [ "$2" = "network-bind" ]; then
        exit 1
    fi
    exit 0
fi
EOF
    run "${SCRIPT_UNDER_TEST}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[FAIL] network-bind (disconnected - core functionality affected)"* ]]
    [[ "$output" == *"[OK]   network"* ]]
}

@test "snapdebug shows INFO for disconnected optional interfaces" {
    cat > "${MOCK_BIN}/snapctl" <<'EOF'
#!/bin/bash
if [ "$1" = "is-connected" ]; then
    if [ "$2" = "system-observe" ]; then exit 1; fi
    exit 0
fi
if [ "$1" = "services" ]; then echo "pihole.pihole-ftl is active"; fi
EOF
    run "${SCRIPT_UNDER_TEST}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[INFO] system-observe (disconnected - optional:"* ]]
}

@test "snapdebug flags unexpected apparmor denials if system-observe is connected" {
    cat > "${MOCK_BIN}/snapctl" <<'EOF'
#!/bin/bash
if [ "$1" = "is-connected" ]; then
    exit 0 # system-observe connected
fi
if [ "$1" = "services" ]; then echo "pihole.pihole-ftl is active"; fi
EOF
    cat > "${MOCK_BIN}/dmesg" <<'EOF'
#!/bin/bash
echo "apparmor=\"DENIED\" operation=\"open\" profile=\"snap.pihole.pihole-ftl\" name=\"/some/unexpected/path\""
EOF
    run "${SCRIPT_UNDER_TEST}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[WARN] Unexpected AppArmor denials"* ]]
    [[ "$output" == *"apparmor=\"DENIED\""* ]]
}

@test "snapdebug filters benign dmi and proc denials as non-fatal" {
    cat > "${MOCK_BIN}/snapctl" <<'EOF'
#!/bin/bash
if [ "$1" = "is-connected" ]; then exit 0; fi
if [ "$1" = "services" ]; then echo "pihole.pihole-ftl is active"; fi
EOF
    cat > "${MOCK_BIN}/dmesg" <<'EOF'
#!/bin/bash
echo "apparmor=\"DENIED\" profile=\"snap.pihole.pihole-ftl\" name=\"/sys/devices/virtual/dmi/id/bios_vendor\""
echo "apparmor=\"DENIED\" profile=\"snap.pihole.pihole-ftl\" name=\"/proc/123/comm\""
echo "apparmor=\"DENIED\" profile=\"snap.pihole.pihole-ftl\" name=\"/etc/ldap/ldap.conf\""
EOF
    run "${SCRIPT_UNDER_TEST}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[OK] No unexpected AppArmor denials"* ]]
    [[ "$output" != *"[WARN] Unexpected AppArmor denials"* ]]
}

@test "snapdebug skips dmesg check if system-observe is disconnected" {
    cat > "${MOCK_BIN}/snapctl" <<'EOF'
#!/bin/bash
if [ "$1" = "is-connected" ]; then
    if [ "$2" = "system-observe" ]; then exit 1; fi
    exit 0
fi
if [ "$1" = "services" ]; then echo "pihole.pihole-ftl is active"; fi
EOF
    cat > "${MOCK_BIN}/dmesg" <<'EOF'
#!/bin/bash
echo "apparmor=\"DENIED\" operation=\"open\" profile=\"snap.pihole.pihole-ftl\""
EOF
    run "${SCRIPT_UNDER_TEST}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"system-observe not connected; AppArmor denial check skipped"* ]]
    [[ "$output" == *"system-observe is optional"* ]]
    [[ "$output" != *"apparmor=\"DENIED\""* ]]
}

@test "snapdebug detects port 53 tcp conflicts when ftl is not running" {
    cat > "${MOCK_BIN}/snapctl" <<'EOF'
#!/bin/bash
if [ "$1" = "services" ]; then
    echo "pihole.pihole-ftl is inactive"
fi
exit 0
EOF
    # timeout 1 succeeds -> means port is in use
    cat > "${MOCK_BIN}/timeout" <<'EOF'
#!/bin/bash
exit 0
EOF
    run "${SCRIPT_UNDER_TEST}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[FAIL] Port 53 (TCP) - systemd-resolved conflict on 127.0.0.53"* ]]
}

@test "snapdebug skips port checks when ftl is running" {
    cat > "${MOCK_BIN}/snapctl" <<'EOF'
#!/bin/bash
if [ "$1" = "services" ]; then
    echo "pihole.pihole-ftl is active"
fi
exit 0
EOF
    run "${SCRIPT_UNDER_TEST}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[OK] pihole-FTL is active. Port conflict checks skipped."* ]]
    [[ "$output" != *"[FAIL] Port 53 (TCP)"* ]]
}

@test "snapdebug tails the FTL log" {
    run "${SCRIPT_UNDER_TEST}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Log line 1"* ]]
}

@test "snapdebug detects missing gravity.db" {
    rm "${SNAP_DATA}/etc/pihole/gravity.db"
    run "${SCRIPT_UNDER_TEST}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[FAIL] gravity.db is missing"* ]]
}

@test "snapdebug detects 0-byte gravity.db" {
    > "${SNAP_DATA}/etc/pihole/gravity.db" # truncate to 0 bytes
    run "${SCRIPT_UNDER_TEST}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[FAIL] gravity.db exists but is 0 bytes"* ]]
}

@test "snapdebug detects valid gravity.db" {
    run "${SCRIPT_UNDER_TEST}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[OK] gravity.db is present and populated"* ]]
}

@test "snapdebug detects missing pihole-FTL.db as WARN" {
    rm "${SNAP_DATA}/etc/pihole/pihole-FTL.db"
    run "${SCRIPT_UNDER_TEST}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[WARN] pihole-FTL.db is missing or empty"* ]]
}

@test "snapdebug fails if pihole.toml missing upstreams" {
    echo 'some_setting = "value"' > "${SNAP_DATA}/etc/pihole/pihole.toml"
    run "${SCRIPT_UNDER_TEST}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[FAIL] No upstream DNS servers found in pihole.toml"* ]]
}

@test "snapdebug flags missing adlists" {
    cat > "${SNAP}/usr/bin/pihole-FTL" <<'EOF'
#!/bin/bash
echo "0"
EOF
    chmod +x "${SNAP}/usr/bin/pihole-FTL"

    run "${SCRIPT_UNDER_TEST}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[WARN] No enabled adlists found in gravity.db"* ]]
}
