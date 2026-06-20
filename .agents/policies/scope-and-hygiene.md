# Scope And Hygiene

Use this policy for all agent work in this repository.

## Scope Control

- Keep behavior changes separate from mechanical formatting.
- Do not expand the assigned task.
- Do not redesign surrounding code unless the packet explicitly assigns it.
- Do not add dependencies unless the packet explicitly assigns it.
- Edit only files listed in the implementation packet.
- Stop if the required fix needs files outside the allowed scope.

## Generated And Local Files

Do not edit, format, commit, or include generated, vendored, local, or build
output paths unless the task explicitly asks for them:

- `parts/`
- `prime/`
- `stage/`
- `coverage/`
- `coverage-js/`
- `local-*`
- `tests/node_modules/`
- `.wiki/`, unless direct wiki edit mode is explicitly assigned

Do not commit `.snap` files, local dashboard previews, coverage reports,
`tests/node_modules/`, personal editor settings, local agent profiles, API
keys, model selections, or tool-permission rules.

## User Changes

- Preserve unrelated user changes.
- Do not revert work you did not make.
- If user changes affect the task, work with them instead of overwriting them.
- Ask only when user changes make the task impossible to complete safely.

## Verification

Run the narrowest relevant Workshop verification for the changed area, then
broaden only when risk or blast radius warrants it. Report skipped checks and
residual risk clearly.
