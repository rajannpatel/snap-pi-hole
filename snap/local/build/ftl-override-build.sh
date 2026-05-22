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

# Explicitly copy host's Rust coreutils binary to bypass Snapcraft base snap exclusions.
# Since the build host (Ubuntu 26.04) uses Rust-based uutils coreutils by default,
# realpath resolves /usr/bin/timeout to the multicall binary. Copying the resolved
# binary as a real file avoids AppArmor symlink resolution issues inside the snap.
mkdir -p "${CRAFT_PART_INSTALL}/usr/bin"
cp "$(realpath /usr/bin/timeout)" "${CRAFT_PART_INSTALL}/usr/bin/timeout"
cp "$(realpath /usr/bin/truncate)" "${CRAFT_PART_INSTALL}/usr/bin/truncate"

