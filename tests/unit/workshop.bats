#!/usr/bin/env bats
#
# Static validation tests for the committed Workshop definition.
#
# The root workshop.yaml is the project contract for contributors. Personal
# preferences belong in ignored local helpers, not in alternate committed
# Workshop definitions.

setup() {
    REPO_ROOT="$(git rev-parse --show-toplevel)"
}

@test "workshop.yaml parses and declares the project workshop" {
    python3 - <<PYEOF
import yaml

with open("${REPO_ROOT}/workshop.yaml") as f:
    doc = yaml.safe_load(f)

assert doc["name"] == "snap-pi-hole", doc.get("name")
assert doc["base"] == "ubuntu@26.04", doc.get("base")
assert isinstance(doc.get("sdks"), list) and doc["sdks"], "sdks must be a non-empty list"
assert isinstance(doc.get("actions"), dict) and doc["actions"], "actions must be a non-empty map"
PYEOF
}

@test "workshop.yaml keeps only project-required SDKs active" {
    python3 - <<PYEOF
import yaml

with open("${REPO_ROOT}/workshop.yaml") as f:
    doc = yaml.safe_load(f)

names = [sdk.get("name") for sdk in doc["sdks"]]
assert names == ["uv", "project-tools", "system"], names
assert "codex" not in names
assert "copilot" not in names
assert "claude-code" not in names
assert "gemini" not in names
PYEOF
}

@test "workshop tunnels rely on matching plug and slot names" {
    python3 - <<PYEOF
import yaml

with open("${REPO_ROOT}/workshop.yaml") as f:
    doc = yaml.safe_load(f)

system = next(sdk for sdk in doc["sdks"] if sdk.get("name") == "system")
plugs = system["plugs"]

assert "connections" not in doc, doc.get("connections")
assert set(plugs) == {"admin-web", "dns-tcp", "dns-udp"}, plugs
assert plugs["admin-web"] == {
    "interface": "tunnel",
    "endpoint": "localhost:8080/tcp",
}, plugs["admin-web"]
assert plugs["dns-tcp"] == {
    "interface": "tunnel",
    "endpoint": "localhost:5300/tcp",
}, plugs["dns-tcp"]
assert plugs["dns-udp"] == {
    "interface": "tunnel",
    "endpoint": "localhost:5300/udp",
}, plugs["dns-udp"]
PYEOF
}

@test "workshop.yaml exposes the expected contributor actions" {
    python3 - <<PYEOF
import yaml

with open("${REPO_ROOT}/workshop.yaml") as f:
    doc = yaml.safe_load(f)

expected = {
    "doctor",
    "context",
    "lint",
    "deps-js",
    "lint-js",
    "format-check",
    "shellcheck",
    "yamllint",
    "test",
    "test-jsdom",
    "test-playwright-snap",
    "coverage",
    "build",
    "clean",
    "install",
    "smoke",
    "logs",
    "debug",
    "uninstall",
}
actual = set(doc["actions"])
assert actual == expected, f"expected actions {sorted(expected)}, got {sorted(actual)}"
PYEOF
}

@test "workshop action bodies are valid Bash syntax" {
    python3 - <<PYEOF
import subprocess
import sys
import yaml

with open("${REPO_ROOT}/workshop.yaml") as f:
    actions = yaml.safe_load(f)["actions"]

failed = []
for name, script in actions.items():
    result = subprocess.run(["bash", "-n"], input=script, text=True, capture_output=True)
    if result.returncode != 0:
        failed.append(f"{name}: {result.stderr.strip()}")

if failed:
    print("\\n".join(failed), file=sys.stderr)
    raise SystemExit(1)
PYEOF
}

@test "workshop doctor covers tools used by workshop actions" {
    python3 - <<PYEOF
import re
import yaml

with open("${REPO_ROOT}/workshop.yaml") as f:
    actions = yaml.safe_load(f)["actions"]

doctor = actions["doctor"]
required = {
    "awk",
    "bats",
    "curl",
    "dig",
    "fd",
    "g++",
    "gcc",
    "gh",
    "git",
    "jq",
    "kcov",
    "make",
    "node",
    "nodejs",
    "npm",
    "npx",
    "pre-commit",
    "python3",
    "rg",
    "ruby",
    "sed",
    "shellcheck",
    "snapcraft",
    "tree",
    "uv",
    "wget",
    "yamllint",
    "yq",
}
declared = set(re.findall(r"^\\s*command -v ([A-Za-z0-9_.+-]+)\\s*$", doctor, re.MULTILINE))
missing = sorted(required - declared)
assert not missing, f"doctor is missing command checks for: {missing}"
assert "dpkg-query -W -f='\${Status}' build-essential" in doctor
assert "test -x /snap/bin/chromium" in doctor

for action_name in (
    "context",
    "shellcheck",
    "yamllint",
    "deps-js",
    "lint-js",
    "format-check",
    "test",
    "test-jsdom",
    "test-playwright-snap",
    "coverage",
    "build",
    "install",
    "smoke",
):
    assert action_name in actions, f"missing action: {action_name}"
PYEOF
}

