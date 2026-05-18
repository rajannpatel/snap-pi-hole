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
A strictly confined, native [snap](https://snapcraft.io/) package for [Pi-hole](https://pi-hole.net), the network-wide ad-blocking DNS sinkhole.

For a detailed explanation of what this snap is, how it works, and why it's the preferred deployment method, please see the **[Home Page of our Wiki](https://github.com/rajannpatel/snap-pi-hole/wiki)**!

## In this documentation

- 🎓 **Tutorial**
  - [Getting Started with the Pi-hole Snap](https://github.com/rajannpatel/snap-pi-hole/wiki/Tutorial:-Getting-Started)
- 🛠️ **How-to guides**
  - [Migrate from an Existing Install](https://github.com/rajannpatel/snap-pi-hole/wiki/How-To:-Migrate-from-an-Existing-Install)
  - [Supported Deployment Patterns](https://github.com/rajannpatel/snap-pi-hole/wiki/How-To:-Supported-Deployment-Patterns)
  - [Operator Runbook](https://github.com/rajannpatel/snap-pi-hole/wiki/How-To:-Operator-Runbook)
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
  - [Topology and Architecture](https://github.com/rajannpatel/snap-pi-hole/wiki/Explanation:-Topology-and-Architecture)
  - [Security Model](https://github.com/rajannpatel/snap-pi-hole/wiki/Explanation:-Security-Model)
  - [Why Unbound is Not Bundled](https://github.com/rajannpatel/snap-pi-hole/wiki/Explanation:-Why-Unbound-is-Not-Bundled)
  - [Refresh Behavior and Updates](https://github.com/rajannpatel/snap-pi-hole/wiki/Explanation:-Refresh-Behavior-and-Updates)

## Project and community

The contents of this repository (`snapcraft.yaml`, `launcher-ftl` scripts, and the GitHub Actions) are simply build instructions and wrapper scripts. They don't contain any of Pi-hole's source code. Therefore, this snap package is licensed under a permissive MIT license. This is a standard practice and highly encouraged.