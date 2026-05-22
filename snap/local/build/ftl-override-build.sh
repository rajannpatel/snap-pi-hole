#!/bin/bash
set -e

# Single source of truth for the FTL version: the tag we just fetched.
# No YAML interpolation, no drift with the heredoc-in-core, no
# dependency on undocumented snapcraft variables.
FTL_TAG=$(git -C "${CRAFT_PART_SRC}" describe --tags --always)
export GIT_VERSION="${FTL_TAG}"
export GIT_TAG="${FTL_TAG}"
craftctl default
# Publish the tag for the pi_hole part to consume via CRAFT_STAGE.
# Excluded from the final snap by the `prime:` block below.
mkdir -p "${CRAFT_PART_INSTALL}/snap-meta"
printf '%s\n' "${FTL_TAG}" > "${CRAFT_PART_INSTALL}/snap-meta/ftl-tag"

# Explicitly copy host's coreutils binaries as real files to avoid AppArmor symlink execution denials on Ubuntu Core.
# Since the build host uses Rust-based uutils coreutils by default, realpath resolves the symlinks
# to the multicall binary. Copying the resolved binary as a real file under the command name
# avoids AppArmor symlink resolution issues inside the snap.
mkdir -p "${CRAFT_PART_INSTALL}/usr/bin"
(
    # Restrict PATH to host system paths so we don't resolve to already staged/installed binaries
    PATH="/usr/sbin:/usr/bin:/sbin:/bin"
    for cmd in timeout truncate mkdir cp rm sleep date seq ls tail cat chmod chown mv ln uname touch id whoami head wc tr cut sort uniq tee dirname basename readlink realpath env true false stat; do
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




