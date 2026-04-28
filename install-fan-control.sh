# -------------------------------------------------------------------------
# FILE: install-fan-control.sh
# ROLE: Fan Control Service Installer
#
# DESCRIPTION:
# Bootstraps the thermal management system by installing necessary 
# dependencies, deploying the monitoring logic, and registering a 
# cron job to ensure the script runs every minute.
#
# HARDWARE COMPATIBILITY:
# - Targets Proxmox Host environment.
# - Requires access to dynamic-fan-control.sh script.
# -------------------------------------------------------------------------

#!/bin/bash

# Define source and destination
SOURCE_SCRIPT="dynamic-fan-control.sh"
DEST_PATH="/root/dynamic-fan-control.sh"

echo "--- Step 1: Installing Dependencies ---"
# Installs tools required for IPMI, drive monitoring, and math logic
apt update && apt install -y ipmitool smartmontools nvme-cli bc

echo "--- Step 2: Deploying Fan Control Script ---"
if [ -f "$SOURCE_SCRIPT" ]; then
    # Copies the existing file instead of generating it via EOF
    cp "$SOURCE_SCRIPT" "$DEST_PATH"
    echo "Successfully copied $SOURCE_SCRIPT to $DEST_PATH"
else
    echo "ERROR: $SOURCE_SCRIPT not found in current directory."
    exit 1
fi

echo "--- Step 3: Setting Permissions ---"
# Ensures the script can be executed by the system
chmod +x "$DEST_PATH"

echo "--- Step 4: Adding to Crontab ---"
# Registers the job to run every minute if it isn't already present
(crontab -l 2>/dev/null | grep -Fq "$DEST_PATH") || \
(crontab -l 2>/dev/null; echo "* * * * * $DEST_PATH > /dev/null 2>&1") | crontab -

echo "SUCCESS: Fan control installed and scheduled."
