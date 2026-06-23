# /update-model-selection

Use this command to create or refresh a local `model-selection.yaml` inventory
from the AI SDKs and agent surfaces visible in Workshop.

## Required Start

Before collecting inventory details or writing the YAML, confirm the active role
and repo context through Workshop:

```bash
workshop run <project-alias> -- agent-role <role>
workshop run <project-alias> -- context
```

When running from the host, route commands through the project wrapper:

```bash
tools/workshop-shell -c 'workshop run <project-alias> -- context'
```

## Workflow

1. Inspect the AI SDKs and model surfaces that are explicitly visible in the
   current Workshop environment.
2. Use only visible, non-secret information to fill the local model-selection
   inventory.
3. Update `.agents/local/model-selection.yaml` unless the developer explicitly
   requested another ignored local path.
4. Keep the output compatible with `.agents/models/selection.schema.yaml` and
   aligned with `.agents/models/selection.template.yaml`.
5. Do not inspect secrets, private provider config, or hidden account data.
6. Do not invent model availability. If a field cannot be populated from visible
   Workshop information, stop and ask for the missing details.

## Constraints

- Do not commit the generated inventory.
- Do not write outside ignored local paths.
- Do not run project tools directly on the host.
- Preserve the repository's Workshop confinement and model-selection policy.

## Output

Report:

- the output path updated
- the visible Workshop sources used
- any missing information that blocked completion
- whether the inventory was fully updated or still partial
