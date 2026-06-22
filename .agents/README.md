# Agentic Development Workflow

This repository supports an architect, planner, implementer, and reviewer workflow for AI
assisted development. The goal is to let a high reasoning model own design,
planning, and review while a lower cost worker model performs narrowly scoped
implementation.

The workflow supports VS Code and Zed as first-class editor targets, with any
configured agent CLI, inline assistant, model gateway, or local model runtime.
Users choose one of two agent UI modes in personal editor or agent preferences
that are not committed. Both modes share the same execution policy: every shell
command an agent runs for this project must enter Workshop. See
[security/workshop-confinement.md](security/workshop-confinement.md).

## Model Selection

Follow [models/selection.md](models/selection.md). Use
`.agents/templates/model-selection.md` when assigning concrete models.

## Model Roles

| Role | Recommended model | Responsibility |
| --- | --- | --- |
| Architect | selected high-reasoning model | Inspect the repo, make design decisions, and write one implementation packet. |
| Implementer | selected worker coding model | Apply the packet exactly, run listed Workshop checks, and stop. |
| Reviewer | selected high-reasoning reviewer | Review the diff, verify scope, run checks, and create any follow-up packet. |
| Inline assistant | selected IDE inline assistant | Help with small local edits while a human is steering. |

Do not ask the implementer to plan. Do not ask the reviewer to accept work
without reading the diff.

For Zed Agent Panel and VS Code extension panel role assignments, follow
[workflows/delegation.md#panel-role-assignment](workflows/delegation.md#panel-role-assignment).

## Multi-Agent Enforcement

When the user requests the repository multi-agent workflow, the planning thread
is the Architect by default. The Architect writes one implementation packet and
then stops. It must not apply the packet, edit project files, or substitute its
own command-running tools for the selected Implementer.

Implementation starts only in a separate thread on the selected Implementer
surface from the local model-selection inventory. A platform sub-agent or
same-model worker is not a replacement for that Implementer unless it is
running on the configured Implementer model and Workshop-routed surface.

If the selected Implementer is unavailable, out of credits, or cannot be
launched through Workshop, delegation is blocked. Ask the developer whether to
update `.agents/local/model-selection.yaml`, launch the Implementer later, or
explicitly switch the task to single-agent mode.

## Repository Rules

All agents must follow `AGENTS.md`.

- Identify agent role at launch, run `workshop run snap-pi-hole -- agent-role <role>` preflight verification, and run `workshop run snap-pi-hole -- context` before planning or editing.
- Choose Workshop terminal mode or native panel mode in uncommitted personal
  preferences before starting agent work, following
  `.agents/security/workshop-confinement.md`.
- Run terminal-backed agent sessions from `tools/workshop-shell` when using
  Workshop terminal mode.
- Run project verification only through `workshop run snap-pi-hole -- ...`.
- Keep AI agent shell commands inside Workshop. Host-side Git mutation is a
  maintainer operation unless explicitly assigned.
- Follow `.agents/policies/scope-and-hygiene.md`.
- Preserve unrelated user changes.

## Latest Documentation

Follow [docs/wiki-workflow.md](docs/wiki-workflow.md). Use
`.agents/templates/wiki-update-proposal.md` when documentation changes should
be proposed but not applied directly.

## Editor Setup

Open this repository in VS Code or Zed from the same host, WSL, or Linux VM
environment where Workshop is installed.

VS Code:

1. The `Workshop: Open Check` task runs when the folder opens.
2. If Open Check fails, run `Workshop: Launch` or `Workshop: Refresh`, then
   run `Workshop: Doctor`.
3. Choose Workshop terminal mode or native panel mode in personal preferences.
4. Configure your personal terminal profile to use `tools/workshop-shell`, or
   run `Workshop: Shell`, before starting terminal-backed agents.
5. Configure your agent CLI, inline assistant, model gateway, or local runtime
   according to your local extension or CLI setup.
6. Select the chosen implementer model for worker threads when using
   OpenRouter-backed agent execution.

Zed:

1. Run `task: spawn`, then `Workshop: Doctor`.
2. If Doctor fails, run `Workshop: Launch` or `Workshop: Refresh`, then
   rerun `Workshop: Doctor`.
3. Choose Workshop terminal mode or native panel mode in personal preferences.
4. Configure your personal Zed terminal shell to use `tools/workshop-shell`, or
   run `Workshop: Shell`, before starting terminal-backed agents.
5. Configure your agent CLI, inline assistant, model gateway, or local runtime
   according to your local Zed or CLI setup.
6. Select the chosen implementer model for worker threads when using
   OpenRouter-backed agent execution.

Use checked-in editor tasks for verification instead of writing shell commands
from memory. `.vscode/tasks.json` and `.zed/tasks.json` mirror the supported
Workshop actions.

Zed native Agent Panel tools and VS Code extension tools can have their own
permission and execution paths. The allow, deny, and confirm rules for those
tools are personal preferences. Keep them out of the repository. Do not allow
native panel tools to run arbitrary host shell commands for this project.

## Operating Loop

Follow [workflows/delegation.md](workflows/delegation.md).

## Packet Size

See [workflows/delegation.md](workflows/delegation.md).

## Worker Guardrails

See [workflows/delegation.md](workflows/delegation.md) and
[policies/scope-and-hygiene.md](policies/scope-and-hygiene.md).

## Verification Matrix

| Change type | Narrow verification | Broader verification |
| --- | --- | --- |
| Shell runtime or testing helper | `workshop run snap-pi-hole -- test tests/unit/<file>.bats` | `workshop run snap-pi-hole -- lint` |
| Snap hook | `workshop run snap-pi-hole -- test tests/unit/hooks.bats` | `workshop run snap-pi-hole -- lint` |
| Snapcraft metadata | `workshop run snap-pi-hole -- test tests/unit/snapcraft-schema.bats` | `workshop run snap-pi-hole -- build` |
| Dashboard JavaScript | `workshop run snap-pi-hole -- deps-js` and `workshop run snap-pi-hole -- test-jsdom` | `workshop run snap-pi-hole -- lint-js` and `workshop run snap-pi-hole -- format-check` |
| Snap runtime behavior | focused BATS test | `workshop run snap-pi-hole -- build`, `install`, and `smoke` |
| Wiki context only | `git -C .wiki pull --ff-only` | no wiki edits |
| Wiki update proposal | review proposal against current `.wiki/` content | no wiki commit |
| Direct wiki edit | `git -C .wiki status --short` and relevant `.wiki/.hooks` checks | separate `.wiki/` commit and push |

## Branch Discipline

Use one branch per coherent change. Follow
[policies/scope-and-hygiene.md](policies/scope-and-hygiene.md).

Wiki edits are not part of the main repository branch. When direct wiki edits
are explicitly assigned, commit and push them from inside `.wiki/` as a separate
repository after the main change is reviewed.

## Failure Handling

See [workflows/delegation.md](workflows/delegation.md).
