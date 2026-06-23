# Agentic Development Workflow

This repository supports Router, Architect, Implementer, and Reviewer roles for
AI-assisted development. The goal is to let a high-reasoning model own design,
planning, and review while a lower-cost worker model performs narrowly scoped
implementation.

All agents must follow the root [AGENTS.md](../AGENTS.md). It is the bootstrap
and hard-policy index for this repository.

## Start Here

- [Role bootstrap](bootstrap.md): role assignment, required `agent-role`
  preflight, required `context`, and Workshop launch caveats.
- [Workshop confinement](security/workshop-confinement.md): the mandatory
  Workshop execution boundary and agent UI modes.
- [Commands](commands.md): canonical Workshop actions and lower-level command
  references.
- [Verification](workflows/verification.md): standard loops and area-specific
  verification matrix.
- [Git boundary](policies/git-boundary.md): Git inspection, commits/tags, and
  the no-Workshop-push rule.
- [Scope and hygiene](policies/scope-and-hygiene.md): scope control,
  generated artifacts, and user changes.

## Roles

| Role | Responsibility |
| --- | --- |
| [Router](roles/router.md) | Receive unstructured requests, answer read-only repository questions directly, route verification-only requests, coordinate manual handoffs, and hand implementation-oriented work to the Architect. |
| [Architect](roles/architect.md) | Inspect the repo, make design decisions, and write one implementation packet. |
| [Implementer](roles/implementer.md) | Apply the packet exactly, run listed Workshop checks, and stop. |
| [Reviewer](roles/reviewer.md) | Review the diff, verify scope, run checks, and create any follow-up packet. |
| Inline assistant | Help with small local edits while a human is steering. |

Do not ask the Implementer to plan. Do not ask the Reviewer to accept work
without reading the diff.

## Workflows

- [Delegation workflow](workflows/delegation.md): multi-agent enforcement,
  operating loop, panel role assignment, packet size, and failure handling.
- [Editor preflight](workflows/editor-preflight.md): VS Code and Zed Workshop
  readiness checks.
- [Agent skills](workflows/agent-skills.md): repo-local slash-command workflows
  for `/tdd`, `/grill-with-docs`, and `/diagnose`.
- [Wiki workflow](docs/wiki-workflow.md): documentation modes and wiki-specific
  checks.
- [Model selection](models/selection.md): model and surface assignment.

Use [templates/role-launch-prompts.md](templates/role-launch-prompts.md) for
minimal role prompts and [templates/implementation-packet.md](templates/implementation-packet.md)
for implementation packets.

## Reusable Policy Modules

The following modules are intended to be reusable by other Workshop-backed
projects with project names and action lists adjusted:

- [bootstrap.md](bootstrap.md)
- [commands.md](commands.md)
- [policies/git-boundary.md](policies/git-boundary.md)
- [policies/formatting.md](policies/formatting.md)
- [policies/scope-and-hygiene.md](policies/scope-and-hygiene.md)
- [security/workshop-confinement.md](security/workshop-confinement.md)
- [workflows/delegation.md](workflows/delegation.md)
- [workflows/editor-preflight.md](workflows/editor-preflight.md)
- [workflows/verification.md](workflows/verification.md)
