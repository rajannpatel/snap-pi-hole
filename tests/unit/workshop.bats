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
    "shell",
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

@test "workshop shell action provides an interactive container shell" {
    python3 - <<PYEOF
import yaml

with open("${REPO_ROOT}/workshop.yaml") as f:
    shell = yaml.safe_load(f)["actions"]["shell"]

assert "set -euo pipefail" in shell
assert 'if [ "\$#" -gt 0 ]; then' in shell
assert 'exec "\$@"' in shell
assert "Workshop shell for snap-pi-hole" in shell
assert "exec bash --noprofile --norc -i" in shell
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
assert vscode_tasks["Workshop: Shell"]["command"] == "workshop run snap-pi-hole -- shell"

expected_zed = {
    "Workshop: Doctor": ["run", "snap-pi-hole", "--", "doctor"],
    "Workshop: Launch": ["launch", "snap-pi-hole"],
    "Workshop: Refresh": ["refresh", "snap-pi-hole"],
    "Workshop: Context": ["run", "snap-pi-hole", "--", "context"],
    "Workshop: Shell": ["run", "snap-pi-hole", "--", "shell"],
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

@test "editor settings do not commit personal agent mode preferences" {
    python3 - <<PYEOF
import json
from pathlib import Path

vscode = json.loads(Path("${REPO_ROOT}/.vscode/settings.json").read_text())
zed = json.loads(Path("${REPO_ROOT}/.zed/settings.json").read_text())

for key in vscode:
    assert not key.startswith("terminal.integrated."), key
    assert "tool_permissions" not in key, key

assert "terminal" not in zed
assert "agent" not in zed
PYEOF
}

@test "agent security docs define Workshop confinement policy" {
    python3 - <<PYEOF
from pathlib import Path

security_dir = Path("${REPO_ROOT}/.agents/security")
readme = security_dir / "README.md"
confinement = security_dir / "workshop-confinement.md"

assert readme.is_file(), readme
assert confinement.is_file(), confinement

readme_text = readme.read_text()
confinement_text = confinement.read_text()

for text in (readme_text, confinement_text):
    assert "Workshop" in text
    assert "personal" in text
    assert "not commit" in text or "not committed" in text

for required in (
    "Every shell command an AI agent runs for this project must enter Workshop.",
    "Workshop terminal mode",
    "Native panel mode",
    "tools/workshop-shell",
    "workshop run snap-pi-hole -- ...",
    "must not run arbitrary host shell commands",
):
    assert required in confinement_text, required
PYEOF
}

@test "agent shared policy docs exist and are linked from prompts" {
    python3 - <<PYEOF
from pathlib import Path

root = Path("${REPO_ROOT}")
required_docs = {
    ".agents/docs/wiki-workflow.md": [
        "Documentation Modes",
        "git -C .wiki pull --ff-only",
        "Wiki update proposal",
    ],
    ".agents/models/selection.md": [
        "Role Selection",
        "private provider configuration",
        "Separate model access from agent surfaces",
        "OpenRouter",
        "OpenCode terminal/TUI",
        "OpenCode desktop",
        "surface that can run commands safely through Workshop",
        "selection.template.yaml",
        "selection.example.yaml",
        ".agents/local/model-selection.md",
        ".agents/local/model-selection.yaml",
        "choose exactly one local output path",
        "must not invent providers, models, gateways, local",
        "stop and ask for the missing details",
        "Do not commit personal model choices",
    ],
    ".agents/workflows/delegation.md": [
        "Operating Loop",
        "Panel Role Assignment",
        "If a panel cannot enforce Workshop-only shell commands",
        "Worker Guardrails",
        "Failure Handling",
    ],
    ".agents/policies/scope-and-hygiene.md": [
        "Scope Control",
        "Generated And Local Files",
        "Preserve unrelated user changes",
    ],
}

for rel, needles in required_docs.items():
    path = root / rel
    assert path.is_file(), rel
    text = path.read_text()
    for needle in needles:
        assert needle in text, f"{rel} missing {needle!r}"

references = {
    ".agents/README.md": [
        "security/workshop-confinement.md",
        "models/selection.md",
        "docs/wiki-workflow.md",
        "workflows/delegation.md",
        "panel-role-assignment",
        "policies/scope-and-hygiene.md",
    ],
    ".agents/roles/architect.md": [
        ".agents/security/workshop-confinement.md",
        ".agents/docs/wiki-workflow.md",
        ".agents/models/selection.md",
        ".agents/policies/scope-and-hygiene.md",
        ".agents/workflows/delegation.md",
    ],
    ".agents/roles/implementer.md": [
        ".agents/security/workshop-confinement.md",
        ".agents/policies/scope-and-hygiene.md",
        ".agents/docs/wiki-workflow.md",
    ],
    ".agents/roles/reviewer.md": [
        ".agents/security/workshop-confinement.md",
        ".agents/policies/scope-and-hygiene.md",
        ".agents/docs/wiki-workflow.md",
    ],
    ".agents/templates/implementation-packet.md": [
        ".agents/security/workshop-confinement.md",
        ".agents/policies/scope-and-hygiene.md",
        ".agents/docs/wiki-workflow.md",
    ],
    ".agents/templates/model-selection.md": [
        ".agents/models/selection.md",
        "selection.schema.yaml",
        "selection.template.yaml",
        "selection.example.yaml",
        "Developer-Supplied Inventory Prompt",
        "Choose exactly one",
        ".agents/models/selection.local.yaml",
        ".agents/models/selection.personal.yaml",
        "Do not invent providers, models, gateways, local",
        "stop and ask me for the missing details",
        "OpenRouter",
        "Workshop terminal CLI/TUI",
        "OpenCode terminal/TUI",
        "OpenCode desktop",
        ".agents/local/model-selection.yaml",
    ],
}

for rel, needles in references.items():
    text = (root / rel).read_text()
    for needle in needles:
        assert needle in text, f"{rel} missing reference {needle!r}"
PYEOF
}

@test "agent model selection YAML files define a validated assignment contract" {
    python3 - <<PYEOF
from pathlib import Path
import re
import yaml

root = Path("${REPO_ROOT}")
schema = yaml.safe_load((root / ".agents/models/selection.schema.yaml").read_text())
template = yaml.safe_load((root / ".agents/models/selection.template.yaml").read_text())
example = yaml.safe_load((root / ".agents/models/selection.example.yaml").read_text())

assert schema["kind"] == "agent-model-selection-schema"
assert template["kind"] == "agent-model-selection"
assert example["kind"] == "agent-model-selection"
assert schema["schema_version"] == template["schema_version"] == example["schema_version"] == 1

assert schema["allowed_inventory_output_paths"] == [
    ".agents/local/model-selection.yaml",
    ".agents/models/selection.local.yaml",
    ".agents/models/selection.personal.yaml",
]
generation_rules = schema["generation_rules"]
assert generation_rules["choose_exactly_one_output_path"] is True
assert generation_rules["use_template_as_starting_structure"] == ".agents/models/selection.template.yaml"
assert generation_rules["validate_against_schema"] == ".agents/models/selection.schema.yaml"
assert generation_rules["populate_only_from_user_supplied_model_access_and_surfaces"] is True
assert generation_rules["preserve_exact_provider_model_surface_names"] is True
assert {
    "providers",
    "models",
    "gateways",
    "local_runtimes",
    "editor_surfaces",
    "command_permissions",
    "role_assignments",
}.issubset(generation_rules["do_not_invent"])
assert {
    "required_schema_field",
    "role_assignment",
    "command_routing_or_permission_behavior",
}.issubset(generation_rules["stop_and_ask_if_missing"])
assert {
    "secrets",
    "api_keys",
    "provider_configuration",
    "account_files",
    "private_settings",
    "private_gateway_configuration",
    "local_runtime_configuration",
    "editor_specific_tool_permissions",
}.issubset(generation_rules["do_not_inspect"])

for top_level in schema["required_top_level"]:
    assert top_level in template, f"template missing {top_level}"
    assert top_level in example, f"example missing {top_level}"

roles = set(schema["roles"])
assert roles == set(template["assignments"]), template["assignments"].keys()
assert roles == set(example["assignments"]), example["assignments"].keys()

for group in schema["model_access_groups"]:
    assert group in template["model_access"], group
    assert group in example["model_access"], group

allowed_surface_types = set(schema["surface_types"])
allowed_modes = set(schema["command_execution_modes"])

def assert_surface_shape(doc, *, allow_empty_models):
    surfaces = doc["agent_surfaces"]
    ids = [surface["id"] for surface in surfaces]
    assert len(ids) == len(set(ids)), ids
    assert {
        "zed_agent_panel",
        "vscode_extension_panel",
        "workshop_terminal_cli_tui",
        "opencode_terminal_tui",
        "opencode_desktop",
        "inline_assistant",
    }.issubset(ids), ids

    for surface in surfaces:
        assert surface["type"] in allowed_surface_types, surface
        assert isinstance(surface["providers_or_gateways"], list), surface
        assert isinstance(surface["models"], list), surface
        if not allow_empty_models:
            assert surface["models"], surface["id"]
        command = surface["command_execution"]
        assert isinstance(command["can_run_shell"], bool), surface["id"]
        assert isinstance(command["workshop_routed"], bool), surface["id"]
        assert command["mode"] in allowed_modes, surface["id"]
        assert isinstance(command["allowed_entrypoints"], list), surface["id"]

assert_surface_shape(template, allow_empty_models=True)
assert_surface_shape(example, allow_empty_models=False)

surface_by_id = {surface["id"]: surface for surface in example["agent_surfaces"]}
implementer = example["assignments"]["implementer"]
implementer_surface = surface_by_id[implementer["surface_id"]]
safe = schema["safe_implementer_surface"]

assert implementer_surface["command_execution"]["can_run_shell"] == safe["requires"]["can_run_shell"]
assert implementer_surface["command_execution"]["workshop_routed"] == safe["requires"]["workshop_routed"]
assert implementer_surface["command_execution"]["mode"] in safe["allowed_modes"]
assert set(implementer_surface["command_execution"]["allowed_entrypoints"]) & set(safe["allowed_entrypoints"])

for role, assignment in example["assignments"].items():
    assert assignment["surface_id"] in surface_by_id, role
    assert assignment["model"], role
    surface = surface_by_id[assignment["surface_id"]]
    assert assignment["model"] in surface["models"], role

assert implementer["surface_id"] != "opencode_desktop"
assert surface_by_id["opencode_desktop"]["command_execution"]["workshop_routed"] is False
assert surface_by_id["opencode_desktop"]["command_execution"]["mode"] == "unknown"
assert "OpenRouter" in [gateway["name"] for gateway in example["model_access"]["gateways"]]
assert "OpenRouter" not in surface_by_id["vscode_extension_panel"]["providers_or_gateways"]

for surface_id in ("workshop_terminal_cli_tui", "opencode_terminal_tui"):
    command = surface_by_id[surface_id]["command_execution"]
    assert command["workshop_routed"] is True
    assert "tools/workshop-shell" in command["allowed_entrypoints"]

for surface_id in ("zed_agent_panel", "vscode_extension_panel"):
    surface = surface_by_id[surface_id]
    assert surface["type"] == "native_panel"
    if surface_id == "vscode_extension_panel":
        assert surface["command_execution"]["mode"] == "disabled"
    else:
        assert surface["command_execution"]["mode"] == "confirmation_gated"

assert schema["forbidden_committed_fields"], "schema must define forbidden fields"

for doc_name, doc in {"template": template, "example": example}.items():
    dumped = yaml.safe_dump(doc)
    for forbidden in schema["forbidden_committed_fields"]:
        assert forbidden not in dumped.lower(), f"{doc_name} contains {forbidden}"
    assert not re.search(r"(?i)(api[_-]?key|bearer\\s+[a-z0-9._-]+)", dumped), doc_name
PYEOF
}

@test "workshop-shell routes ad hoc commands through Workshop" {
    shell="${REPO_ROOT}/tools/workshop-shell"
    [ -x "${shell}" ]

    run bash -n "${shell}"
    [ "$status" -eq 0 ]

    grep -qF 'workshop run "${project}" -- shell' "${shell}"
    grep -qF 'run_command "${1:-}"' "${shell}"
    grep -qF 'workshop\ run\ "${project}"\ --*' "${shell}"
}

@test "local Workshop customization paths are ignored" {
    grep -qxF ".workshop-local/" "${REPO_ROOT}/.gitignore"
    grep -qxF "workshop.local.*" "${REPO_ROOT}/.gitignore"

    run git -C "${REPO_ROOT}" check-ignore .workshop-local/example.sh workshop.local.agents
    [ "$status" -eq 0 ]
}

@test "personal agent model configuration paths are ignored" {
    grep -qxF ".agents/local/" "${REPO_ROOT}/.gitignore"
    grep -qxF ".agents/**/*.local.md" "${REPO_ROOT}/.gitignore"
    grep -qxF ".agents/**/*.personal.md" "${REPO_ROOT}/.gitignore"
    grep -qxF ".agents/**/*.local.yaml" "${REPO_ROOT}/.gitignore"
    grep -qxF ".agents/**/*.personal.yaml" "${REPO_ROOT}/.gitignore"
    grep -qxF ".agents/**/*.local.yml" "${REPO_ROOT}/.gitignore"
    grep -qxF ".agents/**/*.personal.yml" "${REPO_ROOT}/.gitignore"

    run git -C "${REPO_ROOT}" check-ignore \
        .agents/local/model-selection.md \
        .agents/local/model-selection.yaml \
        .agents/models/selection.local.md \
        .agents/models/selection.personal.md \
        .agents/models/selection.local.yaml \
        .agents/models/selection.personal.yaml
    [ "$status" -eq 0 ]
}
