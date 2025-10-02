# mpath_pr_test Detailed Design Document

## Overview

The `mpath_pr_test` program is a comprehensive test suite for validating SCSI Persistent Reservations (PR) functionality on device-mapper multipath devices using the `mpathpersist` and `sg_persist` utilities. The test simulates real-world scenarios including multiple device access patterns and path failures while systematically testing all supported PR commands.

## Architecture

### Program Type
- **Implementation**: Bash shell script
- **Rationale**: All operations are command-line tools (`mpathpersist`, `sg_persist`, `dd`). Bash provides natural orchestration of external commands with simpler string parsing and process management compared to C.

### Command Line Interface
```bash
mpath_pr_test.sh <device1> <device2>
```

**Parameters:**
- `device1`: Multipath device name (e.g., "mpatha")
- `device2`: SCSI device name pointing to the same underlying storage as device1 (e.g., "sdb") - device name only, not full path

## State Management

### Core State Variables
```bash
DEVICE1_KEY="0x0"        # Current registration key for device1 (0x0 = not registered)
DEVICE2_KEY="0x1"        # Fixed registration key for device2 when registered
DEVICE1_NEXT_KEY="0x2"   # Next key to assign to device1 (increments: 0x2, 0x3, 0x4...)
RESERVATION_HOLDER=""    # Current reservation holder: "device1", "device2", or "" (none)
PREEMPTED_KEY=""         # Key that was just preempted (for verification, cleared after verify_state)
```

### Key Management Strategy
- **Device1**: Starts with key `0x2`, increments for each new registration (`0x3`, `0x4`, etc.)
- **Device2**: Always uses fixed key `0x1` when registered
- **Key Conflicts**: Avoided by design - device1 starts at `0x2` and only increments upward
- **Unregistration**: Device1 key resets to `0x0` (special value indicating not registered)

### State Tracking Functions

#### Registration Status Checking
```bash
check_device1_registered()
check_device2_registered()
```

**Implementation Details:**
- Device1: Uses `mpathpersist -ik` to read registered keys
- Device2: Uses `sg_persist_with_retry -ik /dev/"$DEVICE2"` to read registered keys (uses device name with /dev/ prefix)
- **Critical Logic**:
  - Device1: First checks for "0 registered reservation key" pattern
  - Device2: First checks for "there are NO registered reservation keys" pattern
- **Output Format Differences**: sg_persist vs mpathpersist have different no-keys messages
- **Avoids False Positives**: Generation numbers in output could match expected keys
- **Multi-path Handling**: Same key appears multiple times (once per path) - only need one match
- **Pure Functions**: Only return status, do not modify state variables

#### Device2 sg_persist Retry Logic
```bash
sg_persist_with_retry()
```

**Implementation Details:**
- Wraps all `sg_persist` commands with automatic retry logic
- **Unit Attention Handling**: Exit code 6 indicates Unit Attention condition (not an error)
- **Retry Strategy**: Up to 3 attempts with 0.1 second delay between retries
- **Error Propagation**: Non-6 exit codes immediately return as errors
- **Timeout Protection**: Prevents infinite retry loops on persistent Unit Attention
- **Pre-increment Fix**: Uses `((++retry_count))` instead of `((retry_count++))` to avoid arithmetic evaluation issues where zero would be treated as failure status

#### State Verification
```bash
verify_state()
```

**Implementation Details:**
- Verifies actual device state matches tracked state variables
- **Device1 Registration**: Only checks if `DEVICE1_KEY != "0x0"` (trusts that 0x0 never appears in key lists)
- **Reservation Status**: Always validates reservation holder matches `RESERVATION_HOLDER`
- **Preemption Verification**: If `PREEMPTED_KEY` is set, verifies that key does NOT appear in registered keys output
  - Queries `mpathpersist -ik` and ensures preempted key is absent
  - Logs verification success and clears `PREEMPTED_KEY` after check
  - Exits with error if preempted key still found (indicates preempt command failed)
- **Fail Fast**: Exits with error if verification fails, indicating command or state tracking bugs

