#!/usr/bin/env bash
set -Eeuo pipefail

# Channel Switch Smoke Script
# Installs a snap from one channel, sets a sentinel config, refreshes to another, and verifies health.

SNAP_NAME="${SNAP_NAME:-pihole-by-rajannpatel}"
CHANNEL_SWITCH_PATH="${CHANNEL_SWITCH_PATH:-roundtrip}"
CHANNEL_SWITCH_RESULT="${CHANNEL_SWITCH_RESULT:-channel-switch-result.json}"

# State variables for result JSON
STATUS="failure"
CONCLUSION="failure"
REASON="unknown-error"
STARTED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

TRANSITIONS_JSON="[]"
ERRORS_JSON="[]"
WARNINGS_JSON="[]"
CHECKS_JSON="{}"

STABLE_VER=""
STABLE_REV=""
EDGE_VER=""
EDGE_REV=""

# Parse snap info to extract channel version and revision
parse_snap_info() {
  local info_file="$1"
  local channel="$2"
  
  local line
  line=$(grep -E "^[[:space:]]*${channel}:" "$info_file" || true)
  if [ -z "$line" ]; then
    return 1
  fi

  local without_prefix
  without_prefix="${line#*"${channel}":}"
  # shellcheck disable=SC2001
  without_prefix="$(echo "$without_prefix" | sed -e 's/^[[:space:]]*//')"

  local revision=""
  if [[ "$line" =~ \(([0-9]+)\) ]]; then
    revision="${BASH_REMATCH[1]}"
  fi

  local version
  version="$(echo "$without_prefix" | awk '{print $1}')"

  if [ -z "$version" ] || [ -z "$revision" ]; then
    return 1
  fi

  echo "$version" "$revision"
}

# Determine if stable and edge revisions are the same
same_revision_skip_required() {
  local stable_rev="$1"
  local edge_rev="$2"
  if [ "$stable_rev" = "$edge_rev" ]; then
    return 0
  fi
  return 1
}

# Check for fatal AppArmor denials
check_apparmor_denials() {
  if sudo dmesg | grep -F 'apparmor="DENIED"' | grep "snap.${SNAP_NAME}" | grep -vE 'dac_read_search|dac_override|net_admin|ldap\.conf|name="/sys/fs/cgroup/system\.slice/snap\.[a-zA-Z0-9.-]+\.(scope|service)/cpu\.max".*comm="(snap-exec|snapctl)"|name="/proc/[0-9]+/mountinfo".*comm="(snap-exec|snapctl)"' >/dev/null; then
    return 1
  fi
  return 0
}

# Helper to record error string
record_error() {
  local err="$1"
  ERRORS_JSON=$(echo "$ERRORS_JSON" | jq --arg err "$err" '. + [$err]' 2>/dev/null || echo "$ERRORS_JSON")
}

# Helper to record warning string
record_warning() {
  local warn="$1"
  WARNINGS_JSON=$(echo "$WARNINGS_JSON" | jq --arg warn "$warn" '. + [$warn]' 2>/dev/null || echo "$WARNINGS_JSON")
}

# Helper to append a transition to the result list
append_transition() {
  local from="$1"
  local to="$2"
  local from_rev="$3"
  local to_rev="$4"
  local trans_status="$5"
  local checks_json="$6"
  
  TRANSITIONS_JSON=$(echo "$TRANSITIONS_JSON" | jq \
    --arg from "$from" \
    --arg to "$to" \
    --arg from_rev "$from_rev" \
    --arg to_rev "$to_rev" \
    --arg trans_status "$trans_status" \
    --argjson checks "$checks_json" \
    '. + [{
      from: $from,
      to: $to,
      from_revision: $from_rev,
      to_revision: $to_rev,
      status: $trans_status,
      checks: $checks
    }]')
}

