#!/bin/bash

# -------------------------------------------------------------------------
# FILE: proxmox_setup.sh
# ROLE: Universal Host Tier Initializer
#
# DESCRIPTION:
# Configures Kernel parameters and Storage. 
# Supports two modes:
# 1. Standard (Default): Preps host for NVIDIA Driver/LXC support.
# 2. VM Passthrough (--vm-passthrough): Blacklists drivers for VFIO use.
# -------------------------------------------------------------------------

# --- 0. CONFIGURATION & FLAGS ---
NVME_FAST_ID="/dev/disk/by-id/nvme-WDS100T3X0C-00SJG0_202975803895"
HDD_MIRROR_A="/dev/disk/by-id/ata-WDC_WD140EMFZ-11A0WA0_9RHHRNHL"
HDD_MIRROR_B="/dev/disk/by-id/ata-WDC_WD140EMFZ-11A0WA0_9RJ7U29C"
HDD_FAST_A="/dev/disk/by-id/ata-WDC_WD2002FAEX-007BA0_WD-WCAY01039641"
HDD_FAST_B="/dev/disk/by-id/wwn-0x50014ee2b57e6e11"

# To wipe data from any existing lvm/partion found (true/false)
WIPE_DATA=true
#To setup Proxmox server for VM pass through (true/false)
VM_PASSTHROUGH=true
# Set to true if you want to consolidate boot disk partion into 1 (true/false)
CONSOLIDATE_BOOT=true

for arg in "$@"; do 
    [ "$arg" == "--wipe" ] && WIPE_DATA=true
    [ "$arg" == "--vm-passthrough" ] && VM_PASSTHROUGH=true
	[ "$arg" == "--consolidate-boot" ] && CONSOLIDATE_BOOT=true
done

# --- SAFETY CHECK ---
OS_DEV=$(df / | tail -1 | awk '{print $1}' | sed 's/[0-9]*$//')
echo "Detected OS on: $OS_DEV. Safety Lock Engaged."

if ! touch /tmp/rebuild_test &>/dev/null; then
    echo "❌ FATAL: System partition is READ-ONLY. Reboot required."
    exit 1
fi
rm /tmp/rebuild_test

# --- 1. SYSTEM PREP & KERNEL PARAMETERS ---
if ! command -v parted &> /dev/null; then
    apt update && apt install parted -y
fi

if ! grep -q "intel_iommu=on" /etc/default/grub; then
    echo "--- Phase 1: Kernel Configuration ---"
    
    # Enable IOMMU for both use cases
    sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="quiet"/GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_iommu=on iommu=pt"/' /etc/default/grub
    update-grub

    if [ "$VM_PASSTHROUGH" = true ]; then
        echo "🛠 Setting up VM PASSTHROUGH (Goal B)..."
        cat <<EOF > /etc/modprobe.d/pve-blacklist.conf
blacklist nouveau
blacklist nvidiafb
blacklist nvidia
blacklist nvidia_uvm
blacklist nvidia_modeset
EOF
        # Load VFIO Modules (The 'Hand-off' drivers)
        for mod in vfio vfio_iommu_type1 vfio_pci vfio_virqfd; do
            grep -qxF "$mod" /etc/modules || echo "$mod" >> /etc/modules
        done
        
        # Bind the 1080 Ti IDs (Verified: 1b06 and 10ef)
		echo "options vfio-pci ids=10de:1b06,10de:10ef disable_vga=1" > /etc/modprobe.d/vfio.conf
    else
        echo "🚀 Setting up LXC/Host Driver Support (Goal A)..."
        cat <<EOF > /etc/modprobe.d/pve-blacklist.conf
blacklist nouveau
blacklist nvidiafb
EOF
    fi

    # community scripts post-install (comment if already executed)
    #bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/tools/pve/post-pve-install.sh)"
    update-initramfs -u -k all
	update-grub
    echo "🚨 System configured. Rebooting in 5 seconds..."
    sleep 5 && reboot
    exit 0
fi

# --- Phase 2: STORAGE INITIALIZATION ---
# [Note: The storage logic remains identical to the previous validated version]

# --- Consolidate Boot Disk ---
consolidate_boot_disk() {
    # 1. Check if the 'pve' Volume Group actually has a 'data' logical volume
    if lvs pve/data --noheadings >/dev/null 2>&1; then
        echo "🧹 Dynamically identifying boot disk structures..."
        
        # 2. Tell Proxmox to stop tracking the 'local-lvm' alias
        pvesm remove local-lvm 2>/dev/null
        
        # 3. Destroy the 'data' partition specifically within the 'pve' group
        # This is safe because 'pve' is hardcoded as the OS group by the installer
        lvremove -y pve/data 2>/dev/null
        
        # 4. Grow the 'root' volume to fill the physical space of the 'pve' group
        lvextend -l +100%FREE pve/root
        
        # 5. Expand the filesystem (this works regardless of device name)
        resize2fs /dev/mapper/pve-root
        
        # 6. Re-enable all content types for the single 'local' storage
        pvesm set local --content backup,iso,vztmpl,rootdir,images
        
        echo "✅ Boot disk consolidated successfully into a single volume."
    else
        echo "ℹ️ No 'local-lvm' (pve/data) found on the boot VG. Skipping."
    fi
}


