# Configuration

This page contains reference materials for configuring the Pi-hole snap ecosystem.

<details>
<summary>&ensp;TABLE OF CONTENTS<br><sup>&emsp;&ensp;&thinsp;&thinsp;CLICK TO EXPAND</sup><br></summary>

- **[NATIVE SNAP CONFIGURATION](#native-snap-configuration)**<br><sub>MANAGE PI-HOLE SETTINGS THROUGH SNAPCTL</sub><br>
  > <sub>[EXAMPLES](#examples)<br>COMMON CONFIGURATION CHANGES</sub><br>
  > <sub>[VALIDATION](#validation)<br>TYPE SAFETY AND SCHEMA CHECKING</sub><br>
- **[AUTOMATED UPDATES](#automated-updates)**<br><sub>GRAVITY SYNC CONFIGURATION</sub><br>

</details>

---

<a name="native-snap-configuration"></a>
## NATIVE SNAP CONFIGURATION

The Pi-hole snap acts as a transparent configuration proxy for the underlying `pihole-FTL` daemon. You can manage **any** configuration key available in upstream Pi-hole natively using `snap set` by prefixing the key with `ftl.`.

The snap's `configure` hook dynamically translates `snap set` keys into FTL's configuration syntax (`/var/snap/pihole/current/etc/pihole/pihole.toml`) and delegates all validation to the daemon itself. If the daemon is running when a setting is updated, the hook automatically restarts it.

<a name="examples"></a>
### EXAMPLES

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

<a name="validation"></a>
### VALIDATION

Because the snap leverages `pihole-FTL --config` internally to apply these settings, FTL will strictly validate your inputs. If you attempt to set an invalid value (e.g., passing a string to an integer field), FTL will reject the value, the hook transaction will fail gracefully, and the invalid configuration will be blocked.

---

<a name="automated-updates"></a>
## AUTOMATED UPDATES

In a traditional Pi-hole installation, the gravity database is updated weekly via a cron job. The snap mimics this behavior natively using a snapd timer service (`gravity-sync`).

By default, the snap automatically updates gravity every Sunday between 3:00 AM and 5:00 AM. 

You can completely customize this schedule natively through snapd using `snap set`. For example, to change the update schedule to Mondays at 2:00 AM:
```bash
sudo snap set pihole timer.gravity-sync.schedule="mon,02:00"
```
