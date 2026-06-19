# Model Selection

Use this before delegating work across Architect, Implementer, Reviewer, and
Inline Assistant roles.

## Available Models

List only models the developer explicitly says are available or that the IDE
model picker/provider UI exposes. Do not inspect secrets or private provider
configuration.

- VS Code:
- Zed:
- Agent CLI:
- Inline assistant:
- Model gateway:
- Local/open-weights:

## Assignments

| Role | Selected model | Reason |
| --- | --- | --- |
| Architect |  | Strongest available planning and deep-reasoning model. |
| Implementer |  | Reliable coding model for narrow implementation packets. |
| Reviewer |  | Strong reasoning model for independent review. |
| Inline assistant |  | IDE-native completion/chat model for human-steered edits. |

## Fallback

If model availability is unknown, do not delegate to a worker model. Use the
current agent for planning, implementation, and review, then ask the developer
for their available model list before the next delegated task.
