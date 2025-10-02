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
PREEMPTED_KEY=""         # Key that was just preempted (for verification)

# Background process tracking
MULTIPATH_TEST_PID=""
IO_TEST_PID=""
CURRENT_IO_EXPECTED=""
IO_TEST_RUNNING=false

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

    # Check if a key was just preempted and verify it's no longer registered
    if [[ -n "$PREEMPTED_KEY" ]]; then
        output=$(mpathpersist -ik /dev/mapper/"$DEVICE1" 2>/dev/null)
        if echo "$output" | grep -q "$PREEMPTED_KEY"; then
            log_error "State verification failed: preempted key $PREEMPTED_KEY should not be registered but was found"
            log_error "Registration output: $output"
            exit 1
        fi
        log_info "Verified preempted key $PREEMPTED_KEY was removed"
        PREEMPTED_KEY=""  # Clear after verification
    fi

    # Verify multipathd's view of PR state (only if device1 wasn't preempted)
    if [[ -z "$PREEMPTED_KEY" || "$PREEMPTED_KEY" == "$DEVICE2_KEY" ]]; then
        # Verify registration key
        local prkey_output
        prkey_output=$(multipathd getprkey map "$DEVICE1" 2>/dev/null)

        if [[ "$DEVICE1_KEY" == "0x0" ]]; then
            if [[ "$prkey_output" != "none" ]]; then
                log_error "State verification failed: multipathd getprkey should return 'none' for unregistered device1"
                log_error "multipathd getprkey output: $prkey_output"
                exit 1
            fi
        else
            if [[ "$prkey_output" != "$DEVICE1_KEY" ]]; then
                log_error "State verification failed: multipathd getprkey should return $DEVICE1_KEY"
                log_error "multipathd getprkey output: $prkey_output"
                exit 1
            fi
        fi

        # Verify registration status
        local prstatus_output
        prstatus_output=$(multipathd getprstatus map "$DEVICE1" 2>/dev/null)

        if [[ "$DEVICE1_KEY" == "0x0" ]]; then
            if [[ "$prstatus_output" != "unset" ]]; then
                log_error "State verification failed: multipathd getprstatus should return 'unset' for unregistered device1"
                log_error "multipathd getprstatus output: $prstatus_output"
                exit 1
            fi
        else
            if [[ "$prstatus_output" != "set" ]]; then
                log_error "State verification failed: multipathd getprstatus should return 'set' for registered device1"
                log_error "multipathd getprstatus output: $prstatus_output"
                exit 1
            fi
        fi

        # Verify reservation holder
        local prhold_output
        prhold_output=$(multipathd getprhold map "$DEVICE1" 2>/dev/null)

        if [[ "$RESERVATION_HOLDER" == "device1" ]]; then
            if [[ "$prhold_output" != "set" ]]; then
                log_error "State verification failed: multipathd getprhold should return 'set' when device1 holds reservation"
                log_error "multipathd getprhold output: $prhold_output"
                exit 1
            fi
        else
            if [[ "$prhold_output" != "unset" ]]; then
                log_error "State verification failed: multipathd getprhold should return 'unset' when device1 doesn't hold reservation"
                log_error "multipathd getprhold output: $prhold_output"
                exit 1
            fi
        fi

        log_info "multipathd state verified: prkey=$prkey_output, prstatus=$prstatus_output, prhold=$prhold_output"
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
    PREEMPTED_KEY=""

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

# Function to determine expected I/O result
get_expected_result() {
    # I/O should succeed if device1 has a registered key
    if [[ "$DEVICE1_KEY" != "0x0" ]]; then
        echo "pass"
    else
        # I/O should fail if device1 has no key and there's a reservation
        if [[ -n "$RESERVATION_HOLDER" ]]; then
            echo "fail"
        else
            echo "pass"
        fi
    fi
}

# Function to start background I/O test
start_io_test() {
    local expected_result=$1

    if [[ "$IO_TEST_RUNNING" == "true" ]]; then
        log_error "I/O test is already running (PID: $IO_TEST_PID)"
        return 1
    fi

    log_info "Starting background I/O test (expected: $expected_result)"

    # Start io_test.sh in background
    ./io_test.sh "/dev/mapper/$DEVICE1" "$expected_result" &
    IO_TEST_PID=$!
    CURRENT_IO_EXPECTED="$expected_result"
    IO_TEST_RUNNING=true

    # Verify process started
    sleep 0.1
    if ! kill -0 "$IO_TEST_PID" 2>/dev/null; then
        log_error "Failed to start I/O test process"
        IO_TEST_PID=""
        CURRENT_IO_EXPECTED=""
        IO_TEST_RUNNING=false
        return 1
    fi

    log_info "I/O test started successfully (PID: $IO_TEST_PID)"
}

