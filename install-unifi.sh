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

# Storage ID for the container's root filesystem (Disk/Volume placement)
# This usually needs to be LVM-Thin, ZFS, or a Directory with the 'Container' content type enabled.
ROOTFS_STORAGE="local-zfs"

# Storage ID where templates are downloaded/cached (must support 'Container Templates' - often 'local')
TEMPLATE_CACHE_STORAGE="local"

# Template to use (Check 'pveam available' for options).
TEMPLATE="debian-12-standard"
TEMPLATE_FILE="debian-12-standard_12.12-1_amd64.tar.zst" # Specific file name for template

# Resource Configuration
CORE_COUNT=2             # Number of CPU Cores
RAM_MB=1024              # Memory in MB
SWAP_MB=512              # Swap space in MB
DISK_SIZE_GB=8           # Root disk size in GB

# Network Configuration (REQUIRED for static IP)
NET_BR="vmbr0"           # Network bridge (usually vmbr0)
NET_IP="10.150.0.45/24" # Static IP address with CIDR (e.g., 10.150.0.45/24)
NET_GW="10.150.0.1"     # Gateway IP address
DNS_SERVERS="10.150.0.1 1.1.1.1 8.8.8.8" # DNS servers (space-separated)

# Root Password for the container (will be set during creation)
# NOTE: Highly recommended to change this immediately after creation.
ROOT_PASSWORD="MySecurePassword123"

# --- USER CONFIGURATION END ---

# Function to find storage that allows Container Templates (vztmpl)
find_template_storage() {
    # Filters pvesm status output for storage IDs that contain 'vztmpl' in the 'Content' column
    pvesm status -content vztmpl | awk 'NR>1 {print $1}' | head -n 1
}

echo "--- Proxmox LXC Deployment Script Started ---"
echo "Container ID: $VMID"
echo "Hostname: $CTNAME"
echo "Root Disk Storage: $ROOTFS_STORAGE"

# 1. Check if the VMID is already in use
if pct status "$VMID" &> /dev/null; then
    echo "ERROR: Container ID $VMID is already in use. Please choose a different VMID."
    exit 1
fi

# 2. Validate and/or Select Storage for Template Download
echo "Validating template cache storage..."
# Check if the user's TEMPLATE_CACHE_STORAGE supports templates
if ! pvesm status -storage "$TEMPLATE_CACHE_STORAGE" | grep -q "vztmpl"; then
    echo "WARNING: Configured template cache storage '$TEMPLATE_CACHE_STORAGE' does not support 'Container Templates'."
    NEW_STORAGE=$(find_template_storage)
    if [ -n "$NEW_STORAGE" ]; then
        echo "INFO: Falling back to suitable storage: '$NEW_STORAGE' for template download."
        TEMPLATE_CACHE_STORAGE="$NEW_STORAGE"
    else
        echo "CRITICAL ERROR: No storage pool found that is configured to hold Container Templates (vztmpl)."
        echo "Please check your storage settings in the Proxmox UI."
        exit 1
    fi
else
    echo "INFO: Using configured template cache storage '$TEMPLATE_CACHE_STORAGE'."
fi

# 3. Network Validation Check
echo "Validating host network connectivity..."
# Try to ping a reliable external IP (Cloudflare DNS)
ping -c 1 1.1.1.1 &> /dev/null
if [ $? -ne 0 ]; then
    echo "--------------------------------------------------------"
    echo "CRITICAL ERROR: Proxmox host cannot reach external network (1.1.1.1)."
    echo "Please confirm your Proxmox host has a working internet connection."
    echo "Fix your host network configuration (e.g., /etc/network/interfaces) before trying again."
    echo "--------------------------------------------------------"
    exit 1
fi
echo "Host network connectivity verified."


# 4. Check and Download Template
TEMPLATE_DOWNLOAD_PATH="/var/lib/vz/template/cache/$TEMPLATE_FILE"
if [ ! -f "$TEMPLATE_DOWNLOAD_PATH" ]; then
    echo "Template $TEMPLATE_FILE not found. Downloading to storage '$TEMPLATE_CACHE_STORAGE'..."
    
    # Use TEMPLATE_CACHE_STORAGE for download
    pveam download "$TEMPLATE_CACHE_STORAGE" "$TEMPLATE_FILE"
    
    if [ $? -ne 0 ]; then
        echo "--------------------------------------------------------"
        echo "CRITICAL ERROR: Failed to download template using pveam."
        echo "1. The Proxmox repository is temporarily down."
        echo "2. Storage capacity: Storage '$TEMPLATE_CACHE_STORAGE' is full."
        echo "3. The template name '$TEMPLATE_FILE' is incorrect."
        echo "--------------------------------------------------------"
        exit 1
    fi
    echo "Template downloaded successfully."
else
    echo "Template $TEMPLATE_FILE already exists."
fi

# 5. Create the Container
echo "Creating container $VMID ($CTNAME) on disk storage $ROOTFS_STORAGE..."
# Use ROOTFS_STORAGE for the volume, and TEMPLATE_CACHE_STORAGE for the source template path
pct create "$VMID" "$TEMPLATE_CACHE_STORAGE:vztmpl/$TEMPLATE_FILE" \
    --hostname "$CTNAME" \
    --cores "$CORE_COUNT" \
    --memory "$RAM_MB" \
    --swap "$SWAP_MB" \
    --ostype debian \
    --unprivileged 1 \
    --start 0 \
    --password "$ROOT_PASSWORD" \
    --rootfs "$ROOTFS_STORAGE:$DISK_SIZE_GB"

if [ $? -ne 0 ]; then
    echo "ERROR: Failed to create container $VMID. Exiting."
    exit 1
fi

# 6. Set Network Configuration
echo "Setting static network configuration..."
pct set "$VMID" \
    --net0 "name=eth0,bridge=$NET_BR,ip=$NET_IP,gw=$NET_GW" \
    --nameserver "$DNS_SERVERS"

# 7. Set Additional Options (Autostart and Security)
echo "Setting autostart, CPU limits, and security features..."
pct set "$VMID" \
    --onboot 1 \
    --cpuunits 1024 \
    --features nesting=1,keyctl=1 \
    --sshkeys /root/.ssh/id_rsa.pub # Optional: Adjust to your key path if needed

# 8. Start the Container
echo "Starting container $VMID..."
pct start "$VMID"

# 9. Final Status Check
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
