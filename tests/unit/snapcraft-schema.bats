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

@test "snapcraft.yaml: adopt-info points to the core part" {
    python3 - <<PYEOF
import yaml
with open("${REPO_ROOT}/snap/snapcraft.yaml") as f:
    doc = yaml.safe_load(f)
assert doc.get("adopt-info") == "core", \
    f"expected adopt-info: core, got: {doc.get('adopt-info')}"
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

# ---------------------------------------------------------------------------
# Version single-source-of-truth invariants
#
# The only places versions live in this file are the three `source-tag:`
# lines (one per upstream part). Everything else - the snap version string,
# the GIT_VERSION baked into pihole-FTL, and the `versions` template that
# powers `pihole -v` - is derived at build time from the tags actually
# fetched. These tests prevent a silent revert to hardcoded duplicates.
# ---------------------------------------------------------------------------

@test "snapcraft.yaml: each upstream part declares source-tag" {
    python3 - <<PYEOF
import yaml
with open("${REPO_ROOT}/snap/snapcraft.yaml") as f:
    doc = yaml.safe_load(f)
for name in ("ftl", "core", "web"):
    tag = doc["parts"][name].get("source-tag")
    assert tag and tag.startswith("v"), \
        f"parts.{name}.source-tag missing or malformed: {tag!r}"
PYEOF
}

@test "snapcraft.yaml: ftl build-environment does not reference snapcraft project version vars" {
    # GIT_VERSION/GIT_TAG were previously interpolated from
    # \${SNAPCRAFT_PROJECT_VERSION} and \${CRAFT_PART_SOURCE_TAG}, neither
    # of which exist as snapcraft variables - they expanded to empty
    # strings. Tag values are now exported inside override-build from
    # git describe instead.
    python3 - <<PYEOF
import yaml
with open("${REPO_ROOT}/snap/snapcraft.yaml") as f:
    doc = yaml.safe_load(f)
env = doc["parts"]["ftl"].get("build-environment", []) or []
keys = {k for entry in env for k in entry}
assert "GIT_VERSION" not in keys, \
    "GIT_VERSION must not be in ftl.build-environment; export it from git describe inside override-build"
assert "GIT_TAG" not in keys, \
    "GIT_TAG must not be in ftl.build-environment; export it from git describe inside override-build"
PYEOF
}

@test "snapcraft.yaml: core does not embed a static versions heredoc" {
    # The runtime versions template must be generated from each part's
    # actual fetched tag in core.override-build, not hardcoded in
    # core.override-pull. A heredoc that bakes CORE_VERSION=vX.Y.Z would
    # silently drift the moment the nightly bot bumps any source-tag.
    python3 - <<PYEOF
import re, yaml
with open("${REPO_ROOT}/snap/snapcraft.yaml") as f:
    doc = yaml.safe_load(f)
pull = doc["parts"]["core"].get("override-pull", "")
pattern = re.compile(r"^(CORE|FTL|WEB)_VERSION=v", re.MULTILINE)
assert not pattern.search(pull), \
    "core.override-pull contains a hardcoded *_VERSION= line; this heredoc must live in override-build and read tags from CRAFT_STAGE"
PYEOF
}

@test "snapcraft.yaml: core depends on ftl and web for tag propagation" {
    # core.override-build reads ftl/web tags from CRAFT_STAGE; without
    # `after:`, snapcraft is free to schedule core's build before the
    # other parts have staged their snap-meta/<part>-tag files.
    python3 - <<PYEOF
import yaml
with open("${REPO_ROOT}/snap/snapcraft.yaml") as f:
    doc = yaml.safe_load(f)
after = doc["parts"]["core"].get("after", [])
for required in ("ftl", "web"):
    assert required in after, \
        f"core.after must include {required!r} (got {after!r}) - core reads its tag from CRAFT_STAGE"
PYEOF
}

@test "snapcraft.yaml: core derives version + versions template at build time" {
    # Lock in the dynamic generation: core.override-build must (a) call
    # craftctl set version, (b) read FTL_TAG from CRAFT_STAGE/snap-meta,
    # and (c) read WEB_TAG from the post-organize location under
    # var/www/html/admin/snap-meta.
    python3 - <<PYEOF
import yaml
with open("${REPO_ROOT}/snap/snapcraft.yaml") as f:
    doc = yaml.safe_load(f)
build = doc["parts"]["core"].get("override-build", "")
assert "craftctl set version=" in build, \
    "core.override-build must call 'craftctl set version=...' to expose the upstream pi-hole tag"
assert "\${CRAFT_STAGE}/snap-meta/ftl-tag" in build, \
    "core.override-build must read FTL_TAG from \${CRAFT_STAGE}/snap-meta/ftl-tag"
assert "\${CRAFT_STAGE}/var/www/html/admin/snap-meta/web-tag" in build, \
    "core.override-build must read WEB_TAG from the post-organize web snap-meta path"
PYEOF
}

@test "snapcraft.yaml: ftl and web publish their tag to snap-meta and prime it out" {
    # Each upstream part writes \${CRAFT_PART_INSTALL}/snap-meta/<part>-tag
    # during its override-build so the core part can consume it via
    # CRAFT_STAGE. The prime block then keeps it out of the final snap.
    python3 - <<PYEOF
import yaml
with open("${REPO_ROOT}/snap/snapcraft.yaml") as f:
    doc = yaml.safe_load(f)

ftl = doc["parts"]["ftl"]
assert "snap-meta/ftl-tag" in ftl.get("override-build", ""), \
    "ftl.override-build must write \${CRAFT_PART_INSTALL}/snap-meta/ftl-tag"
assert "-snap-meta" in (ftl.get("prime") or []), \
    "ftl.prime must exclude snap-meta from the final snap"

web = doc["parts"]["web"]
assert "snap-meta/web-tag" in web.get("override-build", ""), \
    "web.override-build must write \${CRAFT_PART_INSTALL}/snap-meta/web-tag"
# The organize rule moves snap-meta under var/www/html/admin/, so the
# prime exclusion lives at the post-organize path.
assert "-var/www/html/admin/snap-meta" in (web.get("prime") or []), \
    "web.prime must exclude var/www/html/admin/snap-meta from the final snap"
PYEOF
}

