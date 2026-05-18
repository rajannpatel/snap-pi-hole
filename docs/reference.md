# Reference

This page contains reference materials for configuring and understanding the Pi-hole snap ecosystem.

## `snap set` configuration keys

The Pi-hole snap acts as a transparent configuration proxy for the underlying `pihole-FTL` daemon. You can manage **any** configuration key available in upstream Pi-hole natively using `snap set` by prefixing the key with `ftl.`.

The snap's `configure` hook dynamically translates `snap set` keys into FTL's configuration syntax (`/var/snap/pihole/current/etc/pihole/pihole.toml`) and delegates all validation to the daemon itself. If the daemon is running when a setting is updated, the hook automatically restarts it.

### Examples

To set the web server port to 8123 (maps to `webserver.port` in FTL):
```bash
sudo snap set pihole ftl.webserver.port=8123
```

To configure multiple upstream DNS servers (maps to `dns.upstreams` in FTL):
```bash
sudo snap set pihole ftl.dns.upstreams="8.8.8.8,1.1.1.1"
```

To configure DNS interface binding behavior (maps to `dns.listeningMode` in FTL):
```bash
sudo snap set pihole ftl.dns.listeningMode=all
```

For a comprehensive list of all available configuration keys, consult the [upstream Pi-hole configuration documentation](https://docs.pi-hole.net/ftldns/configfile/).

### Validation and Type Safety

Because the snap leverages `pihole-FTL --config` internally to apply these settings, FTL will strictly validate your inputs. If you attempt to set an invalid value (e.g., passing a string to an integer field), FTL will reject the value, the hook transaction will fail gracefully, and the invalid configuration will be blocked.

### Automated Gravity Updates

In a traditional Pi-hole installation, the gravity database is updated weekly via a cron job. The snap mimics this behavior natively using a snapd timer service (`gravity-sync`).

By default, the snap automatically updates gravity every Sunday between 3:00 AM and 5:00 AM. 

You can completely customize this schedule natively through snapd using `snap set`. For example, to change the update schedule to Mondays at 2:00 AM:
```bash
sudo snap set pihole timer.gravity-sync.schedule="mon,02:00"
```

### Automatic Refresh Safety Mechanisms

Because Pi-hole controls DNS for your entire network, automatic updates (refreshes) must be rock solid. We implemented 4 pillars of safety to guarantee zero data loss and zero downtime during snap updates:

1. **Transactional Refreshes (Zero Downtime)**: The snap is configured with `refresh-mode: endure`. When a new update downloads, the old FTL daemon continues to serve DNS queries completely uninterrupted. It is only killed *after* the new daemon starts up successfully.
2. **Pre-refresh Snapshots**: Before the new snap revision is allowed to execute any code, the `pre-refresh` hook safely snapshots your `/etc/pihole` configuration (including `gravity.db` and custom lists) into a `.tar.gz` archive. This guarantees you always have a manual rollback point.
3. **Schema Validation & Rollbacks**: After the new snap starts, the `post-refresh` hook intercepts your configuration and re-runs it through the strict schema validator. If the new Pi-hole version introduces a breaking change to configuration parameters, the validation fails and `snapd` **automatically aborts and rolls back** to the previous working version.
4. **Post-refresh Health Checks**: Finally, `post-refresh` queries the new daemon for local DNS resolution (`pi.hole`). If FTL fails to respond within 5 seconds, it exits with an error, triggering another automatic rollback.

While ConfDB is available in `snapd` that runs alongside `core26`, it is still an experimental feature. 

To use native ConfDB today, you have to:
1. Explicitly enable it on the host system via `sudo snap set system experimental.confdb=true`.
2. Provide a `confdb-schema` assertion to `snapd`.

Furthermore, native ConfDB is currently heavily geared toward the **Custodian-Observer pattern**, which is designed for securely sharing configuration data *between* different snaps, rather than just managing internal configuration for a standalone app like Pi-hole. 

Because it requires users to opt into experimental features at the system level, I opted not to rely on native ConfDB for this production-readiness at this point in time. It will be trivial to transfer over to native ConfDB once it is stable. 

By building our own schema validator, we essentially backported the "flavor" and strictness of ConfDB into a mechanism that works out-of-the-box on every system without requiring experimental flags!

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
