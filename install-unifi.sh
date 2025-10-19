#!/bin/bash

# ==============================================================================
# PROXMOX LXC DEPLOYMENT SCRIPT
#
# This script automates the creation and initial configuration of an LXC
# container on a Proxmox VE 9.1 host.
#
# EXECUTION:
# 1. Save the file (e.g., lxc_installer.sh)
# 2. Make it executable: chmod +x lxc_installer.sh
# 3. Run it as root: ./lxc_installer.sh
# ==============================================================================

# --- USER CONFIGURATION START ---

# Container ID (must be unique)
VMID=901

# Container Hostname
CTNAME="Unifi-Server"

# Storage ID for the container rootfs and template cache (e.g., local, local-lvm)
STORAGE="local-zfs"

# Template to use (Check 'pveam available' for options).
# We will use Debian 12 Standard as a default.
TEMPLATE="debian-12-standard"
TEMPLATE_FILE="debian-12-standard_12.5-1_amd64.tar.zst" # Specific file name for template

# Resource Configuration
CORE_COUNT=2             # Number of CPU Cores
RAM_MB=1024              # Memory in MB
SWAP_MB=512              # Swap space in MB
DISK_SIZE_GB=8           # Root disk size in GB

# Network Configuration (REQUIRED for static IP)
NET_BR="vmbr0"           # Network bridge (usually vmbr0)
NET_IP="10.150.0.45/24" # Static IP address with CIDR (e.g., 192.168.1.150/24)
NET_GW="10.150.0.1"     # Gateway IP address
DNS_SERVERS="10.150.0.1 1.1.1.1" # DNS servers (space-separated)

# Root Password for the container (will be set during creation)
# NOTE: Highly recommended to change this immediately after creation.
ROOT_PASSWORD="MySecurePassword123"

# --- USER CONFIGURATION END ---

echo "--- Proxmox LXC Deployment Script Started ---"
echo "Container ID: $VMID"
echo "Hostname: $CTNAME"

# 1. Check if the VMID is already in use
if pct status "$VMID" &> /dev/null; then
    echo "ERROR: Container ID $VMID is already in use. Please choose a different VMID."
    exit 1
fi

# 2. Check and Download Template
TEMPLATE_PATH="/var/lib/vz/template/cache/current/$TEMPLATE_FILE"
if [ ! -f "$TEMPLATE_PATH" ]; then
    echo "Template $TEMPLATE_FILE not found. Downloading..."
    # 'pveam available' shows full template names for 'pveam download'
    pveam download "$STORAGE" "$TEMPLATE_FILE"
    if [ $? -ne 0 ]; then
        echo "ERROR: Failed to download template. Exiting."
        exit 1
    fi
    echo "Template downloaded successfully."
else
    echo "Template $TEMPLATE_FILE already exists."
fi

# 3. Create the Container
echo "Creating container $VMID ($CTNAME)..."
pct create "$VMID" "$STORAGE:vztmpl/$TEMPLATE_FILE" \
    --hostname "$CTNAME" \
    --cores "$CORE_COUNT" \
    --memory "$RAM_MB" \
    --swap "$SWAP_MB" \
    --ostype debian \
    --unprivileged 1 \
    --start 0 \
    --password "$ROOT_PASSWORD" \
    --rootfs "$STORAGE:$DISK_SIZE_GB"

if [ $? -ne 0 ]; then
    echo "ERROR: Failed to create container $VMID. Exiting."
    exit 1
fi

# 4. Set Network Configuration
echo "Setting static network configuration..."
pct set "$VMID" \
    --net0 "name=eth0,bridge=$NET_BR,ip=$NET_IP,gw=$NET_GW" \
    --nameserver "$DNS_SERVERS"

# 5. Set Additional Options (Autostart and Security)
echo "Setting autostart, CPU limits, and security features..."
pct set "$VMID" \
    --onboot 1 \
    --cpuunits 1024 \
    --features nesting=1,keyctl=1 \
    --sshkeys /root/.ssh/id_rsa.pub # Optional: Adjust to your key path if needed

# 6. Start the Container
echo "Starting container $VMID..."
pct start "$VMID"

# 7. Final Status Check
sleep 5
STATUS=$(pct status "$VMID")
IP=$(pct exec "$VMID" ip a | grep 'inet ' | awk '{print $2}' | head -n 1 | cut -d/ -f1)

echo "--------------------------------------------------------"
echo "Deployment Complete!"
echo "Container Status: $STATUS"
echo "Hostname: $CTNAME"
echo "Assigned IP: $NET_IP (Attempting to verify: $IP)"
echo "To access the container via console, run: pct enter $VMID"
echo "To check logs, run: pct log $VMID"
echo "--------------------------------------------------------"
