---
name: model-discovery
description: Discover available AI model inventories from Workshop-installed CLI providers such as agy, copilot, and kiro-cli, then guide the user through reviewing and optionally overwriting .agents/local/model-selection.yaml.
---

# Model Discovery Skill

Use this skill to discover AI models exposed by CLI providers that are reachable
from the snap-pi-hole Workshop container. The generated inventory is reviewed
against the current `.agents/local/model-selection.yaml` and is written only
after an explicit default-no confirmation prompt.

## Workshop Boundary

Run discovery only inside Workshop. Do not invoke provider CLIs directly on the
host.

```bash
workshop run snap-pi-hole -- shell
# inside the Workshop shell:
bash .agents/skills/model-discovery/discover.sh
```

The script refuses to run when the expected Workshop shell context is missing.

## Behavior

`discover.sh` runs all executable provider adapters in
`.agents/skills/model-discovery/providers/`, deduplicates discovered
provider/model pairs, prints models grouped by provider, renders a candidate
configuration by starting from `.agents/models/selection.template.yaml`,
validates it against `.agents/models/selection.schema.yaml`, and compares it
with the current local config. Validation happens before prompting and before
any write.

CLI tools such as `agy`, `copilot`, and `kiro-cli` are recorded under
`model_access.gateways` because they broker model access through command-line
tools rather than exposing direct provider APIs. The generated config populates
only the `workshop_terminal_cli_tui` surface from discovered CLI inventory and
leaves non-discovered surfaces at template defaults.

The script prompts exactly:

```text
Apply discovered config to .agents/local/model-selection.yaml? [y/N]
```

Only `y`, `Y`, or `yes` writes the validated candidate file. Empty input and
all other responses leave the current config unchanged. Writes use a temporary
file followed by an atomic move into `.agents/local/model-selection.yaml`.

## Provider Adapter Contract

Provider adapters are executable shell scripts. Each adapter prints one model
per line to stdout using this tab-delimited format:

```text
provider<TAB>model<TAB>label
```

The label field is optional; `discover.sh` keys and deduplicates on the first
two fields, `provider` and `model`.

Adapters should print concise warnings to stderr and exit successfully when
their CLI is missing or cannot expose a supported model-list command. One
adapter failure should not fail the entire discovery flow unless no provider
models are discovered.

Adapters must keep external provider CLI calls timeout-bounded, either by
wrapping the calls directly or by relying on the timeout behavior implemented in
the adapter. A hung or slow provider CLI should produce a warning or non-fatal
adapter failure, not leave discovery stuck indefinitely.

The included adapters probe:

- `agy`: runs `agy models`
- `copilot`: runs `copilot --help`, detects a supported model-list command,
  then runs it
- `kiro-cli`: runs `kiro-cli --help`, detects a supported model-list command,
  then runs it

## Adding Providers

Add a new executable script under:

```text
.agents/skills/model-discovery/providers/
```

Example:

```bash
#!/usr/bin/env bash
set -euo pipefail

if ! command -v my-cli >/dev/null 2>&1; then
  printf 'model-discovery: warning: my-cli not found\n' >&2
  exit 0
fi

my-cli models | awk 'NF { print "my-cli\t" $0 }'
```

Keep generated YAML compliant with
`.agents/models/selection.template.yaml` and
`.agents/models/selection.schema.yaml`. Discovery treats CLI aggregators as
`model_access.gateways`, populates only the Workshop terminal CLI/TUI inventory,
and preserves existing role assignments only when their provider/model pair is
still discovered. Otherwise, assignment `surface_id`, `model`, and
`provider_or_gateway` fields remain at the template defaults.
