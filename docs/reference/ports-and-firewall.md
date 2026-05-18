# Ports and Firewall Requirements

This page details the network ports required for the Pi-hole snap to function correctly, along with instructions for configuring your host firewall.

<details>
<summary>&ensp;TABLE OF CONTENTS<br><sup>&emsp;&ensp;&thinsp;&thinsp;CLICK TO EXPAND</sup><br></summary>

- **[PORT REQUIREMENTS](#port-requirements)**<br><sub>LIST OF REQUIRED NETWORK PORTS</sub><br>
- **[FIREWALL CONFIGURATION](#firewall-configuration)**<br><sub>UFW CONFIGURATION EXAMPLES</sub><br>

</details>

---

<a name="port-requirements"></a>
## PORT REQUIREMENTS

The Pi-hole snap requires specific ports to be open and available on your host system.

| Port | Protocol | Purpose |
|------|----------|---------|
| `53` | TCP/UDP  | **DNS Queries.** This is the core service port. Without port 53, Pi-hole cannot resolve domain names for clients. |
| `80` | TCP      | **Web Dashboard.** Required to access the Pi-hole admin interface. |
| `67` | UDP      | **DHCP Server (IPv4).** Only required if you enable Pi-hole's built-in DHCP server. |
| `546`| UDP      | **DHCP Server (IPv6).** Only required if you enable Pi-hole's built-in DHCPv6 server. |

---

<a name="firewall-configuration"></a>
## FIREWALL CONFIGURATION

If you are using Uncomplicated Firewall (`ufw`) on your Ubuntu host, you must explicitly allow incoming traffic to these ports so devices on your network can reach Pi-hole.

### Allow DNS (Port 53)
To allow devices to query Pi-hole for DNS resolution:
```bash
sudo ufw allow 53/tcp
sudo ufw allow 53/udp
```

### Allow Web Dashboard (Port 80)
To allow access to the web administration dashboard:
```bash
sudo ufw allow 80/tcp
```

### Allow DHCP (Ports 67 / 546)
If you intend to use Pi-hole as your network's DHCP server, allow the DHCP ports:
```bash
sudo ufw allow 67/udp
sudo ufw allow 546/udp
```

### Apply and Verify
Ensure the firewall is enabled and verify the status:
```bash
sudo ufw enable
sudo ufw status
```
