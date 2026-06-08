#!/usr/bin/env bash
# Shared snapctl stub installer for Bats tests that need snap configuration state.

install_snapctl_stub() {
    local target="$1"
    local test_tmpdir="$2"

    cat > "$target" <<'STUB'
#!/usr/bin/env bash
TEST_TMPDIR="MOCK_TMPDIR"
LOG="${TEST_TMPDIR}/snapctl.log"

echo "SNAPCTL:$*" >> "$LOG"

_ensure_ftl_state() {
    if [ ! -f "${TEST_TMPDIR}/snapctl_ftl.json" ]; then
        echo "${SNAPCTL_GET_D_FTL:-{}}" > "${TEST_TMPDIR}/snapctl_ftl.json"
    fi
}

_refresh_ftl_state_from_env() {
    local current_env="${SNAPCTL_GET_D_FTL:-{}}"
    local last_env=""

    if [ -f "${TEST_TMPDIR}/last_snapctl_get_d_ftl.json" ]; then
        last_env=$(cat "${TEST_TMPDIR}/last_snapctl_get_d_ftl.json")
    fi

    if [ "$current_env" != "$last_env" ]; then
        echo "$current_env" > "${TEST_TMPDIR}/snapctl_ftl.json"
        echo "$current_env" > "${TEST_TMPDIR}/last_snapctl_get_d_ftl.json"
    fi

    _ensure_ftl_state
}

case "${1:-}" in
    get)
        if [ "${2:-}" = "-d" ] && [ "${3:-}" = "timer" ]; then
            echo "${SNAPCTL_GET_D_TIMER:-}"
            exit 0
        fi
        if [ "${2:-}" = "-d" ] && [ "${3:-}" = "ftl" ]; then
            _refresh_ftl_state_from_env
            cat "${TEST_TMPDIR}/snapctl_ftl.json"
            exit 0
        fi
        if [ "${2:-}" = "version" ]; then
            echo "${SNAPCTL_GET_VERSION:-}"
            exit 0
        fi

        key="${2:-}"
        if [ "$key" = "-q" ]; then
            key="${3:-}"
        fi
        [ -n "$key" ] || exit 0

        var="SNAPCTL_GET_$(echo "$key" | tr '.-' '_')"
        echo "${!var:-}"
        ;;
    set)
        if [ "${2:-}" = "ftl" ]; then
            echo "${3:-}" > "${TEST_TMPDIR}/snapctl_ftl.json"
            echo "${3:-}" > "${TEST_TMPDIR}/last_snapctl_get_d_ftl.json"
            exit 0
        elif [[ "${2:-}" =~ ^ftl=(.*)$ ]]; then
            val="${BASH_REMATCH[1]}"
            echo "$val" > "${TEST_TMPDIR}/snapctl_ftl.json"
            echo "$val" > "${TEST_TMPDIR}/last_snapctl_get_d_ftl.json"
            exit 0
        fi

        _ensure_ftl_state
        arg="${2:-}"
        if [[ "$arg" =~ ^ftl\.(.+)=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            val="${BASH_REMATCH[2]}"
            jq --arg val "$val" --arg key "$key" '
              (try ($val | fromjson) catch $val) as $parsed_val |
              setpath($key | split("."); $parsed_val)
            ' "${TEST_TMPDIR}/snapctl_ftl.json" > "${TEST_TMPDIR}/snapctl_ftl.json.tmp"
            mv "${TEST_TMPDIR}/snapctl_ftl.json.tmp" "${TEST_TMPDIR}/snapctl_ftl.json"
        fi
        ;;
    unset)
        if [ "${2:-}" = "ftl" ]; then
            echo "{}" > "${TEST_TMPDIR}/snapctl_ftl.json"
            echo "{}" > "${TEST_TMPDIR}/last_snapctl_get_d_ftl.json"
            exit 0
        fi

        _ensure_ftl_state
        arg="${2:-}"
        if [[ "$arg" =~ ^ftl\.(.+)$ ]]; then
            key="${BASH_REMATCH[1]}"
            jq --arg key "$key" 'delpaths([[$key | split(".")[]]])' "${TEST_TMPDIR}/snapctl_ftl.json" > "${TEST_TMPDIR}/snapctl_ftl.json.tmp"
            mv "${TEST_TMPDIR}/snapctl_ftl.json.tmp" "${TEST_TMPDIR}/snapctl_ftl.json"
        fi
        ;;
    services)
        printf 'Service         Startup  Current  Notes\n'
        printf 'pihole-ftl      enabled  %s        -\n' "${SNAPCTL_SERVICE_STATUS:-inactive}"
        ;;
    is-connected)
        plug_var=$(echo "${2:-}" | tr '-' '_')
        var_name="MOCK_DISCONNECT_${plug_var}"
        if [ "${!var_name:-}" = "true" ] || [ "${SNAPCTL_IS_CONNECTED:-true}" = "false" ]; then
            exit 1
        fi
        exit 0
        ;;
    start|stop|restart)
        action_upper=$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')
        echo "${action_upper}:${2:-}" >> "$LOG"
        ;;
    system-mode)
        echo "${SNAPCTL_SYSTEM_MODE:-run}"
        ;;
    *)
        exit 0
        ;;
esac
STUB

    sed -i "s|MOCK_TMPDIR|${test_tmpdir}|g" "$target"
    chmod +x "$target"
}
