# Agentic Development Workflow

This repository supports a planner, implementer, and reviewer workflow for AI
assisted development. The goal is to let a high reasoning model own design,
planning, and review while a lower cost worker model performs narrowly scoped
implementation.

The workflow supports VS Code and Zed as first-class editor targets, with any
configured agent CLI, inline assistant, model gateway, or local model runtime.
It also preserves the repository rule that project tools run only through
Workshop.

## Model Selection

This repository cannot determine IDE model availability from static files.
Agents must use an explicit model list from the developer, the IDE model
picker, agent CLI, inline assistant, model gateway, or local runtime. Do not
read API keys or private provider configuration to infer access.

Use `.agents/templates/model-selection.md` when assigning models.

| Role | Selection rule | Suitable examples |
| --- | --- | --- |
| Architect | Use the strongest planning and deep-reasoning model available. | Claude Opus-class, GPT-5/o-series-class, Gemini Pro Deep Think-class, DeepSeek reasoning-class, Llama long-context-class |
| Implementer | Use a reliable coding model that can follow a narrow packet cheaply and stop on blockers. | Claude Sonnet-class, GPT coding-class, Gemini coding-class, DeepSeek coding/reasoning-class, other reliable OpenRouter workers |
| Reviewer | Use a strong reasoning model in a separate review pass. | Same tier as Architect, or the strongest available reviewer model |
| Inline assistant | Use the editor-native assistant for small local edits under human control. | GitHub Copilot or the IDE's inline model |

When model availability is unknown, do not invent assignments. Use the
single-agent flow and ask the developer for the models available in VS Code,
Zed, their agent CLI, inline assistant, model gateway, or local runtime.

## Model Roles

| Role | Recommended model | Responsibility |
| --- | --- | --- |
| Architect | selected high-reasoning model | Inspect the repo, make design decisions, and write one implementation packet. |
| Implementer | selected worker coding model | Apply the packet exactly, run listed Workshop checks, and stop. |
| Reviewer | selected high-reasoning reviewer | Review the diff, verify scope, run checks, and create any follow-up packet. |
| Inline assistant | selected IDE inline assistant | Help with small local edits while a human is steering. |

Do not ask the implementer to plan. Do not ask the reviewer to accept work
without reading the diff.

## Repository Rules

All agents must follow `AGENTS.md`.

- Run `workshop run snap-pi-hole -- context` before planning or editing.
- Run project verification only through `workshop run snap-pi-hole -- ...`.
- Use host `git` commands for Git operations.
- Keep generated artifacts out of commits unless explicitly assigned.
- Preserve unrelated user changes.

## Latest Documentation

The latest project documentation lives in the separate wiki repository that can
be cloned at `.wiki/`. A normal clone of the main repository does not create
`.wiki/`. That directory is gitignored in this repository, but when present it
is a full standalone checkout of `snap-pi-hole.wiki`.

Clone it only when documentation context is needed:

```bash
git clone https://github.com/rajannpatel/snap-pi-hole.wiki.git .wiki
```

Before any agent reads wiki content, it must run:

```bash
git -C .wiki pull --ff-only
```

Use `.wiki/` for current documentation context, especially for IDE setup,
agent integration, how-to guides, and user-facing docs.

Treat `.wiki/` as read-only by default. This avoids requiring every contributor
to fork, reconfigure, and keep a separate wiki remote fresh. Main repository
commits do not include `.wiki/` changes.

Documentation work has three modes:

| Mode | Use when | Output |
| --- | --- | --- |
| Read-only context | A code change needs current docs for planning or review. | Pull `.wiki/`, read it, and make no wiki edits. |
| Proposal | A contributor change should also update user-facing docs. | Return a wiki update proposal using `.agents/templates/wiki-update-proposal.md`. |
| Direct wiki edit | A maintainer explicitly asks for wiki edits and has wiki push access configured. | Edit `.wiki/`, run wiki checks, then commit and push from inside `.wiki/` separately. |

If the implementation packet does not specify a mode, use read-only context.
Agents must not silently create wiki commits.

## Editor Setup

Open this repository in VS Code or Zed from the same host, WSL, or Linux VM
environment where Workshop is installed.

VS Code:

1. The `Workshop: Open Check` task runs when the folder opens.
2. If Open Check fails, run `Workshop: Launch` or `Workshop: Refresh`, then
   run `Workshop: Doctor`.
3. Configure your agent CLI, inline assistant, model gateway, or local runtime
   according to your local extension or CLI setup.
4. Select the chosen implementer model for worker threads when using
   OpenRouter-backed agent execution.

Zed:

1. Run `task: spawn`, then `Workshop: Doctor`.
2. If Doctor fails, run `Workshop: Launch` or `Workshop: Refresh`, then
   rerun `Workshop: Doctor`.
3. Configure your agent CLI, inline assistant, model gateway, or local runtime
   according to your local Zed or CLI setup.
4. Select the chosen implementer model for worker threads when using
   OpenRouter-backed agent execution.

Use checked-in editor tasks for verification instead of writing shell commands
from memory. `.vscode/tasks.json` and `.zed/tasks.json` mirror the supported
Workshop actions.

## Operating Loop

1. Start an architect planning thread.
2. Give the architect model the request and ask it to use
   `.agents/roles/architect.md`.
3. The architect reads relevant files and produces an implementation packet
   using `.agents/templates/implementation-packet.md`.
4. Start a separate worker thread with the selected implementer model.
5. Give the worker only the implementation packet and
   `.agents/roles/implementer.md`.
6. The worker edits only the allowed files and runs only the listed commands.
7. Start a reviewer thread with the packet, the worker summary, and the current
   diff.
8. The reviewer uses `.agents/roles/reviewer.md`.
9. If fixes are needed, the reviewer writes a new small packet. Repeat from
   step 4.

## Packet Size

Good packets usually touch one behavior and one test area:

- one shell runtime file plus one focused BATS file
- one snap hook plus its focused hook tests
- one dashboard JavaScript file plus JSDOM tests
- one Snapcraft metadata change plus schema or freshness tests
- one wiki update proposal, or maintainer-assigned wiki edit plus relevant
  wiki checks

Split the task when it crosses unrelated areas, requires a design decision, or
needs packaging/runtime verification after source-level tests.

## Worker Guardrails

The worker prompt should start with:

```md
You are an implementation worker, not the planner.

Do exactly the task below. Do not expand scope. Do not redesign. Do not search
for unrelated improvements. If the task cannot be completed within the allowed
files and commands, stop and write a blocker report.
```

The worker final response must include:

1. Files changed
2. Behavior changed
3. Commands run
4. Test results
5. Wiki proposal or wiki status, when documentation is in scope
6. Blockers or residual risks

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

Use one branch per coherent change. Keep implementation commits separate from
mechanical formatting. Do not commit `.snap` files, coverage reports, local
dashboard previews, or `tests/node_modules/`.

Wiki edits are not part of the main repository branch. When direct wiki edits
are explicitly assigned, commit and push them from inside `.wiki/` as a separate
repository after the main change is reviewed.

## Failure Handling

If the worker hits a blocker, the architect should make one of three decisions:

- narrow the packet further
- add missing context to the packet
- take the task back into the architect model when the work requires more
  reasoning

Do not keep prompting a worker model after the same blocker repeats. That is a
planning failure, not an implementation failure.
