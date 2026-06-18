#!/usr/bin/env bats
#
# Static validation tests for the repository structure and snapcraft.yaml
# schema. These tests assert invariants about the project itself rather
# than about the runtime behaviour of any particular script.
#
# Catching configuration drift early (e.g. a hook added but not shellchecked,
# or refresh-mode accidentally removed) is the goal here.
#
# Tests are organised top-down:
#   1. Top-level snap metadata          - confinement, base, license, ...
#   2. Parts and layout structure       - ftl, pi_hole, web, wrappers, paths
#   3. Daemon (apps.pihole-ftl)         - refresh-mode, plugs, lifecycle
#   4. Other apps and timers            - CLI, gravity-sync
#   5. Version single-source-of-truth   - locks in derivation from source refs
#   6. Build-rule safety nets           - snapcraft schema gotchas
#   7. Repository file presence         - hooks, launchers, assets
#   8. Shell script integrity           - bash -n on hooks and launchers
#
# Run locally:  bats tests/unit/snapcraft-schema.bats
# In CI:        see .github/workflows/cicd.yml (lint+unit job)

setup() {
    REPO_ROOT="$(git rev-parse --show-toplevel)"
}

# 1. Top-level snap metadata

@test "snapcraft.yaml confinement is strict" {
    python3 - <<PYEOF
import yaml
with open("${REPO_ROOT}/snap/snapcraft.yaml") as f:
    doc = yaml.safe_load(f)
assert doc.get("confinement") == "strict"
PYEOF
}

@test "snapcraft.yaml base is core26" {
    python3 - <<PYEOF
import yaml
with open("${REPO_ROOT}/snap/snapcraft.yaml") as f:
    doc = yaml.safe_load(f)
assert doc.get("base") == "core26"
PYEOF
}

@test "snapcraft.yaml license is MIT" {
    python3 - <<PYEOF
import yaml
with open("${REPO_ROOT}/snap/snapcraft.yaml") as f:
    doc = yaml.safe_load(f)
assert doc.get("license") == "MIT"
PYEOF
}

@test "snapcraft.yaml epoch is defined (data migration safety)" {
    python3 - <<PYEOF
import yaml
with open("${REPO_ROOT}/snap/snapcraft.yaml") as f:
    doc = yaml.safe_load(f)
assert "epoch" in doc, "epoch key missing from snapcraft.yaml"
PYEOF
}

@test "snapcraft.yaml adopt-info points to the pi_hole part" {
    python3 - <<PYEOF
import yaml
with open("${REPO_ROOT}/snap/snapcraft.yaml") as f:
    doc = yaml.safe_load(f)
assert doc.get("adopt-info") == "pi_hole", \
    f"expected adopt-info: pi_hole, got: {doc.get('adopt-info')}"
PYEOF
}

# 2. Parts and layout structure

@test "snapcraft.yaml all four parts exist (ftl, pi_hole, web, wrappers)" {
    python3 - <<PYEOF
import yaml
with open("${REPO_ROOT}/snap/snapcraft.yaml") as f:
    doc = yaml.safe_load(f)
parts = doc.get("parts", {})
expected = {"ftl", "pi_hole", "web", "wrappers"}
actual = set(parts.keys())
assert actual == expected, f"expected parts {expected}, got {actual}"
PYEOF
}

