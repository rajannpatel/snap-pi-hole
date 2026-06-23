# Implementation Packet

## Task Overview
Enforce `workshop_routed: true` requirement for project-oriented roles (Architect, Implementer, Reviewer) within the model selection and role documentation. Ensure all project-oriented roles operate strictly within the Workshop container.

## Environment & Model Context
*Required: Must be filled by Architect before delegation.*
- **Target Workshop Surface:** Workshop terminal CLI/TUI
- **Assigned Implementer Model:** Claude 3.5 Sonnet
- **Workshop-Routed:** Yes
- **Authorized Entrypoints:** `tools/workshop-shell`, `workshop run <project-alias> -- ...`

## Files to Edit
- `.agents/models/selection.md`
- `.agents/roles/architect.md`
- `.agents/roles/implementer.md`
- `.agents/roles/reviewer.md`
- `.agents/templates/implementation-packet.md.template`

## Required Workshop Commands
1. No implementation commands required; verify changes by reading the updated files.

## Acceptance Criteria
- `selection.md` explicitly mandates `workshop_routed: true` for Architect, Implementer, and Reviewer.
- Role documents for Architect, Implementer, and Reviewer contain explicit instructions on Workshop confinement.
- `implementation-packet.md.template` includes a mandatory field to confirm the role is Workshop-routed.

## Verification Plan
1. Check that `.agents/models/selection.md` and role files now document the strict Workshop requirement.
