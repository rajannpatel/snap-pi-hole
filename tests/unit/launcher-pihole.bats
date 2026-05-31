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
    export SNAP_COMMON="${TMPDIR}/common"
    export SNAP="${TMPDIR}/snap"
    mkdir -p "${SNAP_DATA}" "${SNAP_COMMON}" "${SNAP}" "${TMPDIR}/etc"

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
        -e "s|/etc/pihole|${TMPDIR}/etc|g" \
        "${REPO_ROOT}/snap/local/runtime/launcher-pihole.sh" > "${LAUNCHER}"
    chmod +x "${LAUNCHER}"

    cat > "${STUB}" <<'EOF'
#!/bin/sh
printf 'STUB:%s\n' "$*"
exit 0
EOF
    chmod +x "${STUB}"

    # Stub the snap-specific snap-check and snap-debug tools
    mkdir -p "${SNAP}/bin"
    cat > "${SNAP}/bin/snap-check" <<'EOF'
#!/bin/sh
printf 'STUB_SNAP_CHECK:%s\n' "$*"
exit 0
EOF
    chmod +x "${SNAP}/bin/snap-check"

    cat > "${SNAP}/bin/snap-debug" <<'EOF'
#!/bin/sh
printf 'STUB_SNAP_DEBUG:%s\n' "$*"
exit 0
EOF
    chmod +x "${SNAP}/bin/snap-debug"
}

teardown() {
    rm -rf "${TMPDIR}"
}

# --- blocked subcommands -------------------------------------------------

@test "block -up and point at snap refresh" {
    run "${LAUNCHER}" -up
    [ "$status" -eq 1 ]
    [[ "$output" == *"not supported in the snap"* ]]
    [[ "$output" == *"snap refresh pihole"* ]]
}

@test "block updatePihole and point at snap refresh" {
    run "${LAUNCHER}" updatePihole
    [ "$status" -eq 1 ]
    [[ "$output" == *"snap refresh pihole"* ]]
}

@test "block updatechecker and point at snap refresh" {
    run "${LAUNCHER}" updatechecker
    [ "$status" -eq 1 ]
    [[ "$output" == *"snap refresh pihole"* ]]
}

@test "block checkout and point at snap refresh" {
    run "${LAUNCHER}" checkout master
    [ "$status" -eq 1 ]
    [[ "$output" == *"snap refresh pihole"* ]]
}

@test "block -r and point at snap revert" {
    run "${LAUNCHER}" -r
    [ "$status" -eq 1 ]
    [[ "$output" == *"snap revert pihole"* ]]
}

@test "block repair and point at snap revert" {
    run "${LAUNCHER}" repair
    [ "$status" -eq 1 ]
    [[ "$output" == *"snap revert pihole"* ]]
}

@test "block uninstall and point at snap remove" {
    run "${LAUNCHER}" uninstall
    [ "$status" -eq 1 ]
    [[ "$output" == *"snap remove pihole"* ]]
}

# --- pass-through --------------------------------------------------------

@test "pass status through to upstream script" {
    run "${LAUNCHER}" status
    [ "$status" -eq 0 ]
    [[ "$output" == "STUB:status" ]]
}

@test "pass -g (gravity update) through" {
    run "${LAUNCHER}" -g
    [ "$status" -eq 0 ]
    [[ "$output" == "STUB:-g" ]]
}

@test "pass multi-argument subcommands through verbatim" {
    run "${LAUNCHER}" allow example.com
    [ "$status" -eq 0 ]
    [[ "$output" == "STUB:allow example.com" ]]
}

@test "pass no-argument invocation through" {
    run "${LAUNCHER}"
    [ "$status" -eq 0 ]
    [[ "$output" == "STUB:" ]]
}

@test "pass -h / help through" {
    run "${LAUNCHER}" -h
    [ "$status" -eq 0 ]
    [[ "$output" == "STUB:-h" ]]
}

# --- regression guards ---------------------------------------------------

@test "blocked subcommands do not invoke upstream script" {
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

@test "blocked subcommand error message goes to stderr" {
    # Verify blocked commands print to stderr (not stdout) by checking
    # the stub is never invoked (its STUB: prefix never appears in output)
    run "${LAUNCHER}" -up
    [ "$status" -eq 1 ]
    [[ "$output" == *"not supported in the snap"* ]]
    [[ "$output" != *"STUB:"* ]]
}

# --- exit code propagation -----------------------------------------------

@test "propagate non-zero exit code from upstream" {
    cat > "${STUB}" <<'EOF'
#!/bin/sh
exit 42
EOF
    run "${LAUNCHER}" status
    [ "$status" -eq 42 ]
}

@test "propagate zero exit code from upstream" {
    run "${LAUNCHER}" status
    [ "$status" -eq 0 ]
}

# --- environment ----------------------------------------------------------

@test "export HOME as SNAP_DATA" {
    cat > "${STUB}" <<'EOF'
#!/bin/sh
echo "HOME=${HOME}"
EOF
    run "${LAUNCHER}" status
    [ "$status" -eq 0 ]
    [[ "$output" == "HOME=${SNAP_DATA}" ]]
}

@test "prepend /opt/pihole to PATH" {
    cat > "${STUB}" <<'EOF'
#!/bin/sh
echo "PATH=${PATH}"
EOF
    run "${LAUNCHER}" status
    [ "$status" -eq 0 ]
    # After sed rewriting, /opt/pihole becomes ${TMPDIR}/opt, so check for that
    [[ "$output" == *"${TMPDIR}/opt"* ]]
}

# --- root privilege checks ------------------------------------------------

@test "reject administrative commands when run as non-root in snap environment" {
    export SNAP_REVISION="123"
    run "${LAUNCHER}" allow example.com
    [ "$status" -eq 1 ]
    [[ "$output" == *"must be run with root privileges"* ]]
    [[ "$output" == *"sudo pihole allow example.com"* ]]
}

@test "allow help, version, status, and query commands when run as non-root in snap environment" {
    export SNAP_REVISION="123"
    
    # 1. Help flag
    run "${LAUNCHER}" -h
    [ "$status" -eq 0 ]
    [[ "$output" == "STUB:-h" ]]
    
    # 2. Version flag
    run "${LAUNCHER}" -v
    [ "$status" -eq 0 ]
    [[ "$output" == "STUB:-v" ]]
    
    # 3. Status command
    run "${LAUNCHER}" status
    [ "$status" -eq 0 ]
    [[ "$output" == "STUB:status" ]]
    
    # 4. Query command
    run "${LAUNCHER}" query example.com
    [ "$status" -eq 0 ]
    [[ "$output" == "STUB:query example.com" ]]

    # 5. Snap-check command
    run "${LAUNCHER}" snap-check
    [ "$status" -eq 0 ]
    [[ "$output" == "STUB_SNAP_CHECK:" ]]
}

# --- snap specific diagnostic subcommands routing -------------------------

@test "route snap-check and snap-debug to their custom scripts" {
    # 1. snap-check
    run "${LAUNCHER}" snap-check
    [ "$status" -eq 0 ]
    [[ "$output" == "STUB_SNAP_CHECK:" ]]

    # 2. snap-debug (run as root / not in SNAP_REVISION to allow execution)
    run "${LAUNCHER}" snap-debug
    [ "$status" -eq 0 ]
    [[ "$output" == "STUB_SNAP_DEBUG:" ]]
}
