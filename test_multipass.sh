#!/usr/bin/env bash
# test_multipass.sh
# Developer utility script for interactive testing and debugging of the snap on Multipass.
# Excluded from automated CI / shellcheck / bats.

set -euo pipefail

# Resolve repository root and ensure we run from there
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

# Default configuration
PLATFORM=""
CPUS="4"
MEMORY="8G"
DISK="15G"
REBUILD=""
LINT=""
KEEP="false"
WIZARD_USED=true

# Logging helpers
log() {
    echo -e "\033[1;34m==>\033[0m $1"
}
log_success() {
    echo -e "\033[1;32m==> Success:\033[0m $1"
}
log_warn() {
    echo -e "\033[1;33m==> Warning:\033[0m $1"
}
log_error() {
    echo -e "\033[1;31m==> Error:\033[0m $1" >&2
}

# Check if running inside a VM (nested virtualization warning)
IS_VM=false
if command -v systemd-detect-virt >/dev/null 2>&1; then
    if systemd-detect-virt --vm --quiet; then
        IS_VM=true
    fi
elif grep -q "hypervisor" /proc/cpuinfo 2>/dev/null; then
    IS_VM=true
fi

if [ "$IS_VM" = "true" ]; then
    log_warn "This script appears to be running inside a virtual machine (nested virtualization)."
    log_warn "Running Multipass inside a VM can be extremely slow, unstable, or fail entirely."
    read -r -p "Do you want to continue anyway? [y/N]: " continue_choice
    case "$continue_choice" in
        [yY]|[yY][eE][sS])
            log "Proceeding with nested virtualization..."
            ;;
        *)
            log "Aborting."
            exit 1
            ;;
    esac
fi

show_help() {
    cat <<EOF
Usage: $0 [options]

Developer utility script for interactive testing and debugging of the snap on Multipass.

Options:
  -p, --platform PLATFORM   Target platform: lts, core24, core22
  -c, --cpus NUM            Number of CPUs for VM (default: 4)
  -m, --memory SIZE         Memory for VM (default: 8G)
  -d, --disk SIZE           Disk size for VM (default: 15G)
  --rebuild                 Rebuild the snap package (snapcraft clean && snapcraft)
  --no-rebuild              Do not rebuild the snap package
  --lint                    Run local linter & unit tests (shellcheck && bats)
  --no-lint                 Do not run local linter & unit tests
  -k, --keep                Keep VM running at the end of the test without prompting
  -h, --help                Show this help message
EOF
}

# Parse options
while [ $# -gt 0 ]; do
    case "$1" in
        -p|--platform)
            PLATFORM="$2"
            shift 2
            WIZARD_USED=false
            ;;
        -c|--cpus)
            CPUS="$2"
            shift 2
            WIZARD_USED=false
            ;;
        -m|--memory)
            MEMORY="$2"
            shift 2
            WIZARD_USED=false
            ;;
        -d|--disk)
            DISK="$2"
            shift 2
            WIZARD_USED=false
            ;;
        --rebuild)
            REBUILD="true"
            shift
            WIZARD_USED=false
            ;;
        --no-rebuild)
            REBUILD="false"
            shift
            WIZARD_USED=false
            ;;
        --lint)
            LINT="true"
            shift
            WIZARD_USED=false
            ;;
        --no-lint)
            LINT="false"
            shift
            WIZARD_USED=false
            ;;
        -k|--keep)
            KEEP="true"
            shift
            WIZARD_USED=false
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        --)
            shift
            break
            ;;
        *)
            log_error "Unrecognized option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Check host dependencies
log "Checking host dependencies..."
HAS_MULTIPASS=true
HAS_SNAPCRAFT=true
HAS_SHELLCHECK=true
HAS_BATS=true

if command -v multipass >/dev/null 2>&1; then
    echo -e "  [✓] multipass   (Required: VM manager)"
else
    echo -e "  [✗] multipass   (Required: VM manager)"
    HAS_MULTIPASS=false
fi

if command -v snapcraft >/dev/null 2>&1; then
    echo -e "  [✓] snapcraft   (Optional: required for --rebuild)"
