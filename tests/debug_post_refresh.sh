#!/bin/bash
set -x
WORKSPACE="/home/rajan/Projects/snap-pi-hole"
TMPDIR="${WORKSPACE}/scratch_tmp"
mkdir -p "${TMPDIR}/data" "${TMPDIR}/common" "${TMPDIR}/snap/opt/pihole/templates" "${TMPDIR}/bin"

export SNAP_DATA="${TMPDIR}/data"
export SNAP_COMMON="${TMPDIR}/common"
export SNAP="${TMPDIR}/snap"
export SNAP_NAME="pihole"

echo "CORE_VERSION=v6.4.2" > "${SNAP}/opt/pihole/templates/versions"

cat > "${TMPDIR}/bin/configure" <<'EOF'
#!/bin/sh
echo "CONFIGURE CALLED"
exit 0
EOF
chmod +x "${TMPDIR}/bin/configure"

cat > "${TMPDIR}/bin/dig" <<'EOF'
#!/bin/sh
echo "DIG CALLED"
exit 0
EOF
chmod +x "${TMPDIR}/bin/dig"

export PATH="${TMPDIR}/bin:${PATH}"

"${WORKSPACE}/snap/hooks/post-refresh"
STATUS=$?
echo "EXIT STATUS: ${STATUS}"

rm -rf "${TMPDIR}"
exit ${STATUS}
