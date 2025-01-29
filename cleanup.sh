#!/bin/bash
# Set strict bash error handling:
# -e: Exit immediately if a command exits with non-zero status
# -u: Exit when using undefined variables
# -o pipefail: Return value of a pipeline is the value of the last (rightmost) command to exit with non-zero status
set -euo pipefail

# Color output functions
print_command() {
    echo "$(tput setaf 6)>>> $1$(tput sgr0)"
    eval "$1"
}

print_message() {
    echo "$(tput setaf 2)$1$(tput sgr0)"
}
# Find the CDT project directory
# Searches in home directory for a directory containing 'cdt'
print_command "PROJECTDIR=\$(find ~/ -maxdepth 1 | grep cdt | head -n1)"
if [ -z "$PROJECTDIR" ]; then
    print_message "Error: No CDT project directory found"
    exit 1
fi
# Extract just the project directory name
print_command "PROJECT=\$(basename \"\$PROJECTDIR\")"
USER=${USER:-$(whoami)}
DEPLOY_NAME="${USER}-deploy"
NETWORK_NAME="${USER}-windows-net"     # Private network for VMs
DC_NAME="${USER}-dc01"                 # Domain Controller VM name
MEMBER_NAME="${USER}-member01"         # Member Server VM name

# Switch to the specified Incus remote and project
# This ensures we're working in the correct environment
print_command "incus remote switch gcicompute02"
print_command "incus project switch ${PROJECT}"

# Clean up any existing resources from previous runs
print_message "Cleaning up existing resources..."
print_command "incus stop --force ${DC_NAME} 2>/dev/null || true"
print_command "incus stop --force ${MEMBER_NAME} 2>/dev/null || true"
print_command "incus delete ${DC_NAME} 2>/dev/null || true"
print_command "incus delete ${MEMBER_NAME} 2>/dev/null || true"
print_command "incus stop --force ${DEPLOY_NAME} 2>/dev/null || true"
print_command "incus delete ${DEPLOY_NAME} 2>/dev/null || true"
print_command "incus network delete ${NETWORK_NAME} 2>/dev/null || true"
