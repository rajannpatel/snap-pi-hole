# Implementation Packet

## Task

One sentence describing the exact behavior or documentation change.

## Model Assignments

Use only when this packet is part of a multi-model workflow:

- Architect:
- Implementer:
- Reviewer:
- Inline assistant:

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
- Wiki documentation context, if needed: `.wiki/` is not cloned automatically
  with the main repository. Clone `snap-pi-hole.wiki` into `.wiki/` only when
  wiki context is required, then run `git -C .wiki pull --ff-only` before
  reading `.wiki/`; treat `.wiki/` as read-only unless documentation mode is
  `direct wiki edit`.

## Documentation Mode

Choose one when documentation is in scope:

- `read-only context`: read current `.wiki/` content only.
- `wiki update proposal`: do not edit `.wiki/`; include proposed wiki changes
  in the final response.
- `direct wiki edit`: maintainer-only; edit listed `.wiki/` files and report
  separate `.wiki/` status.

## Implementation Constraints

- Do not expand the scope.
- Do not add dependencies.
- Do not redesign surrounding code.
- Do not perform broad mechanical formatting.
- Preserve unrelated user changes.
- Run project commands only through Workshop.

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