@test "project-tools SDK installs and checks agent and JavaScript tooling" {
    python3 - <<PYEOF
from pathlib import Path

setup_base = Path("${REPO_ROOT}/.workshop/tools/hooks/setup-base").read_text()
setup_project = Path("${REPO_ROOT}/.workshop/tools/hooks/setup-project").read_text()
check_health = Path("${REPO_ROOT}/.workshop/tools/hooks/check-health").read_text()

assert "nodejs" in setup_base
assert "npm" in setup_base
for package in (
    "build-essential",
    "curl",
    "fd-find",
    "gawk",
    "gh",
    "git",
    "jq",
    "make",
    "ripgrep",
    "ruby",
    "sed",
    "tree",
    "wget",
    "yq",
):
    assert package in setup_base, f"setup-base missing package: {package}"
assert "ln -sf /usr/bin/fdfind /usr/local/bin/fd" in setup_base
assert "/usr/local/bin/nodejs" in setup_base
assert "snap install chromium" in setup_base
assert "tests/package-lock.json" in setup_project
assert "npm ci" in setup_project
for command in ("awk", "curl", "fd", "g++", "gcc", "gh", "git", "jq", "make", "node", "nodejs", "npm", "npx", "python3", "rg", "ruby", "sed", "tree", "uv", "wget", "yq"):
    assert command in check_health, f"check-health missing command: {command}"
assert "build-essential" in check_health
assert "/snap/bin/chromium" in check_health
PYEOF
}

@test "workshop context derives useful actions from workshop.yaml" {
    python3 - <<PYEOF
import yaml

with open("${REPO_ROOT}/workshop.yaml") as f:
    context = yaml.safe_load(f)["actions"]["context"]

assert "set -euo pipefail" in context
assert "yq -r '.actions | keys | .[]' workshop.yaml" in context
assert "printf '%s\\\\n'" not in context
PYEOF
}

@test "workshop yamllint action targets project YAML contracts" {
    python3 - <<PYEOF
import yaml

with open("${REPO_ROOT}/workshop.yaml") as f:
    yamllint = yaml.safe_load(f)["actions"]["yamllint"]

assert "yamllint -d" in yamllint
assert "line-length: disable" in yamllint
assert "snap/snapcraft.yaml" in yamllint
assert "workshop.yaml" in yamllint
assert "yamllint ." not in yamllint
PYEOF
}

@test "workshop shellcheck action fails loudly and handles empty input" {
    python3 - <<PYEOF
import yaml

with open("${REPO_ROOT}/workshop.yaml") as f:
    shellcheck = yaml.safe_load(f)["actions"]["shellcheck"]

assert "set -euo pipefail" in shellcheck
assert "git ls-files" in shellcheck
assert "xargs -r file --mime-type -Nnf-" in shellcheck
assert "xargs -r shellcheck --check-sourced --external-sources" in shellcheck
assert "--no-run-if-empty" not in shellcheck
PYEOF
}

@test "workshop install action uses shell filename expansion instead of parsing ls" {
    python3 - <<PYEOF
import yaml

with open("${REPO_ROOT}/workshop.yaml") as f:
    install = yaml.safe_load(f)["actions"]["install"]

assert "set -eu" in install
assert "shopt -s nullglob" in install
assert "snaps=(*.snap)" in install
assert 'snap_file="\${snaps[0]}"' in install
assert "ls -t" not in install
PYEOF
}

@test "workshop snapcraft actions run destructive operations with sudo" {
    python3 - <<PYEOF
import yaml

with open("${REPO_ROOT}/workshop.yaml") as f:
    actions = yaml.safe_load(f)["actions"]

assert actions["build"].strip().startswith("sudo snapcraft --destructive-mode"), actions["build"]
assert actions["clean"].strip().startswith("sudo snapcraft clean"), actions["clean"]
PYEOF
}

@test "workshop logs action uses snap logs line-count option" {
    python3 - <<PYEOF
import yaml

with open("${REPO_ROOT}/workshop.yaml") as f:
    logs = yaml.safe_load(f)["actions"]["logs"]

assert "snap logs pihole-by-rajannpatel.pihole-ftl" in logs, logs
assert '-n="\${1:-100}"' in logs, logs
assert "--last" not in logs, logs
PYEOF
}

@test "editor task files expose Workshop preflight commands" {
    python3 - <<PYEOF
import json
from pathlib import Path

vscode = json.loads(Path("${REPO_ROOT}/.vscode/tasks.json").read_text())
zed = json.loads(Path("${REPO_ROOT}/.zed/tasks.json").read_text())

vscode_tasks = {task["label"]: task for task in vscode["tasks"]}
zed_tasks = {task["label"]: task for task in zed}

assert vscode_tasks["Workshop: Open Check"]["runOptions"]["runOn"] == "folderOpen"
assert "workshop run snap-pi-hole -- doctor" in vscode_tasks["Workshop: Open Check"]["command"]
assert vscode_tasks["Workshop: Launch"]["command"] == "workshop launch snap-pi-hole"
assert vscode_tasks["Workshop: Doctor"]["command"] == "workshop run snap-pi-hole -- doctor"
assert vscode_tasks["Workshop: Refresh"]["command"] == "workshop refresh snap-pi-hole"
assert vscode_tasks["Workshop: Context"]["command"] == "workshop run snap-pi-hole -- context"

expected_zed = {
    "Workshop: Doctor": ["run", "snap-pi-hole", "--", "doctor"],
    "Workshop: Launch": ["launch", "snap-pi-hole"],
    "Workshop: Refresh": ["refresh", "snap-pi-hole"],
    "Workshop: Context": ["run", "snap-pi-hole", "--", "context"],
}

for label, args in expected_zed.items():
    task = zed_tasks[label]
    assert task["command"] == "workshop"
    assert task["args"] == args
    assert task["cwd"] == "\$ZED_WORKTREE_ROOT"
PYEOF

    run git -C "${REPO_ROOT}" check-ignore .vscode/tasks.json
    [ "$status" -eq 1 ]
}

@test "local Workshop customization paths are ignored" {
    grep -qxF ".workshop-local/" "${REPO_ROOT}/.gitignore"
    grep -qxF "workshop.local.*" "${REPO_ROOT}/.gitignore"

    run git -C "${REPO_ROOT}" check-ignore .workshop-local/example.sh workshop.local.agents
    [ "$status" -eq 0 ]
}
