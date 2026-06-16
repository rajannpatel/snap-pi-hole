#!/usr/bin/env bats

setup() {
    REPO_ROOT="$(git rev-parse --show-toplevel)"
    export TEST_TMPDIR="$(mktemp -d)"
    MOCK_BIN="${TEST_TMPDIR}/bin"
    mkdir -p "$MOCK_BIN"
    export PATH="${MOCK_BIN}:${PATH}"
    
    export SNAP_NAME="pihole-by-rajannpatel"

    # Create sudo stub that replaces /var/snap/ paths with TEST_TMPDIR/var/snap/ and resolves wildcards
    cat > "${MOCK_BIN}/sudo" <<'EOF'
#!/bin/bash
args=()
for arg in "$@"; do
  if [[ "$arg" == /var/snap/* ]]; then
    pattern="${TEST_TMPDIR}${arg}"
    if [[ "$pattern" == *"*"* ]]; then
      # Expand glob on translated path
      files=($pattern)
      if [ -e "${files[0]}" ]; then
        args+=("${files[@]}")
      else
        args+=("$pattern")
      fi
    else
      args+=("$pattern")
    fi
  else
    args+=("$arg")
  fi
done
exec "${args[@]}"
EOF
    chmod +x "${MOCK_BIN}/sudo"

    cat > "${MOCK_BIN}/${SNAP_NAME}.pihole" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "${MOCK_BIN}/${SNAP_NAME}.pihole"

    cat > "${MOCK_BIN}/uname" <<'EOF'
#!/bin/sh
echo "aarch64"
EOF
    chmod +x "${MOCK_BIN}/uname"

    cat > "${MOCK_BIN}/sleep" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "${MOCK_BIN}/sleep"

    cat > "${MOCK_BIN}/date" <<'EOF'
#!/bin/sh
if [ "$*" = "-u +%Y-%m-%dT%H:%M:%SZ" ]; then
  echo "2026-06-15T12:00:00Z"
else
  /usr/bin/date "$@"
fi
EOF
    chmod +x "${MOCK_BIN}/date"

    mkdir -p "${TEST_TMPDIR}/var/snap/${SNAP_NAME}/current/etc/pihole"
    mkdir -p "${TEST_TMPDIR}/var/snap/${SNAP_NAME}/common/snapshots"
    echo "gravity" > "${TEST_TMPDIR}/var/snap/${SNAP_NAME}/current/etc/pihole/gravity.db"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

@test "parse snap info extracts stable and edge revisions" {
    CHANNEL_SWITCH_TEST_MODE=1 source "${REPO_ROOT}/tests/scripts/channel-switch-smoke.sh"
    
    cat > "${TEST_TMPDIR}/mock_info" <<'EOF'
channels:
  latest/stable:    v6.4.2              2026-06-08 (123) 14MB -
  latest/edge:      v6.4.2+git.abc.123  2026-06-08 (124) 14MB -
EOF

    run parse_snap_info "${TEST_TMPDIR}/mock_info" "latest/stable"
    [ "$status" -eq 0 ]
    [ "$output" = "v6.4.2 123" ]

    run parse_snap_info "${TEST_TMPDIR}/mock_info" "latest/edge"
    [ "$status" -eq 0 ]
    [ "$output" = "v6.4.2+git.abc.123 124" ]
}

@test "parse snap info handles channels in any order" {
    CHANNEL_SWITCH_TEST_MODE=1 source "${REPO_ROOT}/tests/scripts/channel-switch-smoke.sh"
    
    cat > "${TEST_TMPDIR}/mock_info" <<'EOF'
channels:
  latest/edge:      v6.4.2+git.abc.123  2026-06-08 (124) 14MB -
  latest/stable:    v6.4.2              2026-06-08 (123) 14MB -
EOF

    run parse_snap_info "${TEST_TMPDIR}/mock_info" "latest/stable"
    [ "$status" -eq 0 ]
    [ "$output" = "v6.4.2 123" ]
}

@test "parse snap info fails when stable missing" {
    CHANNEL_SWITCH_TEST_MODE=1 source "${REPO_ROOT}/tests/scripts/channel-switch-smoke.sh"
    
    cat > "${TEST_TMPDIR}/mock_info" <<'EOF'
channels:
  latest/edge:      v6.4.2+git.abc.123  2026-06-08 (124) 14MB -
EOF

    run parse_snap_info "${TEST_TMPDIR}/mock_info" "latest/stable"
    [ "$status" -ne 0 ]
}

@test "parse snap info fails when edge missing" {
    CHANNEL_SWITCH_TEST_MODE=1 source "${REPO_ROOT}/tests/scripts/channel-switch-smoke.sh"
    
    cat > "${TEST_TMPDIR}/mock_info" <<'EOF'
channels:
  latest/stable:    v6.4.2              2026-06-08 (123) 14MB -
EOF

    run parse_snap_info "${TEST_TMPDIR}/mock_info" "latest/edge"
    [ "$status" -ne 0 ]
}

@test "same revision skip writes skipped result" {
    export CHANNEL_SWITCH_RESULT="${TEST_TMPDIR}/result.json"
    
    cat > "${TEST_TMPDIR}/mock_snap_info" <<'EOF'
channels:
  latest/stable:    v6.4.2              2026-06-08 (123) 14MB -
  latest/edge:      v6.4.2              2026-06-08 (123) 14MB -
EOF

    cat > "${MOCK_BIN}/snap" <<'EOF'
#!/bin/sh
if [ "$1" = "info" ]; then
  cat "${TEST_TMPDIR}/mock_snap_info"
else
  exit 0
fi
EOF
    chmod +x "${MOCK_BIN}/snap"

    run bash "${REPO_ROOT}/tests/scripts/channel-switch-smoke.sh"
    [ "$status" -eq 0 ]
    
    [ -f "$CHANNEL_SWITCH_RESULT" ]
    run jq -r '.status' "$CHANNEL_SWITCH_RESULT"
    [ "$output" = "skipped" ]
    run jq -r '.reason' "$CHANNEL_SWITCH_RESULT"
    [ "$output" = "stable-and-edge-same-revision" ]
}

@test "invalid path exits with reason invalid-path" {
    export CHANNEL_SWITCH_RESULT="${TEST_TMPDIR}/result.json"
    export CHANNEL_SWITCH_PATH="bad"
    
    run bash "${REPO_ROOT}/tests/scripts/channel-switch-smoke.sh"
    [ "$status" -eq 2 ]
    
    [ -f "$CHANNEL_SWITCH_RESULT" ]
    run jq -r '.status' "$CHANNEL_SWITCH_RESULT"
    [ "$output" = "failure" ]
    run jq -r '.reason' "$CHANNEL_SWITCH_RESULT"
    [ "$output" = "invalid-path" ]
}

@test "roundtrip path schedules two transitions" {
    export CHANNEL_SWITCH_RESULT="${TEST_TMPDIR}/result.json"
    export CHANNEL_SWITCH_PATH="roundtrip"
    
    cat > "${TEST_TMPDIR}/mock_snap_info" <<'EOF'
channels:
  latest/stable:    v6.4.2              2026-06-08 (123) 14MB -
  latest/edge:      v6.4.2+git.abc.124  2026-06-08 (124) 14MB -
EOF

    cat > "${MOCK_BIN}/snap" <<'EOF'
#!/bin/sh
if [ "$1" = "info" ]; then
  cat "${TEST_TMPDIR}/mock_snap_info"
elif [ "$1" = "services" ]; then
  echo "active"
else
  exit 0
fi
EOF
    chmod +x "${MOCK_BIN}/snap"

    cat > "${MOCK_BIN}/dig" <<'EOF'
#!/bin/sh
echo "pi.hole"
EOF
    chmod +x "${MOCK_BIN}/dig"

    cat > "${MOCK_BIN}/seq" <<'EOF'
#!/bin/sh
echo "1"
EOF
    chmod +x "${MOCK_BIN}/seq"

    # Seed files and config so tests pass checks
    echo 'ftl.webserver.port=8123' > "${TEST_TMPDIR}/var/snap/${SNAP_NAME}/current/etc/pihole/pihole.toml"
    touch "${TEST_TMPDIR}/var/snap/${SNAP_NAME}/common/snapshots/pihole-backup-123.tar.gz"

    cat > "${MOCK_BIN}/dmesg" <<'EOF'
#!/bin/sh
echo ""
EOF
    chmod +x "${MOCK_BIN}/dmesg"

    run bash "${REPO_ROOT}/tests/scripts/channel-switch-smoke.sh"
    [ "$status" -eq 0 ]
    
    [ -f "$CHANNEL_SWITCH_RESULT" ]
    run jq -r '.status' "$CHANNEL_SWITCH_RESULT"
    [ "$output" = "success" ]
    run jq -r '.arch' "$CHANNEL_SWITCH_RESULT"
    [ "$output" = "arm64" ]
    
    # Check transitions
    run jq -r '.transitions | length' "$CHANNEL_SWITCH_RESULT"
    [ "$output" = "2" ]
    
    run jq -r '.transitions[0].from' "$CHANNEL_SWITCH_RESULT"
    [ "$output" = "latest/stable" ]
    run jq -r '.transitions[0].to' "$CHANNEL_SWITCH_RESULT"
    [ "$output" = "latest/edge" ]
    run jq -r '.transitions[1].from' "$CHANNEL_SWITCH_RESULT"
    [ "$output" = "latest/edge" ]
    run jq -r '.transitions[1].to' "$CHANNEL_SWITCH_RESULT"
    [ "$output" = "latest/stable" ]

    run jq -r '.transitions[0].evidence[] | select(.command == "sudo snap refresh pihole-by-rajannpatel --channel=latest/edge") | .status' "$CHANNEL_SWITCH_RESULT"
    [ "$output" = "success" ]
    run jq -r '.transitions[0].evidence[] | select(.command == "snap list pihole-by-rajannpatel") | .title' "$CHANNEL_SWITCH_RESULT"
    [ "$output" = "Installed snap revision after refresh" ]
    run jq -r '.transitions[0].evidence[] | select(.command == "dig +short +time=1 +tries=1 @127.0.0.1 pi.hole") | .output' "$CHANNEL_SWITCH_RESULT"
    [ "$output" = "pi.hole" ]
}

@test "stable-to-edge schedules one transition" {
    export CHANNEL_SWITCH_RESULT="${TEST_TMPDIR}/result.json"
    export CHANNEL_SWITCH_PATH="stable-to-edge"
    
    cat > "${TEST_TMPDIR}/mock_snap_info" <<'EOF'
channels:
  latest/stable:    v6.4.2              2026-06-08 (123) 14MB -
  latest/edge:      v6.4.2+git.abc.124  2026-06-08 (124) 14MB -
EOF

    cat > "${MOCK_BIN}/snap" <<'EOF'
#!/bin/sh
if [ "$1" = "info" ]; then
  cat "${TEST_TMPDIR}/mock_snap_info"
elif [ "$1" = "services" ]; then
  echo "active"
else
  exit 0
fi
EOF
    chmod +x "${MOCK_BIN}/snap"

    cat > "${MOCK_BIN}/dig" <<'EOF'
#!/bin/sh
echo "pi.hole"
EOF
    chmod +x "${MOCK_BIN}/dig"

    cat > "${MOCK_BIN}/seq" <<'EOF'
#!/bin/sh
echo "1"
EOF
    chmod +x "${MOCK_BIN}/seq"

    # Seed files and config so tests pass checks
    echo 'ftl.webserver.port=8123' > "${TEST_TMPDIR}/var/snap/${SNAP_NAME}/current/etc/pihole/pihole.toml"
    touch "${TEST_TMPDIR}/var/snap/${SNAP_NAME}/common/snapshots/pihole-backup-123.tar.gz"

    cat > "${MOCK_BIN}/dmesg" <<'EOF'
#!/bin/sh
echo ""
EOF
    chmod +x "${MOCK_BIN}/dmesg"

    run bash "${REPO_ROOT}/tests/scripts/channel-switch-smoke.sh"
    [ "$status" -eq 0 ]
    
    [ -f "$CHANNEL_SWITCH_RESULT" ]
    run jq -r '.transitions | length' "$CHANNEL_SWITCH_RESULT"
    [ "$output" = "1" ]
    run jq -r '.transitions[0].from' "$CHANNEL_SWITCH_RESULT"
    [ "$output" = "latest/stable" ]
    run jq -r '.transitions[0].to' "$CHANNEL_SWITCH_RESULT"
    [ "$output" = "latest/edge" ]
}

@test "edge-to-stable schedules one transition" {
    export CHANNEL_SWITCH_RESULT="${TEST_TMPDIR}/result.json"
    export CHANNEL_SWITCH_PATH="edge-to-stable"
    
    cat > "${TEST_TMPDIR}/mock_snap_info" <<'EOF'
channels:
  latest/stable:    v6.4.2              2026-06-08 (123) 14MB -
  latest/edge:      v6.4.2+git.abc.124  2026-06-08 (124) 14MB -
EOF

    cat > "${MOCK_BIN}/snap" <<'EOF'
#!/bin/sh
if [ "$1" = "info" ]; then
  cat "${TEST_TMPDIR}/mock_snap_info"
elif [ "$1" = "services" ]; then
  echo "active"
else
  exit 0
fi
EOF
    chmod +x "${MOCK_BIN}/snap"

    cat > "${MOCK_BIN}/dig" <<'EOF'
#!/bin/sh
echo "pi.hole"
EOF
    chmod +x "${MOCK_BIN}/dig"

    cat > "${MOCK_BIN}/seq" <<'EOF'
#!/bin/sh
echo "1"
EOF
    chmod +x "${MOCK_BIN}/seq"

    # Seed files and config so tests pass checks
    echo 'ftl.webserver.port=8123' > "${TEST_TMPDIR}/var/snap/${SNAP_NAME}/current/etc/pihole/pihole.toml"
    touch "${TEST_TMPDIR}/var/snap/${SNAP_NAME}/common/snapshots/pihole-backup-123.tar.gz"

    cat > "${MOCK_BIN}/dmesg" <<'EOF'
#!/bin/sh
echo ""
EOF
    chmod +x "${MOCK_BIN}/dmesg"

    run bash "${REPO_ROOT}/tests/scripts/channel-switch-smoke.sh"
    [ "$status" -eq 0 ]
    
    [ -f "$CHANNEL_SWITCH_RESULT" ]
    run jq -r '.transitions | length' "$CHANNEL_SWITCH_RESULT"
    [ "$output" = "1" ]
    run jq -r '.transitions[0].from' "$CHANNEL_SWITCH_RESULT"
    [ "$output" = "latest/edge" ]
    run jq -r '.transitions[0].to' "$CHANNEL_SWITCH_RESULT"
    [ "$output" = "latest/stable" ]
}

@test "sentinel config failure marks transition failure" {
    export CHANNEL_SWITCH_RESULT="${TEST_TMPDIR}/result.json"
    export CHANNEL_SWITCH_PATH="stable-to-edge"
    
    cat > "${TEST_TMPDIR}/mock_snap_info" <<'EOF'
channels:
  latest/stable:    v6.4.2              2026-06-08 (123) 14MB -
  latest/edge:      v6.4.2+git.abc.124  2026-06-08 (124) 14MB -
EOF

    cat > "${MOCK_BIN}/snap" <<'EOF'
#!/bin/sh
if [ "$1" = "info" ]; then
  cat "${TEST_TMPDIR}/mock_snap_info"
elif [ "$1" = "services" ]; then
  echo "active"
else
  exit 0
fi
EOF
    chmod +x "${MOCK_BIN}/snap"

    cat > "${MOCK_BIN}/dig" <<'EOF'
#!/bin/sh
echo "pi.hole"
EOF
    chmod +x "${MOCK_BIN}/dig"

    cat > "${MOCK_BIN}/seq" <<'EOF'
#!/bin/sh
echo "1"
EOF
    chmod +x "${MOCK_BIN}/seq"

    # Seed tombarport but without '8123' so the grep sentinel check fails
    echo 'ftl.webserver.port=9999' > "${TEST_TMPDIR}/var/snap/${SNAP_NAME}/current/etc/pihole/pihole.toml"
    touch "${TEST_TMPDIR}/var/snap/${SNAP_NAME}/common/snapshots/pihole-backup-123.tar.gz"

    cat > "${MOCK_BIN}/dmesg" <<'EOF'
#!/bin/sh
echo ""
EOF
    chmod +x "${MOCK_BIN}/dmesg"

    run bash "${REPO_ROOT}/tests/scripts/channel-switch-smoke.sh"
    [ "$status" -eq 1 ]
    
    [ -f "$CHANNEL_SWITCH_RESULT" ]
    run jq -r '.status' "$CHANNEL_SWITCH_RESULT"
    [ "$output" = "failure" ]
    run jq -r '.reason' "$CHANNEL_SWITCH_RESULT"
    [ "$output" = "sentinel-config-missing" ]
    run jq -r '.transitions[0].checks.sentinel_config' "$CHANNEL_SWITCH_RESULT"
    [ "$output" = "failure" ]
}

@test "dns failure marks transition failure" {
    export CHANNEL_SWITCH_RESULT="${TEST_TMPDIR}/result.json"
    export CHANNEL_SWITCH_PATH="stable-to-edge"
    
    cat > "${TEST_TMPDIR}/mock_snap_info" <<'EOF'
channels:
  latest/stable:    v6.4.2              2026-06-08 (123) 14MB -
  latest/edge:      v6.4.2+git.abc.124  2026-06-08 (124) 14MB -
EOF

    cat > "${MOCK_BIN}/snap" <<'EOF'
#!/bin/sh
if [ "$1" = "info" ]; then
  cat "${TEST_TMPDIR}/mock_snap_info"
elif [ "$1" = "services" ]; then
  echo "active"
else
  exit 0
fi
EOF
    chmod +x "${MOCK_BIN}/snap"

    # Stub dig to fail
    cat > "${MOCK_BIN}/dig" <<'EOF'
#!/bin/sh
exit 1
EOF
    chmod +x "${MOCK_BIN}/dig"

    cat > "${MOCK_BIN}/seq" <<'EOF'
#!/bin/sh
echo "1"
EOF
    chmod +x "${MOCK_BIN}/seq"

    echo 'ftl.webserver.port=8123' > "${TEST_TMPDIR}/var/snap/${SNAP_NAME}/current/etc/pihole/pihole.toml"
    touch "${TEST_TMPDIR}/var/snap/${SNAP_NAME}/common/snapshots/pihole-backup-123.tar.gz"

    cat > "${MOCK_BIN}/dmesg" <<'EOF'
#!/bin/sh
echo ""
EOF
    chmod +x "${MOCK_BIN}/dmesg"

    run bash "${REPO_ROOT}/tests/scripts/channel-switch-smoke.sh"
    [ "$status" -eq 1 ]
    
    [ -f "$CHANNEL_SWITCH_RESULT" ]
    run jq -r '.status' "$CHANNEL_SWITCH_RESULT"
    [ "$output" = "failure" ]
    run jq -r '.reason' "$CHANNEL_SWITCH_RESULT"
    [ "$output" = "dns-failed" ]
}

@test "apparmor fatal denial marks transition failure" {
    export CHANNEL_SWITCH_RESULT="${TEST_TMPDIR}/result.json"
    export CHANNEL_SWITCH_PATH="stable-to-edge"
    
    cat > "${TEST_TMPDIR}/mock_snap_info" <<'EOF'
channels:
  latest/stable:    v6.4.2              2026-06-08 (123) 14MB -
  latest/edge:      v6.4.2+git.abc.124  2026-06-08 (124) 14MB -
EOF

    cat > "${MOCK_BIN}/snap" <<'EOF'
#!/bin/sh
if [ "$1" = "info" ]; then
  cat "${TEST_TMPDIR}/mock_snap_info"
elif [ "$1" = "services" ]; then
  echo "active"
else
  exit 0
fi
EOF
    chmod +x "${MOCK_BIN}/snap"

    cat > "${MOCK_BIN}/dig" <<'EOF'
#!/bin/sh
echo "pi.hole"
EOF
    chmod +x "${MOCK_BIN}/dig"

    cat > "${MOCK_BIN}/seq" <<'EOF'
#!/bin/sh
echo "1"
EOF
    chmod +x "${MOCK_BIN}/seq"

    echo 'ftl.webserver.port=8123' > "${TEST_TMPDIR}/var/snap/${SNAP_NAME}/current/etc/pihole/pihole.toml"
    touch "${TEST_TMPDIR}/var/snap/${SNAP_NAME}/common/snapshots/pihole-backup-123.tar.gz"

    cat > "${MOCK_BIN}/dmesg" <<EOF
#!/bin/sh
echo '[ 12.34] apparmor="DENIED" operation="capable" profile="snap.pihole-by-rajannpatel.ftl" pid=123 comm="ftl" capability=12'
EOF
    chmod +x "${MOCK_BIN}/dmesg"

    run bash "${REPO_ROOT}/tests/scripts/channel-switch-smoke.sh"
    [ "$status" -eq 1 ]
    
    [ -f "$CHANNEL_SWITCH_RESULT" ]
    run jq -r '.status' "$CHANNEL_SWITCH_RESULT"
    [ "$output" = "failure" ]
    run jq -r '.reason' "$CHANNEL_SWITCH_RESULT"
    [ "$output" = "fatal-apparmor-denial" ]
}

@test "benign apparmor denials are ignored" {
    export CHANNEL_SWITCH_RESULT="${TEST_TMPDIR}/result.json"
    export CHANNEL_SWITCH_PATH="stable-to-edge"
    
    cat > "${TEST_TMPDIR}/mock_snap_info" <<'EOF'
channels:
  latest/stable:    v6.4.2              2026-06-08 (123) 14MB -
  latest/edge:      v6.4.2+git.abc.124  2026-06-08 (124) 14MB -
EOF

    cat > "${MOCK_BIN}/snap" <<'EOF'
#!/bin/sh
if [ "$1" = "info" ]; then
  cat "${TEST_TMPDIR}/mock_snap_info"
elif [ "$1" = "services" ]; then
  echo "active"
else
  exit 0
fi
EOF
    chmod +x "${MOCK_BIN}/snap"

    cat > "${MOCK_BIN}/dig" <<'EOF'
#!/bin/sh
echo "pi.hole"
EOF
    chmod +x "${MOCK_BIN}/dig"

    cat > "${MOCK_BIN}/seq" <<'EOF'
#!/bin/sh
echo "1"
EOF
    chmod +x "${MOCK_BIN}/seq"

    echo 'ftl.webserver.port=8123' > "${TEST_TMPDIR}/var/snap/${SNAP_NAME}/current/etc/pihole/pihole.toml"
    touch "${TEST_TMPDIR}/var/snap/${SNAP_NAME}/common/snapshots/pihole-backup-123.tar.gz"

    cat > "${MOCK_BIN}/dmesg" <<EOF
#!/bin/sh
echo '[ 12.34] apparmor="DENIED" operation="capable" profile="snap.pihole-by-rajannpatel.ftl" pid=123 comm="ss" capability=12  info="net_admin"'
EOF
    chmod +x "${MOCK_BIN}/dmesg"

    run bash "${REPO_ROOT}/tests/scripts/channel-switch-smoke.sh"
    [ "$status" -eq 0 ]
    
    [ -f "$CHANNEL_SWITCH_RESULT" ]
    run jq -r '.status' "$CHANNEL_SWITCH_RESULT"
    [ "$output" = "success" ]
}

@test "cleanup failure records warning without replacing success" {
    export CHANNEL_SWITCH_RESULT="${TEST_TMPDIR}/result.json"
    export CHANNEL_SWITCH_PATH="stable-to-edge"
    
    cat > "${TEST_TMPDIR}/mock_snap_info" <<'EOF'
channels:
  latest/stable:    v6.4.2              2026-06-08 (123) 14MB -
  latest/edge:      v6.4.2+git.abc.124  2026-06-08 (124) 14MB -
EOF

    cat > "${MOCK_BIN}/snap" <<'EOF'
#!/bin/sh
if [ "$1" = "info" ]; then
  cat "${TEST_TMPDIR}/mock_snap_info"
elif [ "$1" = "services" ]; then
  echo "active"
elif [ "$1" = "list" ]; then
  echo "pihole-by-rajannpatel active"
elif [ "$1" = "remove" ]; then
  exit 1
else
  exit 0
fi
EOF
    chmod +x "${MOCK_BIN}/snap"

    cat > "${MOCK_BIN}/dig" <<'EOF'
#!/bin/sh
echo "pi.hole"
EOF
    chmod +x "${MOCK_BIN}/dig"

    cat > "${MOCK_BIN}/seq" <<'EOF'
#!/bin/sh
echo "1"
EOF
    chmod +x "${MOCK_BIN}/seq"

    echo 'ftl.webserver.port=8123' > "${TEST_TMPDIR}/var/snap/${SNAP_NAME}/current/etc/pihole/pihole.toml"
    touch "${TEST_TMPDIR}/var/snap/${SNAP_NAME}/common/snapshots/pihole-backup-123.tar.gz"

    cat > "${MOCK_BIN}/dmesg" <<'EOF'
#!/bin/sh
echo ""
EOF
    chmod +x "${MOCK_BIN}/dmesg"

    run bash "${REPO_ROOT}/tests/scripts/channel-switch-smoke.sh"
    [ "$status" -eq 0 ]
    
    [ -f "$CHANNEL_SWITCH_RESULT" ]
    run jq -r '.status' "$CHANNEL_SWITCH_RESULT"
    [ "$output" = "success" ]
    run jq -r '.warnings[0]' "$CHANNEL_SWITCH_RESULT"
    [ "$output" = "cleanup-failed" ]
}

@test "result file is written when command fails early" {
    export CHANNEL_SWITCH_RESULT="${TEST_TMPDIR}/result.json"
    
    cat > "${MOCK_BIN}/snap" <<'EOF'
#!/bin/sh
exit 1
EOF
    chmod +x "${MOCK_BIN}/snap"

    run bash "${REPO_ROOT}/tests/scripts/channel-switch-smoke.sh"
    [ "$status" -eq 1 ]
    
    [ -f "$CHANNEL_SWITCH_RESULT" ]
    run jq -r '.status' "$CHANNEL_SWITCH_RESULT"
    [ "$output" = "failure" ]
    run jq -r '.reason' "$CHANNEL_SWITCH_RESULT"
    [ "$output" = "could-not-parse-snap-info" ]
}

@test "shared service availability rejects missing gravity database" {
    source "${REPO_ROOT}/tests/scripts/pihole-service-health.sh"
    rm -f "${TEST_TMPDIR}/var/snap/${SNAP_NAME}/current/etc/pihole/gravity.db"

    cat > "${MOCK_BIN}/snap" <<'EOF'
#!/bin/sh
if [ "$1" = "services" ]; then echo "active"; else exit 0; fi
EOF
    chmod +x "${MOCK_BIN}/snap"

    run pihole_service_available "$SNAP_NAME"
    [ "$status" -ne 0 ]
}

@test "shared service availability waits while first-run gravity is active" {
    source "${REPO_ROOT}/tests/scripts/pihole-service-health.sh"

    cat > "${MOCK_BIN}/snap" <<'EOF'
#!/bin/sh
if [ "$1" = "services" ]; then echo "active"; else exit 0; fi
EOF
    chmod +x "${MOCK_BIN}/snap"

    cat > "${MOCK_BIN}/pgrep" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "${MOCK_BIN}/pgrep"

    cat > "${MOCK_BIN}/dig" <<'EOF'
#!/bin/sh
echo "pi.hole"
EOF
    chmod +x "${MOCK_BIN}/dig"

    run pihole_service_available "$SNAP_NAME"
    [ "$status" -ne 0 ]
}
