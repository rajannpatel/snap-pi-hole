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
    mkdir -p "${TEST_DIR}/extracted/usr/share/doc/missing-package"

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
    }
  ]
}
EOF

    # 3. Execute the enrich script
    run python3 "${REPO_ROOT}/snap/local/build/enrich_sbom.py" "${TEST_DIR}/sbom.json" "${TEST_DIR}/extracted"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Successfully enriched 3 components"* ]]

    # 4. Verify results inside JSON
    python3 - <<PYEOF
import json
with open("${TEST_DIR}/sbom.json") as f:
    data = json.load(f)

components = {c["name"]: c for c in data["components"]}

# Verify curl (DEP-5 parsed)
curl_lic = components["curl"]["licenses"][0]["license"]
assert curl_lic.get("id") == "MIT", f"Expected MIT, got {curl_lic}"

# Verify libc6 (Heuristic fallback parsed)
libc_lic = components["libc6:amd64"]["licenses"][0]["license"]
assert libc_lic.get("id") == "LGPL-2.1-or-later", f"Expected LGPL-2.1-or-later, got {libc_lic}"

# Verify pihole-ftl (Static fallback project license)
ftl_lic = components["pihole-ftl"]["licenses"][0]["license"]
assert ftl_lic.get("id") == "GPL-3.0-only", f"Expected GPL-3.0-only, got {ftl_lic}"

# Verify missing-package remains unchanged
assert not components["missing-package"].get("licenses"), "Expected no license for missing-package"

print("All assertions passed!")
PYEOF
}
