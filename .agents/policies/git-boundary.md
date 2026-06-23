# Git Boundary

Use this policy for agent Git operations in this repository.

## Inspection

AI agent Git inspection runs inside Workshop. Use `tools/workshop-shell` or
`workshop run <project-alias> -- ...` for status, diff, log, grep, and other
read-only inspection.

## Mutation

Host-side Git mutation such as commits and tags is a maintainer operation
unless the user explicitly asks the agent to perform it. When explicitly
assigned, keep the operation scoped to the current task and preserve unrelated
user changes.

## Push Boundary

Agents must never run `git push` from inside Workshop.

If asked to push, stop before pushing and direct the user to push from the host
or maintainer environment.

Do not add SSH host keys, update `known_hosts`, configure Workshop SSH trust,
or otherwise prepare Workshop credentials or trust solely to enable pushing
from Workshop.
