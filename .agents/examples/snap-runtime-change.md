# Example Packet: Snap Runtime Change

## Task

Make `snap/local/runtime/config-sync.sh` preserve an existing user-managed
comment when regenerating Pi-hole configuration.

## Scope

Allowed files:

- `snap/local/runtime/config-sync.sh`
- `tests/unit/config-sync.bats`

Forbidden paths:

- `parts/`
- `prime/`
- `stage/`
- `coverage/`
- `coverage-js/`
- `local-*`
- `tests/node_modules/`
- `.wiki/`

## Context

- Runtime shell changes should have focused BATS coverage.
- Keep shell style consistent with the existing file.
- Do not run BATS directly on the host.

## Implementation Constraints

- Do not change unrelated config sync behavior.
- Do not add dependencies.
- Preserve unrelated user changes.

## Required Commands

Before edits:

```bash
workshop run <project-alias> -- context
```

Verification:

```bash
workshop run <project-alias> -- test tests/unit/config-sync.bats
workshop run <project-alias> -- lint
```

## Acceptance Criteria

- The existing comment is preserved when the target config is regenerated.
- `tests/unit/config-sync.bats` covers the preservation case.
- The focused BATS test and lint pass.

## Stop Conditions

Stop if the fix requires changing snap hooks, Snapcraft metadata, or generated
build output.
