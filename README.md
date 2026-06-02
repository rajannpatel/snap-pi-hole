# Pi-hole snap package

<img align="right" src="./snap/gui/pihole.png" width="120" alt="Pi-hole Logo">

A strictly confined, native [snap](https://snapcraft.io/) package for [Pi-hole](https://pi-hole.net), the network-wide ad-blocking DNS sinkhole.

[![Get it from the Snap Store](https://snapcraft.io/en/dark/install.svg)](https://snapcraft.io/pihole-by-rajannpatel)

[![Build and Smoke Test](https://github.com/rajannpatel/snap-pi-hole/actions/workflows/publish.yml/badge.svg)](https://github.com/rajannpatel/snap-pi-hole/actions/workflows/publish.yml)


```bash
# 1. Install snapd (if not already present on the host)
# - On Debian:
#     sudo apt update && sudo apt install -y snapd
# - On RHEL/Rocky Linux/AlmaLinux:
#     sudo dnf install -y epel-release && sudo dnf install -y snapd && sudo systemctl enable --now snapd.socket
# - On Alpine: 
#     sudo apk add snapd && sudo rc-update add snapd && sudo rc-service snapd start
# - On Void Linux: 
#     sudo xbps-install -S snapd && sudo ln -s /etc/sv/snapd /var/service/
# - On Devuan/MX Linux: 
#     sudo apt update && sudo apt install -y snapd

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
| | [![Update Upstream Tags](https://github.com/rajannpatel/snap-pi-hole/actions/workflows/update-tags.yml/badge.svg)](https://github.com/rajannpatel/snap-pi-hole/actions/workflows/update-tags.yml) |
| **[FTL](https://github.com/pi-hole/FTL)** | v6.6.2 |
| **[pi-hole (core)](https://github.com/pi-hole/pi-hole)** | v6.4.2 |
| **[web](https://github.com/pi-hole/web)** | v6.5 |

> These upstream components are automatically tracked and the snap is repackaged to include the latest stable versions by a daily GitHub Actions bot.

## Supported Linux distributions

The snap package is built and integration-tested automatically across various Linux distributions and init configurations:

| | Distribution | Version | Name | Status |
| :--- | :--- | :--- | :--- | :--- |
| ![Ubuntu](https://img.shields.io/badge/Ubuntu-E95420?style=flat-square&logo=ubuntu&logoColor=white) | Ubuntu | 26.04 | resolute | [![Test on Ubuntu](https://github.com/rajannpatel/snap-pi-hole/actions/workflows/test-ubuntu.yml/badge.svg)](https://github.com/rajannpatel/snap-pi-hole/actions/workflows/test-ubuntu.yml) |
| ![Ubuntu](https://img.shields.io/badge/Ubuntu_Core-E95420?style=flat-square&logo=ubuntu&logoColor=white) | Ubuntu Core | 26 | Core | [![Test on Ubuntu Core](https://github.com/rajannpatel/snap-pi-hole/actions/workflows/test-ubuntu-core.yml/badge.svg)](https://github.com/rajannpatel/snap-pi-hole/actions/workflows/test-ubuntu-core.yml) |
| ![Debian](https://img.shields.io/badge/Debian-A81D33?style=flat-square&logo=debian&logoColor=white) | Debian | - | - | [![Test on Debian](https://github.com/rajannpatel/snap-pi-hole/actions/workflows/test-debian.yml/badge.svg)](https://github.com/rajannpatel/snap-pi-hole/actions/workflows/test-debian.yml) |
| ![Fedora](https://img.shields.io/badge/Fedora-3C6EB4?style=flat-square&logo=fedora&logoColor=white) | Fedora | - | - | [![Test on Fedora](https://github.com/rajannpatel/snap-pi-hole/actions/workflows/test-fedora.yml/badge.svg)](https://github.com/rajannpatel/snap-pi-hole/actions/workflows/test-fedora.yml) |
| ![Rocky Linux](https://img.shields.io/badge/Rocky_Linux-10B981?style=flat-square&logo=rockylinux&logoColor=white) | Rocky Linux | - | - | [![Test on Rocky Linux](https://github.com/rajannpatel/snap-pi-hole/actions/workflows/test-rockylinux.yml/badge.svg)](https://github.com/rajannpatel/snap-pi-hole/actions/workflows/test-rockylinux.yml) |
| ![AlmaLinux](https://img.shields.io/badge/AlmaLinux-F43F5E?style=flat-square&logo=almalinux&logoColor=white) | AlmaLinux | - | - | [![Test on AlmaLinux](https://github.com/rajannpatel/snap-pi-hole/actions/workflows/test-almalinux.yml/badge.svg)](https://github.com/rajannpatel/snap-pi-hole/actions/workflows/test-almalinux.yml) |
| ![openSUSE](https://img.shields.io/badge/openSUSE-73BA25?style=flat-square&logo=opensuse&logoColor=white) | openSUSE | Leap | - | [![Test on openSUSE Leap](https://github.com/rajannpatel/snap-pi-hole/actions/workflows/test-opensuse-leap.yml/badge.svg)](https://github.com/rajannpatel/snap-pi-hole/actions/workflows/test-opensuse-leap.yml) |
| ![openSUSE](https://img.shields.io/badge/openSUSE-73BA25?style=flat-square&logo=opensuse&logoColor=white) | openSUSE | Rolling | Tumbleweed | [![Test on openSUSE Tumbleweed](https://github.com/rajannpatel/snap-pi-hole/actions/workflows/test-opensuse-tumbleweed.yml/badge.svg)](https://github.com/rajannpatel/snap-pi-hole/actions/workflows/test-opensuse-tumbleweed.yml) |
| ![Arch Linux](https://img.shields.io/badge/Arch_Linux-1793D1?style=flat-square&logo=archlinux&logoColor=white) | Arch Linux | Rolling | - | [![Test on Arch Linux](https://github.com/rajannpatel/snap-pi-hole/actions/workflows/test-archlinux.yml/badge.svg)](https://github.com/rajannpatel/snap-pi-hole/actions/workflows/test-archlinux.yml) |
| ![Alpine Linux](https://img.shields.io/badge/Alpine_Linux-0D597F?style=flat-square&logo=alpinelinux&logoColor=white) | Alpine Linux | - | - | [![Test on Alpine Linux](https://github.com/rajannpatel/snap-pi-hole/actions/workflows/test-alpine.yml/badge.svg)](https://github.com/rajannpatel/snap-pi-hole/actions/workflows/test-alpine.yml) |

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