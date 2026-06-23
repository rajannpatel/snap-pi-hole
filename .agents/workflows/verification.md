# Verification

Run the narrowest relevant Workshop verification for the changed area, then
broaden when risk or blast radius warrants it. Report skipped checks and
residual risk clearly.

## Standard Loops

For normal edits:

```bash
workshop run <project-alias> -- context
workshop run <project-alias> -- test tests/unit/<relevant-file>.bats
workshop run <project-alias> -- lint
```

For packaging/runtime changes:

```bash
workshop run <project-alias> -- build
workshop run <project-alias> -- install
workshop run <project-alias> -- smoke
```

For pre-submit:

```bash
workshop run <project-alias> -- test
workshop run <project-alias> -- deps-js
workshop run <project-alias> -- test-jsdom
workshop run <project-alias> -- test-playwright-snap
workshop run <project-alias> -- lint
workshop run <project-alias> -- lint-js
workshop run <project-alias> -- format-check
```

## Verification Matrix

| Change type | Narrow verification | Broader verification |
| --- | --- | --- |
| Shell runtime or testing helper | `workshop run <project-alias> -- test tests/unit/<file>.bats` | `workshop run <project-alias> -- lint` |
| Snap hook | `workshop run <project-alias> -- test tests/unit/hooks.bats` | `workshop run <project-alias> -- lint` |
| Snapcraft metadata | `workshop run <project-alias> -- test tests/unit/snapcraft-schema.bats` | `workshop run <project-alias> -- build` |
| Dashboard JavaScript | `workshop run <project-alias> -- deps-js` and `workshop run <project-alias> -- test-jsdom` | `workshop run <project-alias> -- test-playwright-snap`, `workshop run <project-alias> -- lint-js`, and `workshop run <project-alias> -- format-check` |
| Snap runtime behavior | focused BATS test | `workshop run <project-alias> -- build`, `install`, and `smoke` |
| Wiki context only | `git -C .wiki pull --ff-only` | no wiki edits |
| Wiki update proposal | review proposal against current `.wiki/` content | no wiki commit |
| Direct wiki edit | `git -C .wiki status --short` and relevant `.wiki/.hooks` checks | separate `.wiki/` commit and push |

## Area References

- Dashboard JS: `workshop run <project-alias> -- deps-js`,
  `workshop run <project-alias> -- test-jsdom`,
  `workshop run <project-alias> -- test-playwright-snap`,
  `workshop run <project-alias> -- lint-js`, and
  `workshop run <project-alias> -- format-check`.
- Snap runtime: focused BATS tests first, then `build`, `install`, and
  `smoke` when behavior crosses packaging or runtime boundaries.
- Shell/BATS: `workshop run <project-alias> -- test tests/unit/<file>.bats`.
- Snapcraft metadata: `workshop run <project-alias> -- test tests/unit/snapcraft-schema.bats`
  and `workshop run <project-alias> -- yamllint`; use `build` when packaging
  risk warrants it.
- Wiki: follow [../docs/wiki-workflow.md](../docs/wiki-workflow.md).

Wiki verification commands, when direct wiki work is explicitly assigned:

```bash
vale .wiki/How-to:-*.md
python3 .wiki/.hooks/check_toc.py .wiki/How-to:-*.md
python3 .wiki/.hooks/audit_snapcraft.py .wiki/How-to:-*.md
cd .wiki && pre-commit run --all-files
```
