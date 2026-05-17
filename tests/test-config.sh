#!/bin/sh
# test-config.sh
# Mocks snapctl and pihole-FTL to test the configuration helper logic directly.
set -eu

# Create a temporary environment to test our config-helper without 
# requiring a full snap build and install.
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

# Mock FTL
mkdir -p "${TEST_DIR}/usr/bin"
cat > "${TEST_DIR}/usr/bin/pihole-FTL" <<'EOF'
#!/bin/sh
if [ "$1" = "--config" ]; then
    # Fake setting a value. We just echo it to a log so we can assert it was called.
    if [ $# -eq 3 ]; then
        echo "$2=$3" >> "$FTL_MOCK_LOG"
    elif [ $# -eq 2 ]; then
        # simulate read
        grep "^$2=" "$FTL_MOCK_LOG" | cut -d= -f2 || true
    fi
fi
EOF
chmod +x "${TEST_DIR}/usr/bin/pihole-FTL"
export SNAP="${TEST_DIR}"
export FTL_MOCK_LOG="${TEST_DIR}/ftl.log"
touch "$FTL_MOCK_LOG"

# Source our library
. "$(dirname "$0")/../snap/hooks/lib/config-helper.sh"

echo "Running tests..."
fails=0

assert_valid() {
    local key="$1"
    local val="$2"
    if ! apply_to_ftl "$key" "$val" >/dev/null 2>&1; then
        echo "FAIL: Expected valid key '$key' with value '$val' to pass."
        fails=$((fails + 1))
    else
        echo "PASS: Valid key '$key' with value '$val'"
    fi
}

assert_invalid() {
    local key="$1"
    local val="$2"
    if apply_to_ftl "$key" "$val" >/dev/null 2>&1; then
        echo "FAIL: Expected invalid key '$key' with value '$val' to fail."
        fails=$((fails + 1))
    else
        echo "PASS: Invalid key '$key' with value '$val' failed gracefully"
    fi
}

# Type: int port validation
assert_valid "dns.port" "53"
assert_valid "dns.port" "5353"
assert_invalid "dns.port" "0"
assert_invalid "dns.port" "65536"
assert_invalid "dns.port" "abc"

# Type: bool
assert_valid "dns.dnssec" "true"
assert_valid "dns.dnssec" "false"
assert_invalid "dns.dnssec" "yes"
assert_invalid "dns.dnssec" "1"

# Type: ip
assert_valid "dhcp.range.start" "192.168.1.100"
assert_invalid "dhcp.range.start" "256.256.256.256"
assert_invalid "dhcp.range.start" "192.168.1.100.1"
assert_invalid "dhcp.range.start" "not.an.ip"

# Type: enum
assert_valid "dns.interface" "local"
assert_valid "dns.interface" "bind"
assert_invalid "dns.interface" "eth0"

# Verify mapping was passed to FTL
assert_valid "logging.query" "false"
if grep -q "database.DBimport=false" "$FTL_MOCK_LOG"; then
    echo "PASS: FTL mapping successful"
else
    echo "FAIL: FTL mapping failed. Log contents:"
    cat "$FTL_MOCK_LOG"
    fails=$((fails + 1))
fi

if [ "$fails" -eq 0 ]; then
    echo "All tests passed!"
    exit 0
else
    echo "$fails tests failed."
    exit 1
fi
