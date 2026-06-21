# Implementation Packet

## Task

One sentence describing the exact behavior or documentation change.

## Model Assignments

Use only when this packet is part of a multi-model workflow:

- Architect:
- Implementer:
- Reviewer:
- Inline assistant:

Handoff rule:

- The Architect stops after producing this packet.
- Only the selected Implementer may apply this packet.
- If the selected Implementer is unavailable, stop with a blocker report
  instead of applying the packet from the Architect or Reviewer thread.

## Scope

Allowed files:

- `path/to/file`

Forbidden paths:

- `parts/`
- `prime/`
- `stage/`
- `coverage/`
- `coverage-js/`
- `local-*`
- `tests/node_modules/`
- `.wiki/` unless this packet explicitly assigns wiki work

## Context

- Relevant current behavior:
- Relevant tests:
- Important project rule:
- Wiki documentation context, if needed: follow
  `.agents/docs/wiki-workflow.md`.

## Documentation Mode

Choose one when documentation is in scope:

- `read-only context`
- `wiki update proposal`
- `direct wiki edit`

Use `.agents/docs/wiki-workflow.md` for mode definitions.

## Implementation Constraints

- Do not expand the scope.
- Do not add dependencies.
- Do not redesign surrounding code.
- Do not perform broad mechanical formatting.
- Preserve unrelated user changes.
- Run project commands only through Workshop.
- Follow `.agents/security/workshop-confinement.md`.
- Follow `.agents/policies/scope-and-hygiene.md`.
- Do not apply this packet from the Architect or Reviewer thread unless the
  developer explicitly switches the task to single-agent mode.

## Required Commands

Before edits:

```bash
workshop run snap-pi-hole -- context
```

Focused verification:

```bash
workshop run snap-pi-hole -- test tests/unit/<file>.bats
```

Additional verification, if relevant:

```bash
workshop run snap-pi-hole -- lint
workshop run snap-pi-hole -- lint-js
workshop run snap-pi-hole -- test-jsdom
workshop run snap-pi-hole -- format-check
workshop run snap-pi-hole -- build
workshop run snap-pi-hole -- install
workshop run snap-pi-hole -- smoke
```

## Acceptance Criteria

- Observable result:
- Test result:
- No generated artifacts or unrelated files changed:
- Documentation result, if in scope:

## Stop Conditions

Stop and report a blocker if:

- the required files are missing
- the fix requires files outside the allowed scope
- Workshop is unavailable
- verification fails for unclear reasons
- the packet conflicts with `AGENTS.md`

## Worker Final Response Format

1. Files changed
2. Behavior changed
3. Commands run
4. Test results
5. Wiki proposal or wiki status, when documentation is in scope
6. Blockers or residual risks