else
    echo -e "  [ ] snapcraft   (Optional: required for --rebuild)"
    HAS_SNAPCRAFT=false
fi

if command -v shellcheck >/dev/null 2>&1; then
    echo -e "  [✓] shellcheck  (Optional: static analysis / linter)"
else
    echo -e "  [ ] shellcheck  (Optional: static analysis / linter)"
    HAS_SHELLCHECK=false
fi

if command -v bats >/dev/null 2>&1; then
    echo -e "  [✓] bats        (Optional: testing framework / unit tests)"
else
    echo -e "  [ ] bats        (Optional: testing framework / unit tests)"
    HAS_BATS=false
fi
echo ""

if [ "$HAS_MULTIPASS" = "false" ]; then
    log_error "Multipass is not installed on this host. Please install it to use this script."
    exit 1
fi

if [ "${REBUILD:-}" = "true" ] && [ "$HAS_SNAPCRAFT" = "false" ]; then
    log_error "Snapcraft is required to rebuild the snap package, but it is not installed."
    exit 1
fi

if [ "${LINT:-}" = "true" ]; then
    if [ "$HAS_SHELLCHECK" = "false" ] || [ "$HAS_BATS" = "false" ]; then
        log_error "--lint was requested, but required tools are missing (shellcheck: $HAS_SHELLCHECK, bats: $HAS_BATS)."
        exit 1
    fi
fi

# Run Interactive Wizard if parameters were omitted
if [ -z "$PLATFORM" ]; then
    echo "Select target platform/image for the Multipass VM:"
    echo "  1) Ubuntu LTS (lts)"
    echo "  2) Ubuntu Core 24 (core24)"
    echo "  3) Ubuntu Core 22 (core22)"
    read -r -p "Enter choice [1-3, default 1]: " plat_choice
    case "$plat_choice" in
        2) PLATFORM="core24" ;;
        3) PLATFORM="core22" ;;
        *) PLATFORM="lts" ;;
    esac
fi

# Track cleanup status and background launch state
CLEANUP_ON_EXIT=true
VM_NAME=""
LAUNCH_LOG=$(mktemp)
LAUNCH_PID=""

# Trap to clean up background launch and/or VM if interrupted early or if a step fails
cleanup() {
    # If the background launch process is still running, kill it
    if [ -n "${LAUNCH_PID:-}" ] && kill -0 "$LAUNCH_PID" 2>/dev/null; then
        echo ""
        log_warn "Terminating background VM launch process..."
        kill "$LAUNCH_PID" 2>/dev/null || true
        wait "$LAUNCH_PID" 2>/dev/null || true
    fi
    
    # Try to extract the VM name from the launch log if it was created
    if [ -z "${VM_NAME:-}" ] && [ -n "${LAUNCH_LOG:-}" ] && [ -f "$LAUNCH_LOG" ]; then
        VM_NAME=$(sed -n 's/.*Launched:[[:space:]]*\([^[:space:]]*\).*/\1/p' "$LAUNCH_LOG" | tr -d '\r' | head -n 1)
    fi

    if [ "${CLEANUP_ON_EXIT:-false}" = "true" ] && [ -n "${VM_NAME:-}" ]; then
        echo ""
        log_warn "Cleaning up VM '$VM_NAME'..."
        multipass delete --purge "$VM_NAME" || true
        log "VM '$VM_NAME' cleaned up."
    fi
    
    # Clean up temp file
    if [ -n "${LAUNCH_LOG:-}" ] && [ -f "$LAUNCH_LOG" ]; then
        rm -f "$LAUNCH_LOG"
    fi
}
trap cleanup EXIT INT TERM

# Start launching the Multipass VM in the background immediately
log "Launching Multipass VM with image '$PLATFORM' in the background..."
multipass launch "$PLATFORM" --cpus "$CPUS" --memory "$MEMORY" --disk "$DISK" > "$LAUNCH_LOG" 2>&1 &
LAUNCH_PID=$!

if [ -z "$LINT" ]; then
    if [ "$HAS_SHELLCHECK" = "false" ] && [ "$HAS_BATS" = "false" ]; then
        log_warn "Both shellcheck and bats are missing. Skipping local checks."
        LINT="false"
    else
        read -r -p "Run local linting (shellcheck) and unit tests (bats) first? [Y/n]: " lint_choice
        case "$lint_choice" in
            [nN]|[nN][oO]) LINT="false" ;;
            *) LINT="true" ;;
        esac
    fi
