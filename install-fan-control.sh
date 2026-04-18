# -------------------------------------------------------------------------
# FILE: install-fan-control.sh
# ROLE: Fan Control Service Installer
#
# DESCRIPTION:
# Bootstraps the thermal management system by installing necessary 
# dependencies, deploying the monitoring logic, and registering a 
# cron job to ensure the script runs every minute.
#
# HARDWARE COMPATIBILITY:
# - Targets Proxmox Host environment.
# - Requires access to iDRAC credentials for IPMI commands.
# -------------------------------------------------------------------------

#!/bin/bash
# install-fan-control.sh

echo "--- Step 1: Installing Dependencies ---"
apt update
apt install -y ipmitool smartmontools nvme-cli bc

echo "--- Step 2: Creating the Fan Control Script ---"
cat << 'EOF' > /root/dynamic-fan-control.sh
#!/bin/bash
# (Your v2.3 script logic goes here)
IDRAC_IP="192.168.2.158"
IDRAC_USER="root"
IDRAC_PASS="calvin"

CPU_MAX=75
GPU_MAX=80
HDD_MAX=50
NVME_MAX=60
EXHAUST_MAX=55

CPU_T=$(ipmitool -I lanplus -H $IDRAC_IP -U $IDRAC_USER -P $IDRAC_PASS sdr type temperature | grep "Inlet Temp" | cut -d"|" -f5 | sed 's/[^0-9]//g')
CPU_T=${CPU_T:-0}
EXHAUST_T=$(ipmitool -I lanplus -H $IDRAC_IP -U $IDRAC_USER -P $IDRAC_PASS sdr type temperature | grep "Exhaust Temp" | cut -d"|" -f5 | sed 's/[^0-9]//g')
EXHAUST_T=${EXHAUST_T:-0}
GPU_T=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null | sed 's/[^0-9]//g')
GPU_T=${GPU_T:-0}
HDD_T=$(smartctl -a /dev/sda 2>/dev/null | grep "Temperature_Celsius" | awk '{print $10}' | sed 's/[^0-9]//g')
HDD_T=${HDD_T:-0}
NVME_RAW=$(nvme smart-log /dev/nvme0 2>/dev/null | grep "^temperature" | awk '{print $3}' | sed 's/[^0-9]//g')
if nvme smart-log /dev/nvme0 2>/dev/null | grep -q "°F"; then
    NVME_T=$(echo "($NVME_RAW - 32) * 5 / 9" | bc)
else
    NVME_T=$NVME_RAW
fi
NVME_T=${NVME_T:-0}

if [ "$CPU_T" -eq 0 ] || [ "$GPU_T" -eq 0 ]; then
    ipmitool -I lanplus -H $IDRAC_IP -U $IDRAC_USER -P $IDRAC_PASS raw 0x30 0x30 0x01 0x01
    exit 1
fi

CPU_LOAD=$(echo "scale=2; $CPU_T / $CPU_MAX" | bc)
GPU_LOAD=$(echo "scale=2; $GPU_T / $GPU_MAX" | bc)
HDD_LOAD=$(echo "scale=2; $HDD_T / $HDD_MAX" | bc)
NVME_LOAD=$(echo "scale=2; $NVME_T / $NVME_MAX" | bc)
EXHAUST_LOAD=$(echo "scale=2; $EXHAUST_T / $EXHAUST_MAX" | bc)

MAX_LOAD=$(echo -e "$CPU_LOAD\n$GPU_LOAD\n$HDD_LOAD\n$NVME_LOAD\n$EXHAUST_LOAD" | sort -rn | head -1)

if (( $(echo "$MAX_LOAD >= 1.0" | bc -l) )); then
    ipmitool -I lanplus -H $IDRAC_IP -U $IDRAC_USER -P $IDRAC_PASS raw 0x30 0x30 0x01 0x01
elif (( $(echo "$MAX_LOAD >= 0.8" | bc -l) )); then
    SPEED="0x3c"
elif (( $(echo "$MAX_LOAD >= 0.6" | bc -l) )); then
    SPEED="0x28"
elif (( $(echo "$MAX_LOAD >= 0.4" | bc -l) )); then
    SPEED="0x19"
else
    SPEED="0x0a"
fi

if [ "$MAX_LOAD" != "1.00" ]; then
    ipmitool -I lanplus -H $IDRAC_IP -U $IDRAC_USER -P $IDRAC_PASS raw 0x30 0x30 0x01 0x00
    ipmitool -I lanplus -H $IDRAC_IP -U $IDRAC_USER -P $IDRAC_PASS raw 0x30 0x30 0x02 0xff $SPEED
fi
echo "System Status (C): CPU:$CPU_T GPU:$GPU_T HDD:$HDD_T NVMe:$NVME_T EXH:$EXHAUST_T | LOAD:$MAX_LOAD"
EOF

echo "--- Step 3: Setting Permissions ---"
chmod +x /root/dynamic-fan-control.sh

echo "--- Step 4: Adding to Crontab ---"
# Check if the job already exists to avoid duplicates
(crontab -l 2>/dev/null | grep -Fq "/root/dynamic-fan-control.sh") || (crontab -l 2>/dev/null; echo "* * * * * /root/dynamic-fan-control.sh > /dev/null 2>&1") | crontab -

echo "SUCCESS: Fan control installed and scheduled."
