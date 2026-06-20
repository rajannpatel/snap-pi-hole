# Model Selection

Use this policy before delegating work across Architect, Implementer, Reviewer,
and Inline Assistant roles.

Repository files cannot determine which AI models are enabled in a developer's
IDE, provider account, model gateway, or local runtime. Agents must not read
secrets, API keys, or private provider configuration to infer model access.

Use only an explicit model list supplied by the developer, the IDE model
picker, an agent extension, an agent CLI, an inline assistant, a model gateway,
or a local runtime.

## Role Selection

| Role | Selection rule |
| --- | --- |
| Architect | Use the strongest planning and deep-reasoning model available. Prefer models suited to architecture, complex refactors, long-horizon debugging, and repository-level planning. |
| Implementer | Use a reliable coding model that follows narrow instructions cheaply and stops on blockers. |
| Reviewer | Use a strong reasoning model with good bug-finding behavior. It can be the same model class as Architect, but should run in a separate review pass. |
| Inline assistant | Use the editor-native completion/chat assistant for small local edits under human control. |

Suitable examples include Claude Opus/Sonnet-class models, GPT-5/o-series or
GPT coding-class models, Gemini Pro/Flash coding models, DeepSeek
coding/reasoning-class models, strong reasoning open-weights models, and
GitHub Copilot or editor-native inline assistants.

If model availability is unknown, do not invent assignments. Use the default
single-agent flow and ask the developer for their available model list before
delegating work to a lower-cost implementer.

Use `.agents/templates/model-selection.md` when writing concrete assignments.

## Personal Model Inventories

Shared model-selection policy belongs in this file and is committed. Personal
model inventories, filled assignment worksheets, provider notes, and local
agent configuration do not belong in the repository.

Provide available models in the prompt, or save local notes only under ignored
paths such as:

- `.agents/local/model-selection.md`
- `.agents/models/selection.local.md`
- `.agents/models/selection.personal.md`

Do not commit personal model choices, account-specific provider names, API
keys, private gateway URLs, local runtime endpoints, or tool-permission rules.
