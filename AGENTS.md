# Agent Execution Rules for snap-pi-hole

## Principle
The editor process starts in the host development environment, which may be
Linux, Windows with WSL2, or macOS with a Linux VM. Project tools and
terminal-backed agent work must run in the Workshop LXD container.

This repository supports two agent UI modes under one mandatory execution
policy: every shell command an agent runs for this project must enter
Workshop. The user chooses the UI mode and enforcement details in personal
editor or agent preferences that are not committed. See
[.agents/security/workshop-confinement.md](.agents/security/workshop-confinement.md).

The committed `tools/workshop-shell` wrapper is the Workshop terminal entry
point. It starts an interactive Workshop shell and routes ad hoc `-c` commands
into Workshop. Treat any agent shell command that runs directly on the host as
misconfigured and stop.

Never install or run project tools directly on the host.

On Windows with WSL2, shell scripts such as `.workshop-local/run.sh` can be
run from the WSL terminal inside the editor, or from Windows using `bash`
provided by Git for Windows. On macOS, connect the editor to the Linux VM
via SSH and run scripts inside that session. On Linux, run scripts directly
in the host terminal.

## Role bootstrap

AI agents must identify their role at launch before planning or performing any work:
- The Zed Architect prompt explicitly assigns the Architect role.
- The Workshop Implementer prompt explicitly assigns the Implementer role.
- A prompt that says `You are the <role> for snap-pi-hole` is a complete role assignment.
  The agent must immediately run the required role preflight and
  context commands for that role; the developer does not need to paste those
  commands into every role prompt.
- If the role is not explicitly assigned at launch or is unknown, the agent must treat itself as a Router.
- A Router must run `workshop run snap-pi-hole -- context`, classify the
  request, and then answer a read-only informational question directly, route a
  verification-only request to the appropriate Workshop command-running path,
  coordinate a requested manual handoff, or hand an implementation-oriented
  request to the Architect. See
  `.agents/roles/router.md`.
- A Router must not edit files, run implementation commands, or substitute
  itself for the Architect. It may perform narrow read-only inspection when
  needed to answer a factual repository question. It may run an existing
  verification command only for a verification-only request and only when the
  current surface is the configured Workshop-routed command-running surface.
- All agents must run the role preflight command before planning:
  `workshop run snap-pi-hole -- agent-role <role>`
  (e.g., `workshop run snap-pi-hole -- agent-role router`, `workshop run snap-pi-hole -- agent-role architect`, or `workshop run snap-pi-hole -- agent-role implementer`)
  This command prints the assigned model, surface, and permissions, verifying the agent's environment context.

## Required workflow

1. **Verify role and read context before planning:**
   - Run the role preflight check: `workshop run snap-pi-hole -- agent-role <role>`
   - Run the project context check: `workshop run snap-pi-hole -- context`

2. **Run all project checks through Workshop:**
   - Environment check:      `workshop run snap-pi-hole -- doctor`
   - Focused BATS test:     `workshop run snap-pi-hole -- test tests/unit/<file>.bats`
   - Full BATS suite:       `workshop run snap-pi-hole -- test`
   - JS dependencies:       `workshop run snap-pi-hole -- deps-js`
   - JSDOM tests:           `workshop run snap-pi-hole -- test-jsdom`
   - Playwright browser tests: `workshop run snap-pi-hole -- test-playwright-snap`
   - Lint suite:            `workshop run snap-pi-hole -- lint`
   - JavaScript lint:       `workshop run snap-pi-hole -- lint-js`
   - Format check:          `workshop run snap-pi-hole -- format-check`
   - Build snap:            `workshop run snap-pi-hole -- build`
   - Install local snap:    `workshop run snap-pi-hole -- install`
   - Smoke test:            `workshop run snap-pi-hole -- smoke`

3. **Do NOT run** `snapcraft`, `bats`, `shellcheck`, `yamllint`,
   `pre-commit`, `kcov`, `node`, `npm`, or `npx` on the host. Always use
   Workshop.

