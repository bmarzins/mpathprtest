#!/bin/bash

# Multipath Path Failure/Recovery Test Script
# Usage: ./multipath_test.sh <multipath_device_name>

set -euo pipefail

# Configuration
CYCLE_DELAY=2          # seconds to wait between path cycles

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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

# Function to validate multipath device
validate_multipath_device() {
    local device=$1
    
    # Check if multipath is managing this device
    if ! dmsetup table "$device" | grep -q "multipath"; then
        log_error "$device is not a multipath device"
        exit 1
    fi
}

# Function to get all paths for a multipath device
get_multipath_paths() {
    local device=$1
    local paths=()
    local path
    
    for path in `multipathd show paths raw format "%m %d" | grep ${device} | awk '{print $2}'`; do
        paths+=($path)
    done
    
    echo "${paths[@]}"
}

# Function to wait for multipathd to notice path state change
wait_for_multipathd() {
    local device=$1
    local path=$2
    local expected_state=$3
    local timeout=30
    local count=0
    local sleeptime
    
    log_info "Waiting for multipathd to notice $path is $expected_state..."
    
    until multipathd show paths raw format "%d %t" | grep -q "${path} ${expected_state}" ; do
        count=$((count+1))
	if [[ $count -ge $timeout ]]; then
            log_warning "Timeout waiting for multipathd to detect $path state change"
            return 1
        fi
	sleeptime=$(multipathd show paths raw format "%d %C" | sed -n "s|${path}.* \([[:digit:]]\+\)/.*|\1|p")
        log_info "waiting ${sleeptime}s for ${path} to be in ${expected_state}"
	sleep ${sleeptime}
    done
    log_success "multipathd detected $path as $expected_state"
}

# Function to set path state
set_path_state() {
    local path=$1
    local state=$2
    local state_file="/sys/block/$path/device/state"
    
    if [[ ! -f "$state_file" ]]; then
        log_error "State file $state_file does not exist"
        return 1
    fi
    
    log_info "Setting $path to $state..."
    echo "$state" > "$state_file"
    
    # Verify the state was set
    local current_state
    current_state=$(cat "$state_file" 2>/dev/null || echo "unknown")
    if [[ "$current_state" == "$state" ]]; then
        log_success "Successfully set $path to $state"
        return 0
    else
        log_error "Failed to set $path to $state (current: $current_state)"
        return 1
    fi
}

# Function to display multipath status
show_multipath_status() {
    local device=$1
    echo
    log_info "Current multipath status for $device:"
    multipath -l "$device"
    echo
}

# Function to test a single path
test_path() {
    local device=$1
    local path=$2
    
    echo
    log_info "Testing path: $path"
    # log_info "============================================"
    
    # Show initial status
    # show_multipath_status "$device"
    
    # Disable path
    if set_path_state "$path" "offline"; then
        wait_for_multipathd "$device" "$path" "failed"
        
        # Show status after disabling
        # show_multipath_status "$device"
        
        # Re-enable path
        if set_path_state "$path" "running"; then
            wait_for_multipathd "$device" "$path" "active"
            
            # Show status after re-enabling
            # show_multipath_status "$device"
        else
            log_error "Failed to re-enable $path"
        fi
    else
        log_error "Failed to disable $path"
    fi
}

# Function to handle cleanup on exit
cleanup() {
    log_info "Cleaning up..."
    
    # Try to re-enable all paths that might be offline
    if [[ -n "${MULTIPATH_DEVICE:-}" ]]; then
        local paths
        paths=($(get_multipath_paths "$MULTIPATH_DEVICE"))
        
        for path in "${paths[@]}"; do
            set_path_state "$path" "running" || true
        done
    fi
    
    log_info "Cleanup complete"
}

# Main function
main() {
    local device=$1
    
    log_info "Starting multipath path failure test for device: $device"
    
    # Store device name for cleanup
    MULTIPATH_DEVICE="$device"
    
    # Set up cleanup trap
    trap cleanup EXIT INT TERM
    
    # Validate device
    validate_multipath_device "$device"
    
    # Get all paths
    local paths
    paths=($(get_multipath_paths "$device"))
    
    if [[ ${#paths[@]} -eq 0 ]]; then
        log_error "No paths found for device $device"
        exit 1
    fi
    
    log_info "Found ${#paths[@]} paths: ${paths[*]}"
    log_info "Enabling all paths..."    
    for path in "${paths[@]}"; do
        set_path_state "$path" "running"
    done
    log_info "All paths enabled"
    # Test each path in a loop
    local cycle=1
    while true; do
        echo
        log_info "Starting cycle $cycle"
        # log_info "========================================"
        
        for path in "${paths[@]}"; do
            test_path "$device" "$path"
    
            log_info "Waiting $CYCLE_DELAY seconds before next path..."
            sleep "$CYCLE_DELAY"
        done
        
        log_success "Completed cycle $cycle"
        ((cycle++))
    done
}

# Script entry point
if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <multipath_device_name>"
    echo "Example: $0 mpatha"
    exit 1
fi

# Check prerequisites
check_root

# Check if required commands are available
for cmd in multipath multipathd dmsetup; do
    if ! command -v "$cmd" &> /dev/null; then
        log_error "Required command '$cmd' not found"
        exit 1
    fi
done

# Run main function
main "$1"