# Run health checks after install or refresh
verify_health() {
  local is_post_refresh="$1"
  
  local status_check="success"
  local dns_check="success"
  local sentinel_check="success"
  local snapshot_check="success"
  local apparmor_check="success"
  local overall_success=0
  
  # 1. Wait for FTL to become active
  local ftl_active=0
  for _ in $(seq 1 60); do
    if snap services "$SNAP_NAME.pihole-ftl" 2>/dev/null | grep -qw active; then
      ftl_active=1
      break
    fi
    sleep 1
  done
  
  if [ "$ftl_active" -ne 1 ]; then
    status_check="failure"
    REASON="ftl-not-active"
    record_error "ftl-not-active"
    overall_success=1
  fi
  
  # 2. CLI status check
  if [ "$overall_success" -eq 0 ]; then
    if ! sudo "$SNAP_NAME.pihole" status >/dev/null 2>&1; then
      status_check="failure"
      REASON="pihole-status-failed"
      record_error "pihole-status-failed"
      overall_success=1
    fi
  fi
  
  # 3. Verify DNS resolution
  if [ "$overall_success" -eq 0 ]; then
    if ! (dig +short +time=1 +tries=1 @127.0.0.1 pi.hole >/dev/null 2>&1 || dig +short +time=1 +tries=1 @127.0.0.1 . NS 2>/dev/null | grep -q '.'); then
      dns_check="failure"
      REASON="dns-failed"
      record_error "dns-failed"
      overall_success=1
    fi
  fi
  
  # 4. Verify config file exists and is non-empty
  if [ "$overall_success" -eq 0 ]; then
    if ! sudo test -s "/var/snap/${SNAP_NAME}/current/etc/pihole/pihole.toml"; then
      REASON="pihole-toml-missing"
      record_error "pihole-toml-missing"
      overall_success=1
    fi
  fi
  
  # 5. Verify sentinel config persists
  if [ "$overall_success" -eq 0 ] && [ "$is_post_refresh" -eq 1 ]; then
    if ! sudo grep -E '8123' "/var/snap/${SNAP_NAME}/current/etc/pihole/pihole.toml" >/dev/null 2>&1; then
      sentinel_check="failure"
      REASON="sentinel-config-missing"
      record_error "sentinel-config-missing"
      overall_success=1
    fi
  fi
  
  # 6. Verify refresh snapshot exists
  if [ "$overall_success" -eq 0 ] && [ "$is_post_refresh" -eq 1 ]; then
    if ! sudo ls "/var/snap/${SNAP_NAME}/common/snapshots"/pihole-backup-*.tar.gz >/dev/null 2>&1; then
      snapshot_check="failure"
      REASON="refresh-snapshot-missing"
      record_error "refresh-snapshot-missing"
      overall_success=1
    fi
  fi
  
  # 7. Check for fatal AppArmor denials
  if [ "$overall_success" -eq 0 ]; then
    if ! check_apparmor_denials; then
      apparmor_check="failure"
      REASON="fatal-apparmor-denial"
      record_error "fatal-apparmor-denial"
      overall_success=1
    fi
  fi
    # Print diagnostics if health check failed and not in unit test mode
  if [ "$overall_success" -ne 0 ] && [ "${CHANNEL_SWITCH_TEST_MODE:-0}" != "1" ]; then
    echo "=== HEALTH CHECK FAILED ===" >&2
    echo "snap services:" >&2
    snap services "$SNAP_NAME" >&2 || true
    echo "systemctl status:" >&2
    systemctl status "snap.${SNAP_NAME}.pihole-ftl.service" >&2 || true
    echo "journalctl logs for FTL:" >&2
    sudo journalctl -n 50 -u "snap.${SNAP_NAME}.pihole-ftl.service" >&2 || true
    
    for log_path in "/var/snap/${SNAP_NAME}/common/var/log/pihole/pihole-FTL.log" \
                    "/var/snap/${SNAP_NAME}/common/var/log/pihole/FTL.log"; do
      if sudo test -f "$log_path"; then
        echo "FTL log ($log_path):" >&2
        sudo tail -n 100 "$log_path" >&2 || true
      fi
    done
    
    if [ "$apparmor_check" = "failure" ]; then
      echo "AppArmor denials:" >&2
      sudo dmesg | grep -F 'apparmor="DENIED"' | grep "snap.${SNAP_NAME}" || true
    fi
    echo "==========================" >&2
  fi

  CHECKS_JSON=$(jq -n \
    --arg status "$status_check" \
    --arg dns "$dns_check" \
    --arg sentinel "$sentinel_check" \
    --arg snapshot "$snapshot_check" \
    --arg apparmor "$apparmor_check" \
    '{
      status: $status,
      dns: $dns,
      sentinel_config: $sentinel,
      snapshot: $snapshot,
      apparmor: $apparmor
    }')
    
  return "$overall_success"
}

