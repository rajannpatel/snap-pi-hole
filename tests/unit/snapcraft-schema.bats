#!/usr/bin/env bats
#
# Static validation tests for the repository structure and snapcraft.yaml
# schema. These tests assert invariants about the project itself rather
# than about the runtime behaviour of any particular script.
#
# Catching configuration drift early (e.g. a hook added but not shellchecked,
# or refresh-mode accidentally removed) is the goal here.
#
# Run locally:  bats tests/unit/snapcraft-schema.bats
# In CI:        see .github/workflows/build.yml (lint+unit job)

setup() {
    REPO_ROOT="$(git rev-parse --show-toplevel)"
}

# ---------------------------------------------------------------------------
# snapcraft.yaml schema invariants
# ---------------------------------------------------------------------------

@test "snapcraft.yaml: confinement is strict" {
    grep -q "^confinement: strict" "${REPO_ROOT}/snap/snapcraft.yaml"
}

@test "snapcraft.yaml: base is core26" {
    grep -q "^base: core26" "${REPO_ROOT}/snap/snapcraft.yaml"
}

@test "snapcraft.yaml: license is MIT" {
    grep -q "^license: MIT" "${REPO_ROOT}/snap/snapcraft.yaml"
}

@test "snapcraft.yaml: pihole-ftl service has refresh-mode: endure" {
    # Verify the key exists under the pihole-ftl app block
    python3 - <<PYEOF
import yaml, sys
with open("${REPO_ROOT}/snap/snapcraft.yaml") as f:
    doc = yaml.safe_load(f)
ftl = doc["apps"]["pihole-ftl"]
assert ftl.get("refresh-mode") == "endure", \
    f"expected refresh-mode: endure, got: {ftl.get('refresh-mode')}"
PYEOF
}

@test "snapcraft.yaml: pihole-ftl service has stop-timeout defined" {
    python3 - <<PYEOF
import yaml
with open("${REPO_ROOT}/snap/snapcraft.yaml") as f:
    doc = yaml.safe_load(f)
ftl = doc["apps"]["pihole-ftl"]
assert "stop-timeout" in ftl, "stop-timeout missing from pihole-ftl"
PYEOF
}

@test "snapcraft.yaml: pihole-ftl daemon is disabled on install" {
    python3 - <<PYEOF
import yaml
with open("${REPO_ROOT}/snap/snapcraft.yaml") as f:
    doc = yaml.safe_load(f)
ftl = doc["apps"]["pihole-ftl"]
assert ftl.get("install-mode") == "disable", \
    f"expected install-mode: disable, got: {ftl.get('install-mode')}"
PYEOF
}

@test "snapcraft.yaml: pihole-ftl has network-bind plug for DNS" {
    python3 - <<PYEOF
import yaml
with open("${REPO_ROOT}/snap/snapcraft.yaml") as f:
    doc = yaml.safe_load(f)
plugs = doc["apps"]["pihole-ftl"].get("plugs", [])
assert "network-bind" in plugs, f"network-bind missing from pihole-ftl plugs: {plugs}"
PYEOF
}

@test "snapcraft.yaml: pihole-ftl has system-observe plug for web dashboard" {
    python3 - <<PYEOF
import yaml
with open("${REPO_ROOT}/snap/snapcraft.yaml") as f:
    doc = yaml.safe_load(f)
plugs = doc["apps"]["pihole-ftl"].get("plugs", [])
assert "system-observe" in plugs, f"system-observe missing from pihole-ftl plugs"
PYEOF
}

@test "snapcraft.yaml: all three build parts exist (ftl, core, web)" {
    python3 - <<PYEOF
import yaml
with open("${REPO_ROOT}/snap/snapcraft.yaml") as f:
    doc = yaml.safe_load(f)
parts = doc.get("parts", {})
for required in ["ftl", "core", "web", "wrappers"]:
    assert required in parts, f"part '{required}' missing from snapcraft.yaml"
PYEOF
}

@test "snapcraft.yaml: all layout paths are defined" {
    python3 - <<PYEOF
import yaml
with open("${REPO_ROOT}/snap/snapcraft.yaml") as f:
    doc = yaml.safe_load(f)
layout = doc.get("layout", {})
required = ["/etc/pihole", "/etc/dnsmasq.d", "/var/www/html", "/var/log/pihole", "/opt/pihole"]
for path in required:
    assert path in layout, f"layout path '{path}' missing from snapcraft.yaml"
PYEOF
}

@test "snapcraft.yaml: epoch is defined (data migration safety)" {
    python3 - <<PYEOF
import yaml
with open("${REPO_ROOT}/snap/snapcraft.yaml") as f:
    doc = yaml.safe_load(f)
assert "epoch" in doc, "epoch key missing from snapcraft.yaml"
PYEOF
}

# ---------------------------------------------------------------------------
# Repository structure invariants
# ---------------------------------------------------------------------------

