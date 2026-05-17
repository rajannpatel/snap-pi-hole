# Rationale: Why Unbound is Not Bundled

When configuring Pi-hole, many users choose to set up `unbound` as a recursive DNS resolver to improve privacy and security. While it might seem convenient to bundle `unbound` directly into the Pi-hole snap package, we have made the deliberate architectural decision to keep them entirely separate. 

Instead, we recommend installing `unbound` via the host OS's native package manager (e.g., `apt install unbound` on Ubuntu) or running it as a completely independent snap, and configuring Pi-hole to point to `127.0.0.1#5335`.

Here are the technical and security reasons driving this decision:

## 1. Independent Security Updates
`unbound` is a complex, internet-facing DNS resolver maintained by NLnet Labs, whereas Pi-hole is maintained by the Pi-hole team. If a zero-day vulnerability is discovered in `unbound`, it is critical to apply the upstream security patch immediately. If it were bundled into the snap, users would be forced to wait for us to manually rebuild, test, and publish a new Pi-hole snap just to deliver the `unbound` security fix. Keeping them separate allows users to receive automated `unbound` updates directly from their OS's security repositories.

## 2. Separation of Concerns (Blast Radius)
Strict confinement relies on AppArmor profiles to isolate applications. By running `unbound` as a separate deb package (or independent snap), it runs under its own AppArmor profile and user permissions. If `unbound` is ever compromised, the attacker is contained within that specific boundary and does not automatically gain access to Pi-hole's Gravity database, web admin secrets, or the rest of the Pi-hole environment. 

## 3. Configuration Complexity
Snaps are strictly confined, read-only filesystems. If we bundled `unbound`, we would have to map its configuration paths (`/etc/unbound`), write wrapper scripts to allow users to inject custom `unbound.conf` fragments into the read-only snap environment, and run a second background daemon inside the same snap. This dramatically increases the complexity, fragility, and maintenance burden of the `snapcraft.yaml` recipe.

## 4. Upstream Alignment
The official Pi-hole project does not bundle `unbound` in their standard install scripts or official Docker containers. They explicitly treat it as an optional, third-party companion service. Keeping it external aligns our snap packaging philosophy directly with Pi-hole's upstream architecture and official documentation.
