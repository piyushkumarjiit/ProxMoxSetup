# -------------------------------------------------------------------------
# FILE: setup-gpu-host.sh
# ROLE: Proxmox Host NVIDIA Driver Installer
#
# DESCRIPTION:
# Installs headless NVIDIA kernel drivers and DKMS on the Proxmox host.
# Handles Nouveau blacklisting and sets up UDEV rules to ensure device 
# nodes (/dev/nvidia*) persist across reboots for LXC passthrough.
#
# HARDWARE COMPATIBILITY:
# - Targets NVIDIA GeForce GTX 1080 Ti (Driver v580.126.09).
# - Requires pve-headers matching the current running kernel.
# -------------------------------------------------------------------------

#!/bin/bash
# setup-gpu-host.sh - Run on Proxmox Host

DRIVER_VER="580.126.09" # Update this to the latest stable for 1080Ti
URL="https://us.download.nvidia.com/XFree86/Linux-x86_64/${DRIVER_VER}/NVIDIA-Linux-x86_64-${DRIVER_VER}.run"

echo "Step 1: Installing dependencies..."
apt update && apt install -y pve-headers-$(uname -r) build-essential dkms

echo "Step 2: Blacklisting Nouveau..."
cat <<EOF > /etc/modprobe.d/blacklist-nouveau.conf
blacklist nouveau
options nouveau modeset=0
EOF

echo "Step 3: Downloading NVIDIA Driver ${DRIVER_VER}..."
wget -O nvidia-driver.run "$URL"
chmod +x nvidia-driver.run

echo "Step 4: Installing Driver (Headless + DKMS)..."
./nvidia-driver.run --dkms --silent

echo "Step 5: Setting up UDEV rules for LXC persistence..."
cat <<EOF > /etc/udev/rules.d/70-nvidia.rules
KERNEL=="nvidia", RUN+="/bin/bash -c '/usr/bin/nvidia-smi -L && /bin/chmod 666 /dev/nvidia*'"
KERNEL=="nvidia_uvm", RUN+="/bin/bash -c '/usr/bin/nvidia-modprobe -c0 -u && /bin/chmod 0666 /dev/nvidia-uvm*'"
EOF

update-initramfs -u
echo "DONE. Please REBOOT the host, then verify with 'nvidia-smi'."
