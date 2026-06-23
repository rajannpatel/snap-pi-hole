# Example Packet: Dashboard JavaScript Change

## Task

Update the dashboard channel switch UI to show a stable fallback label when the
current channel is missing from generated data.

## Scope

Allowed files:

- `snap/local/assets/dashboard-channel-switch.js`
- `tests/dashboard-logic-tests.spec.js`

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

- JavaScript formatting is owned by Prettier.
- Use repo-local test commands through Workshop.
- Do not run `npm`, `node`, `npx`, or Prettier directly on the host.

## Implementation Constraints

- Do not change generated dashboard data.
- Do not redesign the channel switch UI.
- Do not add dependencies.

## Required Commands

Before edits:

```bash
workshop run <project-alias> -- context
```

Verification:

```bash
workshop run <project-alias> -- deps-js
workshop run <project-alias> -- test-jsdom
workshop run <project-alias> -- lint-js
workshop run <project-alias> -- format-check
```

## Acceptance Criteria

- Missing current channel data renders a deterministic fallback label.
- The relevant JSDOM tests cover the fallback case.
- JS tests, JS lint, and format check pass.

## Stop Conditions

Stop if the change requires altering generated report data, Playwright snap
fixtures, or package dependencies.
