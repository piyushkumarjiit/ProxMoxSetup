#!/bin/bash
# -------------------------------------------------------------------------
# ROLE: Proxmox Host Lifecycle Manager (Zen Edition)
# DESCRIPTION: Automates full-system image backups and restores.
# -------------------------------------------------------------------------

# --- CONFIGURATION ---
BACKUP_NAME="proxmox_zen_consolidated.fsa"
CONFIG_ARCHIVE="config_only_zen.tar.gz"
VAULT_MOUNT="/mnt/usb_vault"
# You can set this to the label of your USB partition (e.g., "VAULT")
USB_LABEL="USB_2.0_FD" 
USB_SERIAL="AEB03H19YE07001544" # Your specific USB Serial

# --- DYNAMIC USB DETECTION ---
# Looks for the USB device based on the ID specified in USB_SERIAL
USB_DEV=$(lsblk -dno NAME,SERIAL | grep "AEB03H19YE07001544" | awk '{print "/dev/"$1}')

# Fallback: If serial isn't found, look for a partition on a drive < 20GB
if [ -z "$USB_DEV" ]; then
    USB_DEV=$(lsblk -bno NAME,SIZE,TYPE | grep "part" | awk '$2 < 20000000000 {print "/dev/"$1}' | head -n 1)
fi

# --- METHODS ---

do_backup() {
    # 1. Create unique filename with Date and Time
    local TIMESTAMP=$(date +"%Y-%m-%d_%H%M")
    local BACKUP_FILE="proxmox_zen_${TIMESTAMP}.fsa"
    
    echo "💾 Starting Backup Sequence: $BACKUP_FILE"
    
    if [ ! -b "$USB_DEV" ]; then echo "❌ FATAL: USB Vault ($USB_SERIAL) not detected."; exit 1; fi
    
    mkdir -p $VAULT_MOUNT
    mount $USB_DEV $VAULT_MOUNT 2>/dev/null
    
    # 2. Execution
    echo "📦 Creating System Image (EFI + Root)..."
    fsarchiver -A -j4 savefs "$VAULT_MOUNT/$BACKUP_FILE" /dev/sdc2 /dev/mapper/pve-root
    
    # 3. INTEGRITY CHECK (The "Valid Archive" Test)
    echo "🔍 Verifying Archive Integrity..."
    if fsarchiver archinfo "$VAULT_MOUNT/$BACKUP_FILE" > /dev/null 2>&1; then
        echo "✅ VALIDATION PASSED: Archive is readable and healthy."
    else
        echo "❌ VALIDATION FAILED: Archive is corrupt! Do not rely on this backup."
        umount $VAULT_MOUNT
        exit 1
    fi
    
    echo "📂 Archiving Configurations..."
    tar -cvzf "$VAULT_MOUNT/config_zen_${TIMESTAMP}.tar.gz" /etc/pve /etc/network/interfaces /etc/modules /etc/modprobe.d/ /etc/default/grub
    
    echo -e "\n🎉 SUCCESS: Backup verified and stored."
    ls -lh "$VAULT_MOUNT/$BACKUP_FILE"
    umount $VAULT_MOUNT
}

do_restore() {
	# User must provide the specific filename
    if [ -z "$2" ]; then
        echo "❌ Error: Please specify the filename to restore (e.g., --restore proxmox_zen_2026-04-09_1200.fsa)"
        exit 1
    fi
    echo "🚨 WARNING: YOU ARE ABOUT TO OVERWRITE THE SYSTEM DRIVE 🚨"
    echo "This should typically be run from a LIVE USB environment."
    read -p "Are you absolutely sure? (y/n): " confirm
    if [ "$confirm" != "y" ]; then exit 0; fi

    if [ -z "$USB_DEV" ]; then echo "❌ FATAL: USB Vault containing backup not found."; exit 1; fi

    mkdir -p $VAULT_MOUNT
    mount $USB_DEV $VAULT_MOUNT
    
    # Wake up LVM in case we are in a Live Environment
    vgchange -ay pve 2>/dev/null

    echo "⏪ Restoring System Image..."
    fsarchiver restfs $VAULT_MOUNT/$BACKUP_NAME id=0,dest=/dev/sdc2 id=1,dest=/dev/mapper/pve-root
    
    echo "✅ Restore Complete. Please reboot."
    umount $VAULT_MOUNT
}

# --- ARGUMENT PARSING ---
case "$1" in
    --backup) do_backup ;;
    --restore) do_restore "$@" ;;
    *) echo "Usage: $0 {--backup|--restore [filename]}" ; exit 1 ;;
esac