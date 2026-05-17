# How-To: migrate from a script-installed Pi-hole

If you have an existing Pi-hole installation (installed via `curl | bash` or a deb package), you can seamlessly migrate your configuration to the confined snap package.

> [!NOTE]
> **Pre-release status.** This snap is not yet published to the Snap Store, so step 1 below shows the future `snap install pihole` command. Until publication, the only supported path is to build the snap yourself per [How-To: Build and Test from Source](howto-build-and-test.md) and then install the local file with `--dangerous`. Do not install `.snap` files you did not build from a trusted source with `--dangerous`, because it bypasses signature verification.

## Understanding the paths

The host-installed Pi-hole's state lives in `/etc/pihole/`. The snap's layout strictly maps `/etc/pihole` to `$SNAP_DATA/etc/pihole` within its own mount namespace. 

This means a snap command running inside confinement cannot "see" your host's copy. You must manually copy the configuration into the snap's data directory.

## Migration steps

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

### Configuration upgrades

If you are migrating from an older Pi-hole version (v5 or earlier), the new FTL v6 daemon will automatically migrate any legacy `setupVars.conf` or `pihole-FTL.conf` files into the new `pihole.toml` syntax on its very first start! No manual conversion is required.