fi

if [ -z "$REBUILD" ]; then
    if [ "$HAS_SNAPCRAFT" = "false" ]; then
        log_warn "Snapcraft is not installed on the host. Skipping rebuild."
        REBUILD="false"
    else
        read -r -p "Clean and rebuild the snap package? [Y/n]: " rebuild_choice
        case "$rebuild_choice" in
            [nN]|[nN][oO]) REBUILD="false" ;;
            *) REBUILD="true" ;;
        esac
    fi
fi

# Construct and print equivalent CLI command
equivalent_cmd="./test_multipass.sh"
equivalent_cmd+=" --platform $PLATFORM"
equivalent_cmd+=" --cpus $CPUS"
equivalent_cmd+=" --memory $MEMORY"
equivalent_cmd+=" --disk $DISK"
if [ "$REBUILD" = "true" ]; then
    equivalent_cmd+=" --rebuild"
else
    equivalent_cmd+=" --no-rebuild"
fi
if [ "$LINT" = "true" ]; then
    equivalent_cmd+=" --lint"
else
    equivalent_cmd+=" --no-lint"
fi
if [ "$KEEP" = "true" ]; then
    equivalent_cmd+=" --keep"
fi

if [ "$WIZARD_USED" = "true" ]; then
    echo ""
    log "============================================================"
    log "WIZARD COMPLETED! To run this configuration directly next time, use:"
    echo -e "\033[1;35m  $equivalent_cmd\033[0m"
    log "============================================================"
    echo ""
fi

