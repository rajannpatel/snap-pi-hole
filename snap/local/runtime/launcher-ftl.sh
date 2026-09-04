#!/bin/bash
# Daemon launcher for pihole-FTL inside the snap sandbox.
#
# Path remapping is handled by the `layout:` block in snapcraft.yaml,
# so /etc/pihole and /var/log/pihole already point at writable snap data
# dirs by the time this script runs. The PID file lives in /etc/pihole/
# (layout-mounted) so it is accessible to ALL snap apps regardless of
# the snap's published store name.
set -eu

# Prepend snap staged paths to PATH to ensure we use our staged GNU coreutils
# rather than hitting AppArmor execution denials on the base snap's rust-coreutils.
export PATH="${SNAP}/usr/sbin:${SNAP}/usr/bin:${SNAP}/sbin:${SNAP}/bin:${PATH:-}"

SCRIPT_DIR="$(unset CDPATH; cd -P -- "$(dirname "$0")" && pwd)"
# shellcheck source=snap/local/runtime/pihole-config.sh
. "${SCRIPT_DIR}/pihole-config.sh"


# The launcher no longer performs pre-flight port 53 checks.
# If port 53 is occupied, FTL will log a clear EADDRINUSE error and crash,
# which the user can diagnose via `snap logs` and `pihole.check-system`.
# Pre-flight bash socket checks are brittle (lack of timeout can cause indefinite hangs)
# and fail to account for users who intentionally configure custom IP bindings.

mkdir -p "${SNAP_DATA}/etc/pihole" "${SNAP_DATA}/etc/dnsmasq.d" "${SNAP_COMMON}/var/log/pihole" "${SNAP_DATA}/run/pihole"

# Seed/Update the static version profile template if present inside the snap squashfs
pihole_seed_versions_file "$(pihole_versions_template_file "${SNAP:-}")" "$(pihole_versions_file "${SNAP_DATA:-}")"


# Seed a default config on first boot. FTL requires upstream servers to be configured
# in order to resolve adlist domains during the initial background gravity sync.
pihole_seed_default_toml "$(pihole_toml_file)"

# TLS bootstrap: pihole-FTL refuses to start its webserver at all when a
# configured HTTPS port cannot be served because the TLS certificate is
# missing or cannot be generated, which took down the plain-HTTP admin UI
# and API on fresh installs (issue #13). While the port configuration is
# still the unmodified FTL default and no certificate exists, try to
# generate the self-signed certificate once per boot: first through FTL's
# native --gen-x509, then through staged OpenSSL. Only when both fail are
# the TLS entries dropped so the webserver comes up HTTP-only.
# Operator-configured webserver.port values are never touched - supplying
# your own certificate and TLS ports keeps working as before.
#
# Note: pihole-FTL --config stores the value verbatim, so the replacement
# port list must be passed WITHOUT surrounding quote characters.
_ftl_default_webserver_port='80o,443os,[::]:80o,[::]:443os'
_http_only_webserver_port='80o,[::]:80o'
_webserver_port="$(pihole_toml_flat "$(pihole_toml_file)" 2>/dev/null | pihole_flat_value webserver.port)"
_webserver_port="$(pihole_normalize_config_value "${_webserver_port:-}")"
# An empty value means FTL will apply its built-in default (which requests
# TLS), so it is treated the same way. A stale artifact of an older fallback
# that embedded literal quote characters is also ours to repair; FTL cannot
# parse such a value and would leave the webserver down. Anything else was
# customized by the operator and is left strictly alone.
_webserver_managed=""
if [ -z "${_webserver_port}" ] || [ "${_webserver_port}" = "${_ftl_default_webserver_port}" ]; then
    _webserver_managed="${_ftl_default_webserver_port}"
elif printf '%s' "${_webserver_port}" | grep -qF -- '"'"${_http_only_webserver_port}"; then
    _webserver_managed="stale"
fi

# Emit a self-signed certificate with the staged OpenSSL. Used as a fallback
# when pihole-FTL's own generator fails inside the sandbox (its bundled
# mbedTLS build cannot write certificates - issue #13). Produces a single
# combined PEM (certificate followed by key), the layout the embedded
# webserver expects.
launcher_generate_tls_certificate() {
    tls_pem="${1:?target PEM path required}"
    tls_key_tmp="${tls_pem}.key.$$"
    tls_crt_tmp="${tls_pem}.crt.$$"
    if ! "${SNAP}/usr/bin/openssl" req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
            -sha256 -nodes -days 3650 -subj "/CN=pi.hole" \
            -addext "subjectAltName=DNS:pi.hole,DNS:localhost,IP:127.0.0.1" \
            -keyout "${tls_key_tmp}" -out "${tls_crt_tmp}" >/dev/null 2>&1 \
            || [ ! -s "${tls_key_tmp}" ] || [ ! -s "${tls_crt_tmp}" ]; then
        rm -f "${tls_key_tmp}" "${tls_crt_tmp}"
        return 1
    fi
    cat "${tls_crt_tmp}" "${tls_key_tmp}" > "${tls_pem}"
    chmod 600 "${tls_pem}"
    rm -f "${tls_key_tmp}" "${tls_crt_tmp}"
}

