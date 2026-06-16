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

@test "workshop.yaml exposes the expected contributor actions" {
    python3 - <<PYEOF
import yaml

with open("${REPO_ROOT}/workshop.yaml") as f:
    doc = yaml.safe_load(f)

expected = {
    "doctor",
    "context",
    "lint",
    "shellcheck",
    "yamllint",
    "test",
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
    "snapcraft",
    "bats",
    "shellcheck",
    "yamllint",
    "yq",
    "pre-commit",
    "kcov",
    "node",
    "dig",
}
declared = set(re.findall(r"^\\s*command -v ([A-Za-z0-9_.+-]+)\\s*$", doctor, re.MULTILINE))
missing = sorted(required - declared)
assert not missing, f"doctor is missing command checks for: {missing}"

for action_name in ("context", "shellcheck", "yamllint", "test", "coverage", "build", "install", "smoke"):
    assert action_name in actions, f"missing action: {action_name}"
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

@test "workshop install action uses shell globbing instead of parsing ls" {
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

@test "local Workshop customization paths are ignored" {
    grep -qxF ".workshop-local/" "${REPO_ROOT}/.gitignore"
    grep -qxF "workshop.local.*" "${REPO_ROOT}/.gitignore"

    run git -C "${REPO_ROOT}" check-ignore .workshop-local/example.sh workshop.local.agents
    [ "$status" -eq 0 ]
}