# Wait for snapd stability (specific to Ubuntu Core)
wait_for_snapd_stability() {
    log "Ensuring snapd is completely stable and idle..."
    local idle_checks=0
    local max_idle_checks=3
    
    while [ $idle_checks -lt $max_idle_checks ]; do
        if ! multipass exec "$VM_NAME" -- echo "Online" >/dev/null 2>&1; then
            log "VM is offline/rebooting. Waiting for it to come online..."
            sleep 10
            idle_checks=0
            continue
        fi
        
        if multipass exec "$VM_NAME" -- test -f /run/systemd/shutdown/scheduled 2>/dev/null; then
            log "A system reboot is scheduled by snapd. Rebooting immediately..."
            multipass exec "$VM_NAME" -- sudo reboot || true
            log "Waiting for VM to go offline..."
            sleep 10
            idle_checks=0
            continue
        fi
        
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

# Run local checks/linting if requested
if [ "$LINT" = "true" ]; then
    log "Running local tests and checks..."
    
    if command -v shellcheck >/dev/null 2>&1; then
        log "Running shellcheck..."
        local_scripts=$(grep -rl '^#!/.*sh' snap/local/runtime/ snap/local/build/ snap/hooks/ 2>/dev/null || true)
        if [ -n "$local_scripts" ]; then
            # shellcheck disable=SC2086
            shellcheck $local_scripts
            log_success "Shellcheck completed successfully."
        else
            log_warn "No shell scripts found for shellcheck."
        fi
    else
        log_warn "shellcheck not found on host. Skipping shellcheck checks."
    fi
    
    if command -v bats >/dev/null 2>&1; then
        log "Running BATS unit tests..."
        bats -r tests/
        log_success "BATS tests completed successfully."
    else
        log_warn "bats not found on host. Skipping BATS unit tests."
    fi
fi

# Rebuild the snap if requested
if [ "$REBUILD" = "true" ]; then
    log "Rebuilding snap package..."
    rm -f *.snap
    log "Running snapcraft clean..."
    snapcraft clean
    log "Running snapcraft..."
    snapcraft --verbosity=brief
fi

# Find the latest built snap file
SNAP_FILE=$(ls -t *.snap 2>/dev/null | head -n 1 || true)
if [ -z "$SNAP_FILE" ] || [ ! -f "$SNAP_FILE" ]; then
    log_error "No .snap file found! Please build the snap first or run with --rebuild."
    exit 1
fi
log "Using snap package: $SNAP_FILE"

# Wait for background VM launch to complete
log "Waiting for Multipass VM launch to complete..."
wait "$LAUNCH_PID"

# Print the launch log output for visibility (converting carriage returns to newlines)
tr '\r' '\n' < "$LAUNCH_LOG"

# Parse VM name
VM_NAME=$(sed -n 's/.*Launched:[[:space:]]*\([^[:space:]]*\).*/\1/p' "$LAUNCH_LOG" | tr -d '\r' | head -n 1)
if [ -z "$VM_NAME" ]; then
    log_error "Failed to launch Multipass VM or extract name."
    exit 1
fi
log_success "VM successfully launched! Name: $VM_NAME"

# Configure platform specific settings
if [ "$PLATFORM" = "lts" ]; then
    log "Configuring systemd-resolved on Ubuntu LTS to free port 53..."
    multipass exec "$VM_NAME" -- sudo mkdir -p /etc/systemd/resolved.conf.d
    multipass exec "$VM_NAME" -- sh -c 'printf "[Resolve]\nDNS=127.0.0.1\nDNSStubListener=no\n" | sudo tee /etc/systemd/resolved.conf.d/pihole.conf'
    multipass exec "$VM_NAME" -- sudo systemctl restart systemd-resolved
else
    # Core platform
    wait_for_snapd_stability
fi

# Transfer the snap
log "Transferring snap package to VM..."
VM_SNAP_PATH="/home/ubuntu/$(basename "$SNAP_FILE")"
multipass transfer "$SNAP_FILE" "${VM_NAME}:${VM_SNAP_PATH}"

# Install the snap
log "Installing snap package on VM..."
multipass exec "$VM_NAME" -- sudo snap remove --purge pihole-by-rajannpatel >/dev/null 2>&1 || true
multipass exec "$VM_NAME" -- sudo snap install "$VM_SNAP_PATH" --dangerous

if [ "$PLATFORM" != "lts" ]; then
    wait_for_snapd_stability
fi

# Connect snap interfaces
log "Connecting snap interfaces..."
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
    log "Connecting plug: $plug"
    multipass exec "$VM_NAME" -- sudo snap connect "pihole-by-rajannpatel:$plug" >/dev/null 2>&1 || true
done

# Create command aliases
log "Setting up command aliases..."
aliases=(
    "pihole"
    "check-system"
    "health"
    "status"
    "debug"
    "snapdebug"
)
for alias in "${aliases[@]}"; do
    if [ "$alias" = "pihole" ]; then
        multipass exec "$VM_NAME" -- sudo snap alias pihole-by-rajannpatel.pihole pihole >/dev/null 2>&1 || true
    else
        multipass exec "$VM_NAME" -- sudo snap alias "pihole-by-rajannpatel.$alias" "pihole.$alias" >/dev/null 2>&1 || true
    fi
done

# Start the daemon
log "Starting and enabling pihole-ftl service..."
multipass exec "$VM_NAME" -- sudo snap start --enable pihole-by-rajannpatel.pihole-ftl

# Get VM IP address and display verification
sleep 5
VM_IP=$(multipass info "$VM_NAME" | grep -i "IPv4:" | awk '{print $2}' | head -n 1)

echo ""
echo ""
log "Pi-hole snap is now running in Multipass VM '$VM_NAME'."
log "Admin web interface: http://${VM_IP}/admin"
log "To log into the VM: multipass shell $VM_NAME"
echo ""
echo ""

if [ "$KEEP" = "true" ]; then
    CLEANUP_ON_EXIT=false
    log "Keeping VM '$VM_NAME' running (as requested by --keep)."
else
    read -r -p "Press Enter to terminate/purge the VM, or type 'keep' (then Enter) to keep it: " choice
    if [ "$choice" = "keep" ]; then
        CLEANUP_ON_EXIT=false
        log "Keeping VM '$VM_NAME' running."
    else
        log "Cleaning up and deleting VM..."
        multipass delete --purge "$VM_NAME" || true
        CLEANUP_ON_EXIT=false
        log_success "VM '$VM_NAME' has been deleted and purged."
    fi
fi
