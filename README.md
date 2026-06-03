# Pi-hole snap package

<img align="right" src="./snap/gui/pihole.png" width="120" alt="Pi-hole Logo">

A strictly confined, native [snap](https://snapcraft.io/) package for [Pi-hole](https://pi-hole.net), the network-wide ad-blocking DNS sinkhole.

[![CI/CD Pipeline](https://img.shields.io/github/actions/workflow/status/rajannpatel/snap-pi-hole/cicd.yml?branch=main&style=flat-square&label=CI/CD%20Pipeline)](https://github.com/rajannpatel/snap-pi-hole/actions/workflows/cicd.yml)
[![Code Coverage](https://img.shields.io/badge/Code%20Coverage-kcov-blue?style=flat-square&logo=github)](https://rajannpatel.github.io/snap-pi-hole/coverage/)
[![SBOM Reports](https://img.shields.io/badge/SBOM-CycloneDX-blue?style=flat-square&logo=github)](https://rajannpatel.github.io/snap-pi-hole/sbom/)

[![Get it from the Snap Store](https://snapcraft.io/en/dark/install.svg)](https://snapcraft.io/pihole-by-rajannpatel)

---

## Installation

```bash
# 1. Install snapd (if not already present on the host)
# - On Debian:
#     sudo apt update && sudo apt install -y snapd
# - On Fedora:
#     sudo dnf install -y snapd && sudo systemctl enable --now snapd.socket && sudo ln -s /var/lib/snapd/snap /snap
# - On Rocky Linux/AlmaLinux:
#     sudo dnf install -y epel-release && sudo dnf install -y snapd && sudo systemctl enable --now snapd.socket && sudo ln -s /var/lib/snapd/snap /snap
# - On openSUSE Leap:
#     sudo zypper addrepo --refresh https://download.opensuse.org/repositories/system:snappy/openSUSE_Leap_16.0/system:snappy.repo
#     sudo zypper install -y snapd && sudo systemctl enable --now snapd && sudo ln -s /var/lib/snapd/snap /snap
# - On openSUSE Tumbleweed:
#     sudo zypper addrepo --refresh https://download.opensuse.org/repositories/system:snappy/openSUSE_Tumbleweed/system:snappy.repo
#     sudo zypper install -y snapd && sudo systemctl enable --now snapd && sudo ln -s /var/lib/snapd/snap /snap
# - On Arch Linux:
#     git clone https://aur.archlinux.org/snapd.git && cd snapd && makepkg -si && sudo systemctl enable --now snapd.socket && sudo ln -s /var/lib/snapd/snap /snap

# 2. Install the Pi-hole snap
sudo snap install pihole-by-rajannpatel

# 3. Create the command alias
sudo snap alias pihole-by-rajannpatel.pihole pihole

# 4. Free port 53
if systemctl is-active --quiet systemd-resolved; then
    sudo mkdir -p /etc/systemd/resolved.conf.d
    printf '[Resolve]\nDNS=127.0.0.1\nDNSStubListener=no\n' | sudo tee /etc/systemd/resolved.conf.d/pihole.conf
    sudo systemctl restart systemd-resolved
fi

# 5. Use the wizard
sudo pihole -r
```

> [!NOTE]
> Pi-hole FTL v6.6.x dropped support for mbedTLS 2.x and now strictly requires mbedTLS ≥ 3.5.0 and Nettle ≥ 3.9. The Ubuntu Core 24 snap base (`core24`) ships older versions of both libraries, so the package was bumped to Ubuntu Core 26 (`core26`).

| Upstream Component | Current Version |
| :--- | :--- |
| | [![Track Upstream Releases](https://github.com/rajannpatel/snap-pi-hole/actions/workflows/update-tags.yml/badge.svg?style=flat-square)](https://github.com/rajannpatel/snap-pi-hole/actions/workflows/update-tags.yml) |
| **[FTL](https://github.com/pi-hole/FTL)** | v6.6.2 |
| **[pi-hole (core)](https://github.com/pi-hole/pi-hole)** | v6.4.2 |
| **[web](https://github.com/pi-hole/web)** | v6.5 |

> These upstream components are automatically tracked and the snap is repackaged to include the latest stable versions by a daily GitHub Actions bot.

## Supported Linux distributions

This snap package is built and integration-tested automatically across various Linux distributions.

| | Distribution | Version | Name | Status |
| :--- | :--- | :--- | :--- | :--- |
| ![Ubuntu](https://img.shields.io/badge/-%20-E95420?style=flat-square&logo=ubuntu&logoColor=white) | Ubuntu | 26.04 | Resolute | [![Status](https://img.shields.io/github/actions/workflow/status/rajannpatel/snap-pi-hole/test-ubuntu.yml?style=flat-square&label=)](https://github.com/rajannpatel/snap-pi-hole/actions/workflows/test-ubuntu.yml) |
| ![Ubuntu](https://img.shields.io/badge/-%20-E95420?style=flat-square&logo=ubuntu&logoColor=white) | Ubuntu Daily | 26.04 | Resolute | [![Status](https://img.shields.io/github/actions/workflow/status/rajannpatel/snap-pi-hole/test-ubuntu-daily.yml?style=flat-square&label=)](https://github.com/rajannpatel/snap-pi-hole/actions/workflows/test-ubuntu-daily.yml) |
| ![Ubuntu](https://img.shields.io/badge/-%20-E95420?style=flat-square&logo=ubuntu&logoColor=white) | Ubuntu Core | 26 | Core | [![Status](https://img.shields.io/github/actions/workflow/status/rajannpatel/snap-pi-hole/test-ubuntu-core.yml?style=flat-square&label=)](https://github.com/rajannpatel/snap-pi-hole/actions/workflows/test-ubuntu-core.yml) |
| ![Debian](https://img.shields.io/badge/-%20-A81D33?style=flat-square&logo=debian&logoColor=white) | Debian Stable | 13 | Trixie | [![Status](https://img.shields.io/github/actions/workflow/status/rajannpatel/snap-pi-hole/test-debian-stable.yml?style=flat-square&label=)](https://github.com/rajannpatel/snap-pi-hole/actions/workflows/test-debian-stable.yml) |
| ![Debian](https://img.shields.io/badge/-%20-A81D33?style=flat-square&logo=debian&logoColor=white) | Debian | Rolling | Forky | [![Status](https://img.shields.io/github/actions/workflow/status/rajannpatel/snap-pi-hole/test-debian.yml?style=flat-square&label=)](https://github.com/rajannpatel/snap-pi-hole/actions/workflows/test-debian.yml) |
| ![Fedora](https://img.shields.io/badge/-%20-3C6EB4?style=flat-square&logo=fedora&logoColor=white) | Fedora | 44 | Fedora Linux 44 (Container Image) | [![Status](https://img.shields.io/github/actions/workflow/status/rajannpatel/snap-pi-hole/test-fedora.yml?style=flat-square&label=)](https://github.com/rajannpatel/snap-pi-hole/actions/workflows/test-fedora.yml) |
| ![Rocky Linux](https://img.shields.io/badge/-%20-10B981?style=flat-square&logo=rockylinux&logoColor=white) | Rocky Linux | 9.7 | Rocky Linux 9.7 (Blue Onyx) | [![Status](https://img.shields.io/github/actions/workflow/status/rajannpatel/snap-pi-hole/test-rockylinux.yml?style=flat-square&label=)](https://github.com/rajannpatel/snap-pi-hole/actions/workflows/test-rockylinux.yml) |
| ![AlmaLinux](https://img.shields.io/badge/-%20-F43F5E?style=flat-square&logo=almalinux&logoColor=white) | AlmaLinux | 9.7 | AlmaLinux 9.7 (Moss Jungle Cat) | [![Status](https://img.shields.io/github/actions/workflow/status/rajannpatel/snap-pi-hole/test-almalinux.yml?style=flat-square&label=)](https://github.com/rajannpatel/snap-pi-hole/actions/workflows/test-almalinux.yml) |
| ![openSUSE](https://img.shields.io/badge/-%20-73BA25?style=flat-square&logo=opensuse&logoColor=white) | openSUSE | 16.0 | openSUSE Leap 16.0 | [![Status](https://img.shields.io/github/actions/workflow/status/rajannpatel/snap-pi-hole/test-opensuse-leap.yml?style=flat-square&label=)](https://github.com/rajannpatel/snap-pi-hole/actions/workflows/test-opensuse-leap.yml) |
| ![openSUSE](https://img.shields.io/badge/-%20-73BA25?style=flat-square&logo=opensuse&logoColor=white) | openSUSE | 20260516 | openSUSE Tumbleweed | [![Status](https://img.shields.io/github/actions/workflow/status/rajannpatel/snap-pi-hole/test-opensuse-tumbleweed.yml?style=flat-square&label=)](https://github.com/rajannpatel/snap-pi-hole/actions/workflows/test-opensuse-tumbleweed.yml) |
| ![Arch Linux](https://img.shields.io/badge/-%20-1793D1?style=flat-square&logo=archlinux&logoColor=white) | Arch Linux | Rolling | Arch Linux | [![Status](https://img.shields.io/github/actions/workflow/status/rajannpatel/snap-pi-hole/test-archlinux.yml?style=flat-square&label=)](https://github.com/rajannpatel/snap-pi-hole/actions/workflows/test-archlinux.yml) |

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