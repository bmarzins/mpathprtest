# mpath_pr_test Detailed Design Document

## Overview

The `mpath_pr_test` program is a comprehensive test suite for validating SCSI Persistent Reservations (PR) functionality on device-mapper multipath devices using the `mpathpersist` utility. The test simulates real-world scenarios including multi-host environments and path failures while systematically testing all supported PR commands.

## Architecture

### Program Type
- **Implementation**: Bash shell script
- **Rationale**: All operations are command-line tools (`mpathpersist`, `ssh`, `dd`). Bash provides natural orchestration of external commands with simpler string parsing and process management compared to C.

### Command Line Interface
```bash
mpath_pr_test.sh <device1> <host> <device2>
```

**Parameters:**
- `device1`: Local multipath device name (e.g., "mpatha")
- `host`: Remote host with passwordless SSH access configured
- `device2`: Remote multipath device pointing to the same underlying storage as device1

## State Management

### Core State Variables
```bash
DEVICE1_KEY="0x0"        # Current registration key for device1 (0x0 = not registered)
DEVICE2_KEY="0x1"        # Fixed registration key for device2 when registered
DEVICE1_NEXT_KEY="0x2"   # Next key to assign to device1 (increments: 0x2, 0x3, 0x4...)
RESERVATION_HOLDER=""    # Current reservation holder: "device1", "device2", or "" (none)
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
- Uses `mpathpersist -ik` to read registered keys
- **Critical Logic**: First checks for "0 registered reservation key" pattern
- **Avoids False Positives**: Generation numbers in output could match expected keys
- **Multi-path Handling**: Same key appears multiple times (once per path) - only need one match
- **Pure Functions**: Only return status, do not modify state variables

#### State Verification
```bash
verify_state()
```

**Implementation Details:**
- Verifies actual device state matches tracked state variables
- **Device1 Registration**: Only checks if `DEVICE1_KEY != "0x0"` (trusts that 0x0 never appears in key lists)
- **Reservation Status**: Always validates reservation holder matches `RESERVATION_HOLDER`
- **Fail Fast**: Exits with error if verification fails, indicating command or state tracking bugs

## Device Verification

### WWID Comparison
Ensures both devices point to the same underlying storage using World Wide Identifiers:

**Local Device:**
```bash
multipathd show maps raw format "%n %w" | grep "$DEVICE1" | awk '{print $2}'
```

**Remote Device:**
```bash
ssh "$HOST" "multipathd show maps raw format \"%n %w\" | grep $DEVICE2 | awk '{print \$2}'"
```

**Critical Implementation Notes:**
- Proper quote escaping for SSH commands
- `\$2` prevents local shell expansion of `$2`
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

# Device2 preempts device1 (via SSH)
ssh "$HOST" "mpathpersist --out --preempt --param-rk=$DEVICE2_KEY --param-sark=$DEVICE1_KEY --prout-type=5 /dev/mapper/$DEVICE2"
```

### Multi-Host Testing

#### PREEMPT Test Scenarios

**Device1 Preempts Device2:**
1. Register device2 via SSH with key `0x1` (using `--register-ignore` for reliability)
2. Randomly decide whether device2 grabs reservation (only if no reservation exists)
3. Device1 executes preempt command
4. Device2 becomes unregistered, device1 holds reservation

**Device2 Preempts Device1:**
1. Register device2 via SSH with key `0x1` (using `--register-ignore` for reliability)
2. Device2 executes preempt command via SSH
3. Device1 becomes unregistered, device2 holds reservation

#### SSH Command Considerations
- All remote commands properly escape quotes and variables
- Remote command execution uses double quotes to allow variable expansion
- Special handling for `awk` field separators (`\$2` instead of `$2`)

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

### I/O Test Implementation
```bash
perform_io_test() {
    local should_succeed=$1  # "should_" or "should_not_"

    # Create random test data
    dd if=/dev/urandom of="$temp_data" bs=4096 count=1

    # Perform I/O for specified duration with early exit optimization
    while [[ $(date +%s) -lt $end_time ]]; do
        if dd if="$temp_data" of="/dev/mapper/$DEVICE1" bs=4096 count=1 oflag=direct; then
            any_io_succeeded=true
            # Exit immediately if I/O should NOT succeed
            if [[ "$should_succeed" == "should_not_" ]]; then break; fi
        else
            any_io_failed=true
            # Exit immediately if I/O should succeed
            if [[ "$should_succeed" == "should_" ]]; then break; fi
        fi
    done

    # Validate result matches expectation
    # - When should succeed: fail if ANY I/O failed
    # - When should not succeed: fail if ANY I/O succeeded
}
```

## Background Process Integration

### Multipath Path Testing
**Process:** `multipath-test.sh` runs continuously in background
**Purpose:** Simulates real-world path failures and recoveries
**Requirements:**
- At least one path must remain active at all times
- Path state changes occur every 2 seconds (configurable)
- All paths are restored on cleanup

### Process Management
```bash
# Start background test
./multipath-test.sh "$DEVICE1" &
MULTIPATH_TEST_PID=$!

# Cleanup on exit
kill "$MULTIPATH_TEST_PID" 2>/dev/null || true
wait "$MULTIPATH_TEST_PID" 2>/dev/null || true
```

## Error Handling and Cleanup

### Cleanup Strategy
**Triggered by:** Script exit, interrupt signals (INT, TERM)
**Actions:**
1. Kill background multipath test process
2. Clear all registrations from storage (optimized - only one clear needed)
3. Reset all state variables

### Error Recovery
- All mpathpersist commands include error checking
- SSH failures are handled gracefully
- State verification after each command ensures consistency and fails fast
- Robust parsing handles unexpected output formats
- Startup verification ensures clean initial state

### Cleanup Implementation
```bash
clear_all_registrations() {
    # Try device1 first, fallback to device2 if needed
    # Since --clear removes ALL registrations, only one command needed
    if check_device1_registered; then
        mpathpersist --out --clear --param-rk="$DEVICE1_KEY" /dev/mapper/"$DEVICE1" || true
    elif check_device2_registered; then
        ssh "$HOST" "mpathpersist --out --clear --param-rk=$DEVICE2_KEY /dev/mapper/$DEVICE2" || true
    fi

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
1. Validate command line arguments (3 required parameters)
2. Check root privileges (required for direct I/O and device access)
3. Verify required commands exist (`mpathpersist`, `multipath`, `multipathd`, `ssh`)
4. Verify `multipath-test.sh` exists and is executable
5. Compare device WWIDs to ensure same underlying storage
6. Clear any existing registrations and verify cleanup succeeded
7. Start background multipath test process

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
3. **SSH Integration:** Natural process execution and error handling
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
- SSH access configured between test hosts
- Multipath devices pointing to shared storage

### Software Dependencies
- `mpathpersist` - SCSI persistent reservation utility
- `multipath` - Device-mapper multipath utility
- `multipathd` - Multipath daemon
- `ssh` - Secure shell for remote operations
- `dd` - Data transfer utility for I/O testing

### Network Requirements
- Passwordless SSH authentication between hosts
- Network connectivity during entire test duration
- Stable connection for reliable remote command execution

## Security Considerations

### Privilege Requirements
- Root access required for direct device I/O operations
- SSH keys should be properly secured
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
- SSH timeout and retry logic

### Monitoring and Logging
- Colored output for different message types
- Detailed state logging after each operation
- Integration points for external monitoring tools
- Structured output format for automated analysis

This design provides a robust, maintainable test framework that thoroughly validates multipath persistent reservation functionality under realistic operational conditions.