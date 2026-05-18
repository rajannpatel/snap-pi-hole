# How-To: Configure the DHCP server

If you wish to use Pi-hole as your network's DHCP server, you need to grant the snap elevated network privileges and configure the DHCP variables.

## 1. Connect the privileged plugs

DHCP server mode requires two elevated AppArmor interfaces (`network-control` and `firewall-control`). We deliberately ship them on the same daemon (rather than splitting DHCP into a second app behind a content interface): operators who only want DNS sinkholing never connect them, so the elevated plugs have no security impact.

Connect them manually:

```bash
sudo snap connect pihole:network-control
sudo snap connect pihole:firewall-control
```

## 2. Configure DHCP settings

Use the `snap set` command to configure your DHCP ranges. The snap's configuration hook will automatically map these keys into `/var/snap/pihole/current/etc/pihole/pihole.toml` and restart the daemon.

```bash
sudo snap set pihole \
    dhcp-enabled=true \
    dhcp-start=192.0.2.50 \
    dhcp-end=192.0.2.150 \
    dhcp-router=192.0.2.1 \
    dhcp-leasetime=24 \
    dhcp-domain=lan
```

Once configured, verify that your devices are receiving IP addresses from the Pi-hole host.
