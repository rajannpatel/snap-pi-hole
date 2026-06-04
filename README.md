# Pi-hole snap package

<img align="right" src="./snap/gui/pihole.png" width="120" alt="Pi-hole Logo">

A strictly confined, native [snap](https://snapcraft.io/) package for [Pi-hole](https://pi-hole.net), the network-wide ad-blocking DNS sinkhole.

[![Reports Dashboard](https://img.shields.io/badge/Reports%20Dashboard-GitHub%20Pages-2ea44f?style=flat-square)](https://rajannpatel.github.io/snap-pi-hole/)

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

---

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

* **[CI/CD Reports](https://rajannpatel.github.io/snap-pi-hole/)**

   Live operational status for build, security, dependencies, compatibility, and release health.
