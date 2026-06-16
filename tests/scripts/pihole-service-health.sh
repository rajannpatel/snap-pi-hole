#!/usr/bin/env bash

# Shared service-availability probes for CI smoke tests against an installed
# snap. Keep channel-specific tests focused on their own assertions.

pihole_service_is_active() {
  local snap_name="$1"
  snap services "${snap_name}.pihole-ftl" 2>/dev/null | grep -qw active
}

pihole_first_run_gravity_idle() {
  if ! command -v pgrep >/dev/null 2>&1; then
    return 0
  fi
  ! pgrep -f '/opt/pihole/gravity\.sh -g' >/dev/null 2>&1
}

pihole_gravity_db_ready() {
  local snap_name="$1"
  sudo test -s "/var/snap/${snap_name}/current/etc/pihole/gravity.db"
}

pihole_cli_ready() {
  local snap_name="$1"
  sudo "${snap_name}.pihole" status >/dev/null 2>&1
}

pihole_dns_ready() {
  command -v dig >/dev/null 2>&1 || return 0
  dig +short +time=1 +tries=1 @127.0.0.1 pi.hole >/dev/null 2>&1 ||
    dig +short +time=1 +tries=1 @127.0.0.1 . NS 2>/dev/null | grep -q '.'
}

pihole_service_available() {
  local snap_name="$1"
  pihole_service_is_active "$snap_name" &&
    pihole_gravity_db_ready "$snap_name" &&
    pihole_first_run_gravity_idle &&
    pihole_cli_ready "$snap_name" &&
    pihole_dns_ready
}

wait_for_pihole_service_availability() {
  local snap_name="$1"
  local timeout_seconds="${2:-180}"
  local waited=0

  while [ "$waited" -lt "$timeout_seconds" ]; do
    if pihole_service_available "$snap_name"; then
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done

  return 1
}
