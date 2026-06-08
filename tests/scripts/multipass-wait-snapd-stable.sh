#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <multipass-vm-name>" >&2
    exit 2
fi

vm="$1"
idle_checks=0
max_idle_checks=3

log() {
    echo "Ensuring snapd is stable: $*"
}

while [ "$idle_checks" -lt "$max_idle_checks" ]; do
    if ! multipass exec "$vm" -- echo "Online" >/dev/null 2>&1; then
        log "VM is offline/rebooting; waiting..."
        sleep 10
        idle_checks=0
        continue
    fi

    if multipass exec "$vm" -- \
        test -f /run/systemd/shutdown/scheduled 2>/dev/null; then
        log "A system reboot is scheduled; rebooting now..."
        multipass exec "$vm" -- sudo reboot || true
        log "Waiting for VM to go offline..."
        sleep 10
        idle_checks=0
        continue
    fi

    if multipass exec "$vm" -- snap changes 2>/dev/null | grep -q "Doing"; then
        log "Snapd is busy. Waiting 10 seconds..."
        sleep 10
        idle_checks=0
        continue
    fi

    idle_checks=$((idle_checks + 1))
    log "Snapd is idle (check $idle_checks/$max_idle_checks)..."
    sleep 5
done

log "Snapd is fully stable and idle."
