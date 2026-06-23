# Delegation Workflow

This repository supports a planner, implementer, and reviewer workflow for AI
assisted development. The goal is to let a high-reasoning model own design,
planning, and review while a lower-cost worker model performs narrowly scoped
implementation.

## Multi-Agent Enforcement

When the user requests this workflow, the current planning thread is the
Architect unless it is explicitly running as the selected Implementer. The
Architect produces the implementation packet and stops. It does not edit files,
run implementation commands, or substitute itself for the worker.

A Router thread is never the implementation thread. If the Router receives an
implementation-oriented follow-up after answering prior questions, it must hand
the request to the Architect and stop.

The Implementer must be a separate thread on the selected Implementer model,
provider or gateway, and Workshop-routed surface from the active
model-selection inventory. A platform sub-agent, nested agent, or same-model
worker is not a compliant replacement unless it is launched through that
configured Implementer provider or gateway on that configured surface.

If the selected Implementer is unavailable, out of credits, or cannot be
launched through its configured provider or gateway inside Workshop, the
Architect returns a blocker report and asks the developer whether to update
model selection, launch the Implementer later, or explicitly switch to
single-agent mode.

Role preflight and context checks are defined in
[../bootstrap.md](../bootstrap.md). Git mutation and push boundaries are
defined in [../policies/git-boundary.md](../policies/git-boundary.md).

## Operating Loop

1. Start an architect planning thread.
2. Give the architect model the request and ask it to use
   `.agents/roles/architect.md`.
3. The architect reads relevant files and produces an implementation packet
   using `.agents/templates/implementation-packet.md`, then stops.
4. Start a separate worker thread with the selected implementer model.
5. Give the worker only the implementation packet and
   `.agents/roles/implementer.md`.
6. The worker edits only the allowed files and runs only the listed commands.
7. Start a reviewer thread with the packet, the worker summary, and the current
   diff.
8. The reviewer uses `.agents/roles/reviewer.md`.
9. If fixes are needed, the reviewer writes a new small packet. Repeat from
   step 4.

## Panel Role Assignment

Zed Agent Panel and VS Code extension panels are native panel mode interfaces.
They may be assigned roles only within the Workshop confinement policy in
`.agents/security/workshop-confinement.md`.

| Role | Panel assignment |
| --- | --- |
| Architect | Yes. Panels are suitable for planning, reading code, and producing implementation packets. |
| Reviewer | Yes. Panels are suitable for diff review, scope review, and follow-up packets. |
| Implementer | Only if raw terminal tools are disabled, denied, or confirmation-gated so the panel can run only Workshop entry points. |
| Inline assistant | Yes, for small human-steered edits without autonomous terminal execution. |

For command-running implementation work, prefer Workshop terminal mode. Launch
the CLI, TUI, or terminal-thread agent from `tools/workshop-shell` or
`workshop run <project-alias> -- shell`.

If a panel cannot enforce Workshop-only shell commands, do not assign it the
Implementer role. Use it for Architect or Reviewer only, and hand the packet to
a terminal-backed implementer launched inside Workshop.

## Packet Size

Good packets usually touch one behavior and one test area:

- one shell runtime file plus one focused BATS file
- one snap hook plus its focused hook tests
- one dashboard JavaScript file plus JSDOM tests
- one Snapcraft metadata change plus schema or freshness tests
- one wiki update proposal, or maintainer-assigned wiki edit plus relevant
  wiki checks

Split work when it crosses unrelated areas, requires a design decision, or
needs packaging/runtime verification after source-level tests.

Use [verification.md](verification.md) when choosing packet checks.

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

## Failure Handling

If the worker hits a blocker, the architect should make one of three decisions:

- narrow the packet further
- add missing context to the packet
- take the task back into the architect model when the work requires more
  reasoning

Do not keep prompting a worker model after the same blocker repeats. That is a
planning failure, not an implementation failure.
