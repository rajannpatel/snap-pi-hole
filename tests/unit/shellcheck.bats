#!/usr/bin/env bats
#
# Unit test to ensure all shell scripts and hook scripts pass shellcheck.

setup() {
    REPO_ROOT="$(git rev-parse --show-toplevel)"
}

@test "all shell scripts and hooks pass shellcheck" {
    if ! command -v shellcheck >/dev/null 2>&1; then
        skip "shellcheck is not installed"
    fi

    # Locate all shell scripts and snap hooks:
    # - *.sh files in snap/
    # - *.sh files in tests/ (excluding bats test files themselves)
    # - all files in snap/hooks/
    files=$(find "${REPO_ROOT}/snap" "${REPO_ROOT}/tests" -type f \( -name "*.sh" -o -path "*/snap/hooks/*" \) | sort)

    # Run shellcheck on all identified files
    run shellcheck $files
    [ "$status" -eq 0 ]
}
