#!/bin/bash
set -e

# Capture the fetched tag for the pi_hole part to consume via CRAFT_STAGE.
# The `organize: "*"` below moves snap-meta along with the upstream
# docroot under var/www/html/admin/, so the consumer reads from
# ${CRAFT_STAGE}/var/www/html/admin/snap-meta/web-tag. Excluded from
# the final snap by the `prime:` block below.
WEB_TAG=$(git -C "${CRAFT_PART_SRC}" describe --tags --always)
if [[ ! "$WEB_TAG" =~ ^v ]]; then
    STABLE_VERSIONS_JSON="${CRAFT_PROJECT_DIR}/snap/local/build/stable-versions.json"
    if [ -f "$STABLE_VERSIONS_JSON" ]; then
        STABLE_WEB=$(python3 -c "import json; print(json.load(open('${STABLE_VERSIONS_JSON}'))['web'])")
    else
        STABLE_WEB="v6.5"
    fi
    WEB_TAG="${STABLE_WEB}+git.${WEB_TAG}"
fi
craftctl default
mkdir -p "${CRAFT_PART_INSTALL}/snap-meta"
printf '%s\n' "${WEB_TAG}" > "${CRAFT_PART_INSTALL}/snap-meta/web-tag"
