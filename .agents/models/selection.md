# Model Selection

Use this policy before delegating work across Architect, Implementer, Reviewer,
and Inline Assistant roles.

Repository files cannot determine which AI models are enabled in a developer's
IDE, provider account, model gateway, or local runtime. Agents must not read
secrets, API keys, or private provider configuration to infer model access.

Use only explicit information supplied by the developer from the IDE model
picker, an agent extension, an agent CLI, an inline assistant, a model gateway,
or a local runtime.

Separate model access from agent surfaces:

- **Model access** identifies which providers, gateways, or local runtimes are
  available, such as Anthropic, GitHub Copilot, OpenRouter, or local
  open-weights runtimes.
- **Agent surfaces** identify where those models can be used, such as Zed
  Agent Panel, VS Code Copilot Chat, a Workshop terminal CLI, an inline
  assistant, OpenCode terminal/TUI, OpenCode desktop, or another integration.

Do not assume that a model visible in one surface is available in another
surface. A gateway such as OpenRouter may expose many models, but each editor
panel, extension, CLI, or TUI still needs to be configured to use that gateway.

For every non-null role assignment, `provider_or_gateway` must identify the
direct provider, gateway, or runtime that launches that model on the selected
surface. The same value must appear in the selected surface's
`providers_or_gateways` list. A model name and Workshop-routed surface are not
enough for delegation if the provider or gateway is ambiguous.

## Role Selection

| Role | Selection rule |
| --- | --- |
- Architect: Use the strongest planning and deep-reasoning model available on a suitable surface. Prefer models suited to architecture, complex refactors, long-horizon debugging, and repository-level planning. `workshop_routed: true` is required.
- Implementer: Use a reliable coding model on a surface that can run commands safely through Workshop. The selected model must have an explicit provider or gateway on that same surface. The model must follow narrow instructions and stop on blockers. `workshop_routed: true` is required.
- Reviewer: Use a strong reasoning model with good bug-finding behavior. It can be the same model class as Architect, but should run in a separate review pass. `workshop_routed: true` is required.
| Inline assistant | Use the editor-native completion/chat assistant for small local edits under human control. |

Suitable examples include Claude Opus/Sonnet-class models, GPT-5/o-series or
GPT coding-class models, Gemini Pro/Flash coding models, DeepSeek
coding/reasoning-class models, strong reasoning open-weights models, and
GitHub Copilot or editor-native inline assistants.

If model availability is unknown, do not invent assignments. Use the default
single-agent flow and ask the developer for their available model list before
delegating work to a lower-cost implementer.

If the selected Implementer is unavailable, out of credits, or cannot be
launched through its configured provider or gateway on a Workshop-routed command
surface, delegated implementation is blocked. Do not silently fall back to the
Architect, Reviewer, native panel, or a generic platform sub-agent. Ask the
developer whether to update the local model-selection inventory, launch the
Implementer later, or explicitly switch the task to single-agent mode.

If the strongest available model is only accessible through a native panel that
cannot enforce Workshop-only shell commands, use it for Architect or Reviewer,
not Implementer. Hand implementation to a terminal-backed agent launched inside
Workshop.

OpenCode and similar tools are agent surfaces. Treat OpenCode terminal/TUI as a
Workshop terminal surface only when it is launched from `tools/workshop-shell`
or `workshop run <project-alias> -- shell`. Treat OpenCode desktop like native
panel mode unless its shell/tool execution is confirmed to route through
Workshop.

Use `.agents/models/selection.template.yaml` when generating concrete
assignments, and compare against `.agents/models/selection.example.yaml` for a
comprehensive example. The markdown template at
`.agents/templates/model-selection.md` is only a human prompt note for this YAML
workflow.

When asking an agent to create a personal model-selection inventory, use the
copy-paste prompt in `.agents/templates/model-selection.md`. Use
`.agents/local/model-selection.yaml` by default. Use an alternate local path
only when the developer explicitly requests one:

- `.agents/local/model-selection.yaml`
- `.agents/models/selection.local.yaml`
- `.agents/models/selection.personal.yaml`

The agent must populate the YAML only from model access and agent surfaces the
developer supplies. It must not invent providers, models, gateways, local
runtimes, editor surfaces, command permissions, or role assignments. If a
required schema field or role assignment cannot be populated from the supplied
details, stop and ask for the missing details instead of inspecting local
configuration.

When a model is supplied for a surface, also record which provider, gateway, or
runtime exposes it on that surface. Use `provider_or_gateway: null` only for
surface-agnostic roles or unassigned roles.

For inventory prompts, Zed, VS Code, Inline assistant, and Workshop terminal
CLI/TUI may be treated as available surfaces unless the developer says
otherwise. Workshop terminal CLI/TUI command behavior is Workshop-routed by
policy. These assumptions do not imply model availability: list and use only
the models the developer provides for each surface.

## Personal Model Inventories

Shared model-selection policy belongs in this file and is committed. Personal
model inventories, surface capability maps, filled assignment worksheets,
provider notes, and local agent configuration do not belong in the repository.

Provide available models in the prompt, or save local notes only under ignored
paths such as:

- `.agents/local/model-selection.md`
- `.agents/local/model-selection.yaml`
- `.agents/models/selection.local.md`
- `.agents/models/selection.personal.md`
- `.agents/models/selection.local.yaml`
- `.agents/models/selection.personal.yaml`

Do not commit personal model choices, account-specific provider names, API
keys, private gateway URLs, local runtime endpoints, or tool-permission rules.