4. **AI agent Git inspection** runs inside Workshop. Host-side Git mutation
   such as commits and tags is a maintainer operation unless the user
   explicitly asks the agent to perform it. Agents must never run `git push`
   from inside Workshop. If asked to push, stop before pushing and direct the
   user to push from the host or maintainer environment. Do not add SSH host
   keys, update `known_hosts`, configure Workshop SSH trust, or otherwise
   prepare Workshop credentials or trust solely to enable pushing from
   Workshop.

5. **Generated artifacts** (`.snap` files, coverage reports, local-*
   previews) stay out of commits unless the task explicitly asks for them.

6. **Respect existing uncommitted changes.** Do not revert or overwrite work
   you did not make.

7. **Workshop must be launched before running actions:**
   `workshop launch snap-pi-hole`
   Do not gate role preflight behind `workshop launch snap-pi-hole && ...`.
   Some Workshop versions return a non-zero status when the workshop already
   exists, which would skip the required `agent-role` command. Run the launch
   step separately, use `tools/workshop-shell -c` for chained launch/preflight
   commands, or run the role preflight directly when Workshop is already
   available.

8. **Choose an agent UI mode in uncommitted personal preferences:**
   Workshop terminal mode for command-running agents, or native panel mode
   with raw terminal tools disabled, denied, or confirmation-gated. This
   choice does not change the rule that shell commands must run through
   Workshop. See `.agents/security/workshop-confinement.md`.

## Editor preflight

VS Code runs the `Workshop: Open Check` task when the folder opens. If it
fails, stop and ask the user to run `Workshop: Launch`, then
`Workshop: Doctor`. If the environment was already launched before recent
Workshop SDK changes, run `Workshop: Refresh`, then `Workshop: Doctor`.

Zed does not run project tasks automatically when a folder opens. Use
`task: spawn` and run `Workshop: Doctor` before project work. If it fails,
run `Workshop: Launch` or `Workshop: Refresh`, then rerun `Workshop: Doctor`.

VS Code and Zed provide committed `Workshop: Shell` tasks, but the default
agent UI mode and tool permissions are personal preferences and must not be
committed. Native Agent Panel tools or external agent integrations may have
their own terminal execution path. If a raw terminal tool call is not clearly a
Workshop command, reject it or switch to Workshop terminal mode.

Treat a failed editor preflight as a Workshop readiness problem. Do not fall
back to host-side `npm`, `snapcraft`, `bats`, `shellcheck`, `yamllint`, or
other project tools.

## Model availability and role selection

Follow `.agents/models/selection.md`. Do not inspect secrets, API keys, or
private provider configuration to discover model access.

## Multi-agent role enforcement

When the user requests the repository multi-agent workflow, the current agent
acts as Architect unless it is explicitly running on the selected Implementer
model, provider or gateway, and surface from `.agents/local/model-selection.yaml`
or another developer-supplied model-selection inventory.

The Architect may inspect files and produce an implementation packet, but must
stop before editing project files, running implementation commands, or
substituting itself for the Implementer. Implementation begins only after a
separate worker is launched on the selected Implementer model through the
selected provider or gateway on the selected surface and given the packet.

A platform sub-agent, nested agent, or same-model worker is not the selected
Implementer unless it is launched on the configured Implementer model and
provider or gateway on the Workshop-routed surface. If the selected Implementer
is unavailable, out of credits, or cannot be launched through its configured
provider or gateway inside Workshop, stop with a blocker report and ask whether
to update model selection or explicitly switch to single-agent
mode.

## Commands

Run project tools through Workshop from the host:

