#!/bin/bash
set -e

# Single source of truth for the FTL version: the tag we just fetched.
# No YAML interpolation, no drift with the heredoc-in-core, no
# dependency on undocumented snapcraft variables.
FTL_TAG=$(git -C "${CRAFT_PART_SRC}" describe --tags --always)
if [[ ! "$FTL_TAG" =~ ^v ]]; then
    STABLE_FTL=$(python3 "${CRAFT_PROJECT_DIR}/snap/local/build/resolve_upstream_version.py" ftl --source-dir "${CRAFT_PART_SRC}")
    FTL_TAG="${STABLE_FTL}+git.${FTL_TAG}"
fi
export GIT_VERSION="${FTL_TAG}"
export GIT_TAG="${FTL_TAG}"
craftctl default
# Publish the tag for the pi_hole part to consume via CRAFT_STAGE.
# Excluded from the final snap by the `prime:` block below.
mkdir -p "${CRAFT_PART_INSTALL}/snap-meta"
printf '%s\n' "${FTL_TAG}" > "${CRAFT_PART_INSTALL}/snap-meta/ftl-tag"

# Provide coreutils as REAL per-command binaries in usr/bin.
#
# This override-build runs INSIDE the pinned core26 snapcraft build instance
# (not the developer's host), so resolving commands from its system PATH is
# reproducible. core26 ships rust-coreutils (uutils) as symlinks into a single
# multicall binary, and executing those symlinks under strict confinement trips
# AppArmor symlink-exec denials. We realpath-resolve each command and copy the
# resolved target as a real file named after the command (the multicall
# dispatches on argv[0], so a copy named `timeout` behaves as timeout).
#
# IMPORTANT: this loop is the SOLE source of coreutils in the snap.
# `stage-packages: coreutils` contributes only documentation on core26, not
# usable binaries (verified by building with this loop removed: every coreutils
# binary vanished from usr/bin). Do NOT delete this expecting stage-packages to
# cover it  -  the patched upstream scripts hardcode $SNAP/usr/bin/{timeout,
# truncate,mktemp} (see pi-hole-override-pull.sh) and the snap breaks without it.
mkdir -p "${CRAFT_PART_INSTALL}/usr/bin"
(
    # Restrict PATH to the build instance's base system paths so we don't
    # resolve to already-staged/installed binaries.
    PATH="/usr/sbin:/usr/bin:/sbin:/bin"
    for cmd in timeout truncate mktemp mkdir cp rm sleep date seq ls tail cat chmod chown mv ln uname touch id whoami head wc tr cut sort uniq tee dirname basename readlink realpath env true false stat; do
        path="$(command -v "$cmd")"
        case "$path" in
            /*)
                src="$(realpath "$path")"
                dst="${CRAFT_PART_INSTALL}/usr/bin/$cmd"
                if [ "$src" != "$dst" ]; then
                    cp "$src" "$dst"
                fi
                ;;
        esac
    done
)

# Staging guard: fail loudly if the coreutils the patched upstream scripts call
# by absolute path ($SNAP/usr/bin/<cmd>, see pi-hole-override-pull.sh) did not
# land as real files. Without this, a regression in the copy loop above ships a
# snap whose pihole scripts die at runtime with "no such file or directory".
for _req in timeout truncate mktemp; do
    if [ ! -f "${CRAFT_PART_INSTALL}/usr/bin/${_req}" ]; then
        echo "ERROR: '${_req}' is missing from ${CRAFT_PART_INSTALL}/usr/bin after the coreutils copy." >&2
        echo "       Upstream scripts hardcode \$SNAP/usr/bin/${_req}; the snap would break at runtime." >&2
        exit 1
    fi
done
