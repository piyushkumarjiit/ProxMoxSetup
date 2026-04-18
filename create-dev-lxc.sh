# -------------------------------------------------------------------------
# FILE: create-dev-lxc.sh
# ROLE: GPU-Enabled LXC Provisioner
#
# DESCRIPTION:
# Creates a privileged Ubuntu 24.04 LXC and injects complex hardware 
# passthrough configurations. Maps NVIDIA device nodes and library 
# paths directly from the host into the container to enable CUDA.
#
# HARDWARE COMPATIBILITY:
# - Targets Ubuntu-24.04-standard template.
# - Requires NVIDIA 1080 Ti drivers already active on the host.
# -------------------------------------------------------------------------

#!/bin/bash
# setup-host.sh - Run on Proxmox Host
# Usage: ./setup-host.sh [CT_ID] [HOSTNAME]

CT_ID=${1:-105}
NAME=${2:-ai-dev}
STORAGE="nvme-fast"
LATEST_TEMPLATE="ubuntu-24.04-standard_24.04-2_amd64.tar.zst"

echo "--- Step 1: Cleaning & Creating LXC ---"
pct destroy $CT_ID --purge 2>/dev/null
pct create $CT_ID "local:vztmpl/$LATEST_TEMPLATE" \
  --arch amd64 --ostype ubuntu --hostname "$NAME" \
  --password "Proxmox123!" --net0 name=eth0,bridge=vmbr0,ip=dhcp \
  --storage "$STORAGE" --rootfs 32 --memory 4096 --cores 4 \
  --features nesting=1 --unprivileged 0

echo "--- Step 2: Injecting GPU Passthrough Config ---"
# Resolve the physical driver version on the host
NV_VER="580.126.09"
REAL_ML=$(readlink -f /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1)
REAL_CUDA=$(readlink -f /usr/lib/x86_64-linux-gnu/libcuda.so.1)

cat <<EOF >> /etc/pve/lxc/${CT_ID}.conf
# Device Nodes
lxc.cgroup2.devices.allow: c 195:* rwm
lxc.cgroup2.devices.allow: c 511:* rwm
lxc.cgroup2.devices.allow: a
lxc.mount.entry: /dev/nvidia0 dev/nvidia0 none bind,optional,create=file
lxc.mount.entry: /dev/nvidiactl dev/nvidiactl none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-uvm dev/nvidia-uvm none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-uvm-tools dev/nvidia-uvm-tools none bind,optional,create=file

# Binary & Library Bind Mounts
lxc.mount.entry: /usr/bin/nvidia-smi usr/bin/nvidia-smi none bind,optional,create=file
lxc.mount.entry: $REAL_ML usr/lib/x86_64-linux-gnu/libnvidia-ml.so.$NV_VER none bind,optional,create=file
lxc.mount.entry: $REAL_CUDA usr/lib/x86_64-linux-gnu/libcuda.so.$NV_VER none bind,optional,create=file

# Map physical files to standard symlink locations inside LXC
lxc.mount.entry: $REAL_ML usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1 none bind,optional,create=file
lxc.mount.entry: $REAL_CUDA usr/lib/x86_64-linux-gnu/libcuda.so.1 none bind,optional,create=file

# Logical Bridge (Environment)
lxc.environment: LD_LIBRARY_PATH=/usr/lib/x86_64-linux-gnu

# Security & Docker-in-LXC Fixes
lxc.apparmor.profile: unconfined
lxc.cap.drop:
lxc.mount.auto: proc:rw sys:rw
lxc.mount.entry: /dev/null sys/module/apparmor/parameters/enabled none bind,optional,create=file

EOF

pct start $CT_ID
echo "Waiting for boot..." && sleep 10

echo "--- Step 3: Pushing Internal Script ---"
pct push $CT_ID docker-dev-tools.sh /usr/local/bin/container-setup.sh
pct exec $CT_ID -- chmod +x /usr/local/bin/container-setup.sh

echo "--- Step 4: Executing AI Stack Installation ---"
pct exec $CT_ID -- /usr/local/bin/container-setup.sh