@test "snapcraft.yaml wrappers part sources from snap/local" {
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

@test "snapcraft.yaml all required layout paths are defined" {
    python3 - <<PYEOF
import yaml
with open("${REPO_ROOT}/snap/snapcraft.yaml") as f:
    doc = yaml.safe_load(f)
layout = doc.get("layout", {})
required = ["/etc/pihole", "/etc/.pihole", "/etc/dnsmasq.d", "/var/www/html", "/var/log/pihole", "/opt/pihole", "/usr/local/bin/pihole"]
for path in required:
    assert path in layout, f"layout path '{path}' missing from snapcraft.yaml"
PYEOF
}

# 3. Daemon: apps.pihole-ftl

@test "snapcraft.yaml pihole-ftl has refresh-mode endure (DNS stays up across refresh)" {
    python3 - <<PYEOF
import yaml, sys
with open("${REPO_ROOT}/snap/snapcraft.yaml") as f:
    doc = yaml.safe_load(f)
ftl = doc["apps"]["pihole-ftl"]
assert ftl.get("refresh-mode") == "endure", \
    f"expected refresh-mode: endure, got: {ftl.get('refresh-mode')}"
PYEOF
}

@test "snapcraft.yaml pihole-ftl has stop-timeout defined (graceful shutdown)" {
    python3 - <<PYEOF
import yaml
with open("${REPO_ROOT}/snap/snapcraft.yaml") as f:
    doc = yaml.safe_load(f)
ftl = doc["apps"]["pihole-ftl"]
assert "stop-timeout" in ftl, "stop-timeout missing from pihole-ftl"
PYEOF
}

@test "snapcraft.yaml pihole-ftl is disabled on install (operator must enable)" {
    python3 - <<PYEOF
import yaml
with open("${REPO_ROOT}/snap/snapcraft.yaml") as f:
    doc = yaml.safe_load(f)
ftl = doc["apps"]["pihole-ftl"]
assert ftl.get("install-mode") == "disable", \
    f"expected install-mode: disable, got: {ftl.get('install-mode')}"
PYEOF
}

@test "snapcraft.yaml pihole-ftl has network-bind plug (DNS port 53)" {
    python3 - <<PYEOF
import yaml
with open("${REPO_ROOT}/snap/snapcraft.yaml") as f:
    doc = yaml.safe_load(f)
plugs = doc["apps"]["pihole-ftl"].get("plugs", [])
assert "network-bind" in plugs, f"network-bind missing from pihole-ftl plugs: {plugs}"
PYEOF
}

@test "snapcraft.yaml pihole-ftl has system-observe plug (web dashboard)" {
    python3 - <<PYEOF
import yaml
with open("${REPO_ROOT}/snap/snapcraft.yaml") as f:
    doc = yaml.safe_load(f)
plugs = doc["apps"]["pihole-ftl"].get("plugs", [])
assert "system-observe" in plugs, f"system-observe missing from pihole-ftl plugs"
PYEOF
}

# 4. Other apps and timers

@test "snapcraft.yaml pihole CLI app uses launcher-pihole command" {
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

@test "snapcraft.yaml pihole CLI app has network plug" {
    python3 - <<PYEOF
import yaml
with open("${REPO_ROOT}/snap/snapcraft.yaml") as f:
    doc = yaml.safe_load(f)
plugs = doc["apps"]["pihole"].get("plugs", [])
assert "network" in plugs, f"network missing from pihole CLI plugs: {plugs}"
PYEOF
}

@test "snapcraft.yaml gravity-sync runs as a weekly oneshot timer" {
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

# 5. Version single-source-of-truth invariants
#
# The upstream parts pin source commits. Human-readable release labels are
# resolved from the Pi-hole repositories during build/dashboard generation.

@test "snapcraft.yaml each upstream part declares source-commit" {
    python3 - <<PYEOF
import yaml
with open("${REPO_ROOT}/snap/snapcraft.yaml") as f:
    doc = yaml.safe_load(f)
for name in ("ftl", "pi_hole", "web"):
    part = doc["parts"][name]
    commit = part.get("source-commit")
    assert commit and len(commit) == 40, \
        f"parts.{name}.source-commit missing or malformed: {commit!r}"
    assert "source-tag" not in part, \
        f"parts.{name}.source-tag should not be used for stable branch tracking"
PYEOF
}

@test "stable release labels are resolved from upstream repositories" {
    python3 - <<PYEOF
import pathlib

repo_root = pathlib.Path("${REPO_ROOT}")
assert not (repo_root / "snap/local/build/stable-versions.json").exists()

resolver = (repo_root / "snap/local/build/resolve_upstream_version.py").read_text()
for repo in ("pi-hole/FTL", "pi-hole/pi-hole", "pi-hole/web"):
    assert repo in resolver, f"{repo} missing from resolver"

for script_name in ("ftl-override-build.sh", "pi-hole-override-build.sh", "web-override-build.sh"):
    script = (repo_root / "snap/local/build" / script_name).read_text()
    assert "resolve_upstream_version.py" in script, f"{script_name} does not use upstream resolver"
    assert "stable-versions.json" not in script, f"{script_name} still reads stable-versions.json"
PYEOF
}

@test "snapcraft.yaml ftl build-environment does not reference non-existent snapcraft vars" {
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

@test "snapcraft.yaml pi_hole does not embed a static versions heredoc" {
    # The runtime versions template must be generated from each part's
    # actual fetched tag in pi_hole.override-build, not hardcoded in
    # pi_hole.override-pull. A heredoc that bakes CORE_VERSION=vX.Y.Z would
    # silently drift the moment the upstream source tracker bumps any source ref.
    python3 - <<PYEOF
import re, yaml
with open("${REPO_ROOT}/snap/snapcraft.yaml") as f:
    doc = yaml.safe_load(f)
pull_script = doc["parts"]["pi_hole"].get("override-pull", "").replace("\$CRAFT_PROJECT_DIR", "${REPO_ROOT}")
with open(pull_script) as sf:
    pull = sf.read()
pattern = re.compile(r"^(CORE|FTL|WEB)_VERSION=v", re.MULTILINE)
assert not pattern.search(pull), \
    "pi_hole.override-pull script contains a hardcoded *_VERSION= line; this heredoc must live in override-build and read tags from CRAFT_STAGE"
PYEOF
}

@test "snapcraft.yaml pi_hole depends on ftl and web for tag propagation" {
    # pi_hole.override-build reads ftl/web tags from CRAFT_STAGE; without
    # `after:`, snapcraft is free to schedule pi_hole's build before the
    # other parts have staged their snap-meta/<part>-tag files.
    python3 - <<PYEOF
import yaml
with open("${REPO_ROOT}/snap/snapcraft.yaml") as f:
    doc = yaml.safe_load(f)
after = doc["parts"]["pi_hole"].get("after", [])
for required in ("ftl", "web"):
    assert required in after, \
        f"pi_hole.after must include {required!r} (got {after!r}) - pi_hole reads its tag from CRAFT_STAGE"
PYEOF
}

@test "snapcraft.yaml pi_hole derives version + versions template at build time" {
    # Lock in the dynamic generation: pi_hole.override-build must (a) call
    # craftctl set version, (b) read FTL_TAG from CRAFT_STAGE/snap-meta,
    # and (c) read WEB_TAG from the post-organize location under
    # var/www/html/admin/snap-meta.
    python3 - <<PYEOF
import yaml
with open("${REPO_ROOT}/snap/snapcraft.yaml") as f:
    doc = yaml.safe_load(f)
build_script = doc["parts"]["pi_hole"].get("override-build", "").replace("\$CRAFT_PROJECT_DIR", "${REPO_ROOT}")
with open(build_script) as sf:
    build = sf.read()
assert "craftctl set version=" in build, \
    "pi_hole.override-build script must call 'craftctl set version=...' to expose the upstream pi-hole tag"
assert "\${CRAFT_STAGE}/snap-meta/ftl-tag" in build, \
    "pi_hole.override-build script must read FTL_TAG from \${CRAFT_STAGE}/snap-meta/ftl-tag"
assert "\${CRAFT_STAGE}/var/www/html/admin/snap-meta/web-tag" in build, \
    "pi_hole.override-build script must read WEB_TAG from the post-organize web snap-meta path"
PYEOF
}

@test "versions template paths are centralized in pihole-config helper" {
    python3 - <<PYEOF
import yaml
with open("${REPO_ROOT}/snap/snapcraft.yaml") as f:
    doc = yaml.safe_load(f)
build_script = doc["parts"]["pi_hole"].get("override-build", "").replace("\$CRAFT_PROJECT_DIR", "${REPO_ROOT}")
helper_path = "${REPO_ROOT}/snap/local/runtime/pihole-config.sh"
with open(build_script) as sf:
    build = sf.read()
with open(helper_path) as hf:
    helper = hf.read()

for required in (
    "pihole_versions_template_file",
    "pihole_advanced_versions_template_file",
    "pihole_versions_file",
):
    assert required in helper, f"{required} missing from pihole-config.sh"

assert "pihole_versions_template_file \"\$CRAFT_PART_INSTALL\"" in build, \
    "pi_hole.override-build must derive the primary versions template path from pihole-config.sh"
assert "pihole_advanced_versions_template_file \"\$CRAFT_PART_INSTALL\"" in build, \
    "pi_hole.override-build must derive the advanced versions template path from pihole-config.sh"
assert "/opt/pihole/templates/versions" not in build, \
    "pi_hole.override-build must not hardcode the versions template path"
assert "/etc/.pihole/advanced/Scripts/templates/versions" not in build, \
    "pi_hole.override-build must not hardcode the advanced versions template path"
PYEOF
}

@test "snapcraft.yaml ftl and web publish their tag to snap-meta (and prime it out)" {
    # Each upstream part writes \${CRAFT_PART_INSTALL}/snap-meta/<part>-tag
    # during its override-build so the pi_hole part can consume it via
    # CRAFT_STAGE. The prime block then keeps it out of the final snap.
    python3 - <<PYEOF
import yaml
with open("${REPO_ROOT}/snap/snapcraft.yaml") as f:
    doc = yaml.safe_load(f)

ftl = doc["parts"]["ftl"]
ftl_build_script = ftl.get("override-build", "").replace("\$CRAFT_PROJECT_DIR", "${REPO_ROOT}")
with open(ftl_build_script) as sf:
    ftl_build = sf.read()
assert "snap-meta/ftl-tag" in ftl_build, \
    "ftl.override-build script must write \${CRAFT_PART_INSTALL}/snap-meta/ftl-tag"
assert "-snap-meta" in (ftl.get("prime") or []), \
    "ftl.prime must exclude snap-meta from the final snap"

web = doc["parts"]["web"]
web_build_script = web.get("override-build", "").replace("\$CRAFT_PROJECT_DIR", "${REPO_ROOT}")
with open(web_build_script) as sf:
    web_build = sf.read()
assert "snap-meta/web-tag" in web_build, \
    "web.override-build script must write \${CRAFT_PART_INSTALL}/snap-meta/web-tag"
# The organize rule moves snap-meta under var/www/html/admin/, so the
# prime exclusion lives at the post-organize path.
assert "-var/www/html/admin/snap-meta" in (web.get("prime") or []), \
    "web.prime must exclude var/www/html/admin/snap-meta from the final snap"
PYEOF
}

# 6. Build-rule safety nets
# Catch snapcraft schema gotchas locally before the CI runner does.

@test "snapcraft.yaml organize globs always have trailing-slash destinations" {
    # snapcraft 9.x rejects an organize rule whose source glob matches
    # multiple files when the destination does not end with '/' - it
    # can't tell whether you mean "rename to a single file" or "drop
    # into a directory". 8.x silently treated bare paths as directories;
    # 9.x errors out. Catch this locally instead of on the CI runner.
    python3 - <<PYEOF
import yaml, sys
with open("${REPO_ROOT}/snap/snapcraft.yaml") as f:
    doc = yaml.safe_load(f)
problems = []
for part_name, part in (doc.get("parts") or {}).items():
    for src, dst in (part.get("organize") or {}).items():
        is_glob = any(c in src for c in "*?[")
        if is_glob and not dst.endswith("/"):
            problems.append(f"parts.{part_name}.organize: {src!r} -> {dst!r}")
if problems:
    print("Glob organize source(s) with no trailing-slash destination:", file=sys.stderr)
    for line in problems:
        print(f"  {line}", file=sys.stderr)
    sys.exit(1)
PYEOF
}

@test "snapcraft.yaml passes yamllint validation" {
    if ! command -v yamllint >/dev/null 2>&1; then
        skip "yamllint is not installed"
    fi
    run yamllint -d "{extends: relaxed, rules: {line-length: disable}}" "${REPO_ROOT}/snap/snapcraft.yaml"
    [ "$status" -eq 0 ]
}

# 7. Repository file presence

@test "hooks install, configure, pre-refresh, post-refresh, remove all exist and are executable" {
    for hook in install configure pre-refresh post-refresh remove; do
        path="${REPO_ROOT}/snap/hooks/${hook}"
        [ -f "$path" ] || { echo "missing hook: $hook"; return 1; }
        [ -x "$path" ] || { echo "hook not executable: $hook"; return 1; }
    done
}

@test "local launcher-ftl.sh and launcher-pihole.sh exist and are executable" {
    [ -x "${REPO_ROOT}/snap/local/runtime/launcher-ftl.sh" ]
    [ -x "${REPO_ROOT}/snap/local/runtime/launcher-pihole.sh" ]
    [ -f "${REPO_ROOT}/snap/local/runtime/pihole-config.sh" ]
}

@test "snap/gui store icon exists" {
    [ -f "${REPO_ROOT}/snap/gui/pihole.png" ]
}

@test "repo root LICENSE file exists" {
    [ -f "${REPO_ROOT}/LICENSE" ]
}

@test "readme.md all linked docs/ files exist" {
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

@test "generated GitHub Pages artifacts are not tracked source files" {
    python3 - <<PYEOF
import pathlib
import subprocess

root = pathlib.Path("${REPO_ROOT}")
tracked_docs = subprocess.check_output(
    ["git", "-C", str(root), "ls-files", "docs"],
    text=True,
).splitlines()
present_tracked_docs = sorted(path for path in tracked_docs if (root / path).exists())
assert not present_tracked_docs, f"generated Pages artifacts are tracked: {present_tracked_docs}"

ignore_text = (root / ".gitignore").read_text(encoding="utf-8")
assert "/docs/" in ignore_text.splitlines(), "generated docs/ output is not ignored"
PYEOF
}

# 8. Shell script integrity

@test "shell scripts exist on disk" {
    local scripts=(
        snap/local/runtime/launcher-ftl.sh
        snap/local/runtime/launcher-pihole.sh
        snap/local/runtime/pihole-config.sh
        snap/local/testing/snap-check.sh
        snap/local/testing/snap-debug.sh
        snap/local/testing/snap-setup.sh
        snap/local/testing/port-utils.sh
        snap/local/build/ftl-override-build.sh
        snap/local/build/ftl-override-pull.sh
        snap/local/build/pi-hole-override-build.sh
        snap/local/build/pi-hole-override-pull.sh
        snap/local/build/web-override-build.sh
        tests/scripts/multipass-wait-snapd-stable.sh
        tests/scripts/validate-upstream-patches.sh
        snap/hooks/install
        snap/hooks/configure
        snap/hooks/pre-refresh
        snap/hooks/post-refresh
        snap/hooks/remove
    )
    for script in "${scripts[@]}"; do
        [ -f "${REPO_ROOT}/${script}" ] || { echo "missing: $script"; return 1; }
    done
}

@test "shell scripts pass bash -n syntax check" {
    local scripts=(
        snap/local/runtime/launcher-ftl.sh
        snap/local/runtime/launcher-pihole.sh
        snap/local/runtime/pihole-config.sh
        snap/local/testing/snap-check.sh
        snap/local/testing/snap-debug.sh
        snap/local/testing/snap-setup.sh
        snap/local/testing/port-utils.sh
        snap/local/build/ftl-override-build.sh
        snap/local/build/ftl-override-pull.sh
        snap/local/build/pi-hole-override-build.sh
        snap/local/build/pi-hole-override-pull.sh
        snap/local/build/web-override-build.sh
        tests/scripts/multipass-wait-snapd-stable.sh
        tests/scripts/validate-upstream-patches.sh
        snap/hooks/install
        snap/hooks/configure
        snap/hooks/pre-refresh
        snap/hooks/post-refresh
        snap/hooks/remove
    )
    for script in "${scripts[@]}"; do
        bash -n "${REPO_ROOT}/${script}" \
            || { echo "syntax error in: $script"; return 1; }
    done
}

# 9. Confinement hardening patches

@test "snapcraft.yaml pi_hole override-pull includes sandboxing patches and patch-rot guards" {
    python3 - <<PYEOF
import yaml, sys, glob
with open("${REPO_ROOT}/snap/snapcraft.yaml") as f:
    doc = yaml.safe_load(f)

pull_script = doc["parts"]["pi_hole"].get("override-pull", "").replace("\$CRAFT_PROJECT_DIR", "${REPO_ROOT}")
with open(pull_script) as sf:
    pull = sf.read()

for patch_path in glob.glob("${REPO_ROOT}/snap/local/patches/*.patch"):
    with open(patch_path) as pf:
        pull += "\n" + pf.read()

# Verify that service stops/starts are routed to snapctl
assert "snapctl stop pihole-ftl" in pull, "missing snapctl stop diversion"
assert "snapctl restart pihole-ftl" in pull, "missing snapctl restart diversion"

# Verify that PID files are redirected
assert "/etc/pihole/pihole-FTL.pid" in pull, "missing PID file redirection to /etc/pihole/"

# Verify that readonly is stripped
assert "readonly FTL_PID_FILE" in pull and "FTL_PID_FILE" in pull, "missing FTL_PID_FILE readonly strip"

# Verify updatecheck git neutralization
assert "/opt/pihole/templates/versions" in pull, "missing git neutralization in updatecheck.sh"

# Verify chown neutralization
assert "chown pihole:pihole" in pull and "true # chown pihole:pihole" in pull, "missing chown neutralization"
assert 'chown "\$USER":"\${username}"' in pull and "true # chown disabled inside snap" in pull, "missing piholeDebug.sh chown neutralization"

# Verify patch-rot guards are present
assert "service pihole-FTL" in pull, "missing patch-rot guard for service pihole-FTL"
assert "/run/pihole-FTL.pid" in pull, "missing patch-rot guard for FTL_PID"
assert 'systemctl is-active "\${i}"' in pull, "missing patch-rot guard for systemctl is-active FTL status check"
assert "systemctl status --full --no-pager" in pull, "missing patch-rot guard for FTL systemctl full status check"
PYEOF
}

@test "ftl override-pull uses explicit patches for single-file upstream edits" {
    python3 - <<PYEOF
import glob
from pathlib import Path

root = Path("${REPO_ROOT}")
script = (root / "snap/local/build/ftl-override-pull.sh").read_text()
patches = sorted((root / "snap/local/patches/ftl").glob("*.patch"))
patch_text = "\n".join(path.read_text() for path in patches)

expected = {
    "FTL-h-strstr.patch",
    "x509-mbedtls-rng.patch",
    "dnsmasq-no-setgroups.patch",
    "files-chown-pihole-root-snap.patch",
}
assert {path.name for path in patches} == expected, [path.name for path in patches]

assert "patch --forward --strip=1" in script, "FTL patches are not applied with patch(1)"
assert "snap/local/patches/ftl" in script, "FTL patch directory is not referenced"
assert "mbedtls_psa_get_random" in patch_text, "x509 RNG patch missing"
assert "#undef strstr" in patch_text, "strstr patch missing"
assert "setgroups(0, &dummy) == -1" in patch_text, "dnsmasq patch context missing"
assert "return true;" in patch_text, "chown_pihole patch missing"

for forbidden in (
    r"sed -i 's/mbedtls_x509write_crt_pem",
    r"sed -i 's/mbedtls_pk_parse_keyfile",
    r"sed -i 's/setgroups(0, \&dummy)",
    r"sed -i 's/log_warn(\"chown_pihole(): Failed",
):
    assert forbidden not in script, f"single-file sed patch still in ftl override: {forbidden}"
PYEOF
}

# Helper to check a condition and print a warning annotation on failure without failing the test
assert_warn() {
    local condition_cmd="$1"
    local error_msg="$2"
    if ! eval "$condition_cmd"; then
        echo "::warning file=tests/unit/snapcraft-schema.bats,title=Dashboard Link Verification Failed::${error_msg}" >&2
        echo "WARNING: ${error_msg}" >&2
    fi
}

@test "HTML dashboard templates exist and footer links are correctly configured (non-blocking warning)" {
    local dash_path="${REPO_ROOT}/snap/local/assets/dashboard.html"
    local sbom_path="${REPO_ROOT}/snap/local/assets/sbom-explorer.html"

    assert_warn "[ -f '$dash_path' ]" "missing dashboard.html"
    assert_warn "[ -f '$sbom_path' ]" "missing sbom-explorer.html"

    # Verify dashboard.html links (root level relative paths)
    assert_warn "grep -q 'href=\"sbom/\"' '$dash_path'" "dashboard.html is missing the sbom/ footer link"
    assert_warn "grep -q 'href=\"coverage/\"' '$dash_path'" "dashboard.html is missing the coverage/ footer link"

    # Verify sbom-explorer.html links (sub-folder relative paths)
    assert_warn "grep -q 'href=\"../sbom/\"' '$sbom_path'" "sbom-explorer.html is missing the ../sbom/ footer link"
    assert_warn "grep -q 'href=\"../coverage/\"' '$sbom_path'" "sbom-explorer.html is missing the ../coverage/ footer link"
}
