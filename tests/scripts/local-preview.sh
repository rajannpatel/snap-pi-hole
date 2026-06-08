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
    syft scan local-extracted-snap -o cyclonedx-json=local-sbom.json

    echo "Enriching SBOM licenses..."
    python3 snap/local/build/enrich_sbom.py local-sbom.json local-extracted-snap

    # Clean up extracted directory
    rm -rf local-extracted-snap

    echo "Setting up local SBOM explorer preview..."
    rm -rf local-sbom
    mkdir -p local-sbom
    python3 snap/local/build/render_report_template.py snap/local/assets/sbom-explorer.html local-sbom/index.html
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

    if command -v osv-scanner &>/dev/null && [ -f "local-sbom.json" ]; then
        echo "Found local-sbom.json and osv-scanner. Running real scan..."
        rm -rf local-vulnerabilities
        mkdir -p local-vulnerabilities
        
        cp local-sbom.json local-vulnerabilities/sbom-amd64.cdx.json
        set +e
        osv-scanner scan --format json -L local-vulnerabilities/sbom-amd64.cdx.json --output-file local-vulnerabilities/osv-amd64.json
        rc=$?
        set -e
        if [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ]; then
            use_mock=false
        else
            echo "Warning: osv-scanner execution failed (exit code ${rc}). Falling back to mock data."
        fi
    fi

    if [ "${use_mock}" = "true" ]; then
        echo "Generating realistic mock vulnerability report data..."
        rm -rf local-vulnerabilities
        mkdir -p local-vulnerabilities
        
        cat << 'EOF' > local-vulnerabilities/osv-amd64.json
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
              "details": "This vulnerability allows...",
              "severity": [
                {
                  "type": "CVSS_V3",
                  "score": "CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H"
                }
              ],
              "published": "2023-10-11T12:00:00Z"
            },
            {
              "id": "CVE-2023-99999",
              "aliases": [],
              "summary": "Unactionable example vulnerability",
              "details": "No patch available yet...",
              "severity": [
                {
                  "type": "CVSS_V3",
                  "score": "CVSS:3.1/AV:L/AC:H/PR:H/UI:R/S:C/C:L/I:L/A:L"
                }
              ],
              "published": "2023-12-01T12:00:00Z"
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
