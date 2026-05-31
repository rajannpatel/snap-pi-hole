#!/bin/bash
# CLI launcher: `snap run pihole.pihole <args>` → upstream `pihole` script.
#
# Subcommands that depend on an unconfined install (self-update, repair,
# uninstall, branch-switch) don't make sense inside a snap. Intercept
# them here with a clear message pointing at the snap-native equivalent.
set -eu

# Prepend snap staged paths to PATH to ensure we use our staged GNU coreutils
# rather than hitting AppArmor execution denials on the base snap's rust-coreutils.
export PATH="${SNAP}/usr/sbin:${SNAP}/usr/bin:${SNAP}/sbin:${SNAP}/bin:${PATH:-}"


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

# Check if the command requires root privileges
if [ "${EUID}" -ne 0 ] && [ -n "${SNAP_REVISION:-}" ]; then
    case "${1:-}" in
        ""|-h|--help|help|-v|--version|version|status|-q|query|snap-check)
            # Allowed to run as non-root
            ;;
        *)
            echo "Error: 'pihole $1' must be run with root privileges (sudo)." >&2
            echo "Reason: This command modifies configuration files, updates the database, or restarts services, which require root permissions." >&2
            echo "Please run: sudo pihole $@" >&2
            exit 1
            ;;
    esac
fi

# Intercept snap-specific diagnostic subcommands
case "${1:-}" in
    snap-check)
        exec "${SNAP}/bin/snap-check" "${@:2}"
        ;;
    snap-debug)
        exec "${SNAP}/bin/snap-debug" "${@:2}"
        ;;
esac

export HOME="${SNAP_DATA}"
export PATH="/opt/pihole:${PATH}"

exec /opt/pihole/pihole "$@"
