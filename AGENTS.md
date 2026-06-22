# Agent Execution Rules for snap-pi-hole

## Principle

The editor process starts in the host development environment, but project
tools and terminal-backed agent work must run in the Workshop LXD container.
Every shell command an agent runs for this project must enter Workshop. Treat
any direct host project command as misconfigured and stop.

The committed `tools/workshop-shell` wrapper is the Workshop terminal entry
point. It starts an interactive Workshop shell and routes ad hoc `-c` commands
into Workshop. Never install or run project tools directly on the host.

Detailed policy lives in:

- [Workshop confinement](.agents/security/workshop-confinement.md)
- [Role bootstrap](.agents/bootstrap.md)
- [Commands](.agents/commands.md)
- [Verification](.agents/workflows/verification.md)
- [Git boundary](.agents/policies/git-boundary.md)
- [Formatting](.agents/policies/formatting.md)
- [Scope and hygiene](.agents/policies/scope-and-hygiene.md)
- [Delegation workflow](.agents/workflows/delegation.md)
- [Editor preflight](.agents/workflows/editor-preflight.md)
- [Model selection](.agents/models/selection.md)

## Required Bootstrap

Before planning, editing, reviewing, or running project checks:

```bash
workshop run snap-pi-hole -- agent-role <role>
workshop run snap-pi-hole -- context
```

If the role is not explicitly assigned, act as Router. A prompt that says
`You are the <role> for snap-pi-hole` is a complete role assignment. See
[.agents/bootstrap.md](.agents/bootstrap.md) and the role files under
[.agents/roles/](.agents/roles/).

## Hard Rules

- Run all project shell commands through Workshop.
- Do not run `snapcraft`, `bats`, `shellcheck`, `yamllint`, `pre-commit`,
  `kcov`, `node`, `npm`, or `npx` directly on the host.
- AI agent Git inspection runs inside Workshop.
- Commits and tags are maintainer operations unless explicitly assigned.
- Agents must never run `git push` from inside Workshop. If asked to push,
  stop before pushing and direct the user to push from the host or maintainer
  environment.
- Do not add SSH host keys, update `known_hosts`, configure Workshop SSH
  trust, or otherwise prepare Workshop credentials or trust solely to enable
  pushing from Workshop.
- Generated artifacts (`.snap` files, coverage reports, local-* previews) stay
  out of commits unless the task explicitly asks for them.
- Preserve unrelated user changes. Do not revert or overwrite work you did not
  make.
- Choose Workshop terminal mode or native panel mode in uncommitted personal
  preferences. This choice never changes the Workshop execution boundary.
- Follow `.agents/models/selection.md`. Do not inspect secrets, API keys, or
  private provider configuration to discover model access.

## Common Commands

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

See [.agents/commands.md](.agents/commands.md) for the canonical action list,
Workshop-provided agent tools, and lower-level command references.

## Verification Summary

For normal edits:

```bash
workshop run snap-pi-hole -- context
workshop run snap-pi-hole -- test tests/unit/<relevant-file>.bats
workshop run snap-pi-hole -- lint
```

For packaging/runtime changes:

```bash
workshop run snap-pi-hole -- build
workshop run snap-pi-hole -- install
workshop run snap-pi-hole -- smoke
```

For pre-submit:

```bash
workshop run snap-pi-hole -- test
workshop run snap-pi-hole -- deps-js
workshop run snap-pi-hole -- test-jsdom
workshop run snap-pi-hole -- test-playwright-snap
workshop run snap-pi-hole -- lint
workshop run snap-pi-hole -- lint-js
workshop run snap-pi-hole -- format-check
```

See [.agents/workflows/verification.md](.agents/workflows/verification.md) for
the verification matrix and area-specific checks.

## Wiki Repository

Follow [.agents/docs/wiki-workflow.md](.agents/docs/wiki-workflow.md). Wiki
edits are not part of the main repository branch unless a task explicitly
assigns direct wiki edit mode.

## Secrets

- Do not read, print, or commit API keys or tokens.
- Pass model choices at runtime:
  `workshop run --env CLAUDE_MODEL=haiku snap-pi-hole -- context`

## Host Tunnel Endpoints

After install:

- Admin console: `http://localhost:8080/admin`
- DNS query: `dig @localhost -p 5300 example.com`
