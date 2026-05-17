# Reference

This page contains reference materials for configuring and understanding the Pi-hole snap ecosystem.

## `snap set` configuration keys

The snap's `configure` hook maps a small set of predefined `snap set` keys directly into Pi-hole's configuration file (`/var/snap/pihole/current/etc/pihole/pihole.toml`). If the daemon is running when a setting is updated, the hook automatically restarts it.

| `snap set` key   | TOML key            | Description                                  |
|------------------|---------------------|----------------------------------------------|
| `web-port`       | `webserver.port`    | The HTTP port the web admin UI listens on.   |
| `dns-port`       | `dns.port`          | The DNS port the daemon binds to.            |
| `dhcp-enabled`   | `dhcp.active`       | Enable (`true`) or disable the DHCP server.  |
| `dhcp-start`     | `dhcp.start`        | The start of the DHCP IP address pool.       |
| `dhcp-end`       | `dhcp.end`          | The end of the DHCP IP address pool.         |
| `dhcp-router`    | `dhcp.router`       | The default gateway assigned to clients.     |
| `dhcp-leasetime` | `dhcp.leaseTime`    | The DHCP lease duration (in hours).          |
| `dhcp-domain`    | `dhcp.domain`       | The local domain name assigned to clients.   |

For all other advanced Pi-hole configuration, edit the `pihole.toml` file directly.

## The `pihole` CLI wrapper

The official Pi-hole ecosystem includes a massive `pihole` bash script. Because snaps are confined and immutable, several of these subcommands do not make sense (e.g., you cannot "update" the pi-hole software using its bash script; you must use `snap refresh`). 

The snap provides a wrapper (`snap/local/launcher-pihole`) that intercepts these invalid commands and instructs the user on the correct Snap-native equivalent:

| Blocked Command                  | Use Instead                       |
|----------------------------------|-----------------------------------|
| `pihole -up` / `updatePihole`    | `sudo snap refresh pihole`        |
| `pihole updatechecker`           | `sudo snap refresh pihole`        |
| `pihole checkout <branch>`       | `sudo snap refresh pihole`        |
| `pihole -r` / `repair`           | `sudo snap revert pihole`         |
| `pihole uninstall`               | `sudo snap remove pihole`         |

Everything else seamlessly passes through to the upstream `pihole` script. You can use standard commands like:
- `sudo pihole status`
- `sudo pihole -g`
- `sudo pihole setpassword`
- `sudo pihole tail`
- `sudo pihole reloaddns`
- `sudo pihole -d` / `tricorder`

## Repository layout

```text
.github/workflows/
├── build.yml                # lint + build + smoke-test CI (push, PR)
├── release.yml              # tag-driven publish to the Snap Store
└── update-upstream.yml      # daily cron to bump upstream version tags
docs/                        # Diátaxis documentation framework
snap/
├── snapcraft.yaml           # the declarative build recipe
├── gui/
│   └── pihole.png           # store icon (upstream Vortex logo)
├── hooks/
│   ├── install              # creates data dirs on first install
│   ├── configure            # maps `snap set` keys → pihole.toml
│   ├── pre-refresh          # warns operator about DNS hand-off before upgrade
│   └── remove               # restores systemd-resolved stub on uninstall
└── local/
    ├── launcher-ftl         # daemon launcher (port-53 check, exec FTL)
    └── launcher-pihole      # CLI launcher (intercepts unsupported subcommands)
tests/
└── unit/
    └── launcher-pihole.bats # subcommand-interception unit tests
```