```bash
workshop run snap-pi-hole -- agent-role <role>
workshop run snap-pi-hole -- context
workshop run snap-pi-hole -- doctor
workshop run snap-pi-hole -- test tests/unit/<file>.bats
workshop run snap-pi-hole -- test
workshop run snap-pi-hole -- deps-js
workshop run snap-pi-hole -- test-jsdom
workshop run snap-pi-hole -- test-playwright-snap
workshop run snap-pi-hole -- lint
workshop run snap-pi-hole -- lint-js
workshop run snap-pi-hole -- format-check
workshop run snap-pi-hole -- shellcheck
workshop run snap-pi-hole -- yamllint
workshop run snap-pi-hole -- build
workshop run snap-pi-hole -- install
workshop run snap-pi-hole -- smoke
workshop run snap-pi-hole -- shell
```

## Workshop agent tools

The Workshop SDK provides common agent utilities inside the container:
`rg`, `fd`, `tree`, `jq`, `yq`, `git`, `gh`, `sed`, `awk`, `ruby`, `node`,
`nodejs`, `npm`, `npx`, `python3`, `uv`, `curl`, `wget`, `gcc`, `g++`, and
`make`. JavaScript package management uses npm; Yarn is not part of the
project toolchain.

These are the exact lower-level commands behind the named JS and YAML actions.
Prefer the named Workshop actions above. Run these only inside the Workshop
container or CI environment, not directly on the host:

```bash
cd tests && npm run test:jsdom
cd tests && npm run test:playwright
cd tests && npm run lint:js
cd tests && npm run format:check
yamllint -c .yamllint snap/snapcraft.yaml
```

For reference, the JS lint and repo-wide format check resolve to:

```bash
git ls-files '*.js' | xargs npx --yes eslint@9 --config eslint.config.mjs
npx --yes prettier@3 --check . --ignore-path .prettierignore
```

## Do not touch

Follow `.agents/policies/scope-and-hygiene.md`.

## Formatting policy

JavaScript formatting is owned by Prettier. Run Prettier only on changed JS
files unless the task is an intentional formatting-only commit. Keep behavior
changes separate from mechanical formatting.

To format changed JS from the repository root, inside Workshop or CI:

```bash
git diff --name-only -- '*.js' | xargs -r npx --yes prettier@3 --write --ignore-path .prettierignore
```

Use `cd tests && npm run format:check` for a non-mutating check.

## Review checklist

- Follow `.agents/policies/scope-and-hygiene.md`.
- Run the narrowest relevant tests and report skipped tests.

## Wiki repository (`snap-pi-hole.wiki`)

Follow `.agents/docs/wiki-workflow.md`.

- **Vale** (documentation linter): `vale .wiki/How-to:-*.md`
- **TOC checker**: `python3 .wiki/.hooks/check_toc.py .wiki/How-to:-*.md`
- **Snapcraft link auditor**: `python3 .wiki/.hooks/audit_snapcraft.py .wiki/How-to:-*.md`
- **All pre-commit hooks**: `cd .wiki && pre-commit run --all-files`

## Standard verification loop

For normal edits:
```
workshop run snap-pi-hole -- context
workshop run snap-pi-hole -- test tests/unit/<relevant-file>.bats
workshop run snap-pi-hole -- lint
```

For packaging/runtime changes:
```
workshop run snap-pi-hole -- build
workshop run snap-pi-hole -- install
workshop run snap-pi-hole -- smoke
```

For pre-submit:
```
workshop run snap-pi-hole -- test
workshop run snap-pi-hole -- deps-js
workshop run snap-pi-hole -- test-jsdom
workshop run snap-pi-hole -- test-playwright-snap
workshop run snap-pi-hole -- lint
workshop run snap-pi-hole -- lint-js
workshop run snap-pi-hole -- format-check
```

## Secrets
- Do not read, print, or commit API keys or tokens.
- Pass model choices at runtime:
  `workshop run --env CLAUDE_MODEL=haiku snap-pi-hole -- context`

## Host tunnel endpoints (after install)
- Admin console: `http://localhost:8080/admin`
- DNS query: `dig @localhost -p 5300 example.com`
