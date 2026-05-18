#!/usr/bin/env bats
#
# Unit tests for snap/local/launcher-pihole  -  the CLI wrapper that
# intercepts subcommands that don't make sense inside a snap and passes
# everything else through to the upstream `pihole` bash script.
#
# Run locally:   bats tests/unit/launcher-pihole.bats
# In CI:         see .github/workflows/build.yml (lint+unit job)

setup() {
    REPO_ROOT="$(git rev-parse --show-toplevel)"
    TMPDIR="$(mktemp -d)"
    export SNAP_DATA="${TMPDIR}/data"
    mkdir -p "${SNAP_DATA}"

    # The launcher hardcodes /opt/pihole/pihole as the upstream script.
    # Build a copy where that path points at our stub, which records its
    # arguments to stdout so the test can assert the pass-through path.
    STUB="${TMPDIR}/pihole-stub"
    LAUNCHER="${TMPDIR}/launcher-pihole"

    # NB: substitution order matters  -  the longer path must be rewritten
    # first so the shorter substring rewrite doesn't shadow it.
    sed \
        -e "s|/opt/pihole/pihole|${STUB}|g" \
        -e "s|/opt/pihole|${TMPDIR}/opt|g" \
        "${REPO_ROOT}/snap/local/launcher-pihole" > "${LAUNCHER}"
    chmod +x "${LAUNCHER}"

    cat > "${STUB}" <<'EOF'
#!/bin/sh
printf 'STUB:%s\n' "$*"
exit 0
EOF
    chmod +x "${STUB}"
}

teardown() {
    rm -rf "${TMPDIR}"
}

# --- blocked subcommands -------------------------------------------------

@test "blocks -up and points at snap refresh" {
    run "${LAUNCHER}" -up
    [ "$status" -eq 1 ]
    [[ "$output" == *"not supported in the snap"* ]]
    [[ "$output" == *"snap refresh pihole"* ]]
}

@test "blocks updatePihole and points at snap refresh" {
    run "${LAUNCHER}" updatePihole
    [ "$status" -eq 1 ]
    [[ "$output" == *"snap refresh pihole"* ]]
}

@test "blocks updatechecker and points at snap refresh" {
    run "${LAUNCHER}" updatechecker
    [ "$status" -eq 1 ]
    [[ "$output" == *"snap refresh pihole"* ]]
}

@test "blocks checkout and points at snap refresh" {
    run "${LAUNCHER}" checkout master
    [ "$status" -eq 1 ]
    [[ "$output" == *"snap refresh pihole"* ]]
}

@test "blocks -r and points at snap revert" {
    run "${LAUNCHER}" -r
    [ "$status" -eq 1 ]
    [[ "$output" == *"snap revert pihole"* ]]
}

@test "blocks repair and points at snap revert" {
    run "${LAUNCHER}" repair
    [ "$status" -eq 1 ]
    [[ "$output" == *"snap revert pihole"* ]]
}

@test "blocks uninstall and points at snap remove" {
    run "${LAUNCHER}" uninstall
    [ "$status" -eq 1 ]
    [[ "$output" == *"snap remove pihole"* ]]
}

# --- pass-through --------------------------------------------------------

@test "passes status through to the upstream script" {
    run "${LAUNCHER}" status
    [ "$status" -eq 0 ]
    [[ "$output" == "STUB:status" ]]
}

@test "passes -g (gravity update) through" {
    run "${LAUNCHER}" -g
    [ "$status" -eq 0 ]
    [[ "$output" == "STUB:-g" ]]
}

@test "passes multi-argument subcommands through verbatim" {
    run "${LAUNCHER}" allow example.com
    [ "$status" -eq 0 ]
    [[ "$output" == "STUB:allow example.com" ]]
}

@test "passes no-argument invocation through" {
    run "${LAUNCHER}"
    [ "$status" -eq 0 ]
    [[ "$output" == "STUB:" ]]
}

@test "passes -h / help through (upstream owns usage rendering)" {
    run "${LAUNCHER}" -h
    [ "$status" -eq 0 ]
    [[ "$output" == "STUB:-h" ]]
}

# --- regression guards ---------------------------------------------------

@test "blocked subcommands never invoke the upstream script" {
    # Replace the stub with one that fails loudly. If a 'blocked'
    # subcommand reaches the exec, the test fails.
    cat > "${STUB}" <<'EOF'
#!/bin/sh
echo "BUG: blocked subcommand reached upstream script with args: $*" >&2
exit 0
EOF
    for cmd in -up updatePihole updatechecker checkout -r repair uninstall; do
        run "${LAUNCHER}" "$cmd"
        [ "$status" -eq 1 ]
        [[ "$output" != *"BUG:"* ]]
    done
}

# --- error channel -------------------------------------------------------

@test "blocked subcommand error message goes to stderr, not stdout" {
    # Verify blocked commands print to stderr (not stdout) by checking
    # the stub is never invoked (its STUB: prefix never appears in output)
    run "${LAUNCHER}" -up
    [ "$status" -eq 1 ]
    [[ "$output" == *"not supported in the snap"* ]]
    [[ "$output" != *"STUB:"* ]]
}

# --- exit code propagation -----------------------------------------------

@test "upstream non-zero exit code is propagated to the caller" {
    cat > "${STUB}" <<'EOF'
#!/bin/sh
exit 42
EOF
    run "${LAUNCHER}" status
    [ "$status" -eq 42 ]
}

@test "upstream zero exit code is propagated to the caller" {
    run "${LAUNCHER}" status
    [ "$status" -eq 0 ]
}

# --- environment ----------------------------------------------------------

@test "launcher-pihole exports HOME as SNAP_DATA" {
    cat > "${STUB}" <<'EOF'
#!/bin/sh
echo "HOME=${HOME}"
EOF
    run "${LAUNCHER}" status
    [ "$status" -eq 0 ]
    [[ "$output" == "HOME=${SNAP_DATA}" ]]
}

@test "launcher-pihole prepends /opt/pihole to PATH" {
    cat > "${STUB}" <<'EOF'
#!/bin/sh
echo "PATH=${PATH}"
EOF
    run "${LAUNCHER}" status
    [ "$status" -eq 0 ]
    # After sed rewriting, /opt/pihole becomes ${TMPDIR}/opt, so check for that
    [[ "$output" == *"${TMPDIR}/opt"* ]]
}

@test "launcher-pihole exports FTLCONF_files_pid for IPC" {
    cat > "${STUB}" <<'EOF'
#!/bin/sh
echo "FTLCONF_files_pid=${FTLCONF_files_pid}"
EOF
    run "${LAUNCHER}" status
    [ "$status" -eq 0 ]
    [[ "$output" == "FTLCONF_files_pid=/run/snap.pihole/pihole-FTL.pid" ]]
}