## Device Verification

### WWID Comparison
Ensures both devices point to the same underlying storage using World Wide Identifiers:

**Multipath Device (device1):**
```bash
multipathd show maps raw format "%n %w" | grep "$DEVICE1" | awk '{print $2}'
```

**SCSI Device (device2):**
```bash
udevadm info -n "$DEVICE2" --query=property --property=ID_SERIAL --value
```

**Critical Implementation Notes:**
- Uses udevadm to extract WWID from SCSI device properties
- Both devices must have matching WWIDs to proceed
- Program exits with error if WWIDs don't match

## Command Testing Framework

### Command Validation Logic

#### When Device1 NOT Registered (`DEVICE1_KEY="0x0"`)
**Valid Commands:**
- `REGISTER` - Register new key for device1
- `REGISTER_AND_IGNORE` - Register new key for device1 (ignore existing reservations)

#### When Device1 IS Registered (`DEVICE1_KEY != "0x0"`)
**Most Commands Valid:**
- `REGISTER` (2 variants):
  - Register new key (increment `DEVICE1_KEY`)
  - Unregister (set `DEVICE1_KEY="0x0"`, auto-releases reservation)
- `REGISTER_AND_IGNORE` (2 variants): Same as REGISTER
- `RESERVE` - Create type 5 reservation with device1's key (**only if no reservation exists or device1 holds it**)
- `RELEASE` - Release type 5 reservation (valid even if not holding reservation)
- `CLEAR` - Clear all registrations and reservations
- `PREEMPT` - Device1 preempts device2's registration/reservation
- `PREEMPT_BY_DEVICE2` - Device2 preempts device1's registration/reservation

### Persistent Reservation Commands

#### All PR Operations Use Type 5
**Reservation Type:** Write Exclusive - Registrants Only (`--prout-type=5`)
**Characteristics:**
- Only registered initiators can perform write operations
- Multiple registrants can coexist
- Reservation holder has exclusive write access unless other registrants preempt

#### Command Implementations

**REGISTER Command:**
```bash
# New registration or update existing registration (simplified - always specify --param-rk)
mpathpersist --out --register --param-rk="$DEVICE1_KEY" --param-sark="$new_key" /dev/mapper/"$DEVICE1"

# Unregister
mpathpersist --out --register --param-rk="$DEVICE1_KEY" --param-sark=0x0 /dev/mapper/"$DEVICE1"
```

**REGISTER_AND_IGNORE Command:**
```bash
# New registration (no --param-rk specified - ignores existing reservations)
mpathpersist --out --register-ignore --param-sark="$new_key" /dev/mapper/"$DEVICE1"

# Unregister
mpathpersist --out --register-ignore --param-sark=0x0 /dev/mapper/"$DEVICE1"
```

**RESERVE/RELEASE Commands:**
```bash
# Reserve
mpathpersist --out --reserve --param-rk="$DEVICE1_KEY" --prout-type=5 /dev/mapper/"$DEVICE1"

# Release
mpathpersist --out --release --param-rk="$DEVICE1_KEY" --prout-type=5 /dev/mapper/"$DEVICE1"
```

**CLEAR Command:**
```bash
mpathpersist --out --clear --param-rk="$DEVICE1_KEY" /dev/mapper/"$DEVICE1"
```

**PREEMPT Commands:**
```bash
# Device1 preempts device2
mpathpersist --out --preempt --param-rk="$DEVICE1_KEY" --param-sark="$DEVICE2_KEY" --prout-type=5 /dev/mapper/"$DEVICE1"
# Sets PREEMPTED_KEY="$DEVICE2_KEY" for verification

# Device2 preempts device1 (using sg_persist)
sg_persist_with_retry --out --preempt --param-rk="$DEVICE2_KEY" --param-sark="$DEVICE1_KEY" --prout-type=5 /dev/"$DEVICE2"
# Sets PREEMPTED_KEY="$DEVICE1_KEY" for verification
```

