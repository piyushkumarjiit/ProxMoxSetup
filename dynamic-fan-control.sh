# -------------------------------------------------------------------------
# FILE: dynamic-fan-control.sh
# ROLE: Active Proxmox Thermal Monitor
#
# DESCRIPTION:
# Monitors temperatures across all hardware tiers and adjusts server 
# fan speeds via IPMI. Dynamically scales fan curves based on the 
# hottest component (CPU, GPU, NVMe, or HDD) to prevent thermal throttling.
#
# HARDWARE COMPATIBILITY:
# - Targets Dell PowerEdge iDRAC (IPMI over LAN).
# - Requires ipmitool, smartmontools, and nvme-cli.
# -------------------------------------------------------------------------

#!/bin/bash
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# (Your local IDRAC details go here. Default values populated)
IDRAC_IP="192.168.XX.XX"
IDRAC_USER="root" # default login, change to yours
IDRAC_PASS="calvin" # default passwd, change to yours

# Thermal Thresholds
CPU_MAX=75
GPU_MAX=80
HDD_MAX=50
NVME_MAX=60
EXHAUST_MAX=55

# --- 1. GET SYSTEM TEMPS (IPMI) ---
# Fetching directly from the iDRAC
CPU_T=$(ipmitool -I lanplus -H $IDRAC_IP -U $IDRAC_USER -P $IDRAC_PASS -C 3 sdr type temperature | grep "Inlet Temp" | cut -d"|" -f5 | sed 's/[^0-9]//g')
EXHAUST_T=$(ipmitool -I lanplus -H $IDRAC_IP -U $IDRAC_USER -P $IDRAC_PASS -C 3 sdr type temperature | grep "Exhaust Temp" | cut -d"|" -f5 | sed 's/[^0-9]//g')

# Basic safety check: ensure we got a reading
CPU_T=${CPU_T:-0}
EXHAUST_T=${EXHAUST_T:-0}

# --- 2. GET COMPONENT TEMPS (VIA GUEST AGENT) ---
MAX_GPU_T=0
MAX_NVME_T=0

# Detect VMs with PCIe passthrough
GPU_VMS=$(grep -l "hostpci" /etc/pve/qemu-server/*.conf | awk -F'/' '{print $NF}' | sed 's/.conf//')

for VMID in $GPU_VMS; do
    if [ "$(qm status $VMID | awk '{print $2}')" == "running" ]; then
        # Query all GPUs in the VM
        VM_GPUS=$(qm guest exec $VMID -- nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null | grep "out-data" | awk -F': ' '{print $2}' | sed 's/[^0-9]//g')
        for T in $VM_GPUS; do [ -n "$T" ] && [ "$T" -gt "$MAX_GPU_T" ] && MAX_GPU_T=$T; done

        # Query NVMe (assumes /dev/nvme0)
        VM_NVMES=$(qm guest exec $VMID -- nvme smart-log /dev/nvme0 2>/dev/null | grep "temperature" | awk '{print $3}' | sed 's/[^0-9]//g')
        for T in $VM_NVMES; do [ -n "$T" ] && [ "$T" -gt "$MAX_NVME_T" ] && MAX_NVME_T=$T; done
    fi
done

# --- 3. GET HDD TEMPS (LOCAL) ---
MAX_HDD_T=0
for drive in $(lsblk -dn -o NAME | grep -E 'sd|vd'); do
    T=$(smartctl -a /dev/$drive 2>/dev/null | grep -i "Temperature_Celsius" | awk '{print $10}' | sed 's/[^0-9]//g')
    if [ -n "$T" ] && [ "$T" -gt "$MAX_HDD_T" ]; then
        MAX_HDD_T=$T
    fi
done

# --- 4. CONSOLIDATE RESULTS ---
HDD_T=${MAX_HDD_T:-0}
NVME_T=${MAX_NVME_T:-0}

# GPU Fallback logic
if [ "$MAX_GPU_T" -gt 0 ]; then
    GPU_T=$MAX_GPU_T
else
    GPU_T=$(echo "$EXHAUST_T + 15" | bc)
fi

# --- 5. SAFETY GATE ---
# If critical sensors fail, return to auto mode and exit
if [ "$CPU_T" -eq 0 ] || [ "$EXHAUST_T" -eq 0 ]; then
    ipmitool -I lanplus -H $IDRAC_IP -U $IDRAC_USER -P $IDRAC_PASS -C 3 raw 0x30 0x30 0x01 0x01
    exit 1
fi

# --- 6. CALCULATE LOAD & SET SPEED ---
CPU_LOAD=$(echo "scale=2; $CPU_T / $CPU_MAX" | bc)
GPU_LOAD=$(echo "scale=2; $GPU_T / $GPU_MAX" | bc)
HDD_LOAD=$(echo "scale=2; $HDD_T / $HDD_MAX" | bc)
NVME_LOAD=$(echo "scale=2; $NVME_T / $NVME_MAX" | bc)
EXHAUST_LOAD=$(echo "scale=2; $EXHAUST_T / $EXHAUST_MAX" | bc)

MAX_LOAD=$(echo -e "$CPU_LOAD\n$GPU_LOAD\n$HDD_LOAD\n$NVME_LOAD\n$EXHAUST_LOAD" | sort -rn | head -1)

# Set manual control mode (0x00)
ipmitool -I lanplus -H $IDRAC_IP -U $IDRAC_USER -P $IDRAC_PASS -C 3 raw 0x30 0x30 0x01 0x00

if (( $(echo "$MAX_LOAD >= 1.0" | bc -l) )); then
    # Emergency: Revert to iDRAC Auto
    ipmitool -I lanplus -H $IDRAC_IP -U $IDRAC_USER -P $IDRAC_PASS -C 3 raw 0x30 0x30 0x01 0x01
    SPEED="MAX"
elif (( $(echo "$MAX_LOAD >= 0.8" | bc -l) )); then
    SPEED="0x3c"
elif (( $(echo "$MAX_LOAD >= 0.6" | bc -l) )); then
    SPEED="0x28"
elif (( $(echo "$MAX_LOAD >= 0.4" | bc -l) )); then
    SPEED="0x19"
else
    SPEED="0x0a"
fi

if [ "$SPEED" != "MAX" ]; then
    ipmitool -I lanplus -H $IDRAC_IP -U $IDRAC_USER -P $IDRAC_PASS -C 3 raw 0x30 0x30 0x02 0xff $SPEED
fi

echo "Status: CPU:$CPU_T GPU:$GPU_T HDD:$HDD_T NVMe:$NVME_T | LOAD:$MAX_LOAD | SPEED:$SPEED"
