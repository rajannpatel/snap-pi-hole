# Pi-hole Snap Package

<img align="right" src="./snap/gui/pihole.png" width="120" alt="Pi-hole Logo">

[![Build and Smoke Test](https://github.com/rajannpatel/snap-pi-hole/actions/workflows/build.yml/badge.svg)](https://github.com/rajannpatel/snap-pi-hole/actions/workflows/build.yml)
[![Upstream Tracker](https://github.com/rajannpatel/snap-pi-hole/actions/workflows/update-upstream.yml/badge.svg)](https://github.com/rajannpatel/snap-pi-hole/actions/workflows/update-upstream.yml)


> | Upstream Component | Current Version |
> | :--- | :--- |
> | **FTL** | v6.6.2 |
> | **pi-hole (core)** | v6.4.2 |
> | **web** | v6.5 |
> 
> These versions are automatically tracked and updated by a daily GitHub Actions bot

---

**What is the Pi-hole snap?**

It is a strictly confined, native [snap](https://snapcraft.io/) package for [Pi-hole](https://pi-hole.net), the network-wide ad-blocking DNS sinkhole. It packages Pi-hole's DNS resolver, DHCP server, and web admin interface into a single, immutable package.

**How does it work?**

It bind-mounts Pi-hole's upstream-hardcoded paths into the snap's secure data directory and intercepts incompatible CLI commands, allowing the standard Pi-hole daemon to run out-of-the-box in strict AppArmor confinement.

**Who is it for?**

It is built for homelab operators, system administrators, and privacy advocates who want a stable, network-wide ad blocker without mutating their host operating system.

**Where does it fit?**

Use the Pi-hole snap to:
- Replace Pi-hole's manual `curl | bash` installation script.
- Ensure atomic, one-click rollbacks if a DNS update breaks your network.
- Explicitly audit network privileges rather than granting a script root access.

## In this documentation

- 🎓 **Tutorial**
  - [Getting Started with the Pi-hole Snap](docs/tutorial-getting-started.md)
- 🛠️ **How-to guides**
  - [Configure DHCP](docs/howto-dhcp-setup.md)
  - [Migrate from a Script Install](docs/howto-migrate-from-script.md)
  - [Build and Test from Source](docs/howto-build-and-test.md)
- 📚 **Reference**
  - [Configuration, CLI Wrapping, and Layout](docs/reference.md)
- 💡 **Explanation**
  - [Architecture and Rationale](docs/explanation-architecture.md)
  - [Why Unbound is Not Bundled](docs/explanation-unbound.md)

## Project and community

The contents of this repository (`snapcraft.yaml`, `launcher-ftl` scripts, and the GitHub Actions) are simply build instructions and wrapper scripts. They don't contain any of Pi-hole's source code. Licensing these under a permissive license like MIT is standard practice and highly encouraged.