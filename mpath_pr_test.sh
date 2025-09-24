#!/bin/bash

# mpath_pr_test - Test program for multipath persistent reservations
# Usage: mpath_pr_test.sh <device1> <device2>

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
IO_TEST_DURATION=5  # seconds to run I/O test after each command
CLEANUP_TIMEOUT=30  # seconds to wait for cleanup

# State tracking variables
DEVICE1_KEY="0x0"        # Current key for device1 (0x0 = not registered)
DEVICE2_KEY="0x1"        # Fixed key for device2 when registered
DEVICE1_NEXT_KEY="0x2"   # Next key to use for device1 registration
RESERVATION_HOLDER=""    # "device1", "device2", or "" (no reservation)

# Background process tracking
MULTIPATH_TEST_PID=""

# Function to print colored output
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

# Function to run sg_persist with retry on Unit Attention (exit code 6)
sg_persist_with_retry() {
    local max_retries=3
    local retry_count=0

    while [[ $retry_count -lt $max_retries ]]; do
        if sg_persist "$@"; then
            return 0
        else
            local exit_code=$?
            if [[ $exit_code -eq 6 ]]; then
                ((++retry_count))
                log_info "Unit Attention occurred (attempt $retry_count/$max_retries), retrying..."
                sleep 0.1
            else
                return $exit_code
            fi
        fi
    done

    log_error "sg_persist failed after $max_retries retries due to Unit Attention"
    return 6
}

# Function to verify device WWIDs match
verify_device_wwids() {
    log_info "Verifying that $DEVICE1 and $DEVICE2 point to the same storage..."

    local device1_wwid
    local device2_wwid

    # Get WWID of device1
    device1_wwid=$(multipathd show maps raw format "%n %w" | grep "$DEVICE1" | awk '{print $2}')
    if [[ -z "$device1_wwid" ]]; then
        log_error "Could not get WWID for $DEVICE1"
        exit 1
    fi

    # Get WWID of device2 using udevadm
    device2_wwid=$(udevadm info -n "$DEVICE2" --query=property --property=ID_SERIAL --value)
    if [[ -z "$device2_wwid" ]]; then
        log_error "Could not get WWID for $DEVICE2"
        exit 1
    fi

    # Compare WWIDs
    if [[ "$device1_wwid" == "$device2_wwid" ]]; then
        log_success "Device WWIDs match: $device1_wwid"
    else
        log_error "Device WWIDs do not match: $device1_wwid vs $device2_wwid"
        exit 1
    fi
}

# Function to check if device1 is registered
check_device1_registered() {
    local output
    output=$(mpathpersist -ik /dev/mapper/"$DEVICE1" 2>/dev/null)

    # First check if no keys are registered at all
    if echo "$output" | grep -q "0 registered reservation key"; then
        return 1  # Not registered
    fi

    # Keys exist, check if our specific key is present
    if echo "$output" | grep -q "$DEVICE1_KEY"; then
        return 0  # Registered with our expected key
    else
        return 1  # Not registered
    fi
}

# Function to check if device2 is registered
check_device2_registered() {
    local output
    output=$(sg_persist_with_retry -ik /dev/"$DEVICE2" 2>/dev/null)

    # First check if no keys are registered at all
    if echo "$output" | grep -q "there are NO registered reservation keys"; then
        return 1  # Not registered
    fi

    # Keys exist, check if device2's key is present
    if echo "$output" | grep -q "$DEVICE2_KEY"; then
        return 0  # Registered with expected key
    else
        return 1  # Not registered
    fi
}


# Function to increment device1 key
increment_device1_key() {
    local decimal_key=$((DEVICE1_NEXT_KEY))
    ((decimal_key++))
    DEVICE1_NEXT_KEY=$(printf "0x%x" $decimal_key)
}

