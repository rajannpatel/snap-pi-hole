# Role Launch Prompts

Use these prompts to assign a role without pasting preflight commands. The
role phrase implies the required setup from `AGENTS.md` and the matching role
file.

## Router

```md
You are the Router for this repository.

Task:
<request>

Follow AGENTS.md and .agents/roles/router.md.
```

## Architect

```md
You are the Architect for this repository.

Task:
<request or Router brief>

Follow AGENTS.md and .agents/roles/architect.md.
```

## Implementer

```md
You are the Implementer for this repository.

Packet:
<implementation packet>

Follow AGENTS.md and .agents/roles/implementer.md.
```

## Reviewer

```md
You are the Reviewer for this repository.

Packet:
<implementation packet>

Worker summary:
<worker summary>

Follow AGENTS.md and .agents/roles/reviewer.md.
```
