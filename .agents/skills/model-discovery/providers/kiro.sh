#!/usr/bin/env bash
set -euo pipefail

provider=kiro-cli
timeout_seconds=${MODEL_DISCOVERY_PROVIDER_TIMEOUT_SECONDS:-15}

if ! command -v kiro-cli >/dev/null 2>&1; then
  printf 'model-discovery: warning: kiro-cli not found\n' >&2
  exit 0
fi

if ! command -v timeout >/dev/null 2>&1; then
  printf 'model-discovery: warning: timeout command not found; skipping kiro-cli discovery\n' >&2
  exit 0
fi

run_with_timeout() {
  local label=$1 status output
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

run_help_with_timeout() {
  local label=$1 status output
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
  return 0
}

help_text=$(run_help_with_timeout "kiro-cli --help" kiro-cli --help) || exit 0
list_cmd=()

if grep -Eq '(^|[[:space:]])models([[:space:],]|$)' <<<"$help_text"; then
  list_cmd=(kiro-cli models)
elif grep -Eq '(^|[[:space:]])list-models([[:space:],]|$)' <<<"$help_text"; then
  list_cmd=(kiro-cli list-models)
elif grep -Eq '(^|[[:space:]])model([[:space:],]|$)' <<<"$help_text"; then
  model_help=$(run_help_with_timeout "kiro-cli model --help" kiro-cli model --help) || exit 0
  if grep -Eq '(^|[[:space:]])list([[:space:],]|$)' <<<"$model_help"; then
    list_cmd=(kiro-cli model list)
  fi
elif grep -Eq '(^|[[:space:]])list([[:space:],]|$)' <<<"$help_text"; then
  list_help=$(run_help_with_timeout "kiro-cli list --help" kiro-cli list --help) || exit 0
  if grep -Eiq 'model' <<<"$list_help"; then
    list_cmd=(kiro-cli list models)
  fi
fi

if [ "${#list_cmd[@]}" -eq 0 ]; then
  printf 'model-discovery: warning: kiro-cli has no recognized model-list subcommand\n' >&2
  exit 0
fi

output=$(run_with_timeout "kiro-cli model-list command" "${list_cmd[@]}") || {
  printf 'model-discovery: warning: kiro-cli model-list command failed\n' >&2
  exit 0
}

printf '%s\n' "$output" |
  awk -v provider="$provider" '
    NF == 0 { next }
    /^[[:space:]]*[\[{]/ { next }
    tolower($0) ~ /^[[:space:]]*(name|model|models|id)[[:space:]]*$/ { next }
    tolower($0) ~ /^[[:space:]]*(error|usage):/ { next }
    /^[[:space:]]*[-=]+[[:space:]]*$/ { next }
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      split(line, fields, /[[:space:]]{2,}|\t/)
      model = fields[1]
      sub(/^[*+-][[:space:]]*/, "", model)
      if (model != "") {
        print provider "\t" model
      }
    }
  '
