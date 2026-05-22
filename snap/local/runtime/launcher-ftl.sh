#!/bin/bash
# Daemon launcher for pihole-FTL inside the snap sandbox.
#
# Path remapping is handled by the `layout:` block in snapcraft.yaml,
# so /etc/pihole and /var/log/pihole already point at writable snap data
# dirs by the time this script runs. The PID file lives in /etc/pihole/
# (layout-mounted) so it is accessible to ALL snap apps regardless of
# the snap's published store name.
set -eu


# The launcher no longer performs pre-flight port 53 checks.
# If port 53 is occupied, FTL will log a clear EADDRINUSE error and crash,
# which the user can diagnose via `snap logs` and `pihole.check-system`.
# Pre-flight bash socket checks are brittle (lack of timeout can cause indefinite hangs)
# and fail to account for users who intentionally configure custom IP bindings.

mkdir -p "${SNAP_DATA}/etc/pihole" "${SNAP_DATA}/etc/dnsmasq.d" "${SNAP_COMMON}/var/log/pihole" "${SNAP_DATA}/run/pihole"

# Debug: Log the presence and contents of the templates/versions file
mkdir -p "${SNAP_COMMON}/var/log/pihole"
{
    echo "=== DEBUG VERSIONS ==="
    echo "Date: $(date)"
    echo "SNAP env: ${SNAP:-}"
    echo "Checking ${SNAP:-}/opt/pihole/templates/versions:"
    ls -la "${SNAP:-}/opt/pihole/templates/versions" || true
    echo "Content:"
    cat "${SNAP:-}/opt/pihole/templates/versions" || true
    echo "======================"
} > "${SNAP_COMMON}/var/log/pihole/versions_debug.log" 2>&1


# Seed/Update the static version profile template if present inside the snap squashfs
if [ -f "${SNAP:-}/opt/pihole/templates/versions" ]; then
    cp "${SNAP:-}/opt/pihole/templates/versions" "${SNAP_DATA}/etc/pihole/versions"
fi


# Seed a default config on first boot. FTL requires upstream servers to be configured
# in order to resolve adlist domains during the initial background gravity sync.
if [ ! -f "${SNAP_DATA}/etc/pihole/pihole.toml" ]; then
    cat > "${SNAP_DATA}/etc/pihole/pihole.toml" <<EOF
[dns]
  upstreams = [
    "8.8.8.8",
    "8.8.4.4"
  ]
EOF
fi

# Some scripts (and a few FTL code paths) assume $HOME is writable.
export HOME="${SNAP_DATA}"

# FTL sometimes behaves better when started from a writable directory.
cd "${SNAP_DATA}/run/pihole"

# If gravity.db exists but is 0 bytes, it is invalid and will cause migration
# errors in gravity.sh (e.g. no such table: OLD.group). Remove it to force
# a clean creation from scratch.
if [ -f "${SNAP_DATA}/etc/pihole/gravity.db" ] && [ ! -s "${SNAP_DATA}/etc/pihole/gravity.db" ]; then
    echo "Found 0-byte gravity.db, removing to allow clean re-initialization..."
    rm -f "${SNAP_DATA}/etc/pihole/gravity.db"
fi

# If gravity.db is missing or empty (first install), seed Steven Black's
# default blocklist and build gravity. This mirrors what Pi-hole's own
# basic-install.sh does:
#   1. First pihole -g initialises gravity.db with the correct schema
#      (gravity.sh creates all tables; pihole-FTL does not do this).
#   2. INSERT the Steven Black adlist now that the schema exists.
#   3. Second pihole -g downloads and processes the adlist.
# We sleep 10 s to let FTL fully bind port 53 before pihole -g runs.
if [ ! -s "${SNAP_DATA}/etc/pihole/gravity.db" ]; then
    echo "gravity.db is missing. Seeding default adlist and building gravity..."
    (
        # Ensure the snap-bundled curl (staged from bind9-dnsutils + curl
        # packages) is found by gravity.sh. Minimal Ubuntu images (ubuntu:lts
        # LXC) do not include curl by default.
        export PATH="${SNAP}/usr/bin:${PATH}"
        # Wait until FTL's DNS resolver is accepting queries (up to 90 s).
        # A fixed sleep is unreliable: gravity.sh uses curl which resolves
        # raw.githubusercontent.com via the system resolver; if FTL hasn't
        # started serving yet the download fails and the list is marked
        # inaccessible. dig is available via the staged bind9-dnsutils package.
        _ftl_ready=0
        for _i in $(seq 1 90); do
            if "${SNAP}/usr/bin/dig" +short +time=1 +tries=1 \
                    @127.0.0.1 . NS >/dev/null 2>&1; then
                _ftl_ready=1
                break
            fi
            sleep 1
        done
        if [ "${_ftl_ready}" -eq 0 ]; then
            echo "FTL DNS did not become ready within 90 s; skipping gravity seed." >&2
            exit 0
        fi

        # Pass 1: initialise schema (no adlists configured yet, downloads nothing)
        "${SNAP}/opt/pihole/pihole" -g > "${SNAP_COMMON}/var/log/pihole/gravity-init.log" 2>&1 || true
        # Insert Steven Black's unified hosts list now that the schema exists
        "${SNAP}/usr/bin/pihole-FTL" sqlite3 "${SNAP_DATA}/etc/pihole/gravity.db" \
          "INSERT OR IGNORE INTO adlist (address, enabled, comment) \
           VALUES ('https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts', \
                   1, 'Steven Black unified hosts (default)');" 2>/dev/null || true
        # Pass 2: download and process the adlist
        "${SNAP}/opt/pihole/pihole" -g > "${SNAP_COMMON}/var/log/pihole/gravity-first-run.log" 2>&1
    ) &
fi

exec "${SNAP}/usr/bin/pihole-FTL" no-daemon