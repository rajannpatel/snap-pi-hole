#!/usr/bin/env bats
#
# Unit tests for the enrich_sbom.py helper script.
#

setup() {
    REPO_ROOT="$(git rev-parse --show-toplevel)"
    TEST_DIR="${BATS_TMPDIR}/enrich-sbom-test"
    rm -rf "${TEST_DIR}"
    mkdir -p "${TEST_DIR}"
}

teardown() {
    rm -rf "${TEST_DIR}"
}

@test "enrich_sbom.py shows usage on insufficient arguments" {
    run python3 "${REPO_ROOT}/snap/local/build/enrich_sbom.py"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "enrich_sbom.py successfully enriches mock CycloneDX SBOM" {
    # 1. Setup mock extracted snap tree with copyright files
    mkdir -p "${TEST_DIR}/extracted/usr/share/doc/curl"
    mkdir -p "${TEST_DIR}/extracted/usr/share/doc/libc6"
    mkdir -p "${TEST_DIR}/extracted/usr/share/doc/librtmp1"
    mkdir -p "${TEST_DIR}/extracted/usr/share/doc/missing-package"

    # Mock versions template
    mkdir -p "${TEST_DIR}/extracted/opt/pihole/templates"
    cat <<EOF > "${TEST_DIR}/extracted/opt/pihole/templates/versions"
CORE_VERSION=v6.4.2
CORE_BRANCH=snap
WEB_VERSION=v6.5
WEB_BRANCH=snap
FTL_VERSION=v6.6.2
FTL_BRANCH=snap
EOF

    # DEP-5 machine-readable format
    cat <<EOF > "${TEST_DIR}/extracted/usr/share/doc/curl/copyright"
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Files: *
Copyright: 1996 - 2026, Daniel Stenberg
License: MIT
EOF

    # Heuristic fallback format
    cat <<EOF > "${TEST_DIR}/extracted/usr/share/doc/libc6/copyright"
This package is part of the GNU C Library.
Released under the terms of the GNU Lesser General Public License, version 2.1 or later.
EOF

    # Multiple licenses DEP-5 format
    cat <<EOF > "${TEST_DIR}/extracted/usr/share/doc/librtmp1/copyright"
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Files: *
License: GPL-2+

Files: librtmp/*
License: LGPL-2.1+
EOF

    # 2. Setup mock input CycloneDX SBOM JSON
    cat <<EOF > "${TEST_DIR}/sbom.json"
{
  "bomFormat": "CycloneDX",
  "specVersion": "1.4",
  "serialNumber": "urn:uuid:12345",
  "version": 1,
  "components": [
    {
      "type": "library",
      "name": "curl",
      "version": "8.5.0",
      "properties": [
        {
          "name": "syft:package:foundBy",
          "value": "dpkg-db-cataloger"
        }
      ],
      "licenses": []
    },
    {
      "type": "library",
      "name": "curl",
      "version": "8.5.0-duplicate",
      "properties": [
        {
          "name": "syft:package:foundBy",
          "value": "snap-cataloger"
        }
      ],
      "licenses": []
    },
    {
      "type": "library",
      "name": "libc6:amd64",
      "version": "2.39",
      "licenses": [
        {
          "license": {
            "name": "NONE"
          }
        }
      ]
    },
    {
      "type": "library",
      "name": "librtmp1",
      "version": "2.4",
      "licenses": []
    },
    {
      "type": "application",
      "name": "pihole-ftl",
      "version": "v6.6.2",
      "licenses": []
    },
    {
      "type": "library",
      "name": "missing-package",
      "version": "1.0",
      "licenses": []
    },
    {
      "type": "file",
      "name": "/home/runner/work/snap-pi-hole/snap-pi-hole/extracted-snap/usr/bin/curl"
    }
  ]
}
EOF

    # 3. Execute the enrich script
    run python3 "${REPO_ROOT}/snap/local/build/enrich_sbom.py" "${TEST_DIR}/sbom.json" "${TEST_DIR}/extracted"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Removed 1 file-type components"* ]]
    [[ "$output" == *"Removed 2 duplicate components"* ]]
    [[ "$output" == *"Injected 3 dynamically discovered components"* ]]

    # 4. Verify results inside JSON
    python3 - <<PYEOF
import json
with open("${TEST_DIR}/sbom.json") as f:
    data = json.load(f)

# Count components named curl
curls = [c for c in data["components"] if c["name"] == "curl"]
assert len(curls) == 1, f"Expected exactly 1 curl component, got {len(curls)}"
assert curls[0]["version"] == "8.5.0", f"Expected version 8.5.0 (priority), got {curls[0]['version']}"

components = {c["name"]: c for c in data["components"]}

# Verify curl (DEP-5 parsed)
curl_lic = components["curl"]["licenses"][0]["license"]
assert curl_lic.get("id") == "MIT", f"Expected MIT, got {curl_lic}"

# Verify libc6 (Heuristic fallback parsed with multiple licenses)
libc_lics = components["libc6:amd64"]["licenses"]
libc_ids = sorted([l["license"].get("id") for l in libc_lics])
assert libc_ids == ["LGPL-2.1-only", "LGPL-2.1-or-later"], f"Expected LGPL-2.1-only and LGPL-2.1-or-later, got {libc_ids}"

# Verify librtmp1 (DEP-5 multiple licenses parsed and normalized)
rtmp_lics = components["librtmp1"]["licenses"]
rtmp_ids = sorted([l["license"].get("id") for l in rtmp_lics])
assert rtmp_ids == ["GPL-2.0-only", "GPL-2.0-or-later", "LGPL-2.1-only", "LGPL-2.1-or-later"], f"Expected 4 normalized licenses, got {rtmp_ids}"

# Verify pihole-ftl (Static fallback project license and dynamic discovery)
ftl_lic = components["pihole-ftl"]["licenses"][0]["license"]
assert ftl_lic.get("id") == "GPL-3.0-only", f"Expected GPL-3.0-only, got {ftl_lic}"
assert components["pihole-ftl"]["version"] == "v6.6.2", f"Expected v6.6.2, got {components['pihole-ftl']['version']}"

# Verify pi-hole (Discovered primary component)
assert "pi-hole" in components, "pi-hole missing from SBOM"
assert components["pi-hole"]["version"] == "v6.4.2"
assert components["pi-hole"]["licenses"][0]["license"].get("id") == "GPL-3.0-only"

# Verify web (Discovered primary component)
assert "web" in components, "web missing from SBOM"
assert components["web"]["version"] == "v6.5"
assert components["web"]["licenses"][0]["license"].get("id") == "MIT"

# Verify missing-package remains unchanged
assert not components["missing-package"].get("licenses"), "Expected no license for missing-package"

# Verify file-type component was filtered out
assert "/home/runner/work/snap-pi-hole/snap-pi-hole/extracted-snap/usr/bin/curl" not in components, "Expected file-type component to be filtered out"

print("All assertions passed!")
PYEOF
}

@test "enrich_sbom.py discovers web frontend dependencies from package.json" {
    # 1. Create the web admin directory inside the extracted snap
    mkdir -p "${TEST_DIR}/extracted/var/www/html/admin"

    # 2. Write a minimal but realistic package.json (mirrors pi-hole/web structure)
    cat > "${TEST_DIR}/extracted/var/www/html/admin/package.json" <<'EOF'
{
  "name": "pi-hole-web-interface",
  "version": "1.0.0",
  "license": "EUPL-1.2",
  "dependencies": {
    "bootstrap":     "3.4.1",
    "jquery":        "3.7.1",
    "chart.js":      "4.5.1",
    "@fortawesome/fontawesome-free": "6.7.2"
  }
}
EOF

    # 3. Minimal SBOM JSON (no pre-existing web components)
    cat > "${TEST_DIR}/sbom.json" <<'EOF'
{
  "bomFormat": "CycloneDX",
  "specVersion": "1.4",
  "serialNumber": "urn:uuid:web-test",
  "version": 1,
  "components": []
}
EOF

    # 4. Run enrichment (no pihole-FTL binary present — FTL discovery will warn and skip)
    run python3 "${REPO_ROOT}/snap/local/build/enrich_sbom.py" "${TEST_DIR}/sbom.json" "${TEST_DIR}/extracted"
    [ "$status" -eq 0 ]
    # Discovery print lines should appear in output
    [[ "$output" == *"Discovered web frontend dependency: bootstrap@3.4.1"* ]]
    [[ "$output" == *"Discovered web frontend dependency: jquery@3.7.1"* ]]
    [[ "$output" == *"Discovered web frontend dependency: @fortawesome/fontawesome-free@6.7.2"* ]]

    # 5. Verify the SBOM JSON contains all four components
    python3 - <<PYEOF
import json
with open("${TEST_DIR}/sbom.json") as f:
    data = json.load(f)
components = {c["name"]: c for c in data["components"]}

assert "bootstrap" in components, "bootstrap missing from SBOM"
assert components["bootstrap"]["version"] == "3.4.1", f"bootstrap version wrong: {components['bootstrap']['version']}"
assert components["bootstrap"]["purl"] == "pkg:npm/bootstrap@3.4.1", f"bootstrap purl wrong"

assert "jquery" in components, "jquery missing from SBOM"
assert components["jquery"]["version"] == "3.7.1"

assert "chart.js" in components, "chart.js missing from SBOM"

scoped = "@fortawesome/fontawesome-free"
assert scoped in components, f"{scoped} missing from SBOM"
assert components[scoped]["purl"] == "pkg:npm/%40fortawesome%2Ffontawesome-free@6.7.2", \
    f"scoped purl wrong: {components[scoped]['purl']}"

print("Web frontend discovery assertions passed!")
PYEOF
}


@test "enrich_sbom.py handles edge cases and dynamic discovery" {
    # Setup extracted snap with various edge‑case copyright files

    mkdir -p "${TEST_DIR}/extracted/usr/share/doc/singleline"
    mkdir -p "${TEST_DIR}/extracted/usr/share/doc/shorthand"
    mkdir -p "${TEST_DIR}/extracted/usr/share/doc/unknown"
    mkdir -p "${TEST_DIR}/extracted/usr/share/doc/rtmp"
    mkdir -p "${TEST_DIR}/extracted/usr/share/doc/changelogpkg"
    mkdir -p "${TEST_DIR}/extracted/var/lib/dpkg"
    mkdir -p "${TEST_DIR}/extracted/usr/share/doc/duplicatelic"

    # 1. Single line with multiple SPDX IDs
    cat <<EOF > "${TEST_DIR}/extracted/usr/share/doc/singleline/copyright"
License: GPL-2+ LGPL-2.1+
EOF

    # 2. Shorthand without plus
    cat <<EOF > "${TEST_DIR}/extracted/usr/share/doc/shorthand/copyright"
License: GPL-2
EOF

    # 3. Unknown license
    cat <<EOF > "${TEST_DIR}/extracted/usr/share/doc/unknown/copyright"
License: FooBar
EOF

    # 4. Special mapping (rtmpdump -> rtmp) with multiple licenses
    cat <<EOF > "${TEST_DIR}/extracted/usr/share/doc/rtmp/copyright"
License: GPL-2+
License: LGPL-2.1+
EOF

    # 5. Duplicate component – one with license, one without
    cat <<EOF > "${TEST_DIR}/extracted/usr/share/doc/duplicatelic/copyright"
License: MIT
EOF

    # 6. Changelog fallback – no dpkg status entry, but changelog provides version
    mkdir -p "${TEST_DIR}/extracted/usr/share/doc/changelogpkg"
    gzip -c > "${TEST_DIR}/extracted/usr/share/doc/changelogpkg/changelog.Debian.gz" <<EOF
changelogpkg (1.2.3-1) unstable; urgency=low

  * Initial release.
EOF

    # 7. Minimal dpkg status file for other packages (optional)
    cat <<EOF > "${TEST_DIR}/extracted/var/lib/dpkg/status"
Package: duplicatelic
Version: 9.9.9
Description: duplicate test package

Package: otherpkg
Version: 0.1
Description: placeholder
EOF

    # 2. Setup mock SBOM JSON with entries for all these packages (empty licenses)
    cat <<EOF > "${TEST_DIR}/sbom.json"
{
  "bomFormat": "CycloneDX",
  "specVersion": "1.4",
  "serialNumber": "urn:uuid:test",
  "version": 1,
  "components": [
    {"type": "library", "name": "singleline", "version": "0.0", "licenses": []},
    {"type": "library", "name": "shorthand", "version": "0.0", "licenses": []},
    {"type": "library", "name": "unknown", "version": "0.0", "licenses": []},
    {"type": "library", "name": "rtmpdump", "version": "0.0", "licenses": []},
    {"type": "library", "name": "duplicatelic", "version": "0.0", "licenses": []},
    {"type": "library", "name": "duplicatelic", "version": "0.0-dup", "licenses": []},
    {"type": "library", "name": "changelogpkg", "version": "0.0", "licenses": []}
  ]
}
EOF

    # 3. Run enrichment
    run python3 "${REPO_ROOT}/snap/local/build/enrich_sbom.py" "${TEST_DIR}/sbom.json" "${TEST_DIR}/extracted"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Successfully enriched"* ]]

    # 4. Verify results
    python3 - <<PYEOF
import json
with open("${TEST_DIR}/sbom.json") as f:
    data = json.load(f)
components = {c["name"]: c for c in data["components"]}

# singleline should have four normalized IDs
sl = sorted([l["license"]["id"] for l in components["singleline"]["licenses"]])
assert sl == ["GPL-2.0-only", "GPL-2.0-or-later", "LGPL-2.1-only", "LGPL-2.1-or-later"], f"singleline licenses mismatch: {sl}"

# shorthand should map to GPL-2.0-only
sh = components["shorthand"]["licenses"][0]["license"]["id"]
assert sh == "GPL-2.0-only", f"shorthand license mismatch: {sh}"

# unknown should retain raw name and have id equal to name
unk = components["unknown"]["licenses"][0]["license"]
assert unk.get("name") == "FooBar", f"unknown name mismatch: {unk}"
assert unk.get("id") == "FooBar", f"unknown id mismatch: {unk}"

# rtmpdump (special mapping) should have four licenses
rt = sorted([l["license"]["id"] for l in components["rtmpdump"]["licenses"]])
assert rt == ["GPL-2.0-only", "GPL-2.0-or-later", "LGPL-2.1-only", "LGPL-2.1-or-later"], f"rtmpdump licenses mismatch: {rt}"

# duplicate lic: the entry with MIT should win
dup = components["duplicatelic"]["licenses"][0]["license"]["id"]
assert dup == "MIT", f"duplicate license mismatch: {dup}"

# changelog fallback: the enrichment loop enriches licenses only, not versions.
# The version field on pre-existing SBOM entries is preserved as-is ("0.0").
# resolve_version_from_status() changelog fallback is used by FTL/web discovery.
ch = components["changelogpkg"]
assert ch["version"] == "0.0", f"pre-existing version should be unchanged: {ch['version']}"
PYEOF
}

@test "enrich_sbom.py discovers FTL embedded dependencies via ldd" {
    # 1. Create a fake pihole-FTL binary (empty file; content irrelevant – ldd is shimmed)
    mkdir -p "${TEST_DIR}/extracted/usr/sbin"
    touch "${TEST_DIR}/extracted/usr/sbin/pihole-FTL"

    # 2. Shim `ldd` so it returns controlled output regardless of the binary
    mkdir -p "${TEST_DIR}/bin"
    cat > "${TEST_DIR}/bin/ldd" <<'LDDEOF'
#!/usr/bin/env bash
echo "        libdnsmasq.so.2 => /usr/lib/x86_64-linux-gnu/libdnsmasq.so.2 (0x00007f0000000000)"
echo "        libcivetweb.so.1 => /usr/lib/x86_64-linux-gnu/libcivetweb.so.1 (0x00007f0000100000)"
echo "        linux-vdso.so.1 (0x00007ffd00000000)"
LDDEOF
    chmod +x "${TEST_DIR}/bin/ldd"
    export PATH="${TEST_DIR}/bin:${PATH}"

    # 3. Minimal dpkg/status entries for the two discovered libs
    mkdir -p "${TEST_DIR}/extracted/var/lib/dpkg"
    cat > "${TEST_DIR}/extracted/var/lib/dpkg/status" <<'EOF'
Package: dnsmasq
Version: 2.91
Description: dnsmasq mock

Package: civetweb
Version: 1.17
Description: civetweb mock
EOF

    # 4. Copyright files providing license information
    mkdir -p "${TEST_DIR}/extracted/usr/share/doc/dnsmasq"
    printf 'License: GPL-2+\n' > "${TEST_DIR}/extracted/usr/share/doc/dnsmasq/copyright"
    mkdir -p "${TEST_DIR}/extracted/usr/share/doc/civetweb"
    printf 'License: MIT\n' > "${TEST_DIR}/extracted/usr/share/doc/civetweb/copyright"

    # 5. Minimal SBOM (only a primary component; FTL libs should be injected by discovery)
    cat > "${TEST_DIR}/sbom.json" <<'EOF'
{
  "bomFormat": "CycloneDX",
  "specVersion": "1.4",
  "serialNumber": "urn:uuid:ftl-test",
  "version": 1,
  "components": [
    {"type": "application", "name": "pihole-ftl", "version": "6.0", "licenses": []}
  ]
}
EOF

    # 6. Run enrichment
    run python3 "${REPO_ROOT}/snap/local/build/enrich_sbom.py" "${TEST_DIR}/sbom.json" "${TEST_DIR}/extracted"
    [ "$status" -eq 0 ]

    # 7. Verify discovered components
    python3 - <<PYEOF
import json, sys

with open("${TEST_DIR}/sbom.json") as f:
    data = json.load(f)
components = {c["name"]: c for c in data["components"]}

# dnsmasq must be present with version from dpkg/status and GPL-2.0-only/GPL-2.0-or-later license
assert "dnsmasq" in components, "dnsmasq not found in SBOM"
assert components["dnsmasq"]["version"] == "2.91", \
    f"dnsmasq version expected 2.91, got {components['dnsmasq']['version']}"
dnsmasq_ids = sorted([l["license"]["id"] for l in components["dnsmasq"]["licenses"]])
assert "GPL-2.0-only" in dnsmasq_ids, f"GPL-2.0-only missing from dnsmasq licenses: {dnsmasq_ids}"

# civetweb must be present with MIT license and version from dpkg/status
assert "civetweb" in components, "civetweb not found in SBOM"
assert components["civetweb"]["version"] == "1.17", \
    f"civetweb version expected 1.17, got {components['civetweb']['version']}"
civetweb_ids = sorted([l["license"]["id"] for l in components["civetweb"]["licenses"]])
assert "MIT" in civetweb_ids, f"MIT missing from civetweb licenses: {civetweb_ids}"

# vdso (linux-vdso) is a virtual DSO with no real path; it must NOT be injected
assert "vdso" not in components, f"linux-vdso should not be injected as a component"

print("FTL discovery assertions passed!")
PYEOF
}

@test "enrich_sbom.py resolves version from changelog.Debian.gz when dpkg/status has no entry" {
    # This exercises the changelog fallback branch of resolve_version_from_status,
    # reached via discover_ftl_embedded_dependencies when dpkg/status lacks the lib.

    # 1. Fake pihole-FTL binary + ldd shim that reports one library
    mkdir -p "${TEST_DIR}/extracted/usr/sbin"
    touch "${TEST_DIR}/extracted/usr/sbin/pihole-FTL"
    mkdir -p "${TEST_DIR}/bin"
    cat > "${TEST_DIR}/bin/ldd" <<'LDDEOF'
#!/usr/bin/env bash
echo "        libchangelogonly.so.1 => /usr/lib/libchangelogonly.so.1 (0x00007f0000000000)"
LDDEOF
    chmod +x "${TEST_DIR}/bin/ldd"
    export PATH="${TEST_DIR}/bin:${PATH}"

    # 2. dpkg/status exists but does NOT have an entry for changelogonly
    mkdir -p "${TEST_DIR}/extracted/var/lib/dpkg"
    cat > "${TEST_DIR}/extracted/var/lib/dpkg/status" <<'EOF'
Package: otherpkg
Version: 9.9.9
Description: unrelated
EOF

    # 3. Provide a changelog.Debian.gz for changelogonly
    mkdir -p "${TEST_DIR}/extracted/usr/share/doc/changelogonly"
    printf 'changelogonly (3.14.0-2) unstable; urgency=low\n\n  * Initial.\n' \
        | gzip -c > "${TEST_DIR}/extracted/usr/share/doc/changelogonly/changelog.Debian.gz"

    # 4. Minimal SBOM
    cat > "${TEST_DIR}/sbom.json" <<'EOF'
{"bomFormat":"CycloneDX","specVersion":"1.4","serialNumber":"urn:uuid:changelog-test","version":1,"components":[]}
EOF

    run python3 "${REPO_ROOT}/snap/local/build/enrich_sbom.py" "${TEST_DIR}/sbom.json" "${TEST_DIR}/extracted"
    [ "$status" -eq 0 ]

    python3 - <<PYEOF
import json
with open("${TEST_DIR}/sbom.json") as f:
    data = json.load(f)
components = {c["name"]: c for c in data["components"]}
assert "changelogonly" in components, "changelogonly not in SBOM"
assert components["changelogonly"]["version"] == "3.14.0-2", \
    f"changelog version wrong: {components['changelogonly']['version']}"
PYEOF
}

@test "enrich_sbom.py resolves license via stem matching (libcurl4 -> curl dir)" {
    # Exercises find_license_in_copyright Step 2: stem matching.
    # libcurl4: strip "lib" -> "curl4", strip numeric suffix -> stem "curl"
    # doc dir "curl": no "lib" prefix, no numeric suffix -> stem "curl"
    # Both stems match, so the copyright in "curl/" is found for "libcurl4".

    mkdir -p "${TEST_DIR}/extracted/usr/share/doc/curl"
    printf 'License: MIT\n' > "${TEST_DIR}/extracted/usr/share/doc/curl/copyright"

    cat > "${TEST_DIR}/sbom.json" <<'EOF'
{
  "bomFormat": "CycloneDX", "specVersion": "1.4",
  "serialNumber": "urn:uuid:stem-test", "version": 1,
  "components": [
    {"type": "library", "name": "libcurl4", "version": "8.5", "licenses": []}
  ]
}
EOF

    run python3 "${REPO_ROOT}/snap/local/build/enrich_sbom.py" "${TEST_DIR}/sbom.json" "${TEST_DIR}/extracted"
    [ "$status" -eq 0 ]

    python3 - <<PYEOF
import json
with open("${TEST_DIR}/sbom.json") as f:
    data = json.load(f)
components = {c["name"]: c for c in data["components"]}
assert "libcurl4" in components, "libcurl4 not found"
ids = [l["license"]["id"] for l in components["libcurl4"]["licenses"]]
assert "MIT" in ids, f"Expected MIT via stem match (libcurl4 -> curl), got {ids}"
PYEOF
}

@test "enrich_sbom.py does not overwrite an already-valid license" {
    # Exercises the has_valid_license guard: components whose license is already
    # populated with a non-empty, non-NONE value must not be modified.

    mkdir -p "${TEST_DIR}/extracted/usr/share/doc/curl"
    # Provide a copyright that would give "MIT" if the guard were bypassed
    printf 'License: Apache-2.0\n' > "${TEST_DIR}/extracted/usr/share/doc/curl/copyright"

    cat > "${TEST_DIR}/sbom.json" <<'EOF'
{
  "bomFormat": "CycloneDX", "specVersion": "1.4",
  "serialNumber": "urn:uuid:guard-test", "version": 1,
  "components": [
    {
      "type": "library", "name": "curl", "version": "8.5.0",
      "licenses": [{"license": {"id": "MIT", "name": "MIT"}}]
    }
  ]
}
EOF

    run python3 "${REPO_ROOT}/snap/local/build/enrich_sbom.py" "${TEST_DIR}/sbom.json" "${TEST_DIR}/extracted"
    [ "$status" -eq 0 ]
    # Script must NOT print an "Enriched: curl" line since the license was already set
    [[ "$output" != *"Enriched: curl"* ]]

    python3 - <<PYEOF
import json
with open("${TEST_DIR}/sbom.json") as f:
    data = json.load(f)
components = {c["name"]: c for c in data["components"]}
ids = [l["license"]["id"] for l in components["curl"]["licenses"]]
assert ids == ["MIT"], f"License was overwritten; expected ['MIT'], got {ids}"
PYEOF
}

@test "enrich_sbom.py strips semver prefix characters from web package.json versions" {
    # Exercises the version.lstrip("^~>= ") path in discover_web_frontend_dependencies.
    # devDependencies use ^ and ~ prefixes; dependencies in pi-hole/web are pinned,
    # but the stripping must work correctly regardless.

    mkdir -p "${TEST_DIR}/extracted/var/www/html/admin"
    cat > "${TEST_DIR}/extracted/var/www/html/admin/package.json" <<'EOF'
{
  "name": "test-web",
  "version": "1.0.0",
  "dependencies": {
    "moment":  "~2.30.1",
    "lodash":  "^4.17.21",
    "react":   ">=18.0.0",
    "vue":     "3.4.0"
  }
}
EOF

    cat > "${TEST_DIR}/sbom.json" <<'EOF'
{"bomFormat":"CycloneDX","specVersion":"1.4","serialNumber":"urn:uuid:semver-test","version":1,"components":[]}
EOF

    run python3 "${REPO_ROOT}/snap/local/build/enrich_sbom.py" "${TEST_DIR}/sbom.json" "${TEST_DIR}/extracted"
    [ "$status" -eq 0 ]

    python3 - <<PYEOF
import json
with open("${TEST_DIR}/sbom.json") as f:
    data = json.load(f)
components = {c["name"]: c for c in data["components"]}

assert components["moment"]["version"]  == "2.30.1",  f"moment: {components['moment']['version']}"
assert components["lodash"]["version"]  == "4.17.21", f"lodash: {components['lodash']['version']}"
assert components["react"]["version"]   == "18.0.0",  f"react: {components['react']['version']}"
assert components["vue"]["version"]     == "3.4.0",   f"vue: {components['vue']['version']}"
PYEOF
}

@test "filter_dpkg_status.py successfully filters dpkg status file" {
    # 1. Setup mock dpkg status file

    cat <<EOF > "${TEST_DIR}/status"
Package: keep-me
Status: install ok installed
Section: utils
Architecture: amd64

Package: delete-me
Status: install ok installed
Section: libs
Architecture: amd64

Package: keep-me-too:amd64
Status: install ok installed
Section: libs
Architecture: amd64
EOF

    # 2. Setup mock prime directory
    mkdir -p "${TEST_DIR}/prime/usr/share/doc/keep-me"
    mkdir -p "${TEST_DIR}/prime/usr/share/doc/keep-me-too"

    # 3. Run filter_dpkg_status.py
    export DPKG_STATUS_PATH="${TEST_DIR}/status"
    run python3 "${REPO_ROOT}/snap/local/build/filter_dpkg_status.py" "${TEST_DIR}/prime"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Filtered dpkg status: kept 2 of 3 packages."* ]]

    # 4. Verify output status file contents
    python3 - <<PYEOF
import os
with open("${TEST_DIR}/prime/var/lib/dpkg/status") as f:
    content = f.read()

packages = []
for block in content.split("\n\n"):
    for line in block.splitlines():
        if line.startswith("Package: "):
            packages.append(line[len("Package: "):].strip())

assert "keep-me" in packages, "Expected keep-me to be preserved"
assert "keep-me-too:amd64" in packages, "Expected keep-me-too:amd64 to be preserved"
assert "delete-me" not in packages, "Expected delete-me to be filtered out"
print("Filter status assertions passed!")
PYEOF
}


@test "enrich_sbom.py normalizes and filters licenses for all components" {
    # 1. Setup mock SBOM JSON with various valid and invalid licenses
    cat > "${TEST_DIR}/sbom.json" <<'EOF'
{
  "bomFormat": "CycloneDX",
  "specVersion": "1.4",
  "serialNumber": "urn:uuid:norm-test",
  "version": 1,
  "components": [
    {
      "type": "library",
      "name": "lib1",
      "version": "1.0",
      "licenses": [
        {"license": {"id": "unicode", "name": "unicode"}},
        {"license": {"id": "gnulib", "name": "gnulib"}},
        {"license": {"id": "MIT", "name": "MIT"}}
      ]
    },
    {
      "type": "library",
      "name": "lib2",
      "version": "1.0",
      "licenses": [
        {"license": {"id": "GPL-2+ with Autoconf exception", "name": "GPL-2+ with Autoconf exception"}}
      ]
    }
  ]
}
EOF

    # 2. Run enrichment (no extracted snap needed as components already have licenses)
    run python3 "${REPO_ROOT}/snap/local/build/enrich_sbom.py" "${TEST_DIR}/sbom.json" "${TEST_DIR}"
    [ "$status" -eq 0 ]

    # 3. Verify results
    python3 - <<PYEOF
import json
with open("${TEST_DIR}/sbom.json") as f:
    data = json.load(f)
components = {c["name"]: c for c in data["components"]}

# lib1: unicode -> Unicode-DFS-2016, gnulib -> removed, MIT -> kept
lib1_lics = sorted([l["license"].get("name") for l in components["lib1"]["licenses"]])
assert lib1_lics == ["MIT", "Unicode-DFS-2016"], f"Expected ['MIT', 'Unicode-DFS-2016'], got {lib1_lics}"

# lib2: GPL-2+ with Autoconf exception -> GPL-2.0-or-later WITH Autoconf-exception-2.0
lib2_lics = [l["license"].get("name") for l in components["lib2"]["licenses"]]
assert lib2_lics == ["GPL-2.0-or-later WITH Autoconf-exception-2.0"], f"Expected ['GPL-2.0-or-later WITH Autoconf-exception-2.0'], got {lib2_lics}"
PYEOF
}


