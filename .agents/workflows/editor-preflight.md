# Editor Preflight

Open this repository in VS Code or Zed from the same host, WSL, or Linux VM
environment where Workshop is installed.

## VS Code

VS Code runs the `Workshop: Open Check` task when the folder opens. If it
fails, stop and ask the user to run `Workshop: Launch`, then
`Workshop: Doctor`. If the environment was already launched before recent
Workshop SDK changes, run `Workshop: Refresh`, then `Workshop: Doctor`.

Choose Workshop terminal mode or native panel mode in personal preferences.
Configure terminal-backed agents to use `tools/workshop-shell`, or run
`Workshop: Shell`, before starting terminal-backed agents.

## Zed

Zed does not run project tasks automatically when a folder opens. Use
`task: spawn` and run `Workshop: Doctor` before project work. If it fails, run
`Workshop: Launch` or `Workshop: Refresh`, then rerun `Workshop: Doctor`.

Choose Workshop terminal mode or native panel mode in personal preferences.
Configure terminal-backed agents to use `tools/workshop-shell`, or run
`Workshop: Shell`, before starting terminal-backed agents.

## Native Panel Caveat

VS Code and Zed provide committed `Workshop: Shell` tasks, but default agent UI
mode and tool permissions are personal preferences and must not be committed.
Native Agent Panel tools or external agent integrations may have their own
terminal execution path. If a raw terminal tool call is not clearly a Workshop
command, reject it or switch to Workshop terminal mode.

Treat a failed editor preflight as a Workshop readiness problem. Do not fall
back to host-side `npm`, `snapcraft`, `bats`, `shellcheck`, `yamllint`, or
other project tools.
