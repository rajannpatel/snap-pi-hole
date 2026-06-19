# Contributing to the Pi-hole snap

Thanks for improving `pihole-by-rajannpatel`. This repository packages Pi-hole
as a strictly confined snap, so useful changes usually touch shell launchers,
snap hooks, Snapcraft metadata, tests, or report-generation tooling.

## Development Environment: Workshop Only

Canonical Workshop is the only supported development environment for
contributors. The committed `workshop.yaml` launches an Ubuntu 26.04 container
to match the snap's `core26` base, installs the project toolchain through the
local `project-tools` SDK, and exposes Pi-hole service tunnels back to your
host. Workshop uses LXD; see the official [Workshop](https://github.com/canonical/workshop),
[LXD installation](https://documentation.ubuntu.com/lxd/latest/installing/),
and [LXD initialization](https://documentation.ubuntu.com/lxd/latest/howto/initialize/)
documentation for platform details.

> [!IMPORTANT]
> **Cross-Platform Compatibility (macOS & Windows)**:
> Canonical Workshop and LXD require Linux container primitives and cannot run natively on macOS or Windows.
> - **Windows**: Install [Git for Windows](https://git-scm.com/download/win) first so Git Bash is available. Most commands in this repository's documentation are Bash commands; use Git Bash for Windows host commands, and use the Ubuntu WSL terminal when a step runs inside WSL2. Do not run project verification from PowerShell or `cmd.exe` unless a command block is explicitly labelled `powershell`.
> - **Windows Workshop setup**: Use Ubuntu on WSL2 with systemd enabled. Install LXD and Workshop inside WSL2. Open VS Code on Windows and use the **WSL** extension, or use Zed's WSL remote workflow.
> - **macOS**: Launch a Linux virtual machine, for example with [Multipass](https://canonical.com/multipass/install), install LXD and Workshop inside the VM, and use your IDE's remote development feature such as VS Code **Remote - SSH** or Zed SSH remoting.
> 
> For step-by-step instructions on setting up your IDE (VS Code or Zed) and configuring AI coding agents, refer to the [IDE and AI Agent Integration Guide](https://github.com/rajannpatel/snap-pi-hole/wiki/How-to:-IDE-and-AI-agent-integration).

Install and initialize LXD, then install Workshop in your Linux environment:

```bash
sudo snap install --channel=6/stable lxd
sudo snap start --enable lxd.daemon
sudo usermod -aG lxd "$USER"
newgrp lxd
lxd init --auto
sudo snap install --classic workshop
```

Fork and clone the repository:

```bash
git clone https://github.com/YOUR_USERNAME/snap-pi-hole.git
cd snap-pi-hole
```

The documentation wiki is not cloned with the main repository. It is a separate
Git repository, and `.wiki/` is gitignored here. Clone it only when you need
current user-facing documentation for context:

```bash
git clone https://github.com/rajannpatel/snap-pi-hole.wiki.git .wiki
git -C .wiki pull --ff-only
```

Keep `.wiki/` read-only by default. Contributor pull requests should include a
wiki update proposal when documentation needs to change. Direct wiki edits are
a maintainer workflow and are committed from inside `.wiki/` separately from
the main repository.

Launch the workshop:

```bash
workshop launch snap-pi-hole
```

If this is the only workshop in the project, `workshop launch` is also enough.
The launch installs build dependencies, BATS, ShellCheck, Node.js, kcov,
pre-commit, Snapcraft 9.x, DNS tools, and the project pre-commit hooks.

## Developer Actions

Run named actions with:

```bash
workshop run snap-pi-hole -- <action>
```

Useful actions:

| Action | Purpose |
| --- | --- |
| `doctor` | Check required tools and snapd/Snapcraft availability. |
| `context` | Print repository state and snap metadata for quick orientation. |
| `lint` | Run the full pre-commit suite. |
| `shellcheck` | Run ShellCheck over tracked shell scripts. |
| `yamllint` | Validate YAML files. |
| `test` | Run BATS tests. Pass a path to narrow scope, for example `workshop run snap-pi-hole -- test tests/unit/hooks.bats`. |
| `coverage` | Generate local kcov HTML coverage via `tests/scripts/local-preview.sh kcov`. |
| `build` | Build the snap with `snapcraft --destructive-mode`. |
| `clean` | Clean Snapcraft build state. |
| `install` | Install the latest local `.snap` inside the workshop and connect declared snap interfaces. |
| `smoke` | Check snap service status and query DNS inside the workshop. |
| `logs` | Show recent `pihole-ftl` snap logs. Pass a count, for example `logs 200`. |
| `debug` | Run the snap debug helper. |
| `uninstall` | Remove the local snap from the workshop. |

Typical loop:

```bash
workshop run snap-pi-hole -- doctor
workshop run snap-pi-hole -- lint
workshop run snap-pi-hole -- test
workshop run snap-pi-hole -- build
workshop run snap-pi-hole -- install
workshop run snap-pi-hole -- smoke
```

## Host Tunnels

The workshop connects three tunnel pairs:

| Host endpoint | Workshop service |
| --- | --- |
| `localhost:8080/tcp` | Pi-hole admin web service on `localhost:80/tcp`. |
| `localhost:5300/tcp` | Pi-hole DNS on `localhost:53/tcp`. |
| `localhost:5300/udp` | Pi-hole DNS on `localhost:53/udp`. |

After `build` and `install`, test from your host:

```bash
dig @localhost -p 5300 example.com
```

Open the admin console in a browser:

```text
http://localhost:8080/admin
```

## External Ubuntu Core Verification

Workshop is the development environment. [Multipass](https://canonical.com/multipass/install)
is an external runtime target for [Ubuntu Core](https://ubuntu.com/core) and
strict-confinement verification. Run Multipass from the host, not from inside
the Workshop container.

Build the snap in Workshop:

```bash
workshop run snap-pi-hole -- build
```

Then install the produced snap into a host-managed Ubuntu Core VM:

```bash
SNAP_FILE="$(ls -t ./*.snap | head -n 1)"
multipass launch core26 --name pihole-core-test --cpus 2 --memory 4G --disk 10G
tests/scripts/multipass-wait-snapd-stable.sh pihole-core-test
multipass exec pihole-core-test -- sudo mkdir -p /etc/systemd/resolved.conf.d
multipass exec pihole-core-test -- bash -c \
  "printf '[Resolve]\nDNS=127.0.0.1\nDNSStubListener=no\n' | sudo tee /etc/systemd/resolved.conf.d/pihole.conf"
multipass exec pihole-core-test -- sudo systemctl restart systemd-resolved
multipass transfer "$SNAP_FILE" pihole-core-test:/home/ubuntu/pihole.snap
multipass exec pihole-core-test -- sudo snap install /home/ubuntu/pihole.snap --dangerous
tests/scripts/multipass-wait-snapd-stable.sh pihole-core-test
```

Connect interfaces and run the snap diagnostics:

```bash
for plug in network-bind network-control firewall-control network-observe \
            system-observe hardware-observe mount-observe process-control \
            time-control; do
  multipass exec pihole-core-test -- \
    sudo snap connect "pihole-by-rajannpatel:$plug" || true
done

multipass exec pihole-core-test -- \
  sudo snap start --enable pihole-by-rajannpatel.pihole-ftl
multipass exec pihole-core-test -- \
  sudo snap alias pihole-by-rajannpatel.pihole pihole
tests/scripts/multipass-wait-snapd-stable.sh pihole-core-test
multipass exec pihole-core-test -- pihole snap-check
```

Remove the VM when finished:

```bash
multipass delete --purge pihole-core-test
```

## Agentic Development Notes

Workshop provides a shared, disposable project container. Coding agents and
human contributors can use the same named actions instead of hand-rolling setup
steps.

### Execution Model
* **Editor Context**: Your IDE (VS Code or Zed) and its AI agent extensions run on the host system (or inside the WSL/VM workspace).
* **Execution Context**: The agent does not run inside the container itself. Instead, it executes commands from the editor terminal using the `workshop run` wrapper (e.g., `workshop run snap-pi-hole -- test`).
* **Workspace Mounting**: The workspace is bind-mounted into the Workshop container, meaning any file changes made by the agent on the host are instantly available inside the container.

Good agent instructions for this repository should ask the agent to:

1. Run `workshop run snap-pi-hole -- context` before planning.
2. Use focused BATS tests while editing.
3. Run `workshop run snap-pi-hole -- lint` before submitting broad changes.
4. Use `build`, `install`, and `smoke` for packaging or runtime changes.
5. Keep generated local reports, coverage, and snap artifacts out of commits
   unless the task explicitly asks for them.

For multi-model development, use the checked-in planner, implementer, and
reviewer workflow in [.agents/README.md](.agents/README.md). The reusable role
prompts and task packet templates live under `.agents/`.

Repository instructions cannot automatically know which models are enabled in
your IDE or provider account. When using Architect, Implementer, Reviewer, and
Inline Assistant roles, provide the available model list from VS Code, Zed,
your agent CLI, inline assistant, model gateway, or local model runtime, then
let the workflow assign models by capability.

The latest user-facing documentation is available from the optional,
gitignored `.wiki/` checkout described above. Treat it as read-only context by
default. Contributor changes that need documentation updates should include a
wiki update proposal unless a maintainer explicitly asks for direct wiki edits,
which are committed from inside `.wiki/` as a separate repository.

## Submitting Changes

Create a topic branch:

```bash
git checkout -b fix/descriptive-name
```

Before opening a pull request, run the narrowest useful verification plus the
full relevant suite. At minimum:

```bash
workshop run snap-pi-hole -- lint
workshop run snap-pi-hole -- test
```

For packaging changes, also run:

```bash
workshop run snap-pi-hole -- build
workshop run snap-pi-hole -- install
workshop run snap-pi-hole -- smoke
```

For changes that affect confinement, interfaces, services, hooks, or Ubuntu
Core behavior, also run the external Ubuntu Core verification flow above.

In the pull request, explain the behavior changed, the tests run, and any
remaining risks or follow-up work.
