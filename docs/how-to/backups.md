# How-To: Backups and Restores

This guide explains how to back up and restore your Pi-hole snap configuration data.

<details>
<summary>&ensp;TABLE OF CONTENTS<br><sup>&emsp;&ensp;&thinsp;&thinsp;CLICK TO EXPAND</sup><br></summary>

- **[MANUAL BACKUPS](#manual-backups)**<br><sub>USING SNAP SAVE</sub><br>
- **[AUTOMATIC SNAPSHOTS](#automatic-snapshots)**<br><sub>PRE-REFRESH ARCHIVES</sub><br>

</details>

---

<a name="manual-backups"></a>
## MANUAL BACKUPS

The snap ecosystem provides a native, robust mechanism for capturing the state of an application. You can take a complete snapshot of your Pi-hole configuration, database, and logs at any time.

### Creating a Snapshot
To create a manual backup, use the `snap save` command:
```bash
sudo snap save pihole
```
This will output a Snapshot ID, which you can use to identify the backup.

### Restoring a Snapshot
To restore a previously created snapshot, use the `snap restore` command followed by the Snapshot ID:
```bash
sudo snap restore <Snapshot-ID>
```
*Note: Restoring a snapshot will stop the daemon, revert the data directory to the exact state it was in when the snapshot was taken, and then restart the daemon.*

---

<a name="automatic-snapshots"></a>
## AUTOMATIC SNAPSHOTS

To guarantee safety during updates, the Pi-hole snap employs a `pre-refresh` hook. Before any update is allowed to apply, the snap automatically creates a compressed `.tar.gz` archive of your `/etc/pihole` directory (which includes `pihole.toml`, `gravity.db`, and custom adlists).

These automatic archives are stored securely within the snap's data directory.

### Locating Automatic Archives
You can find these automatic backups in the common data directory:
```bash
ls -l /var/snap/pihole/common/backups/
```

### Restoring an Automatic Archive
If a refresh goes wrong and you need to manually extract data from an automatic archive:
1. Stop the snap daemon:
   ```bash
   sudo snap stop pihole.pihole-ftl
   ```
2. Extract the archive over the current configuration directory:
   ```bash
   sudo tar -xzf /var/snap/pihole/common/backups/pihole-pre-refresh-v6.4.2.tar.gz -C /var/snap/pihole/current/etc/pihole/
   ```
3. Start the snap daemon:
   ```bash
   sudo snap start pihole.pihole-ftl
   ```
