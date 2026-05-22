#!/bin/bash
# CLI launcher: `snap run pihole.pihole <args>` → upstream `pihole` script.
#
# Subcommands that depend on an unconfined install (self-update, repair,
# uninstall, branch-switch) don't make sense inside a snap. Intercept
# them here with a clear message pointing at the snap-native equivalent.
set -eu

usage_snap_equivalent() {
    case "$1" in
        -up|updatePihole|updatechecker|checkout)
            echo "  Use: sudo snap refresh pihole" >&2
            ;;
        -r|repair)
            echo "  Use: sudo snap revert pihole   # then re-refresh if needed" >&2
            ;;
        uninstall)
            echo "  Use: sudo snap remove pihole" >&2
            ;;
    esac
}

case "${1:-}" in
    -up|updatePihole|-r|repair|uninstall|checkout|updatechecker)
        echo "Error: 'pihole $1' is not supported in the snap." >&2
        usage_snap_equivalent "$1"
        exit 1
        ;;
esac

export HOME="${SNAP_DATA}"
export PATH="/opt/pihole:${PATH}"

# Debug: Log the presence and contents of the templates/versions file
mkdir -p "${SNAP_COMMON}/var/log/pihole"
{
    echo "=== DEBUG PIHOLE LAUNCHER VERSIONS ==="
    echo "Date: $(date)"
    echo "SNAP env: ${SNAP:-}"
    echo "Checking ${SNAP:-}/opt/pihole/templates/versions:"
    ls -la "${SNAP:-}/opt/pihole/templates/versions" || true
    echo "Content:"
    cat "${SNAP:-}/opt/pihole/templates/versions" || true
    echo "======================================"
} > "${SNAP_COMMON}/var/log/pihole/pihole_launcher_debug.log" 2>&1


# Ensure version profile template is seeded before running CLI commands
if [ -f "${SNAP:-}/opt/pihole/templates/versions" ]; then
    cp "${SNAP:-}/opt/pihole/templates/versions" "${SNAP_DATA}/etc/pihole/versions"
fi


exec /opt/pihole/pihole "$@"
