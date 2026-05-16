# Pi-hole Snap Package

A [snap](https://snapcraft.io/) package for [Pi-hole](https://pi-hole.net),
the network-wide ad-blocking DNS sinkhole.

> **Status: `grade: devel`.** The recipe builds, layouts cover every
> path the v6.6.2 FTL source actually touches, the `pihole` CLI is
> wrapped, the `configure` hook is wired up, and a basic CI smoke test
> exercises the build. What's not yet proven: a long-running deployment
> against real LAN clients. See [Remaining work](#remaining-work).

Pinned upstream: **FTL v6.6.2** · **pi-hole (core) v6.4.2** · **web v6.5**.

## Why a snap?

The upstream install path is `curl … | bash`, which mutates the host
extensively: it adds users, edits `resolv.conf`, drops files all over
`/etc` and `/opt`, installs a long list of distro packages, and configures
`systemd` units. Uninstalling reliably is hard, upgrades occasionally
break, and the blast radius if anything in the script misbehaves is the
whole system.

A snap fixes most of that:

- **Atomic install and rollback.** `snap install pihole` and
  `snap revert pihole` are one command each.
- **Confined runtime.** Pi-hole only sees its own data dirs and the
  network. It can't write to `/etc/resolv.conf` behind your back.
- **Auditable interfaces.** Privileges (port binding, DHCP, firewall
  control) are explicit `plugs` the operator connects, not implicit
  side effects of an install script.
- **Predictable upgrades.** Refreshes are transactional; the previous
  revision is kept around for instant rollback.

## Repository layout

```
.github/workflows/build.yml  # lint + build + smoke-test CI
snap/
├── snapcraft.yaml           # the recipe
├── gui/
│   └── pihole.png           # store icon (upstream Vortex logo)
├── hooks/
│   ├── install              # creates data dirs on first install
│   └── configure            # maps `snap set` keys → pihole.toml
└── local/
    ├── launcher-ftl         # daemon launcher (port-53 check, exec FTL)
    └── launcher-pihole      # CLI launcher (intercepts unsupported subcommands)
tests/
└── unit/
    └── launcher-pihole.bats # subcommand-interception unit tests
```

## Building

```sh
snapcraft           # produces pihole_<version>_<arch>.snap
sudo snap install --dangerous --devmode ./pihole_*.snap
```

`--devmode` is required while `grade: devel` is set: confinement is
declared but not enforced, so AppArmor denials surface as warnings in
the journal rather than killing the daemon. Once smoke-tests are green
against real traffic we'll flip to `stable`.

## Architecture

Pi-hole v6 collapsed the old multi-process architecture (FTL +
lighttpd + PHP + cron) into a single binary, `pihole-FTL`, which now
serves DNS, DHCP, the HTTP API, and the embedded web admin UI. That
single-binary design is what makes a strictly-confined snap realistic;
v5 with its PHP/lighttpd dependency would have been much messier.

The snap has four build parts:

1. **`ftl`** — clones `pi-hole/FTL` at v6.6.2 and builds with CMake.
2. **`core`** — pulls `pi-hole/pi-hole` at v6.4.2 (the `pihole` CLI
   and supporting scripts) and stages it under `/opt/pihole`. Two
   `sed` patches at pull time swap out `service`/`systemctl` calls in
   `piholeLogFlush.sh` and `piholeDebug.sh` for `snapctl` equivalents.
3. **`web`** — pulls `pi-hole/web` at v6.5 into `$SNAP/var/www/html/admin`,
   served by FTL's embedded civetweb instance.
4. **`wrappers`** — copies the launcher scripts from `snap/local/`.

Path remapping is done in `snapcraft.yaml` via a `layout:` block that
bind-mounts the upstream-hardcoded paths onto `$SNAP_DATA` / `$SNAP_COMMON`
/ `$SNAP` inside the snap's mount namespace. The C code in FTL and the
bash scripts both keep their original paths and Just Work — no source
patching for paths, no environment-variable plumbing. Note in particular
that `/run/pihole-FTL.pid` is a `bind-file` (not `bind:`) because FTL
treats its PID-file path as security-sensitive and reads it from a
compile-time constant rather than from `pihole.toml`.

`launcher-ftl` does two things before `exec`-ing the daemon: detects
the systemd-resolved stub-listener conflict on port 53 (and prints a
copy-pasteable fix), and seeds an empty `pihole.toml` so FTL can fill
in defaults on first start.

## Operating

### First-time setup

```sh
# 1. Free port 53 (systemd-resolved holds it on Ubuntu).
sudo mkdir -p /etc/systemd/resolved.conf.d
printf '[Resolve]\nDNSStubListener=no\n' \
  | sudo tee /etc/systemd/resolved.conf.d/pihole.conf
sudo systemctl restart systemd-resolved

# 2. Connect baseline interfaces.
sudo snap connect pihole:network-bind

# 3. Start the daemon (it's `install-mode: disable` until you do).
sudo snap start --enable pihole.pihole-ftl

# 4. The admin password is printed to the daemon log on first start.
sudo snap logs pihole.pihole-ftl | grep -i password
```

The web admin UI is then at `http://<host>/admin`.

### Configuration via `snap set`

The configure hook maps a small set of keys to `pihole.toml` and
restarts the daemon if it's running:

| `snap set` key   | TOML key            |
|------------------|---------------------|
| `web-port`       | `webserver.port`    |
| `dns-port`       | `dns.port`          |
| `dhcp-enabled`   | `dhcp.active`       |
| `dhcp-start`     | `dhcp.start`        |
| `dhcp-end`       | `dhcp.end`          |
| `dhcp-router`    | `dhcp.router`       |
| `dhcp-leasetime` | `dhcp.leaseTime`    |
| `dhcp-domain`    | `dhcp.domain`       |

Everything else: edit `/var/snap/pihole/current/etc/pihole/pihole.toml`
directly, or use `sudo pihole.pihole <subcommand>`.

### DHCP

DHCP server mode is gated behind two extra interfaces that are
**declared but not auto-connected**:

```sh
sudo snap connect pihole:network-control
sudo snap connect pihole:firewall-control
sudo snap set pihole dhcp-enabled=true dhcp-start=192.0.2.50 dhcp-end=192.0.2.150 dhcp-router=192.0.2.1
```

We deliberately ship them on the same daemon (rather than splitting
DHCP into a second app behind a content interface): operators who only
want DNS sinkholing never `snap connect` them, so the elevated plugs
have no AppArmor effect. Splitting daemons would add real complexity
(shared config, lifecycle coupling) for no security gain.

### Migrating from a script-installed Pi-hole

The host-installed Pi-hole's state lives in `/etc/pihole/`. The snap's
layout maps `/etc/pihole` to `$SNAP_DATA/etc/pihole`, so a snap command
running inside confinement can't see the host's copy. Copy from the
host shell after the snap is installed but before the daemon starts:

```sh
sudo snap install --dangerous --devmode ./pihole_*.snap
sudo cp -a /etc/pihole/. /var/snap/pihole/current/etc/pihole/
sudo snap start --enable pihole.pihole-ftl
```

FTL v6 will migrate any legacy `setupVars.conf` / `pihole-FTL.conf`
into `pihole.toml` on first start.

### `pihole` subcommands

The wrapper intercepts subcommands that don't make sense inside a snap
and points at the snap-native equivalent:

| Blocked                          | Use instead                       |
|----------------------------------|-----------------------------------|
| `pihole -up` / `updatePihole`    | `sudo snap refresh pihole`        |
| `pihole updatechecker`           | `sudo snap refresh pihole`        |
| `pihole checkout <branch>`       | `sudo snap refresh pihole`        |
| `pihole -r` / `repair`           | `sudo snap revert pihole`         |
| `pihole uninstall`               | `sudo snap remove pihole`         |

Everything else (`status`, `-g`, `-q`, `setpassword`, `-l`, `tail`,
`reloaddns`, `reloadlists`, `networkflush`, `enable`/`disable`, list
management, `-d`/`debug`, `tricorder`, …) passes through to the
upstream `pihole` script.

## Testing

```sh
# Lint shell scripts
shellcheck snap/local/launcher-ftl snap/local/launcher-pihole \
           snap/hooks/install snap/hooks/configure

# Unit tests (apt install bats first)
bats tests/unit/

# End-to-end build + smoke
snapcraft
sudo snap install --dangerous --devmode ./pihole_*.snap
sudo snap start --enable pihole.pihole-ftl
dig @127.0.0.1 example.com
```

CI runs all of the above on every PR, plus a `snap set` round-trip
that asserts hook-driven TOML edits land, plus a (warn-only) sweep of
`dmesg` for `apparmor="DENIED"` lines tagged against `snap.pihole`.
Two `grep` guards in the `core` part's `override-pull` fail the build
if upstream changes the `service`/`systemctl` strings we patch.

## Remaining work

- [ ] **End-to-end LAN verification.** CI proves the snap installs and
      the daemon binds port 53. It does *not* yet prove a full
      query-and-block flow against a populated gravity DB. Run the
      snap against a real client device for a week before flipping
      `grade` to `stable`.
- [ ] **Subcommand verification by execution.** The smoke test exercises
      `version`, `status`, and the `-up` interception path. Extend it to
      cover `setpassword`, `-g` (gravity update), `-d`/`debug`, and
      `tricorder` once each one has a known-good expected output.
- [ ] **`snapcraft remote-build` for arm64/armhf.** GH-hosted runners
      only have amd64. Wire up a Launchpad credential and add a
      separate workflow for cross-arch builds.
- [ ] **Store publication.** Reserve `pi-hole` (or a near-name) in the
      Snap Store, set up the release tracks (edge / candidate /
      stable), and configure a release-on-tag pipeline.
- [ ] **Strict-confinement AppArmor pass.** CI now records denials but
      doesn't fail on them. Once the denial list is empty (or
      explainable), flip the warn-only grep to a hard fail and drop
      `--devmode` from the install commands.

## Out of scope

- **The Pi-hole installer script itself.** This snap is an alternative
  to it, not a wrapper around it.
- **Bundling `unbound`** or other upstream recursive resolvers. Users
  who want that should run unbound separately (possibly as its own
  snap) and point Pi-hole at `127.0.0.1#5335`.
- **HTTPS for the admin UI.** Use a reverse proxy (nginx, Caddy) on
  the host. FTL's embedded server handles HTTPS in v6 but cert
  management inside a confined snap is more friction than it's worth.

## License

The packaging code in this repository is licensed under
[EUPL-1.2](https://eupl.eu/1.2/en/), matching upstream Pi-hole.
