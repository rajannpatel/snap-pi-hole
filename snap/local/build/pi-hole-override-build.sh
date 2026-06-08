#!/bin/bash
set -e

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

# Write the versions file directly to opt/pihole/templates/versions
mkdir -p "${CRAFT_PART_INSTALL}/opt/pihole/templates"
cat <<EOF > "${CRAFT_PART_INSTALL}/opt/pihole/templates/versions"
CORE_VERSION=${CORE_TAG}
CORE_BRANCH=snap
WEB_VERSION=${WEB_TAG}
WEB_BRANCH=snap
FTL_VERSION=${FTL_TAG}
FTL_BRANCH=snap
EOF

# Also copy the template to etc/.pihole/advanced/Scripts/templates/versions explicitly
mkdir -p "${CRAFT_PART_INSTALL}/etc/.pihole/advanced/Scripts/templates"
cp "${CRAFT_PART_INSTALL}/opt/pihole/templates/versions" "${CRAFT_PART_INSTALL}/etc/.pihole/advanced/Scripts/templates/versions"
