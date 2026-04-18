#!/bin/bash

# -------------------------------------------------------------------------
# FILE: setup-zfs-storage.sh
# ROLE: High-Performance Storage & Mount Orchestrator
# Execution: To be executed on the PVE before the Olah setup script is executed on AI VM. Can be excuted after the Ollama script.
#
# DESCRIPTION:
# Automates the configuration of ZFS storage tiers for the AI-VM. 
# Handles the mounting of 9p pass-through devices from Proxmox, 
# initialization of the FastScratch SSD pool, and fstab persistence. 
# Ensures low-latency I/O for AI model caching and video processing.
#
# HARDWARE & INFRASTRUCTURE COMPATIBILITY:
# - Designed for Proxmox-based virtualization using 9p virtio transport.
# - Optimized for ZFS on Linux with specific mount point permissions.
# - Provides the underlying storage foundation for the Olah Mirror service.
# -------------------------------------------------------------------------

# Configuration
POOL_NAME="FastScratch"
DATASET_NAME="olah-cache"
FULL_PATH="$POOL_NAME/$DATASET_NAME"
VM_ID="104"
VM_CONF="/etc/pve/qemu-server/${VM_ID}.conf"
MOUNT_TAG="models"

echo "--- Initializing ZFS Storage for Olah ---"

# 1. Create Dataset if it doesn't exist
if ! zfs list "$FULL_PATH" > /dev/null 2>&1; then
    echo "Creating dataset $FULL_PATH..."
    zfs create "$FULL_PATH"
else
    echo "Dataset $FULL_PATH already exists. Skipping creation."
fi

# 2. Apply Optimizations
echo "Applying ZFS optimizations for large model files..."
zfs set compression=lz4 "$FULL_PATH"
zfs set recordsize=1M "$FULL_PATH"
zfs set atime=off "$FULL_PATH"

# 3. Add VirtFS args to VM config
# We use a specific tag so we can check if it's already there
VIRTFS_ARGS="args: -virtfs local,path=/$FULL_PATH,mount_tag=$MOUNT_TAG,security_model=none,id=$MOUNT_TAG"

if [ ! -f "$VM_CONF" ]; then
    echo "ERROR: VM config for ID $VM_ID not found at $VM_CONF."
    echo "Please check your VM ID in the Proxmox sidebar."
    exit 1
fi

if grep -q "mount_tag=$MOUNT_TAG" "$VM_CONF"; then
    echo "VirtFS args already exist in $VM_CONF. Skipping append."
else
    echo "Appending VirtFS args to $VM_CONF..."
    echo "$VIRTFS_ARGS" >> "$VM_CONF"
    echo "-----------------------------------------------------------"
    echo "SUCCESS: Hardware configuration updated."
    echo "ACTION REQUIRED: You must FULLY SHUTDOWN and START VM $VM_ID"
    echo "from the Proxmox UI for the new 'models' tag to appear."
    echo "-----------------------------------------------------------"
fi

zfs list "$FULL_PATH"