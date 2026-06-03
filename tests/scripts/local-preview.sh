#!/usr/bin/env bash
set -euo pipefail

# local-preview.sh: Run Kcov and SBOM scans locally for development preview.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

show_usage() {
    echo "Usage: $0 [kcov|sbom|all]"
    echo "  kcov   Run BATS unit tests through kcov and apply Vanilla styling"
    echo "  sbom   Generate and enrich SBOM using a local .snap file"
    echo "  all    Run both coverage and SBOM steps"
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
    cp snap/local/assets/sbom-explorer.html local-sbom/index.html
    cp snap/gui/pihole.png local-sbom/pihole.png
    python3 -c "import pathlib; p = pathlib.Path('local-sbom/index.html'); p.write_text(p.read_text().replace('../pihole.png', 'pihole.png'))"
    cp local-sbom.json local-sbom/sbom-amd64.json
    cp local-sbom.json local-sbom/sbom-arm64.json

    echo "Success! Local enriched SBOM generated at: local-sbom.json"
    echo "View SBOM explorer locally at: file://${REPO_ROOT}/local-sbom/index.html"
}

case "$1" in
    kcov)
        run_kcov
        ;;
    sbom)
        run_sbom
        ;;
    all)
        run_kcov
        run_sbom
        ;;
    *)
        show_usage
        ;;
esac
