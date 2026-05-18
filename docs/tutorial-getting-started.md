# Tutorial: getting started with the Pi-hole snap

This tutorial will guide you through the process of taking a fresh Ubuntu machine and turning it into a network-wide ad blocker using the Pi-hole snap.

> [!NOTE]
> **Pre-release status.** This snap is not yet published to the Snap Store; the steps below assume a future `sudo snap install pihole` install path. If you want to try the snap today, see [How-To: Build and Test from Source](howto-build-and-test.md). That guide covers building locally and installing the resulting unsigned `.snap` file with `--dangerous`. **Do not use `--dangerous` to install snaps you did not build yourself**; it bypasses signature verification.

## 1. Install the snap

Once the snap is published to the Snap Store, installation will be a single command:

```bash
sudo snap install pihole
```

## 2. Free up port 53

Pi-hole acts as a DNS resolver, meaning it absolutely must bind to port 53. On modern Ubuntu systems, `systemd-resolved` typically holds this port for its local stub listener.

You must disable the stub listener so Pi-hole can bind:

```bash
sudo mkdir -p /etc/systemd/resolved.conf.d
printf '[Resolve]\nDNSStubListener=no\n' | sudo tee /etc/systemd/resolved.conf.d/pihole.conf
sudo systemctl restart systemd-resolved
```

## 3. Connect required interfaces

Snaps are strictly confined. By default, the Pi-hole daemon cannot bind to privileged network ports. You must explicitly grant it permission:

```bash
sudo snap connect pihole:network-bind
```

*(Note: Depending on your exact needs, you may also want to connect `system-observe`, `hardware-observe`, and `mount-observe` for full web dashboard functionality).*

## 4. Start the daemon

When the snap is first installed, the Pi-hole daemon is disabled to give you time to free port 53. Now that the port is free and the interfaces are connected, you can enable and start it:

```bash
sudo snap start --enable pihole.pihole-ftl
```

## 5. Retrieve your admin password

Pi-hole's web interface requires a password. On first startup, the daemon automatically generates a random password and prints it to its logs. 

Retrieve it by checking the logs:

```bash
sudo snap logs pihole.pihole-ftl | grep -i password
```

## 6. Access the dashboard

You're done! Navigate to `http://<your-machine-ip>/admin` in your browser. You can log in using the password you retrieved in the previous step, and you should now point your router (or your individual clients) to this machine's IP address for DNS resolution!