# Function to verify state matches actual device status
verify_state() {
    local output

    # Check device1 registration status (only if we expect it to be registered)
    if [[ "$DEVICE1_KEY" != "0x0" ]]; then
        output=$(mpathpersist -ik /dev/mapper/"$DEVICE1" 2>/dev/null)
        if echo "$output" | grep -q "0 registered reservation key" || ! echo "$output" | grep -q "$DEVICE1_KEY"; then
            log_error "State verification failed: device1 should be registered with key $DEVICE1_KEY but not found"
            log_error "Registration output: $output"
            exit 1
        fi
    fi

    # Check reservation status
    output=$(mpathpersist -ir /dev/mapper/"$DEVICE1" 2>/dev/null)

    if [[ "$RESERVATION_HOLDER" == "" ]]; then
        # No reservation should exist
        if ! echo "$output" | grep -q "there is NO reservation held"; then
            log_error "State verification failed: no reservation should exist but reservation found"
            log_error "Reservation output: $output"
            exit 1
        fi
    else
        # Reservation should exist with correct key
        if echo "$output" | grep -q "there is NO reservation held"; then
            log_error "State verification failed: reservation should exist for $RESERVATION_HOLDER but none found"
            log_error "Reservation output: $output"
            exit 1
        else
            local reservation_key
            reservation_key=$(echo "$output" | grep "Key = " | sed 's/.*Key = \(0x[0-9a-fA-F]*\).*/\1/')
            local expected_key
            if [[ "$RESERVATION_HOLDER" == "device1" ]]; then
                expected_key="$DEVICE1_KEY"
            elif [[ "$RESERVATION_HOLDER" == "device2" ]]; then
                expected_key="$DEVICE2_KEY"
            else
                log_error "State verification failed: unknown reservation holder $RESERVATION_HOLDER"
                exit 1
            fi

            if [[ "$reservation_key" != "$expected_key" ]]; then
                log_error "State verification failed: reservation key $reservation_key does not match expected $expected_key for $RESERVATION_HOLDER"
                log_error "Reservation output: $output"
                exit 1
            fi
        fi
    fi

    log_info "State verified: device1_key=$DEVICE1_KEY, reservation_holder=$RESERVATION_HOLDER"
}

# Function to clear all registrations and reservations
clear_all_registrations() {
    local verify_clear=${1:-false}  # Optional parameter to verify clearing succeeded

    log_info "Clearing all registrations and reservations..."

    # unregister device1
    mpathpersist --out --register-ignore --param-sark=0x0 /dev/mapper/"$DEVICE1" || true
    # unregister device2
    sg_persist_with_retry --out --register-ignore --param-sark=0x0 /dev/"$DEVICE2" || true

    # Reset state - clear command removes ALL registrations and reservations
    DEVICE1_KEY="0x0"
    DEVICE1_NEXT_KEY="0x2"
    RESERVATION_HOLDER=""

    # Verify clearing succeeded if requested (for startup)
    if [[ "$verify_clear" == "true" ]]; then
        local output
        output=$(mpathpersist -ik /dev/mapper/"$DEVICE1" 2>/dev/null)
        if ! echo "$output" | grep -q "0 registered reservation key"; then
            log_error "Failed to clear all registrations - some keys still registered"
            log_error "Current registration status: $output"
            exit 1
        fi
        log_success "Verified all registrations cleared"
    else
        log_success "All registrations cleared"
    fi
}

# Function to perform I/O test
perform_io_test() {
    local should_succeed=$1
    local test_file="/dev/mapper/$DEVICE1"
    local temp_data="/tmp/mpath_pr_test_$$"

    log_info "Performing I/O test (${should_succeed}succeed) for $IO_TEST_DURATION seconds..."

    # Create test data
    dd if=/dev/urandom of="$temp_data" bs=4096 count=1 2>/dev/null

    local start_time=$(date +%s)
    local end_time=$((start_time + IO_TEST_DURATION))
    local any_io_succeeded=false
    local any_io_failed=false

    while [[ $(date +%s) -lt $end_time ]]; do
        if dd if="$temp_data" of="$test_file" bs=4096 count=1 oflag=direct 2>/dev/null; then
            any_io_succeeded=true
            # If I/O should NOT succeed, fail immediately on first success
            if [[ "$should_succeed" == "should_not_" ]]; then
                break
            fi
        else
            any_io_failed=true
            # If I/O should succeed, fail immediately on first failure
            if [[ "$should_succeed" == "should_" ]]; then
                break
            fi
        fi
        sleep 0.1
    done

    rm -f "$temp_data"

    if [[ "$should_succeed" == "should_" ]]; then
        if [[ "$any_io_failed" == "false" ]]; then
            log_success "I/O test passed: I/O succeeded as expected"
        else
            log_error "I/O test failed: I/O failed but should have succeeded"
            return 1
        fi
    else
        if [[ "$any_io_succeeded" == "false" ]]; then
            log_success "I/O test passed: I/O failed as expected"
        else
            log_error "I/O test failed: I/O succeeded but should have failed"
            return 1
        fi
    fi
}

# Function to determine expected I/O result
should_io_succeed() {
    # I/O should succeed if device1 has a registered key
    if [[ "$DEVICE1_KEY" != "0x0" ]]; then
        echo "should_"
    else
        # I/O should fail if device1 has no key and there's a reservation
        if [[ -n "$RESERVATION_HOLDER" ]]; then
            echo "should_not_"
        else
            echo "should_"
        fi
    fi
}

