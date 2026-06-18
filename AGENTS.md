# Agent Execution Rules for snap-pi-hole

## Principle
The editor and AI agent run in the host development environment, which may
be Linux, Windows with WSL2, or macOS with a Linux VM. Project tools run in
the Workshop LXD container. Never install or run project tools directly on
the host.

On Windows with WSL2, shell scripts such as `.workshop-local/run.sh` can be
run from the WSL terminal inside the editor, or from Windows using `bash`
provided by Git for Windows. On macOS, connect the editor to the Linux VM
via SSH and run scripts inside that session. On Linux, run scripts directly
in the host terminal.

## Required workflow

1. **Read context before planning:**
   `workshop run snap-pi-hole -- context`

2. **Run all project checks through Workshop:**
   - Environment check:      `workshop run snap-pi-hole -- doctor`
   - Focused BATS test:     `workshop run snap-pi-hole -- test tests/unit/<file>.bats`
   - Full BATS suite:       `workshop run snap-pi-hole -- test`
   - JS dependencies:       `workshop run snap-pi-hole -- deps-js`
   - JSDOM tests:           `workshop run snap-pi-hole -- test-jsdom`
   - Snap Chromium tests:   `workshop run snap-pi-hole -- test-playwright-snap`
   - Lint suite:            `workshop run snap-pi-hole -- lint`
   - JavaScript lint:       `workshop run snap-pi-hole -- lint-js`
   - Format check:          `workshop run snap-pi-hole -- format-check`
   - Build snap:            `workshop run snap-pi-hole -- build`
   - Install local snap:    `workshop run snap-pi-hole -- install`
   - Smoke test:            `workshop run snap-pi-hole -- smoke`

3. **Do NOT run** `snapcraft`, `bats`, `shellcheck`, `yamllint`,
   `pre-commit`, `kcov`, `node`, `npm`, or `npx` on the host. Always use
   Workshop.

4. **Git operations** run on the host with normal git commands. Do not git
   inside the Workshop container.

5. **Generated artifacts** (`.snap` files, coverage reports, local-*
   previews) stay out of commits unless the task explicitly asks for them.

6. **Respect existing uncommitted changes.** Do not revert or overwrite work
   you did not make.

7. **Workshop must be launched before running actions:**
   `workshop launch snap-pi-hole`

## Editor preflight

VS Code runs the `Workshop: Open Check` task when the folder opens. If it
fails, stop and ask the user to run `Workshop: Launch`, then
`Workshop: Doctor`. If the environment was already launched before recent
Workshop SDK changes, run `Workshop: Refresh`, then `Workshop: Doctor`.

Zed does not run project tasks automatically when a folder opens. Use
`task: spawn` and run `Workshop: Doctor` before project work. If it fails,
run `Workshop: Launch` or `Workshop: Refresh`, then rerun `Workshop: Doctor`.

Treat a failed editor preflight as a Workshop readiness problem. Do not fall
back to host-side `npm`, `snapcraft`, `bats`, `shellcheck`, `yamllint`, or
other project tools.

## Commands

Run project tools through Workshop from the host:

```bash
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
cd tests && npm run test:playwright:snap
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

Do not edit, format, or commit generated, vendored, or build output paths
unless the task explicitly asks for them:

- `parts/`
- `prime/`
- `stage/`
- `coverage/`
- `coverage-js/`
- `local-*`
- `tests/node_modules/`
- `.wiki/`

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

- Keep behavior changes separate from mechanical formatting.
- Do not mix generated output with source changes.
- If a file has unrelated user changes, preserve them.
- Run the narrowest relevant tests and report skipped tests.

## Wiki repository (`snap-pi-hole.wiki`)

The wiki is a separate repository at
`https://github.com/rajannpatel/snap-pi-hole.wiki.git`. Clone it locally
for agent context and editing:

```bash
# One-time setup from the main repo root:
git clone https://github.com/rajannpatel/snap-pi-hole.wiki.git .wiki
```

`.wiki/` is gitignored. It is a full standalone git clone — you can open
it as its own project in your editor.

**Before reading any wiki file, the agent must pull the latest version:**

```bash
git -C .wiki pull --ff-only
```

This ensures the agent always works from the current wiki content rather
than a stale copy.

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
