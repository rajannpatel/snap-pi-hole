#!/bin/bash
set -e

CONFIG_HELPER="${CRAFT_PROJECT_DIR}/snap/local/runtime/pihole-config.sh"
if [ ! -r "$CONFIG_HELPER" ]; then
    echo "Error: missing configuration helper at $CONFIG_HELPER" >&2
    exit 1
fi

# shellcheck source=snap/local/runtime/pihole-config.sh
. "$CONFIG_HELPER"

FTL_TAG=$(cat "${CRAFT_STAGE}/snap-meta/ftl-tag")
WEB_TAG=$(cat "${CRAFT_STAGE}/var/www/html/admin/snap-meta/web-tag")
CORE_TAG=$(git -C "${CRAFT_PART_SRC}" describe --tags --always)

# Get the short Git hash and commit timestamp from the wrapper repository (snap-pi-hole)
if git -C "${CRAFT_PROJECT_DIR}" rev-parse --short HEAD &>/dev/null; then
    WRAPPER_HASH=$(git -C "${CRAFT_PROJECT_DIR}" rev-parse --short HEAD)
    WRAPPER_TIME=$(git -C "${CRAFT_PROJECT_DIR}" log -1 --format=%ct)
    SNAP_VERSION="${CORE_TAG}+git.${WRAPPER_HASH}.${WRAPPER_TIME}"
else
    SNAP_VERSION="${CORE_TAG}"
fi

# Snap version mirrors the upstream pi-hole/pi-hole tag, matching
# what `pihole -v` reports for CORE_VERSION.
craftctl set version="${SNAP_VERSION}"

craftctl default
# Replicate the advanced/ directory structure to etc/.pihole/advanced
# to satisfy gravity.sh which expects /etc/.pihole/advanced/Templates/ 
# and /etc/.pihole/advanced/Scripts/database_migration/
mkdir -p "${CRAFT_PART_INSTALL}/etc/.pihole"
cp -R "${CRAFT_PART_SRC}/advanced" "${CRAFT_PART_INSTALL}/etc/.pihole/"

# Copy all scripts from advanced/Scripts/ to opt/pihole/ manually to avoid
# Snapcraft organize wildcard and directory merging limitations.
mkdir -p "${CRAFT_PART_INSTALL}/opt/pihole"
cp -R "${CRAFT_PART_SRC}/advanced/Scripts/"* "${CRAFT_PART_INSTALL}/opt/pihole/"

VERSIONS_TEMPLATE="$(pihole_versions_template_file "$CRAFT_PART_INSTALL")"
ADVANCED_VERSIONS_TEMPLATE="$(pihole_advanced_versions_template_file "$CRAFT_PART_INSTALL")"

# Write the versions file to the shared template path used by runtime seeding.
mkdir -p "$(dirname "$VERSIONS_TEMPLATE")"
cat <<EOF > "$VERSIONS_TEMPLATE"
CORE_VERSION=${CORE_TAG}
CORE_BRANCH=snap
WEB_VERSION=${WEB_TAG}
WEB_BRANCH=snap
FTL_VERSION=${FTL_TAG}
FTL_BRANCH=snap
EOF

# Also copy the template to etc/.pihole/advanced/Scripts/templates/versions explicitly
mkdir -p "$(dirname "$ADVANCED_VERSIONS_TEMPLATE")"
cp "$VERSIONS_TEMPLATE" "$ADVANCED_VERSIONS_TEMPLATE"