# Function to execute REGISTER command
execute_register() {
    local variant=$1  # "new_key" or "unregister"

    if [[ "$variant" == "unregister" ]]; then
        log_info "Executing REGISTER to unregister device1 (key=$DEVICE1_KEY -> 0x0)"
        mpathpersist --out --register --param-rk="$DEVICE1_KEY" --param-sark=0x0 /dev/mapper/"$DEVICE1"
        DEVICE1_KEY="0x0"
        if [[ "$RESERVATION_HOLDER" == "device1" ]]; then
            RESERVATION_HOLDER=""  # Unregistering releases reservation
        fi
    else
        local new_key="$DEVICE1_NEXT_KEY"
        log_info "Executing REGISTER with new key (key=$DEVICE1_KEY -> $new_key)"
        mpathpersist --out --register --param-rk="$DEVICE1_KEY" --param-sark="$new_key" /dev/mapper/"$DEVICE1"
        DEVICE1_KEY="$new_key"
        increment_device1_key
    fi
}

# Function to execute REGISTER_AND_IGNORE command
execute_register_and_ignore() {
    local variant=$1  # "new_key" or "unregister"

    if [[ "$variant" == "unregister" ]]; then
        log_info "Executing REGISTER_AND_IGNORE to unregister device1 (key=$DEVICE1_KEY -> 0x0)"
        mpathpersist --out --register-ignore --param-sark=0x0 /dev/mapper/"$DEVICE1"
        DEVICE1_KEY="0x0"
        if [[ "$RESERVATION_HOLDER" == "device1" ]]; then
            RESERVATION_HOLDER=""  # Unregistering releases reservation
        fi
    else
        local new_key="$DEVICE1_NEXT_KEY"
        log_info "Executing REGISTER_AND_IGNORE with new key (key=$DEVICE1_KEY -> $new_key)"
        mpathpersist --out --register-ignore --param-sark="$new_key" /dev/mapper/"$DEVICE1"
        DEVICE1_KEY="$new_key"
        increment_device1_key
    fi
}

# Function to execute RESERVE command
execute_reserve() {
    log_info "Executing RESERVE (key=$DEVICE1_KEY)"
    mpathpersist --out --reserve --param-rk="$DEVICE1_KEY" --prout-type=5 /dev/mapper/"$DEVICE1"
    RESERVATION_HOLDER="device1"
}

# Function to execute RELEASE command
execute_release() {
    log_info "Executing RELEASE (key=$DEVICE1_KEY)"
    mpathpersist --out --release --param-rk="$DEVICE1_KEY" --prout-type=5 /dev/mapper/"$DEVICE1"
    if [[ "$RESERVATION_HOLDER" == "device1" ]]; then
        RESERVATION_HOLDER=""  # Unregistering releases reservation
    fi
}

# Function to execute CLEAR command
execute_clear() {
    log_info "Executing CLEAR (key=$DEVICE1_KEY)"
    mpathpersist --out --clear --param-rk="$DEVICE1_KEY" /dev/mapper/"$DEVICE1"
    DEVICE1_KEY="0x0"
    RESERVATION_HOLDER=""
}

# Function to execute PREEMPT command (device1 preempts device2)
execute_preempt() {
    log_info "Executing PREEMPT test (device1 preempts device2)"

    # Register device2
    log_info "Registering device2 with key $DEVICE2_KEY"
    sg_persist_with_retry --out --register-ignore --param-sark="$DEVICE2_KEY" /dev/"$DEVICE2"

    # Randomly decide whether to grab reservation on device2 (only if no reservation exists)
    if [[ "$RESERVATION_HOLDER" == "" && $((RANDOM % 2)) -eq 0 ]]; then
        log_info "Device2 grabbing reservation"
        sg_persist_with_retry --out --reserve --param-rk="$DEVICE2_KEY" --prout-type=5 /dev/"$DEVICE2"
        RESERVATION_HOLDER="device2"
    fi

    # Execute preempt from device1
    log_info "Device1 preempting device2 (key=$DEVICE1_KEY preempts $DEVICE2_KEY)"
    mpathpersist --out --preempt --param-rk="$DEVICE1_KEY" --param-sark="$DEVICE2_KEY" --prout-type=5 /dev/mapper/"$DEVICE1"
    if [[ "$RESERVATION_HOLDER" == "device2" ]]; then
        RESERVATION_HOLDER="device1"
    fi
}

# Function to execute preempt by device2 (device2 preempts device1)
execute_preempt_by_device2() {
    log_info "Executing PREEMPT test (device2 preempts device1)"

    # Register device2
    log_info "Registering device2 with key $DEVICE2_KEY"
    sg_persist_with_retry --out --register-ignore --param-sark="$DEVICE2_KEY" /dev/"$DEVICE2"

    # Execute preempt from device2
    log_info "Device2 preempting device1 (key=$DEVICE2_KEY preempts $DEVICE1_KEY)"
    sg_persist_with_retry --out --preempt --param-rk="$DEVICE2_KEY" --param-sark="$DEVICE1_KEY" --prout-type=5 /dev/"$DEVICE2"
    DEVICE1_KEY="0x0"  # Device1 gets unregistered
    if [[ "$RESERVATION_HOLDER" == "device1" ]]; then
        RESERVATION_HOLDER="device2"
    fi
}

