# Agent Security

This directory is the shared security reference for AI agent use in this
repository.

The core rule is simple: every shell command an agent runs for this project
must enter Workshop. The editor UI may run on the host, but project command
execution belongs in the Workshop LXD container.

Read [workshop-confinement.md](workshop-confinement.md) before configuring Zed
Agent Panel, VS Code extension agents, Terminal Threads, agent CLIs, TUIs, or
external agent integrations.

Personal choices stay personal. Do not commit model selections, API keys,
agent profiles, tool-permission rules, local agent server definitions, terminal
profile overrides, or editor-specific enforcement settings.
