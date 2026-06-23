#!/usr/bin/env bats

setup() {
    REPO_ROOT="$(git rev-parse --show-toplevel)"
    TEST_TMPDIR="$(mktemp -d)"
    MOCK_BIN="${TEST_TMPDIR}/bin"
    CALL_LOG="${TEST_TMPDIR}/calls.log"
    mkdir -p "$MOCK_BIN"
    touch "$CALL_LOG"
    export CALL_LOG
    export PATH="${MOCK_BIN}:${PATH}"
    export MODEL_DISCOVERY_PROVIDER_TIMEOUT_SECONDS=5
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

write_mock_cli() {
    local name=$1
    local body=$2

    printf '%s\n' "$body" > "${MOCK_BIN}/${name}"
    chmod +x "${MOCK_BIN}/${name}"
}

@test "agy adapter runs agy models and emits provider model rows" {
    write_mock_cli "agy" '#!/usr/bin/env bash
printf "%s\n" "agy $*" >> "$CALL_LOG"
if [ "$1" = "models" ]; then
  printf "%s\n" "claude-3-5-sonnet"
  exit 0
fi
exit 2'

    run bash "${REPO_ROOT}/.agents/skills/model-discovery/providers/agy.sh"

    [ "$status" -eq 0 ]
    [ "$output" = $'agy\tclaude-3-5-sonnet' ]
    [ "$(cat "$CALL_LOG")" = "agy models" ]
}

@test "copilot adapter probes help before selected models command" {
    write_mock_cli "copilot" '#!/usr/bin/env bash
printf "%s\n" "copilot $*" >> "$CALL_LOG"
if [ "$1" = "--help" ]; then
  printf "%s\n" "Commands:" "  models    List available models"
  exit 0
fi
if [ "$1" = "models" ]; then
  printf "%s\n" "gpt-4.1    GitHub Copilot model"
  exit 0
fi
exit 2'

    run bash "${REPO_ROOT}/.agents/skills/model-discovery/providers/copilot.sh"

    [ "$status" -eq 0 ]
    [ "$output" = $'copilot\tgpt-4.1' ]
    [ "$(cat "$CALL_LOG")" = $'copilot --help\ncopilot models' ]
}

@test "copilot adapter warns and exits zero when help has no model-list command" {
    write_mock_cli "copilot" '#!/usr/bin/env bash
printf "%s\n" "copilot $*" >> "$CALL_LOG"
if [ "$1" = "--help" ]; then
  printf "%s\n" "Commands:" "  auth      Manage authentication"
  exit 0
fi
exit 2'

    run bash -c "bash '${REPO_ROOT}/.agents/skills/model-discovery/providers/copilot.sh' 2>&1"

    [ "$status" -eq 0 ]
    [[ "$output" == *"model-discovery: warning: copilot CLI has no recognized model-list subcommand"* ]]
    [ "$(cat "$CALL_LOG")" = "copilot --help" ]
}

@test "kiro-cli adapter probes help before selected list-models command" {
    write_mock_cli "kiro-cli" '#!/usr/bin/env bash
printf "%s\n" "kiro-cli $*" >> "$CALL_LOG"
if [ "$1" = "--help" ]; then
  printf "%s\n" "Commands:" "  list-models"
  exit 0
fi
if [ "$1" = "list-models" ]; then
  printf "%s\n" "kiro-base    Kiro model"
  exit 0
fi
exit 2'

    run bash "${REPO_ROOT}/.agents/skills/model-discovery/providers/kiro.sh"

    [ "$status" -eq 0 ]
    [ "$output" = $'kiro-cli\tkiro-base' ]
    [ "$(cat "$CALL_LOG")" = $'kiro-cli --help\nkiro-cli list-models' ]
}

@test "kiro-cli adapter downgrades selected command failure to warning and exit zero" {
    write_mock_cli "kiro-cli" '#!/usr/bin/env bash
printf "%s\n" "kiro-cli $*" >> "$CALL_LOG"
if [ "$1" = "--help" ]; then
  printf "%s\n" "Commands:" "  list-models"
  exit 0
fi
if [ "$1" = "list-models" ]; then
  printf "%s\n" "provider unavailable" >&2
  exit 7
fi
exit 2'

    run bash -c "bash '${REPO_ROOT}/.agents/skills/model-discovery/providers/kiro.sh' 2>&1"

    [ "$status" -eq 0 ]
    [[ "$output" == *"model-discovery: warning: kiro-cli model-list command failed"* ]]
    [ "$(cat "$CALL_LOG")" = $'kiro-cli --help\nkiro-cli list-models' ]
}
