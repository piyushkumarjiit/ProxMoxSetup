#!/bin/bash
#!/bin/bash
# -------------------------------------------------------------------------
# FILE: dynamic-fan-control.sh
# ROLE: Multi-Tier Thermal Monitor & Dynamic Fan Controller (Proxmox Host)
# -------------------------------------------------------------------------
# DESCRIPTION:
# Manages Dell PowerEdge thermal profiles by interfacing with the iDRAC 
# via IPMI. This script implements a hybrid cooling logic that balances 
# silent operation during idle states with aggressive, linear scaling 
# during high-load AI workloads (RAG/Object Tracking).
#
# FEATURES:
# - Multi-Source Sensing: Aggregates temps from CPU, GPU (VM Passthrough), 
#   NVMe (Host JSON), and Chassis Exhaust.
# - Hybrid Logic: Stepped duty cycles for idle (10%, 25%) and 1:1 linear 
#   scaling for loads > 40%.
# - Smart NVMe Handling: Implements Kelvin-to-Celsius conversion and a 
#   low-temp "floor" to prevent drive-idling fan noise.
# - Clean Reporting: Real-time status output with human-readable 
#   percentages and raw hex values.
#
# UPDATES:
# - Replaced fixed speed tiers with a dynamic 1:1 Load-to-Fan% scaling 
#   for loads above 40%.
# - Switched NVMe sensing to host-level JSON parsing to bypass Guest 
#   Agent inconsistencies.
# - Implemented stderr/stdout suppression for IPMI calls to ensure 
#   clean terminal logging.
# - Adjusted base "Quiet" speed from 20% to 25% for improved static 
#   pressure on HDDs.
# -------------------------------------------------------------------------
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Default values. Please update with your env details below.
IDRAC_IP="192.168.2.56"
IDRAC_USER="root" 
IDRAC_PASS="calvin"

# Thermal Thresholds
CPU_MAX=75
GPU_MAX=75
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

# --- 6. CALCULATE LOAD & SET SPEED ---

# Find the highest load among all components
MAX_LOAD=$(echo -e "$CPU_LOAD\n$GPU_LOAD\n$HDD_LOAD\n$NVME_LOAD\n$EXHAUST_LOAD" | sort -rn | head -1)

# Set manual control mode (0x00)
ipmitool -I lanplus -H $IDRAC_IP -U $IDRAC_USER -P $IDRAC_PASS -C 3 raw 0x30 0x30 0x01 0x00 > /dev/null 2>&1

if (( $(echo "$MAX_LOAD < 0.2" | bc -l) )); then
    # Very Quiet: 10%
    DISPLAY_PERC="10%"
    SPEED="0x0a"
elif (( $(echo "$MAX_LOAD < 0.4" | bc -l) )); then
    # Quiet: 25% (Base speed)
    DISPLAY_PERC="25%"
    SPEED="0x19"
else
    # DYNAMIC SCALING: Above 40% load, fan speed = load percentage
    # Example: 0.56 load = 56% fan speed
    CALC_PERC=$(echo "scale=0; ($MAX_LOAD * 100) / 1" | bc)
    
    # Cap at 100%
    if [ "$CALC_PERC" -gt 100 ]; then CALC_PERC=100; fi
    
    DISPLAY_PERC="${CALC_PERC}%"
    # Convert decimal percentage to Hex for IPMI (e.g., 56 -> 0x38)
    SPEED=$(printf '0x%02x' $CALC_PERC)
fi

if [ -n "$SPEED" ]; then
    ipmitool -I lanplus -H $IDRAC_IP -U $IDRAC_USER -P $IDRAC_PASS -C 3 raw 0x30 0x30 0x02 0xff $SPEED > /dev/null 2>&1
fi

# --- 7. OUTPUT ---
echo -e "Load Status: CPU: $CPU_LOAD GPU: $GPU_LOAD HDD: $HDD_LOAD NVME: $NVME_LOAD Exhaust: $EXHAUST_LOAD"
echo "Status: CPU:${CPU_T}°C GPU:${GPU_T}°C HDD:${HDD_T}°C NVMe:${NVME_T}°C EXHAUST:${EXHAUST_T}°C | LOAD:$MAX_LOAD | FAN SPEED: $DISPLAY_PERC ($SPEED)"
