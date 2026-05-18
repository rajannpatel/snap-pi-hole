# CLI Commands

This page outlines the behavior of the `pihole` CLI command provided by the snap.

<details>
<summary>&ensp;TABLE OF CONTENTS<br><sup>&emsp;&ensp;&thinsp;&thinsp;CLICK TO EXPAND</sup><br></summary>

- **[THE PIHOLE CLI WRAPPER](#the-pihole-cli-wrapper)**<br><sub>UNDERSTANDING SNAP CONFINED COMMANDS</sub><br>
  > <sub>[BLOCKED COMMANDS](#blocked-commands)<br>COMMANDS THAT REQUIRE SNAP EQUIVALENTS</sub><br>
  > <sub>[SUPPORTED COMMANDS](#supported-commands)<br>PASS-THROUGH COMMANDS</sub><br>

</details>

---

<a name="the-pihole-cli-wrapper"></a>
## THE PIHOLE CLI WRAPPER

The official Pi-hole ecosystem includes a massive `pihole` bash script. Because snaps are confined and immutable, several of these subcommands do not make sense (e.g., you cannot "update" the pi-hole software using its bash script; you must use `snap refresh`). 

The snap provides a wrapper (`snap/local/launcher-pihole`) that intercepts these invalid commands and instructs the user on the correct Snap-native equivalent:

<a name="blocked-commands"></a>
### BLOCKED COMMANDS

| Blocked Command                  | Use Instead                       |
|----------------------------------|-----------------------------------|
| `pihole -up` / `updatePihole`    | `sudo snap refresh pihole`        |
| `pihole updatechecker`           | `sudo snap refresh pihole`        |
| `pihole checkout <branch>`       | `sudo snap refresh pihole`        |
| `pihole -r` / `repair`           | `sudo snap revert pihole`         |
| `pihole uninstall`               | `sudo snap remove pihole`         |

<a name="supported-commands"></a>
### SUPPORTED COMMANDS

Everything else seamlessly passes through to the upstream `pihole` script. You can use standard commands like:
- `sudo pihole status`
- `sudo pihole -g`
- `sudo pihole setpassword`
- `sudo pihole tail`
- `sudo pihole reloaddns`
- `sudo pihole -d` / `tricorder`
