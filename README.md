# pihole-snap

A [snap](https://snapcraft.io/) package for [Pi-hole](https://pi-hole.net),
the network-wide ad-blocking DNS sinkhole.

> **Status: scaffolding.** The `snapcraft.yaml` in this repo is a starting
> point. It builds, but the resulting snap is not yet a drop-in replacement
> for the upstream installer. See the **Open work** section below for what
> still needs doing before it is production-ready.

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
snap/
├── snapcraft.yaml         # the recipe
├── hooks/
│   ├── install            # creates data dirs on first install
│   └── configure          # stub for `snap set` keys
└── local/
    ├── launcher-ftl       # daemon launcher (sets paths, execs pihole-FTL)
    ├── launcher-pihole    # CLI launcher (wraps the `pihole` bash script)
    └── pihole-paths.env   # one source of truth for $SNAP_DATA path remap
```

## Building

```sh
snapcraft           # produces pihole_<version>_<arch>.snap
sudo snap install --dangerous --devmode ./pihole_*.snap
```

`--devmode` is the right mode for early iteration: confinement is
declared but not enforced, so AppArmor denials surface as warnings
in the journal rather than killing the daemon. Once the snap runs
clean under devmode we'll tighten back to `--jailmode` and finally
plain `snap install` against an uploaded build.

## Architecture

Pi-hole v6 collapsed the old multi-process architecture (FTL +
lighttpd + PHP + cron) into a single binary, `pihole-FTL`, which now
serves DNS, DHCP, the HTTP API, and the embedded web admin UI. That
single-binary design is what makes a strictly-confined snap realistic;
v5 with its PHP/lighttpd dependency would have been much messier.

The snap has three build parts:

1. **`ftl`** — clones `pi-hole/FTL`, builds with CMake. Produces
   `usr/bin/pihole-FTL` plus its shared-library dependencies.
2. **`core`** — pulls the `pi-hole/pi-hole` repo (the bash `pihole`
   CLI and supporting scripts) and stages it under `/opt/pihole`.
3. **`wrappers`** — copies the launcher scripts from `snap/local/`
   into the snap.

At runtime, `launcher-ftl` sources `pihole-paths.env` to remap every
hard-coded upstream path onto `$SNAP_DATA` / `$SNAP_COMMON`, then execs
`pihole-FTL no-daemon` so systemd-in-snapd manages the lifecycle.

## Open work

The scaffolding compiles and produces a snap; making that snap
actually serve DNS reliably is the work below.

- [ ] **Pin a real FTL/core version.** `v6.0.5` is a placeholder — bump
      to whatever the current upstream release is and verify the build
      packages list against `FTL/CMakeLists.txt`.
- [ ] **Path remapping inside FTL.** `pihole-paths.env` covers the
      shell scripts, but FTL has compile-time defaults in
      `src/config/dnsmasq.c` and `src/files.c` that need either CMake
      flags or a quilt patch. Confirm which env vars FTL honours in v6
      (`FTLCONFFILE` is known; the rest need verifying).
- [ ] **`pihole` CLI subcommand audit.** Walk every subcommand
      (`status`, `-g`, `-q`, `-up`, `setpassword`, `restartdns`,
      `logging`, `tail`, `disable`, `enable`, `debug`, `flush`,
      `chronometer`, `arpflush`, `version`, `uninstall`, `checkout`,
      `admin`) and mark which work, which need wrappers, which should
      be hidden inside the snap (e.g. `-up`, `uninstall`, `checkout`).
- [ ] **`configure` hook.** Wire up the keys listed in
      `hooks/configure` (`web-port`, `dns-port`, `dhcp-enabled`, …) to
      in-place TOML edits + `snapctl restart`.
- [ ] **Interface story for DHCP.** DHCP needs `network-control` and
      `firewall-control`. Decide whether to keep them on the same
      daemon (auto-connect: false, opt-in) or split DHCP into a second
      `daemon: simple` app behind a content interface.
- [ ] **Port 53 conflict UX.** The install hook can't disable
      `systemd-resolved` (we're confined), but it can detect the
      conflict and print a clear message via `snapctl`. Add that
      detection.
- [ ] **Migration from a script-installed Pi-hole.** A one-shot
      `pihole.import-legacy` command that reads `/etc/pihole/` on the
      host (via a `system-files` plug, manual connect only) and
      copies the gravity DB and config into `$SNAP_DATA`.
- [ ] **CI.** GitHub Actions matrix on amd64/arm64 that runs
      `snapcraft remote-build`, installs the resulting snap in a LXD
      container, queries `dig @127.0.0.1 doubleclick.net` against it,
      and asserts the response is `0.0.0.0`.
- [ ] **Store publication.** Track in the snap store under a
      `pihole-snap` or similar name once smoke tests pass; promote
      `grade` from `devel` to `stable` at that point.

## Out of scope

- **The Pi-hole installer script itself.** This snap is an alternative
  to it, not a wrapper around it.
- **Bundling `unbound`** or other upstream recursive resolvers. Users
  who want that should run unbound separately (possibly as its own
  snap) and point Pi-hole at `127.0.0.1#5335`.
- **HTTPS for the admin UI.** Use a reverse proxy (nginx, Caddy) on
  the host. The embedded server handles HTTPS in v6 but cert
  management inside a confined snap is more friction than it's worth.

## License

The packaging code in this repository is licensed under
[EUPL-1.2](https://eupl.eu/1.2/en/), matching upstream Pi-hole.
