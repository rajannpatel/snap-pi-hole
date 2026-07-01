#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(unset CDPATH; cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(unset CDPATH; cd -- "$SCRIPT_DIR/../../.." && pwd)"
PROVIDERS_DIR="$SCRIPT_DIR/providers"
TEMPLATE_PATH="$REPO_ROOT/.agents/models/selection.template.yaml"
SCHEMA_PATH="$REPO_ROOT/.agents/models/selection.schema.yaml"
CURRENT_PATH="$REPO_ROOT/.agents/local/model-selection.yaml"
OUTPUT_PATH="$CURRENT_PATH"

fail() {
  printf 'model-discovery: %s\n' "$*" >&2
  exit 1
}

warn() {
  printf 'model-discovery: warning: %s\n' "$*" >&2
}

require_workshop() {
  if [ "${PWD:-}" != "/project" ] || [ "${USER:-}" != "workshop" ]; then
    fail "run inside Workshop: workshop run snap-pi-hole -- shell, then bash .agents/skills/model-discovery/discover.sh"
  fi

  if [[ ":${PATH:-}:" != *:/var/lib/workshop/sdk/* ]]; then
    warn "Workshop SDK paths were not detected in PATH; provider CLIs may be unavailable"
  fi
}

yaml_quote() {
  local value=${1-}
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  printf '"%s"' "$value"
}

print_yaml_scalar() {
  local value=$1
  if [ "$value" = "null" ]; then
    printf 'null'
  else
    yaml_quote "$value"
  fi
}

list_item() {
  local indent=$1 value=$2
  printf '%*s- %s\n' "$indent" "" "$(yaml_quote "$value")"
}

render_list_or_empty() {
  local indent=$1 file=$2
  if [ -s "$file" ]; then
    while IFS= read -r value; do
      list_item "$indent" "$value"
    done <"$file"
  else
    printf '%*s[]\n' "$indent" ""
  fi
}

has_pair() {
  local provider=$1 model=$2
  grep -Fqx -- "${provider}	${model}" "$DISCOVERED_FILE"
}

list_contains() {
  local expected=$1 file=$2
  grep -Fqx -- "$expected" "$file"
}

schema_list() {
  local path=$1
  yq -r "${path}[]" "$SCHEMA_PATH"
}

validate_candidate_yaml() {
  local error key role actual type mode provider model
  local schema_roles schema_surface_types schema_command_modes

  command -v yq >/dev/null 2>&1 || fail "candidate validation failed: yq is required in Workshop"

  schema_roles=$(mktemp)
  schema_surface_types=$(mktemp)
  schema_command_modes=$(mktemp)

  schema_list .roles >"$schema_roles"
  schema_list .surface_types >"$schema_surface_types"
  schema_list .command_execution_modes >"$schema_command_modes"

  error=

  while IFS= read -r key; do
    if ! yq -e "has(\"$key\")" "$CANDIDATE_FILE" >/dev/null 2>&1; then
      error="missing required top-level key: $key"
      break
    fi
  done < <(schema_list .required_top_level)

  if [ -z "$error" ]; then
    actual=$(yq -r '.kind' "$CANDIDATE_FILE")
    [ "$actual" = "agent-model-selection" ] || error="kind must be agent-model-selection"
  fi

  if [ -z "$error" ]; then
    while IFS= read -r role; do
      if ! yq -e ".assignments | has(\"$role\")" "$CANDIDATE_FILE" >/dev/null 2>&1; then
        error="missing assignment role: $role"
        break
      fi
    done <"$schema_roles"
  fi

  if [ -z "$error" ]; then
    while IFS= read -r role; do
      if ! list_contains "$role" "$schema_roles"; then
        error="unexpected assignment role: $role"
        break
      fi
    done < <(yq -r '.assignments | keys[]' "$CANDIDATE_FILE")
  fi

  if [ -z "$error" ]; then
    while IFS= read -r key; do
      if ! yq -e ".model_access | has(\"$key\")" "$CANDIDATE_FILE" >/dev/null 2>&1; then
        error="missing model_access group: $key"
        break
      fi
    done < <(schema_list .model_access_groups)
  fi

  if [ -z "$error" ]; then
    while IFS= read -r type; do
      if ! list_contains "$type" "$schema_surface_types"; then
        error="invalid surface type: $type"
        break
      fi
    done < <(yq -r '.agent_surfaces[].type' "$CANDIDATE_FILE")
  fi

  if [ -z "$error" ]; then
    while IFS= read -r mode; do
      if ! list_contains "$mode" "$schema_command_modes"; then
        error="invalid command execution mode: $mode"
        break
      fi
    done < <(yq -r '.agent_surfaces[].command_execution.mode' "$CANDIDATE_FILE")
  fi

  if [ -z "$error" ]; then
    while IFS= read -r role; do
      provider=$(yq -r ".assignments.\"$role\".provider_or_gateway" "$CANDIDATE_FILE")
      model=$(yq -r ".assignments.\"$role\".model" "$CANDIDATE_FILE")

      if [ "$provider" = "null" ] && [ "$model" = "null" ]; then
        continue
      fi

      if [ "$provider" = "null" ] || [ "$model" = "null" ]; then
        error="assignment $role must set provider_or_gateway and model together"
        break
      fi

      if ! has_pair "$provider" "$model"; then
        error="assignment $role provider/model was not discovered: $provider/$model"
        break
      fi
    done <"$schema_roles"
  fi

  rm -f "$schema_roles" "$schema_surface_types" "$schema_command_modes"

  [ -z "$error" ] || fail "candidate validation failed: $error"
}

extract_assignment() {
  local role=$1 field=$2 file=$3
  awk -v role="$role" -v field="$field" '
    $0 ~ "^  " role ":" { in_role = 1; next }
    in_role && /^  [[:alnum:]_]+:/ { exit }
    in_role {
      pattern = "^[[:space:]]+" field ":[[:space:]]*"
      if ($0 ~ pattern) {
        sub(pattern, "", $0)
        gsub(/^"|"$/, "", $0)
        print $0
        exit
      }
    }
  ' "$file"
}

load_assignments() {
  local role current_surface current_model current_provider

  for role in router architect implementer reviewer inline_assistant; do
    ASSIGN_SURFACE[$role]=null
    ASSIGN_MODEL[$role]=null
    ASSIGN_PROVIDER[$role]=null
  done
  ASSIGN_SURFACE[inline_assistant]=inline_assistant

  [ -f "$CURRENT_PATH" ] || return 0

  for role in router architect implementer reviewer inline_assistant; do
    current_surface=$(extract_assignment "$role" surface_id "$CURRENT_PATH")
    current_model=$(extract_assignment "$role" model "$CURRENT_PATH")
    current_provider=$(extract_assignment "$role" provider_or_gateway "$CURRENT_PATH")

    if [ -n "$current_model" ] && [ -n "$current_provider" ] &&
      [ "$current_model" != "null" ] && [ "$current_provider" != "null" ] &&
      has_pair "$current_provider" "$current_model"; then
      ASSIGN_SURFACE[$role]=${current_surface:-workshop_terminal_cli_tui}
      ASSIGN_MODEL[$role]=$current_model
      ASSIGN_PROVIDER[$role]=$current_provider
    fi
  done
}

render_assignments_from_template() {
  local line role field indent
  role=

  while IFS= read -r line; do
    if [[ $line =~ ^[[:space:]]{2}([[:alnum:]_]+):$ ]]; then
      role=${BASH_REMATCH[1]}
      printf '%s\n' "$line"
      continue
    fi

    if [[ -n $role && $line =~ ^([[:space:]]{4})(surface_id|model|provider_or_gateway): ]]; then
      indent=${BASH_REMATCH[1]}
      field=${BASH_REMATCH[2]}
      case "$field" in
        surface_id) printf '%s%s: %s\n' "$indent" "$field" "$(print_yaml_scalar "${ASSIGN_SURFACE[$role]:-null}")" ;;
        model) printf '%s%s: %s\n' "$indent" "$field" "$(print_yaml_scalar "${ASSIGN_MODEL[$role]:-null}")" ;;
        provider_or_gateway) printf '%s%s: %s\n' "$indent" "$field" "$(print_yaml_scalar "${ASSIGN_PROVIDER[$role]:-null}")" ;;
      esac
      continue
    fi

    printf '%s\n' "$line"
  done <"$ASSIGNMENTS_TEMPLATE_FILE"
}

render_yaml_from_template() {
  local generated_at line surface in_model_access=0 in_surface=0 skip_template_note=0
  generated_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  load_assignments

  awk '
    /^assignments:/ { in_assignments = 1 }
    in_assignments { print }
  ' "$TEMPLATE_PATH" >"$ASSIGNMENTS_TEMPLATE_FILE"

  while IFS= read -r line; do
    if [ "$line" = "assignments:" ]; then
      render_assignments_from_template
      break
    fi

    if [ "$skip_template_note" -eq 1 ]; then
      case "$line" in
        "    "*|"")
          continue
          ;;
        *)
          skip_template_note=0
          ;;
      esac
    fi

    case "$line" in
      model_access:)
        in_model_access=1
        printf '%s\n' "$line"
        continue
        ;;
      agent_surfaces:)
        in_model_access=0
        printf '%s\n' "$line"
        continue
        ;;
      "  - id: "*)
        surface=${line#*id: }
        in_surface=0
        if [ "$surface" = "workshop_terminal_cli_tui" ]; then
          in_surface=1
        fi
        printf '%s\n' "$line"
        continue
        ;;
    esac

    if [ "$in_model_access" -eq 1 ] && [ "$line" = "  gateways: []" ]; then
      printf '  gateways:\n'
      render_list_or_empty 4 "$PROVIDERS_FILE"
      continue
    fi

    if [[ $line == '  generated_by:'* ]]; then
      printf '  generated_by: "model-discovery"\n'
    elif [[ $line == '  generated_at:'* ]]; then
      printf '  generated_at: "%s"\n' "$generated_at"
    elif [[ $line == '  notes:'* ]]; then
      printf '  notes: >\n'
      printf '    Generated from Workshop-reachable CLI model discovery. CLI aggregators are\n'
      printf '    recorded as gateways because they expose model access through command-line\n'
      printf '    broker tools rather than direct provider APIs.\n'
      skip_template_note=1
    elif [ "$in_surface" -eq 1 ] && [ "$line" = "    providers_or_gateways: []" ]; then
      printf '    providers_or_gateways:\n'
      render_list_or_empty 6 "$PROVIDERS_FILE"
    elif [ "$in_surface" -eq 1 ] && [ "$line" = "    models: []" ]; then
      printf '    models:\n'
      render_list_or_empty 6 "$MODELS_FILE"
    else
      printf '%s\n' "$line"
    fi
  done <"$TEMPLATE_PATH"
}

print_summary() {
  printf '\nDiscovered Models\n'
  if [ ! -s "$DISCOVERED_FILE" ]; then
    printf 'No models discovered.\n'
    return
  fi

  while IFS= read -r provider; do
    printf '\n%s\n' "$provider"
    awk -F '\t' -v provider="$provider" '$1 == provider { printf "  - %s\n", $2 }' "$DISCOVERED_FILE"
  done <"$PROVIDERS_FILE"
}

run_adapters() {
  : >"$RAW_FILE"

  if [ -d "$PROVIDERS_DIR" ]; then
    while IFS= read -r adapter; do
      [ -x "$adapter" ] || continue
      "$adapter" </dev/null >>"$RAW_FILE" || warn "$(basename "$adapter") adapter exited non-zero"
    done < <(find "$PROVIDERS_DIR" -maxdepth 1 -type f | sort)
  fi

  awk -F '\t' 'NF >= 2 && $1 != "" && $2 != "" { print $1 "\t" $2 }' "$RAW_FILE" |
    sort -u >"$DISCOVERED_FILE"

  cut -f1 "$DISCOVERED_FILE" | sort -u >"$PROVIDERS_FILE"
  cut -f2- "$DISCOVERED_FILE" | sort -u >"$MODELS_FILE"
}

show_comparison() {
  printf '\nCurrent Config\n'
  if [ -f "$CURRENT_PATH" ]; then
    sed -n '1,240p' "$CURRENT_PATH"
  else
    printf '(missing: %s)\n' "$CURRENT_PATH"
  fi

  printf '\nDiscovered Config\n'
  sed -n '1,260p' "$CANDIDATE_FILE"

  printf '\nDiff: Current Config -> Discovered Config\n'
  if [ -f "$CURRENT_PATH" ]; then
    diff -u --label "Current Config" --label "Discovered Config" "$CURRENT_PATH" "$CANDIDATE_FILE" || true
  else
    diff -u --label "Current Config" --label "Discovered Config" /dev/null "$CANDIDATE_FILE" || true
  fi
}

main() {
  require_workshop
  [ -f "$TEMPLATE_PATH" ] || fail "missing template: $TEMPLATE_PATH"
  [ -f "$SCHEMA_PATH" ] || fail "missing schema: $SCHEMA_PATH"

  declare -gA ASSIGN_SURFACE ASSIGN_MODEL ASSIGN_PROVIDER
  RAW_FILE=$(mktemp)
  DISCOVERED_FILE=$(mktemp)
  PROVIDERS_FILE=$(mktemp)
  MODELS_FILE=$(mktemp)
  CANDIDATE_FILE=$(mktemp)
  ASSIGNMENTS_TEMPLATE_FILE=$(mktemp)
  trap 'rm -f "$RAW_FILE" "$DISCOVERED_FILE" "$PROVIDERS_FILE" "$MODELS_FILE" "$CANDIDATE_FILE" "$ASSIGNMENTS_TEMPLATE_FILE" "$OUTPUT_PATH.tmp"' EXIT

  run_adapters

  # --list: machine-readable dump of provider\tmodel lines, no interactive flow
  if [ "${1:-}" = "--list" ]; then
    if [ -s "$DISCOVERED_FILE" ]; then
      cat "$DISCOVERED_FILE"
    fi
    exit 0
  fi

  print_summary
  render_yaml_from_template >"$CANDIDATE_FILE"
  validate_candidate_yaml
  show_comparison

  if [ ! -s "$DISCOVERED_FILE" ]; then
    fail "no provider models were discovered; refusing to generate an empty personal config"
  fi

  printf '\nApply discovered config to .agents/local/model-selection.yaml? [y/N] '
  read -r answer
  case "$answer" in
    y|Y|yes)
      mkdir -p "$(dirname -- "$OUTPUT_PATH")"
      install -m 0644 "$CANDIDATE_FILE" "$OUTPUT_PATH.tmp"
      mv "$OUTPUT_PATH.tmp" "$OUTPUT_PATH"
      printf 'Wrote %s\n' "$OUTPUT_PATH"
      ;;
    *)
      printf 'No changes written.\n'
      ;;
  esac
}

main "$@"