safe_wipe() {
    local target=$1
    REAL_TARGET=$(readlink -f "$target")
    if [[ "$REAL_TARGET" == *"$OS_DEV"* ]]; then
        echo "❌ FATAL: Wipe attempted on OS DISK ($REAL_TARGET)! Aborting."
        exit 1
    fi

    echo "🧹 Targeted cleaning of $target..."
    VG_NAME=$(pvdisplay -C -o vg_name --noheadings "$REAL_TARGET" 2>/dev/null | xargs)
    if [ ! -z "$VG_NAME" ] && [ "$VG_NAME" != "pve" ]; then
        vgremove -y "$VG_NAME" --force --force 2>/dev/null
    fi

    zpool labelclear -f "$target" 2>/dev/null
    wipefs -af "$target"
    dd if=/dev/zero of="$REAL_TARGET" bs=1M count=100 conv=fdatasync 2>/dev/null
	sleep 2
    parted -s "$REAL_TARGET" mklabel gpt
    udevadm settle
}

if [ "$CONSOLIDATE_BOOT" = true ]; then
    consolidate_boot_disk
fi

if [ "$WIPE_DATA" = true ]; then
    echo "--- Phase 2: Initializing Storage Tiers ---"
    
    # NVMe
    safe_wipe "$NVME_FAST_ID"
    RAW_NVME=$(readlink -f "$NVME_FAST_ID")
    pvcreate -f "$RAW_NVME"
    vgcreate nvme-fast "$RAW_NVME"
    lvcreate -l 95%FREE -T nvme-fast/data
    if ! pvesm status | grep -q "nvme_fast"; then
        pvesm add lvmthin nvme_fast --vgname nvme-fast --thinpool data --content rootdir,images 2>/dev/null
    fi

    # ZFS Mirror
    safe_wipe "$HDD_MIRROR_A"
    safe_wipe "$HDD_MIRROR_B"
    zpool create -f Bulk14 mirror "$HDD_MIRROR_A" "$HDD_MIRROR_B"
    if ! pvesm status | grep -q "Bulk14"; then
        pvesm add zfspool Bulk14 --pool Bulk14 --content rootdir,images,iso,vztmpl,backup --sparse 1 2>/dev/null
    fi

    # ZFS Fast
    safe_wipe "$HDD_FAST_A"
    safe_wipe "$HDD_FAST_B"
    zpool create -f FastScratch "$HDD_FAST_A" "$HDD_FAST_B"
    if ! pvesm status | grep -q "FastScratch"; then
        pvesm add zfspool FastScratch --pool FastScratch --content rootdir,images --sparse 1 2>/dev/null
    fi
fi

# --- Phase 3: FIXED HEALTH CHECK ---
echo -e "\n--- Phase 3: Final Validation ---"
FAILS=0

# LVM Check
if lvs nvme-fast/data --noheadings -o lv_attr 2>/dev/null | grep -q '^  t'; then
    echo "✅ NVMe Thin Pool: PASSED"
else
    echo "❌ NVMe Thin Pool: FAILED"; ((FAILS++))
fi

# ZFS Checks
if zpool status Bulk14 2>/dev/null | grep -wi "ONLINE" > /dev/null; then
    echo "✅ ZFS Bulk14 Mirror: PASSED"
else
    echo "❌ ZFS Bulk14 Mirror: FAILED"; ((FAILS++))
fi

if zpool status FastScratch 2>/dev/null | grep -wi "ONLINE" > /dev/null; then
    echo "✅ ZFS FastScratch: PASSED"
else
    echo "❌ ZFS FastScratch: FAILED"; ((FAILS++))
fi

# PVE Status
if pvesm status | grep -q "nvme_fast.*active"; then echo "✅ PVE: nvme_fast active"; else echo "❌ PVE: nvme_fast inactive"; ((FAILS++)); fi
if pvesm status | grep -q "Bulk14.*active"; then echo "✅ PVE: Bulk14 active"; else echo "❌ PVE: Bulk14 inactive"; ((FAILS++)); fi
if pvesm status | grep -q "FastScratch.*active"; then echo "✅ PVE: FastScratch active"; else echo "❌ PVE: FastScratch inactive"; ((FAILS++)); fi

check_gpu_readiness() {
    echo -e "\n--- Phase 4: GPU Passthrough Readiness Check ---"
    local gpu_ready=true

    # 1. Find all NVIDIA PCI addresses
    local dev_ids=$(lspci -nn | grep -i "NVIDIA" | cut -d' ' -f1)

    if [ -z "$dev_ids" ]; then
        echo "❌ FATAL: No NVIDIA hardware detected on the PCI bus."
        ((FAILS++));
    fi

    for addr in $dev_ids; do
        echo -n "🔍 Checking Device $addr: "
        
        # Check for vfio-pci driver
        local driver=$(lspci -nnk -s "$addr" | grep "Kernel driver in use" | awk -F': ' '{print $2}')
        
        if [ "$driver" == "vfio-pci" ]; then
            echo "✅ Driver is vfio-pci"
        else
            echo "❌ Driver is $driver (Expected vfio-pci)"
            gpu_ready=false
			((FAILS++));
        fi
    done

    # 2. Check IOMMU status in Kernel
    if dmesg | grep -qE "IOMMU enabled|Intel-IOMMU: enabled"; then
        echo "✅ IOMMU: Hardware/Kernel support is ACTIVE"
    else
        echo "❌ IOMMU: Not detected. Check BIOS (VT-d) and GRUB settings."
        gpu_ready=false
		((FAILS++));
    fi

    # 3. Summary
    if [ "$gpu_ready" = true ]; then
        echo -e "\n🚀 GPU IS READY FOR PASS THROUGH."
        echo "You can now safely attach these PCI IDs to your VM."
    else
        echo -e "\n⚠️  GPU IS NOT READY. Review the errors above."
    fi
}

# --- Execute GPU Check ---
if [ "$VM_PASSTHROUGH" = true ]; then
    check_gpu_readiness
fi


if [ $FAILS -eq 0 ]; then
    echo -e "\n🚀 ALL SYSTEMS NOMINAL. Host is ready."
else
    echo -e "\n⚠️ WARNING: $FAILS storage checks failed."
fi