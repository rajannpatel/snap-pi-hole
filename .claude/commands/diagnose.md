# /diagnose

Use this command to triage a failing command, test, build, smoke check, or
runtime report without jumping straight to a broad rewrite.

## Required Start

Before reproducing or inspecting project state, confirm role and repo context
through Workshop:

```bash
workshop run snap-pi-hole -- agent-role <role>
workshop run snap-pi-hole -- context
```

When running from the host, route commands through the project wrapper:

```bash
tools/workshop-shell -c 'workshop run snap-pi-hole -- context'
```

## Workflow

1. Capture the user's reported failure, including command, expected behavior,
   observed behavior, and relevant environment detail.
2. Reproduce with the narrowest Workshop-routed command available.
3. Record the exact command, exit status, and important failure lines.
4. Classify the likely area: documentation, runtime, snap packaging, test,
   dashboard, build tooling, or out-of-scope.
5. Inspect only the files needed to explain the failure.
6. Identify the narrowest next check or fix. If the current role cannot apply
   it, produce the correct handoff packet instead.
7. Verify the fix or recommendation with the relevant Workshop-routed check.

## Constraints

- Do not run project commands directly on the host.
- Do not start with broad formatting, dependency updates, or rewrites.
- Do not hide unrelated failures. Scope them clearly and stop if they block the
  assigned diagnosis.
- Do not mutate Git history or push from Workshop.

## Output

Report:

- reproduction command and result
- failure classification
- root cause if proven, or the strongest supported hypothesis
- narrow next action or patch summary
- verification command and result
