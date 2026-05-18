# Networking Compatibility

This page outlines the networking compatibility matrix for the Pi-hole snap, detailing how it interacts with various Ubuntu network managers and container bridges.

<details>
<summary>&ensp;TABLE OF CONTENTS<br><sup>&emsp;&ensp;&thinsp;&thinsp;CLICK TO EXPAND</sup><br></summary>

- **[COMPATIBILITY MATRIX](#compatibility-matrix)**<br><sub>SUPPORTED NETWORK MANAGERS</sub><br>
- **[KNOWN CONFLICTS](#known-conflicts)**<br><sub>SYSTEMD-RESOLVED AND OTHERS</sub><br>

</details>

---

<a name="compatibility-matrix"></a>
## COMPATIBILITY MATRIX

The Pi-hole snap is strictly confined but binds to host network interfaces directly. 

| Network Manager / Bridge | Compatibility | Notes |
|--------------------------|---------------|-------|
| `systemd-networkd`       | Excellent     | Native support. Requires disabling the `systemd-resolved` DNS stub listener. |
| `NetworkManager`         | Excellent     | Works out of the box. Ensure `dnsmasq` plugin is disabled in NetworkManager if active. |
| `netplan`                | Excellent     | Netplan generates configs for networkd/NetworkManager. Fully compatible. |
| Docker (`docker0`)       | Good          | Pi-hole can bind to `docker0` interfaces. You may need to configure Pi-hole to listen on all interfaces. |
| LXD / Incus (`lxdbr0`)   | Good          | Similar to Docker. Ensure LXD's built-in `dnsmasq` does not conflict on port 53. |

---

<a name="known-conflicts"></a>
## KNOWN CONFLICTS

### systemd-resolved

By default, modern Ubuntu releases use `systemd-resolved`, which binds a local DNS stub listener to `127.0.0.53:53`. This directly conflicts with Pi-hole, which requires port 53 to serve DNS queries.

The Pi-hole snap includes an automated launcher check that will refuse to start `pihole-FTL` if port 53 is occupied. It will instruct you to disable the `systemd-resolved` stub listener.

To fix this conflict, create a drop-in configuration to disable the stub listener:

```bash
sudo mkdir -p /etc/systemd/resolved.conf.d
printf '[Resolve]\nDNSStubListener=no\n' | sudo tee /etc/systemd/resolved.conf.d/pihole.conf
sudo systemctl restart systemd-resolved
```

### LXD / libvirt dnsmasq

If your host acts as a hypervisor (e.g., running LXD or KVM with `libvirtd`), these services often spawn their own instances of `dnsmasq` that bind to their respective bridge interfaces (like `lxdbr0` or `virbr0`) on port 53.

While Pi-hole typically binds only to your primary interface or `0.0.0.0`, if you configure Pi-hole to listen on *all* interfaces, it will fail to start due to port 53 being in use by these bridges. You must configure Pi-hole to only bind to the interfaces you explicitly want it to serve.
