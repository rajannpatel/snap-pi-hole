# Workshop Confinement

## Mandatory Policy

Every shell command an AI agent runs for this project must enter Workshop.
Native editor panels may be used, but they do not change this execution rule.

If an agent attempts to run a project shell command directly on the host, stop
and reroute through Workshop.

## Allowed Shell Entry Points

Agents may use these host-side entry points:

- `workshop launch snap-pi-hole`
- `workshop refresh snap-pi-hole`
- `workshop run snap-pi-hole -- ...`
- `tools/workshop-shell`

When launch and role preflight are chained, use `tools/workshop-shell -c`
rather than a raw `workshop launch snap-pi-hole && workshop run ...` command.
The wrapper treats the known already-launched `workshop exists` response as
success for `workshop launch snap-pi-hole`, so required preflight commands are
not skipped.

Inside Workshop, use the named project actions from `workshop.yaml`, such as
`context`, `doctor`, `test`, `lint`, `build`, `install`, and `smoke`.

## Agent UI Modes

Users choose the UI mode and enforcement details in uncommitted personal
editor or agent preferences.

Do not commit personal model choices, agent profiles, tool-permission rules,
API keys, local agent server definitions, terminal profile overrides, or
editor-specific enforcement settings.

| Mode | Use when | Required personal preference |
| --- | --- | --- |
| Workshop terminal mode | The agent runs commands through a terminal thread, CLI, or TUI. | Launch the agent from `tools/workshop-shell` or `workshop run snap-pi-hole -- shell`. |
| Native panel mode | The user wants Zed Agent Panel, VS Code extension agents, or another native integration for planning, editing, or review. | Disable, deny, or confirmation-gate raw terminal tools. Permit only the allowed shell entry points above. |

Native panel mode is a UI choice, not a second execution policy. Native panel
tools must not run arbitrary host shell commands for this project.

## Disallowed Host Commands

Do not let agents run project commands directly on the host, including:

- `snapcraft`
- `bats`
- `shellcheck`
- `yamllint`
- `pre-commit`
- `kcov`
- `node`
- `npm`
- `npx`
- project-local Python, Ruby, or shell test scripts

Git inspection should also run inside Workshop for agent work. Host-side Git
mutation, such as commits, tags, and pushes, is a maintainer operation unless
the user explicitly assigns it.

## Stop Conditions

Stop and ask for correction when:

- a terminal command is not clearly routed through Workshop
- a native panel proposes a raw host shell command
- the selected UI mode is unknown and the agent needs to run commands
- Workshop is unavailable
- a proposed personal preference would need to be committed

When in doubt, use Workshop terminal mode.
