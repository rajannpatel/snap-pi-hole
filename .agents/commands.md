# Commands

Run project tools through Workshop from the host. Prefer these named actions
over lower-level commands.

## Workshop Actions

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

Repo-local slash commands such as `/tdd`, `/grill-with-docs`, and `/diagnose`
are documented workflows, not Workshop actions. Their definitions live in
`.claude/commands/` and their shared policy is summarized in
`.agents/workflows/agent-skills.md`.

`test-playwright-snap` is the existing Workshop-routed Playwright browser test
action name. It uses Playwright-managed Chromium; it does not require snap
Chromium.

## Workshop Agent Tools

The Workshop SDK provides common agent utilities inside the container:
`rg`, `fd`, `tree`, `jq`, `yq`, `git`, `gh`, `sed`, `awk`, `ruby`, `node`,
`nodejs`, `npm`, `npx`, `python3`, `uv`, `curl`, `wget`, `gcc`, `g++`, and
`make`. JavaScript package management uses npm; Yarn is not part of the
project toolchain.

## Lower-Level References

These are the lower-level commands behind named JS and YAML actions. Prefer
the named Workshop actions above. Run these only inside the Workshop container
or CI environment, not directly on the host:

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
