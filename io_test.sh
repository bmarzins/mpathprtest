#!/bin/bash

# io_test.sh - Repeatedly test I/O operations on a block device
# Usage: io_test.sh <device> <pass_or_fail>

# Function to handle TERM signal
cleanup() {
    echo "Received TERM signal, exiting successfully"
    exit 0
}

# Set up signal handler
trap cleanup TERM

# Check arguments
if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <device> <pass_or_fail>" >&2
    echo "  <device>: Path to block device" >&2
    echo "  <pass_or_fail>: Either 'pass' or 'fail'" >&2
    exit 1
fi

DEVICE="$1"
EXPECTED_RESULT="$2"

# Validate arguments
if [[ ! -e "$DEVICE" ]]; then
    echo "Error: Device '$DEVICE' does not exist" >&2
    exit 1
fi

if [[ "$EXPECTED_RESULT" != "pass" && "$EXPECTED_RESULT" != "fail" ]]; then
    echo "Error: Expected result must be 'pass' or 'fail', got '$EXPECTED_RESULT'" >&2
    exit 1
fi

echo "Starting I/O test on $DEVICE (expected: $EXPECTED_RESULT)"
echo "Press Ctrl+C or send TERM signal to stop"

# Main test loop
while true; do
    if sg_dd if=/dev/zero of="$DEVICE" bs=512 bpt=8 count=8 oflag=direct,sgio 2>/dev/null; then
        # sg_dd command succeeded
        if [[ "$EXPECTED_RESULT" == "fail" ]]; then
            echo "FAILURE: I/O succeeded but was expected to fail"
            exit 1
        fi
        echo -n "."
    else
        # sg_dd command failed
        EXIT_CODE=$?
        if [[ "$EXPECTED_RESULT" == "pass" ]]; then
            if [[ $EXIT_CODE -eq 24 ]]; then
                echo "FAILURE: I/O failed with conflict but was expected to pass"
                exit 1
            fi
            echo "I/O failed with $EXIT_CODE. checking paths"
            if ! ./probe "$DEVICE" ; then
                echo "FAILURE: probing paths failed"
		exit 1
            fi
        fi
        echo -n "x"
    fi

    sleep 0.1
done