**Device2 Operations (using sg_persist):**
```bash
# Register device2
sg_persist_with_retry --out --register-ignore --param-sark="$DEVICE2_KEY" /dev/"$DEVICE2"

# Reserve from device2
sg_persist_with_retry --out --reserve --param-rk="$DEVICE2_KEY" --prout-type=5 /dev/"$DEVICE2"

# Unregister device2 (cleanup)
sg_persist_with_retry --out --register-ignore --param-sark=0x0 /dev/"$DEVICE2"
```

#### State Tracking Precision
**Conditional Reservation Updates:** The implementation includes precise tracking of reservation holder changes:

- **REGISTER/REGISTER_AND_IGNORE unregister**: Only clears `RESERVATION_HOLDER` if device1 was holding it
- **RELEASE**: Only clears `RESERVATION_HOLDER` if device1 was holding the reservation
- **PREEMPT operations**: Only change `RESERVATION_HOLDER` if the operation actually preempted an existing reservation
- **Prevents false state**: Avoids incorrectly clearing reservation holder when device1 wasn't actually holding it

### Multi-Device Testing

#### PREEMPT Test Scenarios

**Device1 Preempts Device2:**
1. Register device2 using sg_persist with key `0x1` (using `--register-ignore` for reliability)
2. Randomly decide whether device2 grabs reservation (only if no reservation exists)
3. Device1 executes preempt command
4. Device2 becomes unregistered, device1 holds reservation

**Device2 Preempts Device1:**
1. Register device2 using sg_persist with key `0x1` (using `--register-ignore` for reliability)
2. Device2 executes preempt command using sg_persist
3. Device1 becomes unregistered, device2 holds reservation

#### Device Access Patterns
- Device1 (multipath): Uses `mpathpersist` for all operations
- Device2 (SCSI): Uses `sg_persist_with_retry` wrapper for all operations
- Both devices point to same underlying storage with verified matching WWIDs
- Unit Attention conditions on device2 are automatically retried

## I/O Testing Framework

### I/O Test Execution
**Duration:** 5 seconds after each PR command
**Method:** Direct I/O using `dd` with `oflag=direct`
**Test Data:** Random 4KB blocks written to the multipath device

### I/O Success/Failure Logic

#### Expected Success Conditions
- Device1 has registered key (`DEVICE1_KEY != "0x0"`)
- Device1 not registered AND no reservation exists

#### Expected Failure Conditions
- Device1 not registered AND reservation exists (type 5 behavior)

### Background I/O Test Implementation

**Approach:** Continuous I/O monitoring using standalone `io_test.sh` script instead of brief periodic tests.

#### Core Functions
```bash
start_io_test(expected_result) {
    # Start io_test.sh in background with expected result ("pass" or "fail")
    # Track PID and current expectation
    # Validate process started successfully
}

stop_io_test() {
    # Send TERM signal to io_test.sh
    # Wait for process exit and validate exit code
    # Fail if exit code indicates I/O test failure
}

check_io_test_running() {
    # Verify io_test.sh is still running
    # If stopped unexpectedly, capture and report exit code
}

will_io_expectation_change(command) {
    # Analyze if command will change expected I/O result
    # Return true if stop/restart needed, false if can continue
}
```

#### I/O Expectation Management by Command Type

**No expectation change (continue running):**
- RESERVE, RELEASE, CLEAR, PREEMPT: Always result in "pass"

**Always result in "pass" (stop if currently expecting "fail"):**
- REGISTER, REGISTER_NEW, REGISTER_AND_IGNORE, REGISTER_AND_IGNORE_NEW

**Conditional expectation changes:**
- REGISTER_UNREGISTER, REGISTER_AND_IGNORE_UNREGISTER:
  - Result: "fail" if device2 holds reservation, "pass" otherwise
- PREEMPT_BY_DEVICE2:
  - Result: "fail" if any device holds reservation, "pass" if no reservation

#### Test Flow Integration
1. **Initialization:** Start `io_test.sh` expecting "pass" after clearing registrations
2. **Before each command:** Check if expectation will change
3. **If changing:** Stop I/O test, execute command, restart with new expectation
4. **If not changing:** Execute command while I/O test continues
5. **After each command:** Wait IO_TEST_DURATION, verify I/O test still running
6. **Cleanup:** Stop I/O test before clearing registrations

