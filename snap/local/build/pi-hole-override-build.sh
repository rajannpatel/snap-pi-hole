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
CORE_COMMIT=$(git -C "${CRAFT_PART_SRC}" rev-parse --short HEAD)
STABLE_CORE=$(python3 "${CRAFT_PROJECT_DIR}/snap/local/build/resolve_upstream_version.py" pi_hole --source-dir "${CRAFT_PART_SRC}")

CORE_TAG="${STABLE_CORE}+git.${CORE_COMMIT}"
SNAP_VERSION="${CORE_TAG}"

# Snap version mirrors the fetched upstream pi-hole/pi-hole source commit,
# matching what `pihole -v` reports for CORE_VERSION.
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
