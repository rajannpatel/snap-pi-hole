#!/bin/bash
set -e

# Capture the fetched tag for the pi_hole part to consume via CRAFT_STAGE.
# The `organize: "*"` below moves snap-meta along with the upstream
# docroot under var/www/html/admin/, so the consumer reads from
# ${CRAFT_STAGE}/var/www/html/admin/snap-meta/web-tag. Excluded from
# the final snap by the `prime:` block below.
WEB_TAG=$(git -C "${CRAFT_PART_SRC}" describe --tags --always)
craftctl default
mkdir -p "${CRAFT_PART_INSTALL}/snap-meta"
printf '%s\n' "${WEB_TAG}" > "${CRAFT_PART_INSTALL}/snap-meta/web-tag"
