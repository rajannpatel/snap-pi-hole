#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SNAPCRAFT="${REPO_ROOT}/snap/snapcraft.yaml"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

usage() {
  cat <<'EOF'
Usage: tests/scripts/validate-upstream-patches.sh [stable|edge|all]

Clones upstream Pi-hole/FTL sources and runs this repository's real
override-pull scripts with a stub craftctl. This is a networked preflight for
patch drift before sending builds to GitHub runners.

Modes:
  stable  Validate committed source-tag releases from snap/snapcraft.yaml.
  edge    Validate current upstream development heads.
  all     Validate both stable and edge (default).
EOF
}

mode="${1:-all}"
case "${mode}" in
  stable | edge | all)
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

mkdir -p "${TMPDIR}/bin"
printf '#!/bin/sh\nexit 0\n' > "${TMPDIR}/bin/craftctl"
chmod +x "${TMPDIR}/bin/craftctl"

snapcraft_part_value() {
  local part="$1"
  local key="$2"

  python3 - "${SNAPCRAFT}" "${part}" "${key}" <<'PY'
import re
import sys

path, target_part, target_key = sys.argv[1:]
current_part = None

for raw in open(path, encoding="utf-8"):
    part_match = re.match(r"^  ([A-Za-z0-9_]+):\s*$", raw)
    if part_match:
        current_part = part_match.group(1)
        continue
    if current_part == target_part:
        key_match = re.match(rf"^    {re.escape(target_key)}:\s*(\S+)\s*$", raw)
        if key_match:
            print(key_match.group(1).strip("\"'"))
            sys.exit(0)

raise SystemExit(f"Missing parts.{target_part}.{target_key}")
PY
}

clone_ref() {
  local source="$1"
  local ref="$2"
  local destination="$3"

  if [[ "${ref}" == refs/heads/* ]]; then
    git -c advice.detachedHead=false clone --depth 1 --branch "${ref#refs/heads/}" \
      "${source}" "${destination}" >/dev/null
    return
  fi

  if [[ "${ref}" == v* ]]; then
    git -c advice.detachedHead=false clone --depth 1 --branch "${ref}" \
      "${source}" "${destination}" >/dev/null
    return
  fi

  git -c advice.detachedHead=false clone --filter=blob:none --no-checkout \
    "${source}" "${destination}" >/dev/null
  git -C "${destination}" fetch --depth 1 origin "${ref}" >/dev/null
  git -C "${destination}" -c advice.detachedHead=false checkout --detach "${ref}" >/dev/null
}

validate_part() {
  local label="$1"
  local part="$2"
  local ref="$3"
  local override_script="$4"
  local source
  local destination

  source="$(snapcraft_part_value "${part}" source)"
  destination="${TMPDIR}/${label}-${part}"

  echo "==> ${label}: ${part} @ ${ref}"
  clone_ref "${source}" "${ref}" "${destination}"
  PATH="${TMPDIR}/bin:${PATH}" \
    CRAFT_PART_SRC="${destination}" \
    CRAFT_PROJECT_DIR="${REPO_ROOT}" \
    "${override_script}"
}

validate_stable() {
  validate_part stable ftl "$(snapcraft_part_value ftl source-tag)" \
    "${REPO_ROOT}/snap/local/build/ftl-override-pull.sh"
  validate_part stable pi_hole "$(snapcraft_part_value pi_hole source-tag)" \
    "${REPO_ROOT}/snap/local/build/pi-hole-override-pull.sh"
}

validate_edge() {
  validate_part edge ftl refs/heads/development \
    "${REPO_ROOT}/snap/local/build/ftl-override-pull.sh"
  validate_part edge pi_hole refs/heads/development \
    "${REPO_ROOT}/snap/local/build/pi-hole-override-pull.sh"
}

case "${mode}" in
  stable)
    validate_stable
    ;;
  edge)
    validate_edge
    ;;
  all)
    validate_stable
    validate_edge
    ;;
esac

echo "Upstream patch validation passed (${mode})."
