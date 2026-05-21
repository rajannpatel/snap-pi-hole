# Pi-hole snap package

<img align="right" src="./snap/gui/pihole.png" width="120" alt="Pi-hole Logo">

A strictly confined, native [snap](https://snapcraft.io/) package for [Pi-hole](https://pi-hole.net), the network-wide ad-blocking DNS sinkhole.

[![Get it from the Snap Store](https://snapcraft.io/en/dark/install.svg)](https://snapcraft.io/pihole-by-rajannpatel)

> [!NOTE]
> Pi-hole FTL v6.6.x dropped support for mbedTLS 2.x and now strictly requires mbedTLS ≥ 3.5.0 and Nettle ≥ 3.9. The Ubuntu Core 24 snap base (`core24`) ships older versions of both libraries, so the package was bumped to Ubuntu Core 26 (`core26`).

| Upstream Component | Current Version |
| :--- | :--- |
| [![Upstream Tracker](https://github.com/rajannpatel/snap-pi-hole/actions/workflows/update-upstream.yml/badge.svg)](https://github.com/rajannpatel/snap-pi-hole/actions/workflows/update-upstream.yml) | [![Update Upstream Tags](https://github.com/rajannpatel/snap-pi-hole/actions/workflows/update-tags.yml/badge.svg)](https://github.com/rajannpatel/snap-pi-hole/actions/workflows/update-tags.yml) |
| **[FTL](https://github.com/pi-hole/FTL)** | v6.6.2 |
| **[pi-hole (core)](https://github.com/pi-hole/pi-hole)** | v6.4.2 |
| **[web](https://github.com/pi-hole/web)** | v6.5 |

> These versions are automatically tracked and updated by a daily GitHub Actions bot
> 
> [![Build and Smoke Test](https://github.com/rajannpatel/snap-pi-hole/actions/workflows/publish.yml/badge.svg)](https://github.com/rajannpatel/snap-pi-hole/actions/workflows/publish.yml)

## More information

**[Documentation](https://github.com/rajannpatel/snap-pi-hole/wiki)**

* **[Tutorial](https://github.com/rajannpatel/snap-pi-hole/wiki/Tutorial:-Getting-Started)**

   Step-by-step learning for beginners.

* **[How-To Guides](https://github.com/rajannpatel/snap-pi-hole/wiki/How-To:-Supported-Deployment-Patterns)**

   Problem-oriented instructions.

* **[Reference](https://github.com/rajannpatel/snap-pi-hole/wiki/Reference:-Native-Configuration)**

   Information-oriented technical references.

* **[Explanation](https://github.com/rajannpatel/snap-pi-hole/wiki/Explanation:-Architecture-and-Rationale)**

   Understanding-oriented background information.