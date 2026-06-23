# Wiki Workflow

The project wiki is a separate Git repository. The main repository does not
clone `.wiki/` automatically, and `.wiki/` is gitignored here.

## Setup

Clone the wiki only when documentation context is needed:

```bash
git clone <repository>.wiki.git .wiki
```

Before reading any wiki file, pull the latest version:

```bash
git -C .wiki pull --ff-only
```

## Documentation Modes

Choose one mode whenever documentation is in scope:

| Mode | Use when | Output |
| --- | --- | --- |
| Read-only context | A code change needs current docs for planning or review. | Pull `.wiki/`, read it, and make no wiki edits. |
| Wiki update proposal | A contributor change should also update user-facing docs. | Return a proposal using `.agents/templates/wiki-update-proposal.md`; do not edit `.wiki/`. |
| Direct wiki edit | A maintainer explicitly asks for wiki edits and has wiki push access configured. | Edit listed `.wiki/` files, run relevant wiki checks, and commit/push from inside `.wiki/` separately. |

If a packet does not specify a documentation mode, use read-only context.
Agents must not silently create wiki commits.

## Rules

- Treat `.wiki/` as read-only by default.
- Include `.wiki/` paths in the allowed file list only for explicit
  maintainer direct wiki edits.
- Main repository commits do not include `.wiki/` changes.
- Do not require contributors or worker agents to fork or reconfigure the wiki
  repository for normal code changes.
- Prefer a wiki update proposal for normal contributor changes.