write_result_json() {
  local completed_at
  completed_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local start_sec
  start_sec=$(date -d "$STARTED_AT" +%s 2>/dev/null || date -u -d "$STARTED_AT" +%s 2>/dev/null || echo 0)
  local end_sec
  end_sec=$(date -d "$completed_at" +%s 2>/dev/null || date -u -d "$completed_at" +%s 2>/dev/null || echo 0)
  local duration=$((end_sec - start_sec))
  if [ "$duration" -lt 0 ]; then
    duration=0
  fi
  
  local channels_json
  channels_json=$(jq -n \
    --arg stable_ver "$STABLE_VER" \
    --arg stable_rev "$STABLE_REV" \
    --arg edge_ver "$EDGE_VER" \
    --arg edge_rev "$EDGE_REV" \
    '{
      stable: {
        channel: "latest/stable",
        revision: $stable_rev,
        version: $stable_ver,
        tracking: "latest/stable"
      },
      edge: {
        channel: "latest/edge",
        revision: $edge_rev,
        version: $edge_ver,
        tracking: "latest/edge"
      }
    }')
    
  jq -n \
    --argjson schema_version 1 \
    --arg status "$STATUS" \
    --arg conclusion "$CONCLUSION" \
    --arg reason "$REASON" \
    --arg snap_name "$SNAP_NAME" \
    --arg path "$CHANNEL_SWITCH_PATH" \
    --arg arch "$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')" \
    --arg started_at "$STARTED_AT" \
    --arg completed_at "$completed_at" \
    --argjson duration_seconds "$duration" \
    --argjson channels "$channels_json" \
    --argjson transitions "$TRANSITIONS_JSON" \
    --argjson errors "$ERRORS_JSON" \
    --argjson warnings "$WARNINGS_JSON" \
    --arg run_id "${GITHUB_RUN_ID:-}" \
    --arg run_number "${GITHUB_RUN_NUMBER:-}" \
    --arg run_url "${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}" \
    '{
      schema_version: $schema_version,
      status: $status,
      conclusion: $conclusion,
      reason: $reason,
      snap_name: $snap_name,
      path: $path,
      arch: $arch,
      started_at: $started_at,
      completed_at: $completed_at,
      duration_seconds: $duration_seconds,
      channels: $channels,
      transitions: $transitions,
      errors: $errors,
      warnings: $warnings,
      workflow: {
        run_id: $run_id,
        run_number: $run_number,
        url: $run_url
      }
    }' > "$CHANNEL_SWITCH_RESULT"
}

# Cleanup on exit
exit_handler() {
  # Cleanup if snap is installed
  if snap list "$SNAP_NAME" >/dev/null 2>&1; then
    echo "Purging installed snap $SNAP_NAME..."
    if ! sudo snap remove --purge "$SNAP_NAME" >/dev/null 2>&1; then
      record_warning "cleanup-failed"
    fi
  fi
  write_result_json
}

