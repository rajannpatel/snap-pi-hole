# Supported Systems

This page outlines the operating systems and CPU architectures officially supported by the Pi-hole snap.

<details>
<summary>&ensp;TABLE OF CONTENTS<br><sup>&emsp;&ensp;&thinsp;&thinsp;CLICK TO EXPAND</sup><br></summary>

- **[OPERATING SYSTEMS](#operating-systems)**<br><sub>UBUNTU LTS VERSIONS</sub><br>
- **[CPU ARCHITECTURES](#cpu-architectures)**<br><sub>AMD64, ARM64, AND ARMHF</sub><br>

</details>

---

<a name="operating-systems"></a>
## OPERATING SYSTEMS

The Pi-hole snap is built on the `core26` base snap (Ubuntu 26.04 LTS minimal base). However, because snaps bundle their dependencies and are isolated from the host OS, the snap can run on any distribution that supports `snapd`.

We officially test and support the following Ubuntu LTS releases:
- **Ubuntu 20.04 LTS (Focal Fossa)**
- **Ubuntu 22.04 LTS (Jammy Jellyfish)**
- **Ubuntu 24.04 LTS (Noble Numbat)**

While not officially tested, the snap is expected to function perfectly on Debian, Fedora, Arch Linux, and other distributions running modern versions of `snapd` (v2.55 or later).

---

<a name="cpu-architectures"></a>
## CPU ARCHITECTURES

Pi-hole is compiled and published for the following hardware architectures:
- `amd64` (Standard 64-bit Intel/AMD processors)
- `arm64` (64-bit ARM processors, such as the Raspberry Pi 4/5 running a 64-bit OS)
- `armhf` (32-bit ARM processors, such as older Raspberry Pi models)
