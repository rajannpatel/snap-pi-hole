# How-To: Migrate from an Existing Installation

This guide explains how to migrate an existing Pi-hole configuration to the confined snap package.

<details>
<summary>&ensp;TABLE OF CONTENTS<br><sup>&emsp;&ensp;&thinsp;&thinsp;CLICK TO EXPAND</sup><br></summary>

- **[MIGRATION TYPES](#migration-types)**<br><sub>APT DEPENDENCIES VS INSTALL SCRIPT</sub><br>
- **[UNDERSTANDING THE PATHS](#understanding-the-paths)**<br><sub>CONFINED DATA DIRECTORIES</sub><br>
- **[MIGRATION STEPS](#migration-steps)**<br><sub>HOW TO COPY YOUR CONFIGURATION</sub><br>
- **[UPGRADES](#upgrades)**<br><sub>MIGRATING TO V6 CONFIGURATION SYNTAX</sub><br>

</details>

---

<a name="migration-types"></a>
## MIGRATION TYPES

Whether you installed Pi-hole using the official `curl | bash` install script or manually via traditional `apt` package dependencies, your host Pi-hole installation stores its state on the host filesystem. You can seamlessly migrate your configuration to the snap without data loss.

> [!NOTE]
> **Pre-release status.** This snap is not yet published to the Snap Store, so the steps below show the future `snap install pihole` command. Until publication, the only supported path is to build the snap yourself per the Build and Test guide and then install the local file with `--dangerous`. Do not install `.snap` files you did not build from a trusted source with `--dangerous`, because it bypasses signature verification.

---

<a name="understanding-the-paths"></a>
## UNDERSTANDING THE PATHS

The host-installed Pi-hole's state lives in `/etc/pihole/`. The snap's layout strictly maps `/etc/pihole` to `$SNAP_DATA/etc/pihole` within its own mount namespace. 

This means a snap command running inside confinement cannot "see" your host's copy. You must manually copy the configuration into the snap's data directory.

---

<a name="migration-steps"></a>
## MIGRATION STEPS

1. **Install the snap:** Do not start the daemon yet!
   ```bash
   sudo snap install pihole
   ```

2. **Copy your existing configuration:**
   Copy the contents of your host's `/etc/pihole/` into the snap's equivalent data directory:
   ```bash
   sudo cp -a /etc/pihole/. /var/snap/pihole/current/etc/pihole/
   ```

3. **Start the Snap Daemon:**
   Enable and start the snap daemon:
   ```bash
   sudo snap start --enable pihole.pihole-ftl
   ```

---

<a name="upgrades"></a>
## UPGRADES

If you are migrating from an older Pi-hole version (v5 or earlier), the new FTL v6 daemon will automatically migrate any legacy `setupVars.conf` or `pihole-FTL.conf` files into the new `pihole.toml` syntax on its very first start! No manual conversion is required.