# Only register trap and run if not in test mode
if [ "${CHANNEL_SWITCH_TEST_MODE:-0}" != "1" ]; then
  trap exit_handler EXIT
fi

# Execute a single transition refresh and verification
run_transition() {
  local from_channel="$1"
  local to_channel="$2"
  local from_rev="$3"
  local to_rev="$4"
  
  echo "Refreshing snap from $from_channel to $to_channel..."
  
  local trans_status="success"
  local snap_refresh_check="success"
  
  # Run snap refresh
  if ! sudo snap refresh "$SNAP_NAME" --channel="$to_channel"; then
    snap_refresh_check="failure"
    trans_status="failure"
    REASON="snap-refresh-failed"
    record_error "snap-refresh-failed"
  fi
  
  local final_checks_json="{}"
  if [ "$trans_status" = "success" ]; then
    # Record current info
    snap list "$SNAP_NAME" || true
    snap info "$SNAP_NAME" || true
    
    # Run post-refresh health check
    set +e
    verify_health 1
    local rc=$?
    set -e
    
    final_checks_json="$CHECKS_JSON"
    if [ "$rc" -ne 0 ]; then
      trans_status="failure"
    fi
  else
    final_checks_json=$(jq -n \
      --arg status "failure" \
      --arg dns "failure" \
      --arg sentinel "failure" \
      --arg snapshot "failure" \
      --arg apparmor "failure" \
      '{
        status: $status,
        dns: $dns,
        sentinel_config: $sentinel,
        snapshot: $snapshot,
        apparmor: $apparmor
      }')
  fi
  
  # Add snap_refresh check to checks JSON
  final_checks_json=$(echo "$final_checks_json" | jq --arg sr "$snap_refresh_check" '. + {snap_refresh: $sr}')
  
  append_transition "$from_channel" "$to_channel" "$from_rev" "$to_rev" "$trans_status" "$final_checks_json"
  
  if [ "$trans_status" != "success" ]; then
    return 1
  fi
  return 0
}

