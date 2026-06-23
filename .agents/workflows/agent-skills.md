# Agent Skills

This repository exposes a small set of repo-local slash-command workflows for
agent sessions. They are prompts, not Workshop actions. They do not replace the
role bootstrap, Workshop confinement, or verification matrix in `AGENTS.md`.

Slash-command definitions live in `.claude/commands/`:

- `/tdd`: `.claude/commands/tdd.md`
- `/grill-with-docs`: `.claude/commands/grill-with-docs.md`
- `/diagnose`: `.claude/commands/diagnose.md`

## Shared Rules

These workflows must preserve these repository rules:

- Run `agent-role <role>` and `context` before planning, editing, reviewing, or
  running checks.
- Run project shell commands through Workshop, usually with:

  ```bash
  tools/workshop-shell -c 'workshop run <project-alias> -- <action>'
  ```

- Follow the Router, Architect, Implementer, and Reviewer boundaries in
  `.agents/roles/`.
- Use named Workshop actions from `.agents/commands.md` whenever possible.
- Preserve generated-artifact, secret-handling, and Git-push boundaries from
  `AGENTS.md`.

## `/tdd`

Use `/tdd` for a narrow red-green-refactor loop.

Expected behavior:

- identify the smallest testable behavior
- write or update one focused failing test first
- run focused tests through Workshop
- implement only enough to pass
- refactor only after the focused test passes
- finish with the relevant verification from
  `.agents/workflows/verification.md`

## `/grill-with-docs`

Use `/grill-with-docs` to challenge a proposal or explanation against the
repository's documented constraints.

Expected behavior:

- read `AGENTS.md` and the relevant linked docs first
- distinguish documented facts from assumptions
- ask pointed questions where the proposal conflicts with policy or lacks
  acceptance criteria
- require Workshop-routed verification for claims involving project commands
- recommend the smallest next role, question, check, or change

## `/diagnose`

Use `/diagnose` for failure triage.

Expected behavior:

- reproduce with the narrowest Workshop-routed command
- capture the exact command and failure
- classify the likely affected area
- inspect only the files needed to explain the failure
- propose the narrowest next check, fix, or role handoff
- avoid broad rewrites and unrelated cleanup
