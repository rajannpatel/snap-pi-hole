#!/usr/bin/env bats
#
# Static cross-file guard for the coreutils staging coupling.
#
# The build patches the upstream scripts (snap/local/build/pi-hole-override-pull.sh)
# to call certain coreutils by the ABSOLUTE path $SNAP/usr/bin/<cmd>. On core26
# those binaries are NOT provided by `stage-packages: coreutils` (that deb
# contributes only docs); they are copied into usr/bin by the FTL part's build
# step (snap/local/build/ftl-override-build.sh). If those two lists drift apart,
# the snap still builds but the patched scripts die at runtime with
# "no such file or directory".
#
# ftl-override-build.sh already has a *build-time* guard for this, but a build
# is expensive and needs LXD/a TTY. This test catches the drift statically in
# the fast lint job. NOTE: it is a static consistency check only -- it cannot
# verify the binaries actually stage correctly under confinement (that is the
# job of the CI smoke test's AppArmor-denial assertion).
#
# Run locally:  bats tests/unit/coreutils-staging.bats

setup() {
    REPO_ROOT="$(git rev-parse --show-toplevel)"
    PULL="${REPO_ROOT}/snap/local/build/pi-hole-override-pull.sh"
    BUILD="${REPO_ROOT}/snap/local/build/ftl-override-build.sh"

    # Commands that override-pull rewrites to the absolute $SNAP/usr/bin/<cmd>
    # path (the first lowercase-word alternation group on the rewrite line).
    HARDCODED="$(grep -oE '\(([a-z]+\|)+[a-z]+\)' "$PULL" | head -1 | tr -d '()' | tr '|' ' ')"

    # The list ftl-override-build.sh copies into usr/bin.
    COPYLIST="$(grep -E 'for cmd in ' "$BUILD" | sed -E 's/.*for cmd in //; s/;[[:space:]]*do.*//')"

    # The subset ftl-override-build.sh's build-time guard re-checks.
    GUARDLIST="$(grep -E 'for _req in ' "$BUILD" | sed -E 's/.*for _req in //; s/;[[:space:]]*do.*//')"
}

@test "extraction sanity: the three lists are non-empty" {
    # If any extraction breaks (e.g. a script was refactored), fail loudly
    # rather than letting an empty list make the coupling tests pass vacuously.
    [ -n "$HARDCODED" ]
    [ -n "$COPYLIST" ]
    [ -n "$GUARDLIST" ]
}

@test "every coreutils hardcoded to \$SNAP/usr/bin is copied by ftl-override-build.sh" {
    for cmd in $HARDCODED; do
        echo " ${COPYLIST} " | grep -qw "$cmd" \
            || { echo "FAIL: '$cmd' is rewritten to \$SNAP/usr/bin/$cmd in pi-hole-override-pull.sh but is NOT in ftl-override-build.sh's copy loop"; false; }
    done
}

@test "ftl-override-build.sh's build-time guard covers every hardcoded coreutils" {
    for cmd in $HARDCODED; do
        echo " ${GUARDLIST} " | grep -qw "$cmd" \
            || { echo "FAIL: '$cmd' is hardcoded to \$SNAP/usr/bin but the build-time guard in ftl-override-build.sh does not check for it"; false; }
    done
}
