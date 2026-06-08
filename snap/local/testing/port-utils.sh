#!/bin/bash
# Common network socket and port helpers for Pi-hole snap diagnostic and setup scripts.

# check_tcp IP PORT
# Returns 0 if the port is in use, 1 if free.
check_tcp() {
    local ip=$1
    local port=$2
    # Allow unit tests to mock TCP checks
    if [ "${MOCK_TCP_CHECK:-}" = "true" ]; then
        if [[ ",${MOCK_TCP_PORTS_IN_USE:-}," == *",$ip:$port,"* ]]; then
            return 0
        fi
        return 1
    fi
    # Pure bash TCP socket check with 1-second timeout
    (
        bash -c "exec 2>/dev/null 3<>/dev/tcp/$ip/$port" &
        pid=$!
        (sleep 1; kill $pid 2>/dev/null) &
        killer_pid=$!
        wait $pid 2>/dev/null
        rc=$?
        kill $killer_pid 2>/dev/null
        exit $rc
    )
}

# check_udp HEX_PORT
# Returns 0 if the port is in use in /proc/net/udp or /proc/net/udp6, 1 if free.
# Hex matching: 53 is 0035, 67 is 0043, 546 is 0222.
check_udp() {
    local hex_port=$1
    if [ "${MOCK_TCP_CHECK:-}" = "true" ]; then
        if [[ ",${MOCK_UDP_PORTS_IN_USE:-}," == *",$hex_port,"* ]]; then
            return 0
        fi
        return 1
    fi
    grep -qi ":$hex_port " /proc/net/udp 2>/dev/null || grep -qi ":$hex_port " /proc/net/udp6 2>/dev/null
}