## Background Process Integration

### I/O Testing Process
**Process:** `io_test.sh` runs continuously in background
**Purpose:** Continuously validates I/O operations against expected behavior
**Features:**
- Runs `dd if=/dev/zero of=<device> bs=4k count=1 oflag=direct` with 0.1s intervals
- Accepts expected result ("pass" or "fail") as parameter
- Exits with failure if actual result doesn't match expected
- Handles TERM signal gracefully (exits with success code 0)
- Provides visual feedback: "." for successful I/O, "x" for failed I/O

### Multipath Path Testing
**Process:** `multipath-test.sh` runs continuously in background
**Purpose:** Simulates real-world path failures and recoveries
**Requirements:**
- At least one path must remain active at all times
- Path state changes occur every 2 seconds (configurable)
- All paths are restored on cleanup

### Process Management
```bash
# Start background I/O test
./io_test.sh "/dev/mapper/$DEVICE1" "pass" &
IO_TEST_PID=$!

# Start background multipath test
./multipath-test.sh "$DEVICE1" &
MULTIPATH_TEST_PID=$!

# Cleanup on exit
kill -TERM "$IO_TEST_PID" 2>/dev/null || true
wait "$IO_TEST_PID" 2>/dev/null || true
kill "$MULTIPATH_TEST_PID" 2>/dev/null || true
wait "$MULTIPATH_TEST_PID" 2>/dev/null || true
```

**Background Process Cleanup:**
- The `io_test.sh` script handles TERM signals gracefully and exits with code 0
- The `multipath-test.sh` script uses `trap cleanup EXIT` (without INT/TERM) to ensure proper cleanup when terminated by the main test script

## Error Handling and Cleanup

### Cleanup Strategy
**Triggered by:** Script exit, interrupt signals (INT, TERM)
**Actions:**
1. Print exit state diagnostics (registered keys, reservations, multipath device state)
2. Stop background I/O test process (TERM signal, validate exit code)
3. Kill background multipath test process
4. Unregister both devices using REGISTER_AND_IGNORE (works regardless of current state)
5. Reset all state variables

### Error Recovery
- All mpathpersist commands include error checking
- sg_persist Unit Attention conditions are automatically retried
- State verification after each command ensures consistency and fails fast
- Robust parsing handles unexpected output formats
- Startup verification ensures clean initial state

### Cleanup Implementation
```bash
cleanup() {
    # Print diagnostic information before cleanup
    log_info "Exit state."
    log_info "Registered keys:"
    mpathpersist -ik /dev/mapper/"$DEVICE1"
    log_info "Reservation:"
    mpathpersist -ir /dev/mapper/"$DEVICE1"
    log_info "multipath state:"
    multipath -l "$DEVICE1"
    log_info "Cleaning up..."

    # Stop background I/O test and validate exit code
    # Kill background multipath test
    # ...

    # Clear all registrations
    clear_all_registrations
}

clear_all_registrations() {
    # Use REGISTER_AND_IGNORE with param-sark=0x0 to unregister both devices
    # This approach works regardless of current key values or registration state
    mpathpersist --out --register-ignore --param-sark=0x0 /dev/mapper/"$DEVICE1" || true
    sg_persist_with_retry --out --register-ignore --param-sark=0x0 /dev/"$DEVICE2" || true

    # Reset state tracking variables
    DEVICE1_KEY="0x0"
    DEVICE1_NEXT_KEY="0x2"
    RESERVATION_HOLDER=""
    PREEMPTED_KEY=""

    # With verification for startup (ensures clean state)
    if [[ "$verify_clear" == "true" ]]; then
        # Verify no registrations remain
        output=$(mpathpersist -ik /dev/mapper/"$DEVICE1")
        if ! echo "$output" | grep -q "0 registered reservation key"; then
            exit 1  # Fail if cleanup verification fails
        fi
    fi
}
```