# Guarantee a usable certificate at the given path: keep an existing one,
# otherwise try pihole-FTL's native generator first and fall back to
# OpenSSL. Returns non-zero when no certificate could be produced.
launcher_ensure_tls_certificate() {
    tls_pem="${1:?target PEM path required}"
    [ -s "${tls_pem}" ] && return 0
    if "${SNAP}/usr/bin/pihole-FTL" --gen-x509 "${tls_pem}" pi.hole >/dev/null 2>&1 && [ -s "${tls_pem}" ]; then
        echo "Generated self-signed TLS certificate for the webserver."
        return 0
    fi
    rm -f "${tls_pem}"
    if launcher_generate_tls_certificate "${tls_pem}"; then
        echo "Generated self-signed TLS certificate for the webserver (OpenSSL fallback)."
        return 0
    fi
    rm -f "${tls_pem}"
    return 1
}

_tls_pem="${SNAP_DATA}/etc/pihole/tls.pem"
if [ "${_webserver_managed}" = "stale" ]; then
    # Repair the mis-quoted artifact. Keep serving TLS when a working
    # certificate exists (or can be generated); otherwise go HTTP-only.
    if launcher_ensure_tls_certificate "${_tls_pem}"; then
        _repair_port="${_ftl_default_webserver_port}"
    else
        _repair_port="${_http_only_webserver_port}"
        echo "Warning: no TLS certificate could be generated; webserver restricted to plain HTTP (${_http_only_webserver_port})." >&2
    fi
    "${SNAP}/usr/bin/pihole-FTL" --config webserver.port "${_repair_port}"
    echo "Repaired webserver.port (was stored with invalid quoting); set to '${_repair_port}'."
elif [ -n "${_webserver_managed}" ] && [ ! -s "${_tls_pem}" ]; then
    case "${_webserver_managed}" in
        *s*)
            if ! launcher_ensure_tls_certificate "${_tls_pem}"; then
                "${SNAP}/usr/bin/pihole-FTL" --config webserver.port "${_http_only_webserver_port}"
                echo "Warning: TLS certificate generation failed; webserver restricted to plain HTTP (${_http_only_webserver_port})." >&2
            fi
            ;;
    esac
fi

# Sync local configuration back to snapctl database to treat it as the single source of truth
if [ -x "${SNAP}/bin/config-sync" ]; then
    "${SNAP}/bin/config-sync" || echo "Warning: configuration sync failed" >&2
else
    echo "Warning: config-sync not found or not executable at ${SNAP}/bin/config-sync" >&2
fi

# Security: never serve the web UI/API unauthenticated on a network-reachable
# address (GitHub issue #14). Pi-hole v6 allows unauthenticated API access
# when no password is set, so `pwhash = ""` plus a non-loopback
# webserver.port lets any LAN host rewrite the whole configuration (including
# dns.upstreams). When that combination is detected:
#   * first boot: generate a random admin password (the pattern FTL itself
#     uses for /etc/pihole/cli_pw), apply it via the same config call the
#     upstream `pihole setpassword` uses, store it root-only, and announce
#     it here so `snap logs` shows it;
#   * password deliberately removed afterwards: do not fight the operator by
#     regenerating it, but make the exposure impossible to miss.
# This check runs after config-sync so snap-set port/acl overrides are
# already reflected in pihole.toml.
pihole_toml_path="$(pihole_toml_file)"
pihole_web_password_file="${SNAP_DATA}/etc/pihole/web_pw"
pihole_toml_flat_cache="$(pihole_toml_flat "$pihole_toml_path" 2>/dev/null || true)"

if [ -s "$pihole_toml_path" ] && [ -z "$pihole_toml_flat_cache" ]; then
    # A non-empty pihole.toml that yields no key/value lines means the flat
    # parser could not read the file (e.g. a future FTL config syntax). The
    # pwhash/exposure read is then meaningless: do not generate a password
    # (we cannot tell whether one exists) and do not warn about a disabled
    # one; report the skip and let the daemon come up. An empty or missing
    # pihole.toml is a legitimate state (FTL then uses its defaults), and
    # the seeded minimal toml always parses to at least one key.
    echo "Note: could not read key/value pairs from ${pihole_toml_path} to verify web API authentication; skipping the web password check."
