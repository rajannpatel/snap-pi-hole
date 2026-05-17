# Explanation: Architecture and Rationale

This document explores the "why" and "how" behind the Pi-hole snap package.

## Why a snap?

The official upstream Pi-hole install path is `curl … | bash`. While convenient, this script mutates the host machine extensively: it adds new users, edits `/etc/resolv.conf`, drops files all over `/etc` and `/opt`, installs a long list of distro-level package dependencies, and configures raw `systemd` units. Uninstalling it reliably is notoriously hard, upgrades occasionally break, and the blast radius if anything in the script misbehaves is the whole system.

A snap fixes most of that:

- **Atomic install and rollback:** `snap install pihole` and `snap revert pihole` are one command each. If an update breaks your DNS, rolling back takes seconds.
- **Confined runtime:** Pi-hole only sees its own data directories and the network. It strictly cannot write to your host's `/etc/resolv.conf` behind your back.
- **Auditable interfaces:** Privileges (like port binding, DHCP network control, and firewall control) are explicit `plugs` that the operator explicitly connects, not implicit side effects of an install script.

## Architecture

Pi-hole v6 collapsed its old multi-process architecture (FTL + lighttpd + PHP + cron) into a single, unified binary: `pihole-FTL`. This binary now serves DNS, DHCP, the HTTP API, and the embedded web admin UI. That single-binary design is precisely what makes a strictly-confined snap realistic and stable.

The snap consists of four build parts defined in `snapcraft.yaml`:

1. **`ftl`** — clones the `pi-hole/FTL` repository and builds the core daemon natively using CMake.
2. **`core`** — pulls the `pi-hole/pi-hole` repository (the `pihole` CLI and supporting bash scripts) and stages it under `/opt/pihole`. Two source-level `sed` patches applied during the build swap out `service`/`systemctl` calls in `piholeLogFlush.sh` and `piholeDebug.sh` for `snapctl` equivalents.
3. **`web`** — pulls the `pi-hole/web` repository into `$SNAP/var/www/html/admin`, which is then served by FTL's embedded CivetWeb server instance.
4. **`wrappers`** — copies our custom launcher scripts (`launcher-ftl` and `launcher-pihole`) into the snap.

### Path Remapping

Rather than patching Pi-hole's C code and bash scripts to understand snap-specific paths, path remapping is handled entirely by snapd via a `layout:` block in `snapcraft.yaml`. This block seamlessly bind-mounts the upstream-hardcoded paths (like `/etc/pihole`) onto writable directories within the snap's mount namespace (`$SNAP_DATA/etc/pihole`). The C code and bash scripts keep their original paths and work out of the box without environment-variable plumbing.

### The `launcher-ftl` Wrapper

Before executing the daemon, the `launcher-ftl` script performs two critical runtime tasks:
1. **Conflict Detection:** It proactively detects if the host's `systemd-resolved` stub-listener is conflicting on port 53, printing a copy-pasteable fix if true.
2. **Configuration Seeding:** It seeds an empty `pihole.toml` file into the data directory so FTL can populate it with safe defaults on its first start.

## Remaining Work and Out of Scope

The following items are officially out of scope for this snap package:
- **The Pi-hole installer script itself:** This snap is an alternative to the script, not a wrapper around it.
- **HTTPS for the admin UI:** Use a reverse proxy (like Nginx or Caddy) on the host. While FTL's embedded server handles HTTPS in v6, managing certificates directly inside a strictly confined snap introduces friction that is ultimately not worth it.

**Remaining project milestones:**
- [ ] **Decide refresh strategy.** Pick `restart` vs `endure` and document the rationale. Wire `refresh-mode: endure` into `snapcraft.yaml` if going that way.
- [ ] **Set up store name + credentials.**
- [ ] **End-to-end LAN verification.** Run the snap against a real client device on a populated network for a week before flipping the `snapcraft.yaml` grade to `stable`.
- [ ] **Subcommand verification by execution.** Extend the CI smoke test to execute every single `pihole` subcommand and verify its output.
- [ ] **`snapcraft remote-build` for arm64/armhf.** Wire up a Launchpad credential and add a separate CI workflow for cross-architecture builds.
