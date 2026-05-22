#!/bin/bash
set -e

craftctl default
# Fix strstr redefinition error on newer glibc (Ubuntu 26.04)
sed -i 's/#define strstr(haystack, needle)/#undef strstr\n#define strstr(haystack, needle)/' "${CRAFT_PART_SRC}/src/FTL.h"

# Patch x509.c for MbedTLS 3.x API compatibility (MbedTLS 3.6 strictly requires RNG for PEM generation)
sed -i '15i #include <mbedtls/psa_util.h>' src/webserver/x509.c
sed -i 's/mbedtls_x509write_crt_pem(&ca_cert, ca_buffer, sizeof(ca_buffer))/mbedtls_x509write_crt_pem(\&ca_cert, ca_buffer, sizeof(ca_buffer), mbedtls_psa_get_random, MBEDTLS_PSA_RANDOM_STATE)/g' src/webserver/x509.c
sed -i 's/mbedtls_x509write_crt_pem(&server_cert, cert_buffer, sizeof(cert_buffer))/mbedtls_x509write_crt_pem(\&server_cert, cert_buffer, sizeof(cert_buffer), mbedtls_psa_get_random, MBEDTLS_PSA_RANDOM_STATE)/g' src/webserver/x509.c
sed -i 's/mbedtls_pk_parse_keyfile(&key, certfile, NULL)/mbedtls_pk_parse_keyfile(\&key, certfile, NULL, mbedtls_psa_get_random, MBEDTLS_PSA_RANDOM_STATE)/g' src/webserver/x509.c

# Redirect PID files to /etc/pihole/ which is layout-mounted to
# $SNAP_DATA/etc/pihole/ and is visible to ALL snap apps regardless
# of the snap's store name (avoids CRAFT_PROJECT_NAME vs SNAP_NAME mismatch).
# Handle /var/run/ before /run/ to avoid partial-match corruption
# (dnsmasq defaults to /var/run/dnsmasq.pid; a naive s|/run/…| would
# turn that into /var/etc/pihole/dnsmasq.pid).
grep -rlZ '/run/pihole-FTL.pid' "${CRAFT_PART_SRC}" | xargs -0 -r sed -i \
  -e "s|/var/run/pihole-FTL.pid|/etc/pihole/pihole-FTL.pid|g" \
  -e "s|/run/pihole-FTL.pid|/etc/pihole/pihole-FTL.pid|g"
grep -rlZ '/run/dnsmasq.pid' "${CRAFT_PART_SRC}" | xargs -0 -r sed -i \
  -e "s|/var/run/dnsmasq.pid|/etc/pihole/dnsmasq.pid|g" \
  -e "s|/run/dnsmasq.pid|/etc/pihole/dnsmasq.pid|g"

# Neutralize dnsmasq's attempt to drop supplementary groups.
# In a strictly confined snap, daemons run as root without CAP_SETGID
# by default. Since pihole-FTL passes `-u root` internally, dnsmasq
# looks up the root group and tries to call setgroups(0) which fails with EPERM.
sed -i 's/setgroups(0, \&dummy) == -1/0/g' src/dnsmasq/dnsmasq.c
sed -i 's/setgid(gp->gr_gid) == -1/0/g' src/dnsmasq/dnsmasq.c

# Suppress harmless chown_pihole warning in strictly confined snaps
# where the pihole user does not exist. Daemons run as root anyway.
sed -i 's/log_warn("chown_pihole(): Failed to get pihole user.*/return true;/g' src/files.c

# Patch-rot guards. If upstream renames or rewords any of the targets
# above, the sed silently no-ops and the build ships an unpatched
# binary. Fail loudly so the next FTL bump is investigated.
if ! grep -qF '#undef strstr' "${CRAFT_PART_SRC}/src/FTL.h"; then
  echo "ERROR: FTL.h strstr undef patch did not apply" >&2
  exit 1
fi
if ! grep -qF 'mbedtls_psa_get_random' "${CRAFT_PART_SRC}/src/webserver/x509.c"; then
  echo "ERROR: x509.c MbedTLS RNG patch did not apply" >&2
  exit 1
fi
if grep -rnF '/run/pihole-FTL.pid' "${CRAFT_PART_SRC}"; then
  echo "ERROR: PID redirect for pihole-FTL.pid missed a file" >&2
  exit 1
fi
if grep -rnF '/run/dnsmasq.pid' "${CRAFT_PART_SRC}"; then
  echo "ERROR: PID redirect for dnsmasq.pid missed a file" >&2
  exit 1
fi
if grep -nF 'setgroups(0, &dummy) == -1' "${CRAFT_PART_SRC}/src/dnsmasq/dnsmasq.c"; then
  echo "ERROR: dnsmasq setgroups neutralization did not apply" >&2
  exit 1
fi
if grep -nF 'setgid(gp->gr_gid) == -1' "${CRAFT_PART_SRC}/src/dnsmasq/dnsmasq.c"; then
  echo "ERROR: dnsmasq setgid neutralization did not apply" >&2
  exit 1
fi
if grep -nF 'log_warn("chown_pihole(): Failed to get pihole user' "${CRAFT_PART_SRC}/src/files.c"; then
  echo "ERROR: chown_pihole warning suppression did not apply" >&2
  exit 1
fi
