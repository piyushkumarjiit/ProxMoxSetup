# -------------------------------------------------------------------------
# FILE: disk_expand.sh
# ROLE: Dynamic Storage FileSystem Resizer
#
# DESCRIPTION:
# Automatically identifies the root (/) partition and its parent physical 
# disk to expand storage without hardcoded device paths.
#
# FEATURES:
# - Supports both LVM (ubuntu-vg) and Standard Partition layouts.
# - Automates growpart, pvresize, and resize2fs in a single sequence.
# - Safe-check: Exits if partition is already at maximum size.
# -------------------------------------------------------------------------
#!/bin/bash
set -e # Exit on any error

# Ensure cloud-guest-utils (provides growpart) is installed
sudo apt update && sudo apt install -y cloud-guest-utils

echo "🔍 Identifying root partition and parent disk..."

# 1. Find the mount point for root (/), get its source device path
ROOT_DEV=$(lsblk -no PKNAME,MOUNTPOINT | grep -w "/" | awk '{print $1}')

# 2. Get the full path of the physical device and partition number
# This handles cases where ROOT_DEV might be a logical volume (dm-0)
PART_PATH=$(findmnt -nvo SOURCE /)
PARENT_DISK="/dev/$ROOT_DEV"
PART_NUM=$(echo "$PART_PATH" | grep -o '[0-9]*$')

echo "✅ Target Disk: $PARENT_DISK"
echo "✅ Target Partition: $PART_NUM"

# 3. Grow the partition
echo "📏 Expanding partition $PART_NUM on $PARENT_DISK..."
sudo growpart "$PARENT_DISK" "$PART_NUM" || echo "Partition already at max size"

# 4. Check for LVM vs Physical Ext4
if sudo pvs "$PART_PATH" > /dev/null 2>&1; then
    echo "📦 LVM detected. Resizing Physical Volume..."
    sudo pvresize "$PART_PATH"
    
    # Identify the Logical Volume path dynamically
    LV_PATH=$(lvs --noheadings -o lv_path | grep "ubuntu-lv" | tr -d ' ' || lvs --noheadings -o lv_path | head -n 1 | tr -d ' ')
    
    echo "📈 Extending Logical Volume: $LV_PATH"
    sudo lvextend -l +100%FREE "$LV_PATH"
    
    echo "💾 Resizing File System..."
    sudo resize2fs "$LV_PATH"
else
    echo "📂 Standard partition detected. Resizing File System..."
    sudo resize2fs "$PART_PATH"
fi

echo "🚀 Disk expansion complete!"
df -h /