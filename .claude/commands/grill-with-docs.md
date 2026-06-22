# /grill-with-docs

Use this command to challenge an idea, plan, failure explanation, or proposed
implementation against the repository's documented rules before changing code.

## Required Start

Before evaluating claims that depend on project behavior, confirm role and repo
context through Workshop:

```bash
workshop run snap-pi-hole -- agent-role <role>
workshop run snap-pi-hole -- context
```

When running from the host, route commands through the project wrapper:

```bash
tools/workshop-shell -c 'workshop run snap-pi-hole -- context'
```

## Workflow

1. Gather the relevant repo docs first. Start with `AGENTS.md`, then read the
   linked role, command, verification, policy, or workflow docs that govern the
   claim.
2. State which facts are documented and cite the files that establish them.
3. Separate assumptions, guesses, and preferences from documented constraints.
4. Ask pointed questions where the proposal conflicts with the docs, lacks an
   acceptance criterion, or relies on unstated behavior.
5. For claims involving project commands, require a Workshop-routed command or
   a documented reason the command should not be run.
6. End with a narrow recommendation: proceed, revise, ask the user, or hand off
   to the correct role.

## Constraints

- Do not use this workflow to bypass Router, Architect, Implementer, or
  Reviewer responsibilities.
- Do not inspect secrets, model-provider credentials, or private local config.
- Do not turn challenge questions into broad redesign requests.
- Do not run project shell commands outside Workshop.

## Output

Report:

- documented facts with file references
- assumptions or unsupported claims
- blocking questions, if any
- the smallest next action consistent with the docs
