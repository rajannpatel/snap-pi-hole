# Verification

Run the narrowest relevant Workshop verification for the changed area, then
broaden when risk or blast radius warrants it. Report skipped checks and
residual risk clearly.

## Standard Loops

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

## Verification Matrix

| Change type | Narrow verification | Broader verification |
| --- | --- | --- |
| Shell runtime or testing helper | `workshop run snap-pi-hole -- test tests/unit/<file>.bats` | `workshop run snap-pi-hole -- lint` |
| Snap hook | `workshop run snap-pi-hole -- test tests/unit/hooks.bats` | `workshop run snap-pi-hole -- lint` |
| Snapcraft metadata | `workshop run snap-pi-hole -- test tests/unit/snapcraft-schema.bats` | `workshop run snap-pi-hole -- build` |
| Dashboard JavaScript | `workshop run snap-pi-hole -- deps-js` and `workshop run snap-pi-hole -- test-jsdom` | `workshop run snap-pi-hole -- test-playwright-snap`, `workshop run snap-pi-hole -- lint-js`, and `workshop run snap-pi-hole -- format-check` |
| Snap runtime behavior | focused BATS test | `workshop run snap-pi-hole -- build`, `install`, and `smoke` |
| Wiki context only | `git -C .wiki pull --ff-only` | no wiki edits |
| Wiki update proposal | review proposal against current `.wiki/` content | no wiki commit |
| Direct wiki edit | `git -C .wiki status --short` and relevant `.wiki/.hooks` checks | separate `.wiki/` commit and push |

## Area References

- Dashboard JS: `workshop run snap-pi-hole -- deps-js`,
  `workshop run snap-pi-hole -- test-jsdom`,
  `workshop run snap-pi-hole -- test-playwright-snap`,
  `workshop run snap-pi-hole -- lint-js`, and
  `workshop run snap-pi-hole -- format-check`.
- Snap runtime: focused BATS tests first, then `build`, `install`, and
  `smoke` when behavior crosses packaging or runtime boundaries.
- Shell/BATS: `workshop run snap-pi-hole -- test tests/unit/<file>.bats`.
- Snapcraft metadata: `workshop run snap-pi-hole -- test tests/unit/snapcraft-schema.bats`
  and `workshop run snap-pi-hole -- yamllint`; use `build` when packaging
  risk warrants it.
- Wiki: follow [../docs/wiki-workflow.md](../docs/wiki-workflow.md).

Wiki verification commands, when direct wiki work is explicitly assigned:

```bash
vale .wiki/How-to:-*.md
python3 .wiki/.hooks/check_toc.py .wiki/How-to:-*.md
python3 .wiki/.hooks/audit_snapcraft.py .wiki/How-to:-*.md
cd .wiki && pre-commit run --all-files
```