else
    pihole_pwhash_raw="$(printf '%s\n' "$pihole_toml_flat_cache" | pihole_flat_value webserver.api.pwhash)"
    pihole_pwhash="$(pihole_normalize_config_value "${pihole_pwhash_raw:-}")"
    pihole_exposure="$(pihole_webserver_exposure \
        "$(printf '%s\n' "$pihole_toml_flat_cache" | pihole_flat_value webserver.port)")"

    if [ -z "$pihole_pwhash" ] && [ "$pihole_exposure" = "reachable" ]; then
        if [ -e "$pihole_web_password_file" ]; then
            echo "WARNING: the web interface password is disabled while the API listens" >&2
            echo "on non-loopback addresses: any host on the network can change this" >&2
            echo "Pi-hole's configuration. Restore a password with 'sudo pihole setpassword'" >&2
            echo "or restrict access with:" >&2
            echo "  sudo snap set $(pihole_snap_name) ftl.webserver.port=127.0.0.1:8080" >&2
            echo "  sudo snap set $(pihole_snap_name) 'ftl.webserver.acl=+127.0.0.1,+[::1]'" >&2
        else
            # Random 20-char alphanumeric password from the staged coreutils.
            # 256 input bytes make it vanishingly unlikely to see fewer than
            # 20 usable characters (~62 expected); the length guard below
            # guarantees exactly 20 characters are applied. A deterministic
            # fallback would weaken the password, so a short read is retried
            # on the next start instead.
            pihole_web_password=""
            for _pw_attempt in 1 2 3; do
                pihole_web_password="$(head -c 256 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 20)"
                [ "${#pihole_web_password}" -eq 20 ] && break
            done
            if [ "${#pihole_web_password}" -ne 20 ]; then
                echo "Warning: failed to generate a web interface password; the API stays unauthenticated. Retrying on next start." >&2
            elif "${SNAP}/usr/bin/pihole-FTL" --config webserver.api.password "$pihole_web_password" >/dev/null 2>&1; then
                # Root-only plaintext next to the other pihole secrets, mirroring
                # FTL's own /etc/pihole/cli_pw handling.
                (umask 077 && printf '%s\n' "$pihole_web_password" > "$pihole_web_password_file")
                cat <<EOF

SECURITY NOTICE (web interface password)

No web password was configured and the web UI/API listens on all
interfaces. A random administrator password has been generated:

    ${pihole_web_password}

It is stored root-only (mode 0600) at:
    /var/snap/$(pihole_snap_name)/current/etc/pihole/web_pw

Use it to sign in to the web UI, then replace it with your own:
    sudo pihole setpassword

EOF
            else
                echo "Warning: the generated web interface password could not be applied (pihole-FTL --config failed); the API stays unauthenticated. Retrying on next start." >&2
            fi
        fi
    elif [ -z "$pihole_pwhash" ]; then
        if [ "$pihole_exposure" = "disabled" ]; then
            echo "Note: the embedded webserver/API is disabled (webserver.port is empty); no password is configured."
        else
            echo "Note: the web interface has no password, but it listens on loopback only; no password was generated."
        fi
    fi
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
# Pass 2 is deferred to a background child that waits for FTL to actually
# answer DNS before running (a fixed sleep would be unreliable); see the
# lifecycle rationale on that block below.
if [ ! -s "${SNAP_DATA}/etc/pihole/gravity.db" ]; then
    echo "gravity.db is missing. Seeding default adlist and building gravity..."
    
    # Pass 1: initialise schema (no adlists configured yet, downloads nothing)
    # This runs synchronously before FTL starts to avoid any database race conditions.
    "${SNAP}/opt/pihole/pihole" -g > "${SNAP_COMMON}/var/log/pihole/gravity-init.log" 2>&1 || true
    
    # Insert Steven Black's unified hosts list now that the schema exists
    "${SNAP}/usr/bin/pihole-FTL" sqlite3 "${SNAP_DATA}/etc/pihole/gravity.db" \
      "INSERT OR IGNORE INTO adlist (address, enabled, comment) \
       VALUES ('https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts', \
               1, 'Steven Black unified hosts (default)');" 2>/dev/null || true

    # Pass 2 runs as a background child so it does not block FTL's startup:
    # gravity.sh can only download adlists once FTL is resolving DNS, so FTL
    # must come up first (via the exec below) and the fetch runs in parallel.
    #
    # This is deliberately NOT a separate oneshot "seed" service. FTL ships
    # install-mode: disable and gravity needs FTL's resolver running, so an
    # install-time service would have nothing to run against, and ordering a
    # oneshot after an operator-enabled daemon adds complexity for no real gain.
    #
    # The child is safe even though it outlives this script's exec into FTL:
    #   * Self-bounding:    it gives up after 90 s if FTL never answers.
    #   * Reaped by systemd: it remains in the service cgroup, so a stop,
    #     on-failure restart, or `endure` refresh kills it together with the
    #     daemon (default KillMode=control-group) - it cannot leak past the
    #     service's lifetime.
    #   * Self-healing:     if it is killed mid-build, the next start re-checks
    #     for a missing/0-byte gravity.db and rebuilds; the post-refresh hook
    #     and the gravity-sync timer are further backstops.
    (
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
            echo "FTL DNS did not become ready within 90 s; skipping background gravity update." >&2
            exit 0
        fi

        # Pass 2: download and process the adlist
        "${SNAP}/opt/pihole/pihole" -g > "${SNAP_COMMON}/var/log/pihole/gravity-first-run.log" 2>&1
    ) &
fi

exec "${SNAP}/usr/bin/pihole-FTL" no-daemon