@test "all four hooks exist and are executable" {
    for hook in install configure pre-refresh remove; do
        path="${REPO_ROOT}/snap/hooks/${hook}"
        [ -f "$path" ] || { echo "missing hook: $hook"; return 1; }
        [ -x "$path" ] || { echo "hook not executable: $hook"; return 1; }
    done
}

@test "both launcher scripts exist and are executable" {
    [ -x "${REPO_ROOT}/snap/local/launcher-ftl" ]
    [ -x "${REPO_ROOT}/snap/local/launcher-pihole" ]
}

@test "snap store icon exists" {
    [ -f "${REPO_ROOT}/snap/gui/pihole.png" ]
}

@test "LICENSE file exists" {
    [ -f "${REPO_ROOT}/LICENSE" ]
}

@test "all documentation files referenced in README.md exist" {
    python3 - <<PYEOF
import re, pathlib, sys
root = pathlib.Path("${REPO_ROOT}")
readme = (root / "README.md").read_text()
# Find all markdown links to docs/
links = re.findall(r'\(docs/([^)]+\.md)\)', readme)
missing = []
for link in links:
    if not (root / "docs" / link).exists():
        missing.append(link)
if missing:
    print("Missing docs files referenced in README.md:", missing, file=sys.stderr)
    sys.exit(1)
PYEOF
}

@test "all shellcheck-listed scripts exist on disk" {
    local scripts=(
        snap/local/launcher-ftl
        snap/local/launcher-pihole
        snap/hooks/install
        snap/hooks/configure
        snap/hooks/pre-refresh
        snap/hooks/remove
    )
    for script in "${scripts[@]}"; do
        [ -f "${REPO_ROOT}/${script}" ] || { echo "missing: $script"; return 1; }
    done
}

@test "no shell script has a syntax error (bash -n check)" {
    local scripts=(
        snap/local/launcher-ftl
        snap/local/launcher-pihole
        snap/hooks/install
        snap/hooks/configure
        snap/hooks/pre-refresh
        snap/hooks/remove
    )
    for script in "${scripts[@]}"; do
        bash -n "${REPO_ROOT}/${script}" \
            || { echo "syntax error in: $script"; return 1; }
    done
}

@test "snapcraft.yaml: adopt-info points to the ftl part" {
    python3 - <<PYEOF
import yaml
with open("${REPO_ROOT}/snap/snapcraft.yaml") as f:
    doc = yaml.safe_load(f)
assert doc.get("adopt-info") == "ftl", \
    f"expected adopt-info: ftl, got: {doc.get('adopt-info')}"
PYEOF
}

@test "snapcraft.yaml: pihole CLI app exists with correct command" {
    python3 - <<PYEOF
import yaml
with open("${REPO_ROOT}/snap/snapcraft.yaml") as f:
    doc = yaml.safe_load(f)
apps = doc.get("apps", {})
assert "pihole" in apps, "pihole CLI app missing from apps"
assert apps["pihole"].get("command") == "bin/launcher-pihole", \
    f"pihole app command wrong: {apps['pihole'].get('command')}"
PYEOF
}

@test "snapcraft.yaml: pihole CLI app has network plug" {
    python3 - <<PYEOF
import yaml
with open("${REPO_ROOT}/snap/snapcraft.yaml") as f:
    doc = yaml.safe_load(f)
plugs = doc["apps"]["pihole"].get("plugs", [])
assert "network" in plugs, f"network missing from pihole CLI plugs: {plugs}"
PYEOF
}

@test "snapcraft.yaml: wrappers part exists and sources from snap/local" {
    python3 - <<PYEOF
import yaml
with open("${REPO_ROOT}/snap/snapcraft.yaml") as f:
    doc = yaml.safe_load(f)
wrappers = doc["parts"].get("wrappers", {})
assert wrappers, "wrappers part missing"
assert wrappers.get("source", "").endswith("snap/local/") or \
    wrappers.get("source") == "snap/local/", \
    f"wrappers source not snap/local/: {wrappers.get('source')}"
PYEOF
}

@test "snapcraft.yaml: assumes snapd2.55 or later" {
    python3 - <<PYEOF
import yaml
with open("${REPO_ROOT}/snap/snapcraft.yaml") as f:
    doc = yaml.safe_load(f)
assumes = doc.get("assumes", [])
assert any("snapd2" in str(a) for a in assumes), \
    f"no snapd2.x assumption found: {assumes}"
PYEOF
}

@test "snapcraft.yaml: gravity-sync app exists with correct timer schedule" {
    python3 - <<PYEOF
import yaml
with open("${REPO_ROOT}/snap/snapcraft.yaml") as f:
    doc = yaml.safe_load(f)
apps = doc.get("apps", {})
assert "gravity-sync" in apps, "gravity-sync app missing from apps"
app = apps["gravity-sync"]
assert app.get("command") == "bin/launcher-pihole -g", \
    f"gravity-sync command wrong: {app.get('command')}"
assert app.get("daemon") == "oneshot", \
    f"gravity-sync daemon wrong: {app.get('daemon')}"
assert app.get("timer") == "sun,03:00~05:00", \
    f"gravity-sync timer wrong: {app.get('timer')}"
PYEOF
}