## Test Execution Flow

### Initialization Phase
1. Validate command line arguments (2 required parameters, proper error handling with usage message)
2. Assign command line arguments to variables after validation
3. Check root privileges (required for direct I/O and device access)
4. Verify required commands exist (`mpathpersist`, `multipath`, `multipathd`, `sg_persist`, `udevadm`)
5. Verify `multipath-test.sh` exists and is executable
6. Compare device WWIDs to ensure same underlying storage
7. Clear any existing registrations using REGISTER_AND_IGNORE and verify cleanup succeeded
8. Start background multipath test process

### Main Test Loop
```
Loop forever:
    1. Determine valid commands based on current tracked state
    2. Randomly select and execute one valid command
    3. Verify actual device state matches tracked state (fail fast if mismatch)
    4. Determine expected I/O behavior based on verified state
    5. Perform 5-second I/O test and validate results (early exit optimization)
    6. Log iteration completion and continue
```

### Termination
- Manual interruption (Ctrl+C) triggers cleanup
- Script runs indefinitely until manually stopped
- All cleanup actions are performed automatically

## Design Rationale

### Why Bash Over C?
1. **Command Orchestration:** All operations use command-line tools
2. **String Processing:** Easier parsing of mpathpersist output
3. **Local Device Access:** Direct device operations without network dependencies
4. **Maintenance:** More readable and modifiable test logic
5. **Development Speed:** Faster implementation and debugging

### Key Design Decisions

#### Simple Key Management
- **Fixed Device2 Key:** Eliminates coordination complexity
- **Incremental Device1 Keys:** Prevents conflicts, enables unlimited testing
- **No Random Generation:** Deterministic behavior aids debugging

#### Type 5 Only Testing
- **Focused Scope:** Thorough testing of one reservation type
- **Realistic Scenario:** Write Exclusive is common in production
- **Simplified Logic:** Clearer success/failure conditions

#### State-Driven Testing
- **Comprehensive Coverage:** All valid command combinations tested
- **Context Awareness:** Commands selected based on current state
- **Validation:** State verified after each operation

#### Continuous I/O Testing
- **Real-World Simulation:** Tests actual data path functionality
- **Timing Validation:** 5-second duration ensures stable results
- **Direct I/O:** Bypasses filesystem caches for accurate testing

## Dependencies and Requirements

### System Requirements
- Linux system with device-mapper multipath
- Root privileges for direct device I/O
- Multipath device and SCSI device pointing to same underlying storage
- sg_utils package for sg_persist utility

### Software Dependencies
- `mpathpersist` - SCSI persistent reservation utility for multipath devices
- `sg_persist` - SCSI persistent reservation utility for SCSI devices (from sg_utils)
- `multipath` - Device-mapper multipath utility
- `multipathd` - Multipath daemon
- `udevadm` - Device information utility
- `dd` - Data transfer utility for I/O testing

### Hardware Requirements
- Shared storage accessible as both multipath and SCSI device
- Storage must support SCSI Persistent Reservations
- Both devices must have matching WWIDs

## Security Considerations

### Privilege Requirements
- Root access required for direct device I/O operations
- Both devices must be accessible with appropriate permissions
- Test should only run in isolated test environments

### Data Safety
- Uses random test data (no sensitive information)
- Direct device writes could potentially corrupt data
- Should only be run on dedicated test storage
- Automatic cleanup prevents persistent reservations

## Extensibility

### Adding New Commands
1. Add command to `get_valid_commands()` function
2. Implement execution function following existing patterns
3. Update state tracking as needed
4. Add appropriate error handling

### Configuration Options
- I/O test duration (`IO_TEST_DURATION`)
- Key increment strategy (currently simple increment)
- Background test script selection
- sg_persist retry logic for Unit Attention handling

### Monitoring and Logging
- Colored output for different message types
- Detailed state logging after each operation
- Integration points for external monitoring tools
- Structured output format for automated analysis

This design provides a robust, maintainable test framework that thoroughly validates multipath persistent reservation functionality under realistic operational conditions.