# Tutorial: Getting Started with the Pi-hole Snap

This tutorial will guide you through the process of taking a fresh Ubuntu machine and turning it into a network-wide ad blocker using the Pi-hole snap.

## 1. Install the Snap

Currently, this snap is not yet published in the official Snap Store channels, so you must build it from source or download a pre-built `.snap` artifact. 

Once you have your `pihole_*.snap` file, install it with the `--dangerous` flag (required for locally built, unsigned snaps):

```bash
sudo snap install --dangerous ./pihole_*.snap
```

## 2. Free up Port 53

Pi-hole acts as a DNS resolver, meaning it absolutely must bind to port 53. On modern Ubuntu systems, `systemd-resolved` typically holds this port for its local stub listener.

You must disable the stub listener so Pi-hole can bind:

```bash
sudo mkdir -p /etc/systemd/resolved.conf.d
printf '[Resolve]\nDNSStubListener=no\n' | sudo tee /etc/systemd/resolved.conf.d/pihole.conf
sudo systemctl restart systemd-resolved
```

## 3. Connect Required Interfaces

Snaps are strictly confined. By default, the Pi-hole daemon cannot bind to privileged network ports. You must explicitly grant it permission:

```bash
sudo snap connect pihole:network-bind
```

*(Note: Depending on your exact needs, you may also want to connect `system-observe`, `hardware-observe`, and `mount-observe` for full web dashboard functionality).*

## 4. Start the Daemon

When the snap is first installed, the Pi-hole daemon is disabled to give you time to free port 53. Now that the port is free and the interfaces are connected, you can enable and start it:

```bash
sudo snap start --enable pihole.pihole-ftl
```

## 5. Retrieve Your Admin Password

Pi-hole's web interface requires a password. On first startup, the daemon automatically generates a random password and prints it to its logs. 

Retrieve it by checking the logs:

```bash
sudo snap logs pihole.pihole-ftl | grep -i password
```

## 6. Access the Dashboard

You're done! Navigate to `http://<your-machine-ip>/admin` in your browser. You can log in using the password you retrieved in the previous step, and you should now point your router (or your individual clients) to this machine's IP address for DNS resolution!
