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

This snap is currently published with `grade: devel`; it will not install from the `stable` risk level until I have a green end-to-end smoke test on real DNS traffic.

---
A strictly confined, native [snap](https://snapcraft.io/) package for [Pi-hole](https://pi-hole.net), the network-wide ad-blocking DNS sinkhole.

For a detailed explanation of what this snap is, how it works, and why it's the preferred deployment method, please see the **[Home Page of our Wiki](https://github.com/rajannpatel/snap-pi-hole/wiki)**!

## Quickstart

**1. Free up Port 53**
On Ubuntu, `systemd-resolved` usually binds to port 53. You must disable its stub listener before starting Pi-hole:
```bash
sudo mkdir -p /etc/systemd/resolved.conf.d
printf '[Resolve]\nDNSStubListener=no\n' | sudo tee /etc/systemd/resolved.conf.d/pihole.conf
sudo systemctl restart systemd-resolved
```

**2. Install and Connect**
Install the snap and explicitly connect the required network interfaces:
```bash
sudo snap install pihole-by-rajannpatel
sudo snap connect pihole-by-rajannpatel:network-bind

# Optional: Connect these if you plan to use Pi-hole as a DHCP server
sudo snap connect pihole-by-rajannpatel:network-control
sudo snap connect pihole-by-rajannpatel:firewall-control

# 3. Start and Configure
# Enable the daemon and set your secure web admin password:
```bash
sudo snap start --enable pihole-by-rajannpatel.pihole-ftl
echo "YourSecurePasswordHere" | sudo pihole setpassword
```
You can now access the web dashboard at `http://<your-host-ip>/admin`.

## Project and community

The contents of this repository (`snapcraft.yaml`, `launcher-ftl` scripts, and the GitHub Actions) are simply build instructions and wrapper scripts. They don't contain any of Pi-hole's source code. Therefore, this snap package is licensed under a permissive MIT license. This is a standard practice and highly encouraged.