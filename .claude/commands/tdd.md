# /tdd

Use this command when the task should move through a tight test-driven loop.
Keep the scope narrow and preserve snap-pi-hole's Workshop execution boundary.

## Required Start

Before planning, editing, or running checks, confirm the active role and repo
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

1. Identify the smallest behavior the user wants and the smallest test that
   can prove it.
2. Locate the relevant test area before editing implementation code.
3. Write or update one focused failing test. Do not broaden coverage beyond the
   requested behavior.
4. Run the focused test through Workshop and record the exact failing command.
5. Implement only enough code to pass the focused test.
6. Re-run the focused test through Workshop.
7. Refactor only when the test is green, keeping the behavior unchanged.
8. Run the repository's relevant verification from `.agents/workflows/verification.md`.

## Constraints

- Do not run project tools directly on the host.
- Do not skip role bootstrap or `context`.
- Do not rewrite unrelated code while looking for a test seam.
- Do not treat a broad test run as a substitute for first proving the focused
  red-green loop.
- Preserve generated-artifact and Git boundaries from `AGENTS.md`.

## Output

Report:

- the focused failing test or why an existing failing test already covered it
- the exact Workshop-routed commands run
- the implementation files changed
- the final verification result
