#!/usr/bin/env bash
set -euo pipefail

# local-preview.sh: Run Kcov and SBOM scans locally for development preview.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

show_usage() {
    echo "Usage: $0 [kcov|sbom|vuln|all]"
    echo "  kcov   Run BATS unit tests through kcov and apply Vanilla styling"
    echo "  sbom   Generate and enrich SBOM using a local .snap file"
    echo "  vuln   Generate local vulnerability report preview (supports real osv-scanner or mock data)"
    echo "  all    Run coverage, SBOM, and vulnerability report steps"
    exit 1
}

if [ $# -lt 1 ]; then
    show_usage
fi

run_kcov() {
    echo "=== Running local BATS coverage report ==="
    if ! command -v kcov &>/dev/null; then
        echo "Error: 'kcov' is not installed."
        echo "Install it via: sudo apt install kcov"
        return 1
    fi
    if ! command -v bats &>/dev/null; then
        echo "Error: 'bats' is not installed."
        echo "Install it via: sudo apt install bats"
        return 1
    fi

    echo "Cleaning old coverage dir..."
    rm -rf local-coverage

    echo "Executing kcov on tests/unit/..."
    kcov --include-path=snap/local,snap/hooks local-coverage bats tests/unit/

    echo "Applying Vanilla Framework styles and layouts..."
    cp snap/gui/pihole.png local-coverage/pihole.png
    find local-coverage -name "*.css" -exec sh -c 'cat snap/local/assets/kcov-override.css > "$1"' _ {} \;
    python3 snap/local/build/prettify_coverage.py local-coverage

    echo "Success! View report locally at: file://${REPO_ROOT}/local-coverage/index.html"
}

run_sbom() {
    echo "=== Generating local SBOM ==="
    
    # Locate .snap file
    local snap_file
    snap_file=$(find . -maxdepth 1 -name "*.snap" | head -n 1)

    if [ -z "${snap_file}" ]; then
        echo "Error: No .snap file found in the root directory."
        echo "Please build the snap first (e.g., 'snapcraft' or 'snapcraft --use-lxd')."
        return 1
    fi

    echo "Using snap file: ${snap_file}"

    if ! command -v syft &>/dev/null; then
        echo "Error: 'syft' is not installed."
        echo "Install it via: curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh | sh -s -- -b /usr/local/bin"
        return 1
    fi

    echo "Extracting snap..."
    rm -rf local-extracted-snap
    unsquashfs -d local-extracted-snap "${snap_file}"

    echo "Scanning with syft..."
    syft scan local-extracted-snap -o cyclonedx-json@1.5=local-sbom.json

    echo "Enriching SBOM licenses..."
    python3 snap/local/build/enrich_sbom.py local-sbom.json local-extracted-snap

    # Clean up extracted directory
    rm -rf local-extracted-snap

    echo "Setting up local SBOM explorer preview..."
    rm -rf local-sbom
    mkdir -p local-sbom
    python3 snap/local/build/render_report_template.py snap/local/assets/sbom-explorer.html local-sbom/index.html
    cp snap/local/assets/sbom-explorer.css local-sbom/sbom-explorer.css
    cp snap/gui/pihole.png local-sbom/pihole.png
    python3 -c "import pathlib; p = pathlib.Path('local-sbom/index.html'); p.write_text(p.read_text().replace('../pihole.png', 'pihole.png'))"
    cp local-sbom.json local-sbom/sbom-amd64.json
    cp local-sbom.json local-sbom/sbom-arm64.json

    echo "Success! Local enriched SBOM generated at: local-sbom.json"
    echo "View SBOM explorer locally at: file://${REPO_ROOT}/local-sbom/index.html"
}

run_vuln() {
    echo "=== Generating local vulnerability report preview ==="
    local use_mock=true

    reset_vuln_dir() {
        mkdir -p local-vulnerabilities
        find local-vulnerabilities -mindepth 1 -maxdepth 1 ! -name 'llm-cache.json' -exec rm -rf {} +
    }

    if command -v osv-scanner &>/dev/null && [ -f "local-sbom.json" ]; then
        echo "Found local-sbom.json and osv-scanner. Running real scan..."
        reset_vuln_dir
        
        cp local-sbom.json local-vulnerabilities/sbom-stable-amd64.cdx.json
        cp local-sbom.json local-vulnerabilities/sbom-edge-amd64.cdx.json
        set +e
        osv-scanner scan --format json -L local-vulnerabilities/sbom-stable-amd64.cdx.json --output-file local-vulnerabilities/osv-stable-amd64.json
        osv-scanner scan --format json -L local-vulnerabilities/sbom-edge-amd64.cdx.json --output-file local-vulnerabilities/osv-edge-amd64.json
        rc=$?
        set -e
        if [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ]; then
            use_mock=false
            # Create arm64 copies
            cp local-vulnerabilities/osv-stable-amd64.json local-vulnerabilities/osv-stable-arm64.json
            cp local-vulnerabilities/osv-edge-amd64.json local-vulnerabilities/osv-edge-arm64.json
        else
            echo "Warning: osv-scanner execution failed (exit code ${rc}). Falling back to mock data."
        fi
    fi

    if [ "${use_mock}" = "true" ]; then
        echo "Generating realistic mock vulnerability report data for stable/edge and amd64/arm64..."
        reset_vuln_dir
        
        # Stable amd64 mock
        cat << 'EOF' > local-vulnerabilities/osv-stable-amd64.json
{
  "results": [
    {
      "packages": [
        {
          "package": {
            "name": "curl",
            "version": "7.88.1-10+deb12u1",
            "ecosystem": "Ubuntu"
          },
          "vulnerabilities": [
            {
              "id": "CVE-2023-38545",
              "aliases": [
                "USN-6425-1"
              ],
              "summary": "SOCKS5 heap buffer overflow",
              "details": "This vulnerability allows heap buffer overflow in SOCKS5 proxy handshake.",
              "severity": [
                {
                  "type": "CVSS_V3",
                  "score": "CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H"
                }
              ],
              "published": "2023-10-11T12:00:00Z"
            }
          ]
        }
      ]
    }
  ]
}
EOF

        # Stable arm64 mock (same package but different version/vuln maybe, let's keep it simple)
        cat << 'EOF' > local-vulnerabilities/osv-stable-arm64.json
{
  "results": [
    {
      "packages": [
        {
          "package": {
            "name": "curl",
            "version": "7.88.1-10+deb12u1",
            "ecosystem": "Ubuntu"
          },
          "vulnerabilities": [
            {
              "id": "CVE-2023-38545",
              "aliases": [
                "USN-6425-1"
              ],
              "summary": "SOCKS5 heap buffer overflow",
              "details": "This vulnerability allows heap buffer overflow in SOCKS5 proxy handshake.",
              "severity": [
                {
                  "type": "CVSS_V3",
                  "score": "CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H"
                }
              ],
              "published": "2023-10-11T12:00:00Z"
            }
          ]
        }
      ]
    }
  ]
}
EOF

        # Edge amd64 mock
        cat << 'EOF' > local-vulnerabilities/osv-edge-amd64.json
{
  "results": [
    {
      "packages": [
        {
          "package": {
            "name": "git",
            "version": "2.39.2-1.1",
            "ecosystem": "Ubuntu"
          },
          "vulnerabilities": [
            {
              "id": "CVE-2024-32002",
              "aliases": [],
              "summary": "Recursive submodule clone RCE",
              "details": "Git allows remote code execution when cloning a repository with submodules recursively.",
              "severity": [
                {
                  "type": "CVSS_V3",
                  "score": "CVSS:3.1/AV:N/AC:L/PR:N/UI:R/S:C/C:H/I:H/A:H"
                }
              ],
              "published": "2024-05-14T12:00:00Z"
            }
          ]
        }
      ]
    }
  ]
}
EOF

        # Edge arm64 mock
        cat << 'EOF' > local-vulnerabilities/osv-edge-arm64.json
{
  "results": [
    {
      "packages": [
        {
          "package": {
            "name": "git",
            "version": "2.39.2-1.1",
            "ecosystem": "Ubuntu"
          },
          "vulnerabilities": [
            {
              "id": "CVE-2024-32002",
              "aliases": [],
              "summary": "Recursive submodule clone RCE",
              "details": "Git allows remote code execution when cloning a repository with submodules recursively.",
              "severity": [
                {
                  "type": "CVSS_V3",
                  "score": "CVSS:3.1/AV:N/AC:L/PR:N/UI:R/S:C/C:H/I:H/A:H"
                }
              ],
              "published": "2024-05-14T12:00:00Z"
            }
          ]
        }
      ]
    }
  ]
}
EOF
    fi

    python3 snap/local/build/summarize_osv_reports.py local-vulnerabilities
    cp snap/gui/pihole.png local-vulnerabilities/pihole.png
    python3 -c "import pathlib; p = pathlib.Path('local-vulnerabilities/index.html'); p.write_text(p.read_text().replace('../pihole.png', 'pihole.png'))"
    
    echo "Success! View vulnerability report locally at: file://${REPO_ROOT}/local-vulnerabilities/index.html"
}

case "$1" in
    kcov)
        run_kcov
        ;;
    sbom)
        run_sbom
        ;;
    vuln)
        run_vuln
        ;;
    all)
        run_kcov
        run_sbom
        run_vuln
        ;;
    *)
        show_usage
        ;;
esac
