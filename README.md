# Pi-hole snap package

<img align="right" src="./snap/gui/pihole.png" width="120" alt="Pi-hole Logo">

[![Build and Smoke Test](https://github.com/rajannpatel/snap-pi-hole/actions/workflows/edge.yml/badge.svg)](https://github.com/rajannpatel/snap-pi-hole/actions/workflows/edge.yml)
[![Upstream Tracker](https://github.com/rajannpatel/snap-pi-hole/actions/workflows/update-upstream.yml/badge.svg)](https://github.com/rajannpatel/snap-pi-hole/actions/workflows/update-upstream.yml)

> | Upstream Component | Current Version |
> | :--- | :--- |
> | **[FTL](https://github.com/pi-hole/FTL)** | v6.6.2 |
> | **[pi-hole (core)](https://github.com/pi-hole/pi-hole)** | v6.4.2 |
> | **[web](https://github.com/pi-hole/web)** | v6.5 |
>
> These versions are automatically tracked and updated by a daily GitHub Actions bot

This snap is currently published with `grade: devel`; it will not install from the `stable` risk level until a green end-to-end smoke test on real DNS traffic is completed.

---
A strictly confined, native [snap](https://snapcraft.io/) package for [Pi-hole](https://pi-hole.net), the network-wide ad-blocking DNS sinkhole.

[![Get it from the Snap Store](https://snapcraft.io/en/dark/install.svg)](https://snapcraft.io/pihole-by-rajannpatel)

## Documentation

The documentation is organized according to the [Diátaxis framework](https://diataxis.fr/) and is hosted in the **[GitHub Wiki](https://github.com/rajannpatel/snap-pi-hole/wiki)**:

* **[Tutorials](https://github.com/rajannpatel/snap-pi-hole/wiki/Tutorial:-Getting-Started)**: Step-by-step learning for beginners.
* **[How-To Guides](https://github.com/rajannpatel/snap-pi-hole/wiki/How-To:-Supported-Deployment-Patterns)**: Problem-oriented instructions.
* **[Reference](https://github.com/rajannpatel/snap-pi-hole/wiki/Reference:-Native-Configuration)**: Information-oriented technical references.
* **[Explanation](https://github.com/rajannpatel/snap-pi-hole/wiki/Explanation:-Architecture-and-Rationale)**: Understanding-oriented background information.