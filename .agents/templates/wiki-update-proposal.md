# Wiki Update Proposal

Use this when a main repository change needs documentation updates, but the
worker should not edit or commit the gitignored `.wiki/` repository directly.

## Current Wiki Context

- Files read:
- Command run before reading: `git -C .wiki pull --ff-only`

## Proposed Wiki Files

- `.wiki/<page>.md`

## Proposed Changes

Describe the exact documentation changes to apply. Include replacement text or
small Markdown snippets when useful.

## Reason

Explain which code or behavior change makes the documentation update necessary.

## Maintainer Follow-up

If accepted, a maintainer with wiki push access should apply the proposal in
`.wiki/`, run the relevant wiki checks, and commit from inside `.wiki/`.
