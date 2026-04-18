#!/bin/bash
# -------------------------------------------------------------------------
# ROLE: AI-Worker VM Provisioner (Final Optimized Version)
# DESCRIPTION: Creates a high-performance Ubuntu VM for video processing.
# -------------------------------------------------------------------------

# --- CONFIGURATION ---
VM_ID=100
VM_NAME="ubuntu-ai-worker"
STORAGE="nvme_fast"
ISO_STORAGE="local"
ISO_NAME="ubuntu-24.04-live-server-amd64.iso"

# GPU CONFIGURATION
# Address of the GTX 1080 Ti identified in your hardware scan
GPU_PCI_ID="42:00" 

echo "🚀 Starting High-Performance Provisioning for VM $VM_ID..."

# 1. Create the VM Shell (q35 machine + UEFI)
qm create $VM_ID --name $VM_NAME --machine q35 --bios ovmf \
    --ostype l26 --onboot 1 --agent 1

# 2. CPU & RAM (Dual Socket Affinity)
# We use 'host' to pass through AVX/AES-NI instructions for faster AI processing.
qm set $VM_ID --sockets 2 --cores 16 --cpu host --numa 1 --memory 98304 --balloon 0

# 3. NVMe Storage (io_uring + writeback)
# virtio-scsi-single + iothread ensures the disk doesn't bottleneck the CPU.
qm set $VM_ID --scsihw virtio-scsi-single \
    --scsi0 $STORAGE:100,cache=writeback,discard=on,iothread=1,aio=io_uring

# 4. Networking
qm set $VM_ID --net0 virtio,bridge=vmbr0

# 5. NVIDIA 1080 Ti Passthrough (No-Password Config)
# 'x-vga=1' treats this as the primary boot display for the VM.
qm set $VM_ID --hostpci0 ${GPU_PCI_ID},pcie=1,x-vga=1

# 6. EFI & ISO (Secure Boot Disabled)
# We omit pre-enrolled-keys to avoid the MOK password prompts during driver install.
qm set $VM_ID --efidisk0 $STORAGE:0
qm set $VM_ID --ide2 ${ISO_STORAGE}:iso/${ISO_NAME},media=cdrom

# 7. Boot Order
qm set $VM_ID --boot order=ide2;scsi0

echo "✅ VM $VM_ID is created and tuned for AI workloads."
echo "👉 Pro-Tip: Once Ubuntu is installed, run './setupOllamaOpenUI.sh |& tee -a  setupOllamaOpenUI.log' first."