main() {
  # Verify path input
  if [ "$CHANNEL_SWITCH_PATH" != "stable-to-edge" ] && \
     [ "$CHANNEL_SWITCH_PATH" != "edge-to-stable" ] && \
     [ "$CHANNEL_SWITCH_PATH" != "roundtrip" ]; then
    STATUS="failure"
    CONCLUSION="failure"
    REASON="invalid-path"
    record_error "invalid-path"
    exit 2
  fi

  # Discover channel revisions and versions
  local info_file
  info_file=$(mktemp)
  trap 'rm -f "$info_file"' RETURN
  
  # Query snap info with retry
  local info_ok=0
  for _ in $(seq 1 5); do
    if snap info "$SNAP_NAME" > "$info_file" 2>/dev/null; then
      info_ok=1
      break
    fi
    sleep 2
  done
  
  if [ "$info_ok" -ne 1 ]; then
    STATUS="failure"
    CONCLUSION="failure"
    REASON="could-not-parse-snap-info"
    record_error "could-not-parse-snap-info"
    exit 1
  fi

  # Parse stable
  local parsed_stable
  if ! parsed_stable=$(parse_snap_info "$info_file" "latest/stable"); then
    STATUS="failure"
    CONCLUSION="failure"
    REASON="could-not-parse-snap-info"
    record_error "could-not-parse-snap-info"
    exit 1
  fi
  STABLE_VER=$(echo "$parsed_stable" | awk '{print $1}')
  STABLE_REV=$(echo "$parsed_stable" | awk '{print $2}')

  # Parse edge
  local parsed_edge
  if ! parsed_edge=$(parse_snap_info "$info_file" "latest/edge"); then
    STATUS="failure"
    CONCLUSION="failure"
    REASON="could-not-parse-snap-info"
    record_error "could-not-parse-snap-info"
    exit 1
  fi
  EDGE_VER=$(echo "$parsed_edge" | awk '{print $1}')
  EDGE_REV=$(echo "$parsed_edge" | awk '{print $2}')

  # Check same revision skip logic
  if same_revision_skip_required "$STABLE_REV" "$EDGE_REV"; then
    STATUS="skipped"
    CONCLUSION="skipped"
    REASON="stable-and-edge-same-revision"
    echo "Skipping channel switch smoke check because stable and edge point to the same revision (r$STABLE_REV)."
    exit 0
  fi

  # Setup initial channel variables
  local initial_channel="latest/stable"
  if [ "$CHANNEL_SWITCH_PATH" = "edge-to-stable" ]; then
    initial_channel="latest/edge"
  fi

  echo "Installing initial snap $SNAP_NAME from channel $initial_channel..."
  
  # Install initial snap
  local install_ok=0
  for _ in $(seq 1 3); do
    if sudo snap install "$SNAP_NAME" --channel="$initial_channel"; then
      install_ok=1
      break
    fi
    sleep 5
  done

  if [ "$install_ok" -ne 1 ]; then
    STATUS="failure"
    CONCLUSION="failure"
    REASON="snap-install-failed"
    record_error "snap-install-failed"
    exit 1
  fi

  # Plugs connection
  sudo snap connect "$SNAP_NAME:network-bind" || true
  sudo snap connect "$SNAP_NAME:system-observe" || true
  sudo snap connect "$SNAP_NAME:hardware-observe" || true
  sudo snap connect "$SNAP_NAME:mount-observe" || true
  sudo snap connect "$SNAP_NAME:network-control" || true
  sudo snap connect "$SNAP_NAME:firewall-control" || true
  sudo snap connect "$SNAP_NAME:shared-memory" || true
  sudo snap connect "$SNAP_NAME:network-observe" || true

  sudo snap alias "$SNAP_NAME.pihole" pihole || true
  sudo snap start --enable "$SNAP_NAME.pihole-ftl" || true

  # Verify initial health
  set +e
  verify_health 0
  local rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    STATUS="failure"
    CONCLUSION="failure"
    # REASON is already set in verify_health
    exit 1
  fi

  # Set sentinel config before the first switch
  echo "Setting sentinel config..."
  if ! sudo snap set "$SNAP_NAME" ftl.webserver.port=8123; then
    STATUS="failure"
    CONCLUSION="failure"
    REASON="sentinel-config-missing"
    record_error "sentinel-config-missing"
    exit 1
  fi
  sleep 5

  # Run transitions
  if [ "$CHANNEL_SWITCH_PATH" = "stable-to-edge" ]; then
    if ! run_transition "latest/stable" "latest/edge" "$STABLE_REV" "$EDGE_REV"; then
      STATUS="failure"
      CONCLUSION="failure"
      exit 1
    fi
  elif [ "$CHANNEL_SWITCH_PATH" = "edge-to-stable" ]; then
    if ! run_transition "latest/edge" "latest/stable" "$EDGE_REV" "$STABLE_REV"; then
      STATUS="failure"
      CONCLUSION="failure"
      exit 1
    fi
  elif [ "$CHANNEL_SWITCH_PATH" = "roundtrip" ]; then
    # Transition 1: Stable -> Edge
    if ! run_transition "latest/stable" "latest/edge" "$STABLE_REV" "$EDGE_REV"; then
      STATUS="failure"
      CONCLUSION="failure"
      exit 1
    fi
    # Transition 2: Edge -> Stable
    if ! run_transition "latest/edge" "latest/stable" "$EDGE_REV" "$STABLE_REV"; then
      STATUS="failure"
      CONCLUSION="failure"
      exit 1
    fi
  fi

  # If everything succeeded
  STATUS="success"
  CONCLUSION="success"
  REASON=""
  echo "Channel switch check completed successfully!"
}

if [ "${CHANNEL_SWITCH_TEST_MODE:-0}" != "1" ]; then
  main "$@"
fi
