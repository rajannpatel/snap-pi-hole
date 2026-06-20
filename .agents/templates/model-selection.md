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
