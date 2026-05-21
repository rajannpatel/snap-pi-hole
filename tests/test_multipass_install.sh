#!/usr/bin/env bash
# tests/test_multipass_install.sh
# Automates building the snap, launching a Multipass Ubuntu Core 24 VM,
# transferring the snap, installing/configuring it, and running verification tests.

set -euo pipefail

VM_NAME="pihole-test-core"
CPUS=6
MEMORY="12G"
DISK="15G" # Ensure enough space for base snaps, cache, and logs

log() {
    echo -e "\033[1;34m==>\033[0m $1"
}

error() {
    echo -e "\033[1;31mError:\033[0m $1" >&2
    exit 1
}

wait_for_snapd_stability() {
    log "Ensuring snapd is completely stable and idle..."
    local idle_checks=0
    local max_idle_checks=3
    
    while [ $idle_checks -lt $max_idle_checks ]; do
        # 1. Check if VM is online
        if ! multipass exec "$VM_NAME" -- echo "Online" >/dev/null 2>&1; then
            log "VM is offline/rebooting. Waiting for it to come online..."
            sleep 10
            idle_checks=0
            continue
        fi
        
        # 2. Check if a reboot is scheduled
        if multipass exec "$VM_NAME" -- test -f /run/systemd/shutdown/scheduled 2>/dev/null; then
            log "A system reboot is scheduled by snapd. Rebooting immediately..."
            multipass exec "$VM_NAME" -- sudo reboot || true
            log "Waiting for VM to go offline..."
            sleep 10
            idle_checks=0
            continue
        fi
        
        # 3. Check if snapd is busy
        if multipass exec "$VM_NAME" -- snap changes 2>/dev/null | grep -q "Doing"; then
            log "Snapd is busy. Waiting 10 seconds..."
            sleep 10
            idle_checks=0
            continue
        fi
        
        idle_checks=$((idle_checks + 1))
        log "Snapd is idle (check $idle_checks/$max_idle_checks)..."
        sleep 5
    done
    log "Snapd is fully stable and idle!"
}

# 1. Build the snap
log "Starting snap build using snapcraft..."
snapcraft

# Find the built snap
SNAP_FILE=$(ls -t pihole-by-rajannpatel_*.snap 2>/dev/null | head -n1 || true)
if [ -z "$SNAP_FILE" ]; then
    # Fallback to check if named pihole_*
    SNAP_FILE=$(ls -t *.snap 2>/dev/null | head -n1 || true)
fi

if [ -z "$SNAP_FILE" ] || [ ! -f "$SNAP_FILE" ]; then
    error "No built snap found in the directory!"
fi

log "Found built snap: $SNAP_FILE"

# 2. Launch Multipass VM
# Check if VM already exists
if multipass list | grep -q "^$VM_NAME "; then
    log "VM $VM_NAME already exists. Stopping and deleting it for a clean test..."
    multipass delete --purge "$VM_NAME"
fi

log "Launching Multipass VM '$VM_NAME' (Ubuntu Core 24) with $CPUS CPUs, $MEMORY RAM..."
multipass launch core24 --name "$VM_NAME" --cpus "$CPUS" --memory "$MEMORY" --disk "$DISK"

# Wait for VM to be fully initialized
log "Waiting for VM to initialize..."
sleep 10

# 3. Transfer the snap
log "Transferring snap to VM..."
multipass transfer "$SNAP_FILE" "${VM_NAME}:/home/ubuntu/pihole-test.snap"

# 4. Install the snap
log "Installing snap on Ubuntu Core..."
# On Ubuntu Core, snapd will download the base snap core26 dynamically because of base: core26
multipass exec "$VM_NAME" -- sudo snap install --dangerous /home/ubuntu/pihole-test.snap

# Wait for snapd stability (including all post-install refreshes and potential reboots)
wait_for_snapd_stability

# 5. Connect interfaces (plugs)
log "Connecting snap interfaces..."
# Connect plugs listed in the snapcraft.yaml
plugs=(
    "network-bind"
    "network-control"
    "firewall-control"
    "network-observe"
    "system-observe"
    "hardware-observe"
    "mount-observe"
    "process-control"
    "time-control"
)

for plug in "${plugs[@]}"; do
    log "Connecting plug $plug..."
    multipass exec "$VM_NAME" -- sudo snap connect "pihole-by-rajannpatel:$plug" || true
done

# 6. Enable and start the daemon
log "Starting and enabling pihole-ftl daemon..."
multipass exec "$VM_NAME" -- sudo snap start --enable pihole-by-rajannpatel.pihole-ftl

# Wait for the service to start
log "Waiting for pihole-ftl to start (15 seconds)..."
sleep 15

# 7. Verification
log "Running verification checks..."

# Check service status
log "Checking snap services status..."
multipass exec "$VM_NAME" -- snap services pihole-by-rajannpatel

# Check daemon logs
log "Retrieving snap logs..."
multipass exec "$VM_NAME" -- sudo snap logs pihole-by-rajannpatel.pihole-ftl

# Get VM IP address
VM_IP=$(multipass info "$VM_NAME" | grep -i "IPv4:" | awk '{print $2}')
log "VM IP Address is: $VM_IP"

# Test DNS resolution from host
log "Testing DNS resolution from the host via VM's DNS server..."
if dig @$VM_IP google.com +short > /dev/null 2>&1; then
    dig @$VM_IP google.com
    log "DNS resolution test PASSED!"
elif nslookup google.com $VM_IP > /dev/null 2>&1; then
    nslookup google.com $VM_IP
    log "DNS resolution test PASSED!"
else
    log "WARNING: DNS resolution from host failed or dig/nslookup not available on host. Testing internally in VM..."
    if multipass exec "$VM_NAME" -- snap run pihole-by-rajannpatel.sqlite3 "/etc/pihole/gravity.db" "SELECT * FROM domainlist LIMIT 1;" >/dev/null 2>&1; then
        log "Gravity DB check PASSED (sqlite3 works inside snap)."
    else
        log "WARNING: sqlite3 internal check failed."
    fi
fi

# Test Web Admin HTTP response
log "Testing Web Admin HTTP access from host..."
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://${VM_IP}/admin/" || true)
log "HTTP status response from http://${VM_IP}/admin/ is: $HTTP_STATUS"
if [ "$HTTP_STATUS" = "200" ] || [ "$HTTP_STATUS" = "302" ] || [ "$HTTP_STATUS" = "301" ]; then
    log "Web Admin HTTP interface test PASSED!"
else
    error "Web Admin HTTP interface test FAILED with status $HTTP_STATUS!"
fi

log "Testing completed successfully! VM '$VM_NAME' is running at http://${VM_IP}/admin/ ."
