#!/usr/bin/env python3
"""
Generate patch files for the pi-hole snap build.
Downloads the upstream source files at the tag declared in snapcraft.yaml,
applies snap-specific modifications, and writes correct unified diffs using
Python's difflib — no shell escaping issues.

Run from the snap-pi-hole project root:
    python3 snap/local/build/generate-patches.py
    python3 snap/local/build/generate-patches.py v6.4.3   # override tag
"""
import difflib
import pathlib
import re
import sys
import urllib.request


def _read_tag_from_snapcraft() -> str:
    """Read the pi_hole part source-tag from snapcraft.yaml."""
    yaml_path = pathlib.Path("snap/snapcraft.yaml")
    text = yaml_path.read_text()
    # Look for the pi_hole part block and extract source-tag
    m = re.search(r"pi_hole:.*?source-tag:\s*(\S+)", text, re.DOTALL)
    if not m:
        raise RuntimeError("Could not find pi_hole source-tag in snap/snapcraft.yaml")
    return m.group(1)


TAG = sys.argv[1] if len(sys.argv) > 1 else _read_tag_from_snapcraft()
UPSTREAM_BASE = f"https://raw.githubusercontent.com/pi-hole/pi-hole/{TAG}/advanced/Scripts"
PATCHES_DIR = pathlib.Path("snap/local/patches")
PATCHES_DIR.mkdir(parents=True, exist_ok=True)
print(f"Using upstream tag: {TAG}")


def fetch(filename):
    url = f"{UPSTREAM_BASE}/{filename}"
    print(f"  Fetching {url}")
    with urllib.request.urlopen(url) as r:
        return r.read().decode()


def write_patch(filename, original, modified):
    orig_lines = original.splitlines(keepends=True)
    mod_lines = modified.splitlines(keepends=True)
    label = f"advanced/Scripts/{filename}"
    diff = list(difflib.unified_diff(orig_lines, mod_lines,
                                     fromfile=f"a/{label}",
                                     tofile=f"b/{label}"))
    if not diff:
        print(f"  WARNING: no changes for {filename}")
        return
    patch_path = PATCHES_DIR / (filename.replace(".sh", ".patch"))
    patch_path.write_text("".join(diff))
    print(f"  Written  {patch_path}  ({len(diff)} diff lines)")


# ---------------------------------------------------------------------------
# piholeLogFlush.sh
# ---------------------------------------------------------------------------
print("\n=== piholeLogFlush.sh ===")
src = fetch("piholeLogFlush.sh")
mod = src
mod = mod.replace("service pihole-FTL stop",    "snapctl stop pihole-ftl")
mod = mod.replace("service pihole-FTL restart", "snapctl restart pihole-ftl")
mod = mod.replace("service pihole-FTL start",   "snapctl start pihole-ftl")
write_patch("piholeLogFlush.sh", src, mod)

# ---------------------------------------------------------------------------
# piholeDebug.sh
# ---------------------------------------------------------------------------
print("\n=== piholeDebug.sh ===")
src = fetch("piholeDebug.sh")
mod = src

mod = mod.replace(
    'status_of_process=$(systemctl is-active "${i}")',
    'status_of_process=$(snapctl is-active pihole-ftl &>/dev/null && echo "active" || echo "inactive")',
)
mod = mod.replace(
    "service \"${i}\" status | grep -q -E 'is\\srunning|started'",
    "snapctl is-active pihole-ftl &>/dev/null",
)
mod = mod.replace(
    "FTL_status=$(systemctl status --full --no-pager pihole-FTL.service)",
    "FTL_status=$(snapctl services pihole-ftl)",
)
mod = mod.replace(
    'log_write "${INFO} systemctl:  command not found"',
    'FTL_status=$(snapctl services pihole-ftl); log_write "   ${FTL_status}"',
)
mod = mod.replace(
    'chown "$USER":"${username}" ${PIHOLE_DEBUG_LOG}',
    'true # chown disabled inside snap',
)

# Verify all replacements landed
checks = [
    ('systemctl is-active "${i}"',              "systemctl is-active check"),
    ("service \"${i}\" status",                 "service status | grep check"),
    ("systemctl status --full --no-pager",      "FTL systemctl status check"),
    ('systemctl:  command not found',           "systemctl not found log"),
    ('chown "$USER":"${username}"',             "chown in upload_to_tricorder"),
]
for needle, label in checks:
    if needle in mod:
        print(f"  ERROR: {label} — replacement did not apply!")
        raise SystemExit(1)
    else:
        print(f"  OK: {label}")

write_patch("piholeDebug.sh", src, mod)

# ---------------------------------------------------------------------------
# updatecheck.sh
# ---------------------------------------------------------------------------
print("\n=== updatecheck.sh ===")
src = fetch("updatecheck.sh")
mod = src

old_local_funcs = """\
function get_local_branch() {
    # Return active branch
    cd "${1}" 2>/dev/null || { echo "null"; return; }
    git rev-parse --abbrev-ref HEAD || echo "null"
}

function get_local_version() {
    # Return active version
    cd "${1}" 2>/dev/null || { echo "null"; return; }
    git describe --tags --always 2>/dev/null || echo "null"
}

function get_local_hash() {
    cd "${1}" 2>/dev/null || { echo "null"; return; }
    git rev-parse --short=8 HEAD || echo "null"
}"""

new_local_funcs = """\
function get_local_branch() {
    local template="/opt/pihole/templates/versions"
    if [[ "${1}" == "/etc/.pihole" ]]; then
        sed -n "s/^CORE_BRANCH=//p" "${template}" 2>/dev/null || echo "snap"
    else
        sed -n "s/^WEB_BRANCH=//p" "${template}" 2>/dev/null || echo "snap"
    fi
}

function get_local_version() {
    local template="/opt/pihole/templates/versions"
    if [[ "${1}" == "/etc/.pihole" ]]; then
        sed -n "s/^CORE_VERSION=//p" "${template}" 2>/dev/null || echo "N/A"
    else
        sed -n "s/^WEB_VERSION=//p" "${template}" 2>/dev/null || echo "N/A"
    fi
}

function get_local_hash() {
    echo "snap"
}"""

if old_local_funcs not in mod:
    print("  ERROR: could not find local version functions in updatecheck.sh")
    raise SystemExit(1)
mod = mod.replace(old_local_funcs, new_local_funcs)

mod = mod.replace(
    'if [[ "${2}" == "master" ]]; then',
    'if [[ "${2}" == "master" || "${2}" == "snap" ]]; then',
)
mod = mod.replace(
    "git ls-remote \"https://github.com/pi-hole/${1}\" --tags \"${2}\" | awk '{print substr($0, 1,8);}' || echo \"null\"",
    'echo "N/A"',
)

write_patch("updatecheck.sh", src, mod)

print("\n=== All patches generated successfully ===")
print(f"Output directory: {PATCHES_DIR.resolve()}")
