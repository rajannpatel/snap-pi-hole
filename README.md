# Pi-hole Snap Package

<img align="right" src="./snap/gui/pihole.png" width="120" alt="Pi-hole Logo">

[![Build and Smoke Test](https://github.com/rajannpatel/snap-pi-hole/actions/workflows/build.yml/badge.svg)](https://github.com/rajannpatel/snap-pi-hole/actions/workflows/build.yml)
[![Upstream Tracker](https://github.com/rajannpatel/snap-pi-hole/actions/workflows/update-upstream.yml/badge.svg)](https://github.com/rajannpatel/snap-pi-hole/actions/workflows/update-upstream.yml)


> | Upstream Component | Current Version |
> | :--- | :--- |
> | **[FTL](https://github.com/pi-hole/FTL)** | v6.6.2 |
> | **[pi-hole (core)](https://github.com/pi-hole/pi-hole)** | v6.4.2 |
> | **[web](https://github.com/pi-hole/web)** | v6.5 |
>
> These versions are automatically tracked and updated by a daily GitHub Actions bot

> [!NOTE]
> **This snap is built on the Ubuntu [Core 26 base snap (core26)](https://snapcraft.io/core26).**
>
> Pi-hole FTL v6.6.x dropped support for mbedTLS 2.x and now strictly requires **mbedTLS ≥ 3.5.0** and **Nettle ≥ 3.9**. The Ubuntu Core 24 snap base (core24) ships older versions of both libraries, so the package is built on Ubuntu Core 26 (core26).

This snap is currently published with `grade: devel`; it will not install from the `stable` risk level until I have a green end-to-end smoke test on real DNS traffic.

---

**What is the Pi-hole snap?**

It is a strictly confined, native [snap](https://snapcraft.io/) package for [Pi-hole](https://pi-hole.net), the network-wide ad-blocking DNS sinkhole. It packages Pi-hole's DNS resolver, DHCP server, and web admin interface into a single, immutable package.

**How does it work?**

It bind-mounts Pi-hole's upstream-hardcoded paths into the snap's secure data directory and intercepts incompatible CLI commands, allowing the standard Pi-hole daemon to run out-of-the-box in strict AppArmor confinement.

**Who is it for?**

It is built for homelab operators, system administrators, and privacy advocates who want a stable, network-wide ad blocker without mutating their host operating system.

## Why choose the Pi-hole Snap?

Snaps provide a comprehensive, multi-layered approach to software distribution that extends from basic application delivery to full system management. The Pi-hole snap leverages these capabilities to provide a superior deployment experience:

- **System Integrity**: The snap is a tamper-proof, GPG-signed, and compressed read-only filesystem image. Unlike traditional packages, it is mounted rather than unpacked on disk, preventing accidental mutations to the core binaries.
- **Safe & Reliable Updates**: Updates are fully transactional. If a Pi-hole update breaks your network's DNS, you have clear rollback capabilities to safely return to the previous stable state (`snap revert pihole`).
- **Security by Design**: The snap security model follows a "deny by default" principle. Pi-hole runs in an isolated AppArmor sandbox, with system access mediated through pre-defined interfaces explicitly controlled by the administrator.
- **Long-Term Maintainability**: Snapping Pi-hole decouples it from your underlying OS library versions, effectively solving dependency conflicts "forever in the future" and keeping your host operating system clean.
- **Built-in Data Protection**: Snaps include a native backup and restore mechanism (`snap save pihole`). Pre-refresh hooks also automatically back up your Pi-hole configuration and blocklists to ensure your user state is perfectly preserved during updates or rollbacks.

## In this documentation

- 🎓 **Tutorial**
  - [Getting Started with the Pi-hole Snap](https://github.com/rajannpatel/snap-pi-hole/wiki/Tutorial:-Getting-Started)
- 🛠️ **How-to guides**
  - [Migrate from an Existing Install](https://github.com/rajannpatel/snap-pi-hole/wiki/How-To:-Migrate-from-an-Existing-Install)
  - [Configure DHCP](https://github.com/rajannpatel/snap-pi-hole/wiki/How-To:-Configure-DHCP)
  - [Backups and Restores](https://github.com/rajannpatel/snap-pi-hole/wiki/How-To:-Backups-and-Restores)
  - [Build and Test from Source](https://github.com/rajannpatel/snap-pi-hole/wiki/How-To:-Build-and-Test-from-Source)
- 📚 **Reference**
  - [Native Configuration](https://github.com/rajannpatel/snap-pi-hole/wiki/Reference:-Native-Configuration)
  - [CLI Wrapper Commands](https://github.com/rajannpatel/snap-pi-hole/wiki/Reference:-CLI-Wrapper-Commands)
  - [Networking Compatibility](https://github.com/rajannpatel/snap-pi-hole/wiki/Reference:-Networking-Compatibility)
  - [Ports and Firewall](https://github.com/rajannpatel/snap-pi-hole/wiki/Reference:-Ports-and-Firewall)
  - [Supported Systems](https://github.com/rajannpatel/snap-pi-hole/wiki/Reference:-Supported-Systems)
- 💡 **Explanation**
  - [Architecture and Rationale](https://github.com/rajannpatel/snap-pi-hole/wiki/Explanation:-Architecture-and-Rationale)
  - [Why Unbound is Not Bundled](https://github.com/rajannpatel/snap-pi-hole/wiki/Explanation:-Why-Unbound-is-Not-Bundled)
  - [Refresh Behavior and Updates](https://github.com/rajannpatel/snap-pi-hole/wiki/Explanation:-Refresh-Behavior-and-Updates)

## Project and community

The contents of this repository (`snapcraft.yaml`, `launcher-ftl` scripts, and the GitHub Actions) are simply build instructions and wrapper scripts. They don't contain any of Pi-hole's source code. Therefore, this snap package is licensed under a permissive MIT license. This is a standard practice and highly encouraged.