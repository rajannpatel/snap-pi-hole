# How-To: build and test from source

If you wish to contribute to this packaging repository, or if you simply want to build the snap locally yourself, follow these steps.

## Prerequisites

You must have the `snapcraft` packaging tool installed:
```bash
sudo snap install snapcraft --classic
```

To run the unit tests locally, you also need `bats` and `shellcheck`:
```bash
sudo apt update
sudo apt install bats shellcheck
```

## Running the test suite

Before building the full snap, it's highly recommended to run the linters and unit tests on the repository's launcher scripts.

1. **Lint the shell scripts:**
   ```bash
   shellcheck snap/local/launcher-ftl snap/local/launcher-pihole \
              snap/hooks/install snap/hooks/configure
   ```

2. **Run the BATS unit tests:**
   ```bash
   bats tests/unit/
   ```

## Compiling the snap

Once the tests pass, you can invoke `snapcraft` to compile the snap package natively on your architecture.

```bash
snapcraft
```

This will produce a file matching `pihole_<version>_<arch>.snap` in your current directory.

## Local end-to-end smoke test

You can manually perform the end-to-end smoke test that runs in our GitHub Actions CI pipeline:

```bash
# 1. Install your newly built snap natively:
sudo snap install --dangerous ./pihole_*.snap

# 2. Connect the interfaces:
sudo snap connect pihole:network-bind
sudo snap connect pihole:system-observe
sudo snap connect pihole:hardware-observe
sudo snap connect pihole:mount-observe

# 3. Start the daemon:
sudo snap start --enable pihole.pihole-ftl

# 4. Verify local resolution:
dig @127.0.0.1 example.com
```

If the `dig` command successfully resolves a name against the `127.0.0.1` interface, the snap's DNS stack has correctly bound to the port and is serving queries.

### AppArmor Confinement Verification

Our CI pipeline aggressively enforces strict zero-tolerance for unexpected AppArmor denials. During the end-to-end smoke test, it actively scans `dmesg` to ensure that confinement doesn't silently break core functionality.

However, certain underlying utilities inherently probe for elevated capabilities that they do not strictly require for basic operation. The CI explicitly filters these benign, non-fatal requests to prevent false test failures:

- **`dac_read_search` and `dac_override`**: Requested broadly by bash and common coreutils when scanning directories or reading files owned by `root`. The shell and utilities gracefully fall back to standard DAC permissions when denied.
- **`net_admin`**: Requested by `ss` (socket statistics) during `pihole status`. `ss` tries to drop into `net_admin` to fetch deep kernel packet queues and process-level socket ownership. When denied, it successfully falls back to standard unprivileged polling which is sufficient for `pihole status` to verify that port 53 is bound.
