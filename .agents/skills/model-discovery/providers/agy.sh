#!/usr/bin/env bash
set -euo pipefail

provider=agy
timeout_seconds=${MODEL_DISCOVERY_PROVIDER_TIMEOUT_SECONDS:-15}

if ! command -v agy >/dev/null 2>&1; then
  printf 'model-discovery: warning: agy CLI not found\n' >&2
  exit 0
fi

if ! command -v timeout >/dev/null 2>&1; then
  printf 'model-discovery: warning: timeout command not found; skipping agy discovery\n' >&2
  exit 0
fi

run_with_timeout() {
  local label=$1 status
  shift

  set +e
  output=$(timeout --foreground "${timeout_seconds}s" "$@" </dev/null 2>&1)
  status=$?
  set -e

  if [ "$status" -eq 124 ] || [ "$status" -eq 137 ]; then
    printf 'model-discovery: warning: %s timed out after %ss\n' "$label" "$timeout_seconds" >&2
    return 124
  fi

  printf '%s\n' "$output"
  return "$status"
}

output=$(run_with_timeout "agy models" agy models) || {
  printf 'model-discovery: warning: agy models failed\n' >&2
  exit 0
}

printf '%s\n' "$output" |
  awk -v provider="$provider" '
    NF == 0 { next }
    /^[-[:space:]]*$/ { next }
    tolower($0) ~ /^(model|models|name)[[:space:]]*$/ { next }
    tolower($0) ~ /^(error|usage):/ { next }
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      print provider "\t" line
    }
  '
