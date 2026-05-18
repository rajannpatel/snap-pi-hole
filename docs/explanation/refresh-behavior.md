# Refresh Behavior and Updates

This page explains how the Pi-hole snap manages automatic updates and ensures zero downtime during the process.

<details>
<summary>&ensp;TABLE OF CONTENTS<br><sup>&emsp;&ensp;&thinsp;&thinsp;CLICK TO EXPAND</sup><br></summary>

- **[AUTOMATIC REFRESH SAFETY MECHANISMS](#automatic-refresh-safety-mechanisms)**<br><sub>THE FOUR PILLARS OF SNAP UPDATES</sub><br>
- **[CUSTOM SCHEMA VALIDATION](#custom-schema-validation)**<br><sub>WHY WE USE A CUSTOM VALIDATOR INSTEAD OF CONFDB</sub><br>

</details>

---

<a name="automatic-refresh-safety-mechanisms"></a>
## AUTOMATIC REFRESH SAFETY MECHANISMS

Because Pi-hole controls DNS for your entire network, automatic updates (refreshes) must be rock solid. We implemented 4 pillars of safety to guarantee zero data loss and zero downtime during snap updates:

1. **Transactional Refreshes (Zero Downtime)**: The snap is configured with `refresh-mode: endure`. When a new update downloads, the old FTL daemon continues to serve DNS queries completely uninterrupted. It is only killed *after* the new daemon starts up successfully.
2. **Pre-refresh Snapshots**: Before the new snap revision is allowed to execute any code, the `pre-refresh` hook safely snapshots your `/etc/pihole` configuration (including `gravity.db` and custom lists) into a `.tar.gz` archive. This guarantees you always have a manual rollback point.
3. **Schema Validation and Rollbacks**: After the new snap starts, the `post-refresh` hook intercepts your configuration and re-runs it through the strict schema validator. If the new Pi-hole version introduces a breaking change to configuration parameters, the validation fails and `snapd` **automatically aborts and rolls back** to the previous working version.
4. **Post-refresh Health Checks**: Finally, `post-refresh` queries the new daemon for local DNS resolution (`pi.hole`). If FTL fails to respond within 5 seconds, it exits with an error, triggering another automatic rollback.

---

<a name="custom-schema-validation"></a>
## CUSTOM SCHEMA VALIDATION

While ConfDB is available in `snapd` that runs alongside `core26`, it is still an experimental feature. 

To use native ConfDB today, you have to:
1. Explicitly enable it on the host system via `sudo snap set system experimental.confdb=true`.
2. Provide a `confdb-schema` assertion to `snapd`.

Furthermore, native ConfDB is currently heavily geared toward the **Custodian-Observer pattern**, which is designed for securely sharing configuration data *between* different snaps, rather than just managing internal configuration for a standalone app like Pi-hole. 

Because it requires users to opt into experimental features at the system level, we opted not to rely on native ConfDB for this production readiness at this point in time. It will be trivial to transfer over to native ConfDB once it is stable. 

By building our own schema validator, we essentially backported the "flavor" and strictness of ConfDB into a mechanism that works out-of-the-box on every system without requiring experimental flags!