# Function to stop background I/O test
stop_io_test() {
    if [[ "$IO_TEST_RUNNING" != "true" ]]; then
        log_error "I/O test is not currently running"
        return 1
    fi

    log_info "Stopping background I/O test (PID: $IO_TEST_PID)"

    # Send TERM signal
    kill -TERM "$IO_TEST_PID" 2>/dev/null || true

    # Wait for process to exit and capture exit code
    local exit_code=0
    if ! wait "$IO_TEST_PID" 2>/dev/null; then
        exit_code=$?
    fi

    # Reset tracking variables
    IO_TEST_PID=""
    CURRENT_IO_EXPECTED=""
    IO_TEST_RUNNING=false

    if [[ $exit_code -ne 0 ]]; then
        log_error "I/O test failed with exit code $exit_code"
        return 1
    fi

    log_info "I/O test stopped successfully"
}

# Function to check if I/O test is still running
check_io_test_running() {
    if [[ "$IO_TEST_RUNNING" != "true" ]]; then
        log_error "I/O test should be running but is not"
        return 1
    fi

    if ! kill -0 "$IO_TEST_PID" 2>/dev/null; then
        # Process is not running, get exit code
        local exit_code=0
        wait "$IO_TEST_PID" 2>/dev/null || exit_code=$?

        log_error "I/O test process unexpectedly stopped with exit code $exit_code"
        IO_TEST_PID=""
        CURRENT_IO_EXPECTED=""
        IO_TEST_RUNNING=false
        return 1
    fi

    log_info "I/O test is running normally"
}

# Function to determine if I/O expectation will change after a command
will_io_expectation_change() {
    local command=$1
    local current_expected="$CURRENT_IO_EXPECTED"
    local new_expected

    # Calculate what the new expectation would be after the command
    case "$command" in
        "RESERVE"|"RELEASE"|"CLEAR"|"PREEMPT")
            # These commands always result in pass (I/O always succeeds)
            new_expected="pass"
            ;;
        "REGISTER"|"REGISTER_NEW"|"REGISTER_AND_IGNORE"|"REGISTER_AND_IGNORE_NEW")
            # Registration always results in pass (device1 will have a key)
            new_expected="pass"
            ;;
        "REGISTER_UNREGISTER"|"REGISTER_AND_IGNORE_UNREGISTER")
            # If device2 holds reservation, I/O will fail. Otherwise pass.
            if [[ "$RESERVATION_HOLDER" == "device2" ]]; then
                new_expected="fail"
            else
                new_expected="pass"
            fi
            ;;
        "PREEMPT_BY_DEVICE2")
            # I/O will fail if either device holds reservation, pass if no reservation
            if [[ -n "$RESERVATION_HOLDER" ]]; then
                new_expected="fail"
            else
                new_expected="pass"
            fi
            ;;
        *)
            log_error "Unknown command in will_io_expectation_change: $command"
            return 1
            ;;
    esac

    # Return true (0) if expectation will change, false (1) if same
    if [[ "$current_expected" != "$new_expected" ]]; then
        return 0  # Will change
    else
        return 1  # Will not change
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
    PREEMPTED_KEY="$DEVICE2_KEY"
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
    PREEMPTED_KEY="$DEVICE1_KEY"
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
    local io_test_was_stopped=false

    log_info "Selected command: $command"

    # Check if I/O expectation will change after this command
    if will_io_expectation_change "$command"; then
        log_info "I/O expectation will change, stopping I/O test"
        stop_io_test
        io_test_was_stopped=true
    fi

    # Execute the selected command
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

    # If we stopped the I/O test, restart it with the new expectation
    if [[ "$io_test_was_stopped" == "true" ]]; then
        local new_expected_result
        new_expected_result=$(get_expected_result)
        log_info "Restarting I/O test with new expectation: $new_expected_result"
        start_io_test "$new_expected_result"
    fi
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
    log_info "Exit state."
    log_info "Registered keys:"
    mpathpersist -ik /dev/mapper/"$DEVICE1"
    log_info "Reservation:"
    mpathpersist -ir /dev/mapper/"$DEVICE1"
    log_info "multipath state:"
    multipath -l "$DEVICE1"
    log_info "Cleaning up..."

    # Stop I/O test
    if [[ "$IO_TEST_RUNNING" == "true" && -n "$IO_TEST_PID" ]]; then
        log_info "Stopping I/O test (PID $IO_TEST_PID)..."
        kill -TERM "$IO_TEST_PID" 2>/dev/null || true
        wait "$IO_TEST_PID" 2>/dev/null || true
        IO_TEST_PID=""
        IO_TEST_RUNNING=false
        CURRENT_IO_EXPECTED=""
    fi

    # Kill background multipath test
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

    # Start background I/O test (initially expecting pass since no reservations exist)
    start_io_test "pass"

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

        # Wait for I/O test duration and then check if I/O test is still running
        log_info "Waiting $IO_TEST_DURATION seconds for I/O test validation..."
        sleep "$IO_TEST_DURATION"
        check_io_test_running

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
