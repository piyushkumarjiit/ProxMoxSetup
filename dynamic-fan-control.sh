#!/bin/bash
# -------------------------------------------------------------------------
# FILE: dynamic-fan-control.sh
# ROLE: Multi-Tier Thermal Monitor (PVE Host)
# -------------------------------------------------------------------------

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

IDRAC_IP="192.168.2.56"
IDRAC_USER="root"
IDRAC_PASS="calvin"

# Thermal Thresholds
CPU_MAX=75
GPU_MAX=80
HDD_MAX=75
NVME_MAX=70
EXHAUST_MAX=70

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

    fi
done

# --- 2. GET NVME TEMPS (HOST LEVEL) ---
MAX_NVME_T=0
for nvme in $(ls /dev/nvme[0-9] 2>/dev/null); do
    # Get the clean Kelvin value from JSON
    K_VAL=$(nvme smart-log $nvme -o json 2>/dev/null | grep "temperature" | head -1 | sed 's/[^0-9]//g')
    
    if [ -n "$K_VAL" ] && [ "$K_VAL" -gt 273 ]; then
        # Convert Kelvin to Celsius
        T=$((K_VAL - 273))
    else
        T=0
    fi

    if [ -n "$T" ] && [ "$T" -gt "$MAX_NVME_T" ]; then
        MAX_NVME_T=$T
    fi
done

# --- 3. GET HDD TEMPS (LOCAL) ---
#MAX_HDD_T=0
TOTAL_HDD_T=0
DRIVE_COUNT=0

for drive in $(lsblk -dn -o NAME | grep -E 'sd|vd'); do
    T=$(smartctl -a /dev/$drive 2>/dev/null | grep -iE "Temperature_Celsius|Airflow_Temperature_Cel" | awk '{print $10}' | sed 's/[^0-9]//g')
    
    if [ -n "$T" ] && [ "$T" -gt 0 ]; then
        TOTAL_HDD_T=$((TOTAL_HDD_T + T))
        DRIVE_COUNT=$((DRIVE_COUNT + 1))
    fi
done

# Calculate Average (handle division by zero)
if [ "$DRIVE_COUNT" -gt 0 ]; then
    HDD_T=$((TOTAL_HDD_T / DRIVE_COUNT))
else
    HDD_T=0
fi

# --- 4. CONSOLIDATE RESULTS ---
#HDD_T=${MAX_HDD_T:-0}
NVME_T=${MAX_NVME_T:-0}

# GPU Fallback logic
if [ "$MAX_GPU_T" -gt 0 ]; then
    GPU_T=$MAX_GPU_T
else
	#echo "Using fallback logic."
    GPU_T=$(echo "$EXHAUST_T + 5" | bc)
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
EXHAUST_LOAD=$(echo "scale=2; $EXHAUST_T / $EXHAUST_MAX" | bc)

# NVMe Conditional Logic: 
# If below 45°C, cap the load impact to 0.20 (Quiet tier).
if [ "$NVME_T" -lt 45 ]; then
    NVME_LOAD=0.20
else
    NVME_LOAD=$(echo "scale=2; $NVME_T / $NVME_MAX" | bc)
fi

# Find the highest load among all components
MAX_LOAD=$(echo -e "$CPU_LOAD\n$GPU_LOAD\n$HDD_LOAD\n$NVME_LOAD\n$EXHAUST_LOAD" | sort -rn | head -1)

# Set manual control mode (0x00)
ipmitool -I lanplus -H $IDRAC_IP -U $IDRAC_USER -P $IDRAC_PASS -C 3 raw 0x30 0x30 0x01 0x00

if (( $(echo "$MAX_LOAD >= 1.0" | bc -l) )); then
    # FORCED 100% Speed: Keep manual control (0x00) and set speed to 100% (0x64)
    ipmitool -I lanplus -H $IDRAC_IP -U $IDRAC_USER -P $IDRAC_PASS -C 3 raw 0x30 0x30 0x01 0x00
    SPEED="0x64"
elif (( $(echo "$MAX_LOAD >= 0.8" | bc -l) )); then
    # High: 80% Speed (80 in hex is 0x50)
    SPEED="0x50"
elif (( $(echo "$MAX_LOAD >= 0.6" | bc -l) )); then
    # Medium: 65% Speed (65 in hex is 0x41)
    SPEED="0x41"
elif (( $(echo "$MAX_LOAD >= 0.4" | bc -l) )); then
    # Low: 40% Speed (40 in hex is 0x28)
    SPEED="0x28"
elif (( $(echo "$MAX_LOAD >= 0.2" | bc -l) )); then
    # Quiet: 25% Speed (20 in hex is 0x19)
    SPEED="0x19"
else
    # Very Quiet: 10% Speed (10 in hex is 0x0a)
    SPEED="0x0a"
fi

if [ -n "$SPEED" ]; then
    ipmitool -I lanplus -H $IDRAC_IP -U $IDRAC_USER -P $IDRAC_PASS -C 3 raw 0x30 0x30 0x02 0xff $SPEED
fi

# --- 7. HUMAN READABLE OUTPUT ---
case $SPEED in
    "0x64")  DISPLAY_PERC="100%" ;;
    "0x50")  DISPLAY_PERC="80%" ;;
    "0x41")  DISPLAY_PERC="65%" ;;
    "0x28")  DISPLAY_PERC="40%" ;;
	"0x19")  DISPLAY_PERC="25%" ;;
    "0x14")  DISPLAY_PERC="20%" ;;
    "0x0a")  DISPLAY_PERC="10%" ;;
    "MAX")   DISPLAY_PERC="AUTO/100%" ;;
    *)       DISPLAY_PERC="UNKNOWN" ;;
esac

echo -e "Load Status: CPU: $CPU_LOAD GPU: $GPU_LOAD HDD: $HDD_LOAD NVME: $NVME_LOAD Exhaust: $EXHAUST_LOAD"
echo "Status: CPU:${CPU_T}°C GPU:${GPU_T}°C HDD:${HDD_T}°C NVMe:${NVME_T}°C EXHAUST:${EXHAUST_T}°C | LOAD:$MAX_LOAD | FAN SPEED: $DISPLAY_PERC ($SPEED)"
