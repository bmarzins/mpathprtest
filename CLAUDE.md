# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This repository contains a comprehensive test suite for SCSI Persistent Reservations (PR) on device-mapper multipath devices. The test validates `mpathpersist` functionality in real-world scenarios with multi-host environments and path failures.

## Core Components

### Main Test Program: `mpath_pr_test.sh`
- **Purpose**: Tests all PR command types (REGISTER, RESERVE, RELEASE, PREEMPT, CLEAR) with type 5 reservations
- **Usage**: `./mpath_pr_test.sh <device1> <host> <device2>`
- **Requirements**: Root privileges, passwordless SSH to remote host, shared storage between devices
- **Execution**: Runs indefinitely until manually stopped (Ctrl+C)

### Background Path Tester: `multipath-test.sh`
- **Purpose**: Simulates real-world path failures by continuously cycling paths offline/online
- **Usage**: `./multipath-test.sh <multipath_device>`
- **Integration**: Started automatically by main test as background process
- **Behavior**: Ensures at least one path always remains active

## Architecture

### State Management
The test maintains simple state tracking variables:
- `DEVICE1_KEY`: Current registration key for local device (0x0 = unregistered)
- `DEVICE2_KEY`: Fixed key (0x1) for remote device
- `DEVICE1_NEXT_KEY`: Next key to assign (increments: 0x2, 0x3, 0x4...)
- `RESERVATION_HOLDER`: Current holder ("device1", "device2", or "")

### Key Design Patterns
- **Command Validation**: Commands selected based on current state (e.g., RESERVE only valid when no reservation exists or device1 holds it)
- **State Verification**: After each command, actual device state verified against tracked state (fail-fast on mismatch)
- **I/O Testing**: 5-second direct I/O test after each PR command with early exit optimization
- **Cleanup Strategy**: Uses REGISTER_AND_IGNORE with param-sark=0x0 to unregister both devices

### Multi-Host Testing
- Device2 operations executed via SSH
- PREEMPT tests use both directions (device1 preempts device2, device2 preempts device1)
- Uses `--register-ignore` for device2 registration to handle unknown initial state

## Running the Test

### Prerequisites
```bash
# Ensure required tools are available
which mpathpersist multipath multipathd ssh

# Set up passwordless SSH to remote host
ssh-copy-id <host>

# Verify shared storage setup
multipathd show maps raw format "%n %w" | grep <device1>
ssh <host> "multipathd show maps raw format \"%n %w\" | grep <device2>"
```

### Basic Execution
```bash
# Run as root (required for direct I/O)
sudo ./mpath_pr_test.sh mpatha remote-host mpathb
```

### Stopping the Test
- Use Ctrl+C to trigger cleanup
- All registrations and reservations automatically cleared
- Background processes terminated

## Development Notes

### Testing Changes
- Modify `IO_TEST_DURATION` variable to adjust I/O test length
- Update `CYCLE_DELAY` in multipath-test.sh to change path failure frequency
- State verification function `verify_state()` provides detailed error messages on failures

### Command Logic
- All PR operations use `--prout-type=5` (Write Exclusive - Registrants Only)
- REGISTER commands always specify `--param-rk` (works for 0x0 initial state)
- REGISTER_AND_IGNORE commands omit `--param-rk` (proper ignore semantics)
- Conditional reservation holder updates prevent false state tracking

### Key Files to Understand
- `DETAILED_DESIGN.md`: Comprehensive implementation documentation
- `design_doc.txt`: Original requirements specification
- State tracking happens in functions: `verify_state()`, `check_device1_registered()`, `check_device2_registered()`
- Command execution in functions: `execute_register()`, `execute_preempt()`, etc.