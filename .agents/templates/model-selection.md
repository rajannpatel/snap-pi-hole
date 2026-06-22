# Model Selection

Use this before delegating work across Architect, Implementer, Reviewer, and
Inline Assistant roles.

Follow `.agents/models/selection.md`.

Concrete model and surface assignments are YAML, not markdown:

- `.agents/models/selection.schema.yaml` defines the machine-readable contract.
- `.agents/models/selection.template.yaml` is the file an AI agent should copy
  into a prompt response or an ignored personal path before filling it.
- `.agents/models/selection.example.yaml` is the comprehensive example covering
  direct providers, OpenRouter, local runtimes, Zed, VS Code,
  Workshop terminal CLI/TUI, OpenCode terminal/TUI, OpenCode desktop, and
  inline assistants.

Filled personal inventories belong only in ignored files such as
`.agents/local/model-selection.yaml` or
`.agents/models/selection.personal.yaml`.

Do not inspect secrets or private provider configuration. Use only models and
surfaces the developer explicitly provides or that a visible model picker shows.

If availability is unknown, do not invent assignments. Use the current agent
for planning, implementation, and review, then ask the developer for their
available model list before the next delegated task.

## Developer-Supplied Inventory Prompt

Use this copy-paste prompt to create or update a local YAML model-selection
inventory. Before sending it, fill in the model access and per-surface model
lists from visible tools only. Use `.agents/local/model-selection.yaml` unless
there is a specific reason to choose another ignored local path.

```text
Create or update one local YAML model-selection inventory.

Output path:
- Use `.agents/local/model-selection.yaml` unless I explicitly provide a
  different path.
- Also acceptable when explicitly requested:
  - `.agents/models/selection.local.yaml`
  - `.agents/models/selection.personal.yaml`

Use this output path for this request: `.agents/local/model-selection.yaml`

I will provide model access and agent surface details below. Use only those
details. Do not discover model access from local configuration.

Read these checked-in files if they exist:
- `.agents/models/selection.md`
- `.agents/templates/model-selection.md`
- `.agents/models/selection.schema.yaml`
- `.agents/models/selection.template.yaml`

Use `.agents/models/selection.template.yaml` as the starting structure. Keep
the output YAML compatible with `.agents/models/selection.schema.yaml`.

Use YAML for concrete agent, model, and surface assignments. If a Markdown
summary is useful, draft it only as local notes under `.agents/local/`, and do
not replace the YAML assignment file with Markdown.

Populate the output only from the model access and agent surfaces I provide
below. Use exact provider names, model IDs, surface names, and availability
constraints from my lists. Do not invent providers, models, gateways, local
runtimes, editor surfaces, command permissions, or role assignments.

Do not inspect secrets, API keys, provider configuration, account files,
private settings, private gateway configuration, local runtime configuration,
or editor-specific tool permissions. Do not commit the generated inventory or
local notes.

If a required schema field or role assignment cannot be populated from the
details below, stop and ask me for the missing details instead of discovering
them from local configuration.

Role-selection rules:
- Architect: choose the strongest planning and deep-reasoning model available
  on a suitable surface.
- Implementer: choose a reliable coding model only on a surface whose shell
  commands are Workshop-routed.
- Reviewer: choose a strong reasoning and bug-finding model for a separate
  review pass.
- Inline assistant: choose an editor-native assistant for small human-steered
  edits.

Model availability rules:
- A model listed under one provider, gateway, runtime, or surface is not
  automatically available anywhere else.
- A model visible in a gateway is not automatically configured in an editor
  panel or terminal UI.
- For every assigned role, set `provider_or_gateway` to the provider, gateway,
  or runtime that launches that model on the selected surface. The same value
  must appear in the selected surface's `providers_or_gateways` list.
- If a surface does not show command routing or permission behavior, do not
  use that surface for Implementer.

Model access:
- Direct providers:
- Model gateways:
- Local/open-weight runtimes:

Assume these agent surfaces are available unless I say otherwise:
- Zed
- VS Code
- Inline assistant
- Workshop terminal CLI/TUI

Workshop terminal CLI/TUI command behavior is Workshop-routed by policy.

For each surface, list only the models available there:
- Zed:
- VS Code:
- Inline assistant:
- Workshop terminal CLI/TUI:
- OpenCode terminal/TUI:
- OpenCode desktop:

Assign:
- Architect
- Implementer
- Reviewer
- Inline assistant
```