# Function to get list of valid commands based on current state
get_valid_commands() {
    local commands=()

    if [[ "$DEVICE1_KEY" == "0x0" ]]; then
        # Device1 not registered - only register commands valid
        commands+=("REGISTER" "REGISTER_AND_IGNORE")
    else
        # Device1 registered - most commands valid
        commands+=("REGISTER_NEW" "REGISTER_UNREGISTER" "REGISTER_AND_IGNORE_NEW" "REGISTER_AND_IGNORE_UNREGISTER")
        commands+=("RELEASE" "CLEAR" "PREEMPT" "PREEMPT_BY_DEVICE2")

        # RESERVE only valid if no reservation or device1 holds it
        if [[ "$RESERVATION_HOLDER" == "" || "$RESERVATION_HOLDER" == "device1" ]]; then
            commands+=("RESERVE")
        fi
    fi

    echo "${commands[@]}"
}

# Function to execute a random valid command
execute_random_command() {
    local commands
    read -ra commands <<< "$(get_valid_commands)"

    local command="${commands[$((RANDOM % ${#commands[@]}))]}"

    log_info "Selected command: $command"

    case "$command" in
        "REGISTER")
            execute_register "new_key"
            ;;
        "REGISTER_NEW")
            execute_register "new_key"
            ;;
        "REGISTER_UNREGISTER")
            execute_register "unregister"
            ;;
        "REGISTER_AND_IGNORE")
            execute_register_and_ignore "new_key"
            ;;
        "REGISTER_AND_IGNORE_NEW")
            execute_register_and_ignore "new_key"
            ;;
        "REGISTER_AND_IGNORE_UNREGISTER")
            execute_register_and_ignore "unregister"
            ;;
        "RESERVE")
            execute_reserve
            ;;
        "RELEASE")
            execute_release
            ;;
        "CLEAR")
            execute_clear
            ;;
        "PREEMPT")
            execute_preempt
            ;;
        "PREEMPT_BY_DEVICE2")
            execute_preempt_by_device2
            ;;
        *)
            log_error "Unknown command: $command"
            return 1
            ;;
    esac
}

# Function to start background multipath test
start_background_test() {
    log_info "Starting background multipath test..."
    ./multipath-test.sh "$DEVICE1" &
    MULTIPATH_TEST_PID=$!
    log_info "Background test started with PID $MULTIPATH_TEST_PID"
}

# Function to cleanup on exit
cleanup() {
    log_info "Cleaning up..."

    # Kill background test
    if [[ -n "$MULTIPATH_TEST_PID" ]]; then
        log_info "Stopping background test (PID $MULTIPATH_TEST_PID)..."
        kill "$MULTIPATH_TEST_PID" 2>/dev/null || true
        wait "$MULTIPATH_TEST_PID" 2>/dev/null || true
    fi

    # Clear all registrations
    clear_all_registrations 2>/dev/null || true

    log_info "Cleanup complete"
}

# Main function
main() {
    log_info "Starting mpath_pr_test for devices: $DEVICE1 (multipath) and $DEVICE2 (SCSI)"

    # Set up cleanup trap
    trap cleanup EXIT INT TERM

    # Verify devices point to same storage
    verify_device_wwids

    # Clear any existing registrations and verify success
    clear_all_registrations true

    # Start background multipath test
    start_background_test

    # Main test loop
    local iteration=1
    while true; do
        echo
        log_info "=== Test iteration $iteration ==="

        # Execute random command
        execute_random_command

        # Verify state after command
        verify_state

        # Perform I/O test
        local io_expectation
        io_expectation=$(should_io_succeed)
        perform_io_test "$io_expectation"

        log_success "Iteration $iteration completed successfully"
        ((iteration++))

        # Brief pause between iterations
        sleep 1
    done
}

# Script entry point
if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <device1> <device2>"
    echo "  device1: multipath device (e.g., mpatha)"
    echo "  device2: SCSI device pointing to same storage (e.g., sdb)"
    exit 1
fi

# Command line arguments
DEVICE1="$1"
DEVICE2="$2"

# Check prerequisites
check_root

# Check if required commands are available
for cmd in mpathpersist multipath multipathd sg_persist udevadm; do
    if ! command -v "$cmd" &> /dev/null; then
        log_error "Required command '$cmd' not found"
        exit 1
    fi
done

# Check if multipath-test.sh exists
if [[ ! -x "./multipath-test.sh" ]]; then
    log_error "multipath-test.sh not found or not executable in current directory"
    exit 1
fi

# Run main function
main
