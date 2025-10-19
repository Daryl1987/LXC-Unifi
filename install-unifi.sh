#!/bin/bash

# ==============================================================================
# PROXMOX LXC DEPLOYMENT SCRIPT
#
# This script automates the creation and initial configuration of an LXC
# container on a Proxmox VE 9.1 host, and automatically installs the
# Unifi Network Controller software inside the container.
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
ROOTFS_STORAGE="local-zfs"

# Storage ID where templates are downloaded/cached (must support 'Container Templates' - often 'local')
TEMPLATE_CACHE_STORAGE="local"

# Template to use (Debian is required for the installation steps below)
TEMPLATE="debian-12-standard"
TEMPLATE_FILE="debian-12-standard_12.12-1_amd64.tar.zst" # Specific file name for template

# Resource Configuration
CORE_COUNT=2             # Number of CPU Cores
RAM_MB=2048              # Increased Memory for Unifi/Java (RECOMMENDED)
SWAP_MB=512              # Swap space in MB
DISK_SIZE_GB=16          # Increased Disk Size for Unifi Database (RECOMMENDED)

# Network Configuration (REQUIRED for static IP)
NET_BR="vmbr1"           # Network bridge (usually vmbr0)
NET_IP="10.150.0.45/24" # Static IP address with CIDR
NET_GW="10.150.0.1"     # Gateway IP address
DNS_SERVERS="10.150.0.1 1.1.1.1 8.8.8.8" # DNS servers (space-separated)

# Root Password for the container
ROOT_PASSWORD="MySecurePassword123"

# --- USER CONFIGURATION END ---

# NOTE: RAM and DISK size were increased to meet typical Unifi Controller requirements.

# Function to find storage that allows Container Templates (vztmpl)
find_template_storage() {
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
if ! pvesm status -storage "$TEMPLATE_CACHE_STORAGE" | grep -q "vztmpl"; then
    echo "WARNING: Configured template cache storage '$TEMPLATE_CACHE_STORAGE' does not support 'Container Templates'."
    NEW_STORAGE=$(find_template_storage)
    if [ -n "$NEW_STORAGE" ]; then
        echo "INFO: Falling back to suitable storage: '$NEW_STORAGE' for template download."
        TEMPLATE_CACHE_STORAGE="$NEW_STORAGE"
    else
        echo "CRITICAL ERROR: No storage pool found that is configured to hold Container Templates (vztmpl)."
        exit 1
    fi
else
    echo "INFO: Using configured template cache storage '$TEMPLATE_CACHE_STORAGE'."
fi

# 3. Network Validation Check (Host)
echo "Validating host network connectivity..."
ping -c 1 1.1.1.1 &> /dev/null
if [ $? -ne 0 ]; then
    echo "--------------------------------------------------------"
    echo "CRITICAL ERROR: Proxmox host cannot reach external network."
    echo "--------------------------------------------------------"
    exit 1
fi
echo "Host network connectivity verified."


# 4. Check and Download Template
TEMPLATE_DOWNLOAD_PATH="/var/lib/vz/template/cache/$TEMPLATE_FILE"
if [ ! -f "$TEMPLATE_DOWNLOAD_PATH" ]; then
    echo "Template $TEMPLATE_FILE not found. Downloading to storage '$TEMPLATE_CACHE_STORAGE'..."
    pveam download "$TEMPLATE_CACHE_STORAGE" "$TEMPLATE_FILE"
    if [ $? -ne 0 ]; then
        echo "CRITICAL ERROR: Failed to download template using pveam."
        exit 1
    fi
    echo "Template downloaded successfully."
fi

# 5. Create the Container
echo "Creating container $VMID ($CTNAME) on disk storage $ROOTFS_STORAGE..."
# Using absolute path to template to bypass Proxmox storage indexing issues
pct create "$VMID" "$TEMPLATE_DOWNLOAD_PATH" \
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
echo "Setting static network configuration and nameservers..."
pct set "$VMID" \
    --net0 "name=eth0,bridge=$NET_BR,ip=$NET_IP,gw=$NET_GW" \
    --nameserver "$DNS_SERVERS"

# 7. Set Additional Options (Autostart and Security)
echo "Setting autostart, CPU limits, and security features..."
pct set "$VMID" \
    --onboot 1 \
    --cpuunits 1024 \
    --features nesting=1,keyctl=1

# 8. Start the Container
echo "Starting container $VMID..."
pct start "$VMID"
sleep 10 # Give the container time to boot and get an IP

# 9. Unifi Controller Installation (The automation you needed!)
echo "--------------------------------------------------------"
echo "--- Installing Unifi Network Controller (This may take several minutes) ---"
echo "--------------------------------------------------------"

# Wait until the container has an IP address
echo "Waiting for container to report an IP address..."
MAX_TRIES=10
TRIES=0
while [ -z "$IP" ] && [ $TRIES -lt $MAX_TRIES ]; do
    IP=$(pct exec "$VMID" ip a | grep 'inet ' | awk '{print $2}' | head -n 1 | cut -d/ -f1)
    sleep 5
    TRIES=$((TRIES + 1))
done

if [ -z "$IP" ]; then
    echo "CRITICAL WARNING: Container failed to get an IP. Skipping Unifi installation."
else
    echo "Container has IP: $IP. Proceeding with installation."

    # Step 1: Install required packages (curl, Java 17)
    pct exec "$VMID" -- apt update -y
    pct exec "$VMID" -- apt install -y openjdk-17-jdk curl wget gnupg apt-transport-https

    # Step 2: Add Unifi GPG Key and Repository (Modern Debian 12 Method)
    echo "Adding Unifi repository key and source using modern, secure method..."
    # 2a. Download GPG key and store in the standard keyrings location
    pct exec "$VMID" -- bash -c 'curl -fsSL https://dl.ui.com/unifi/unifi-repo.gpg | gpg --dearmor -o /usr/share/keyrings/unifi-archive-keyring.gpg'
    
    # 2b. Add the source line, explicitly using 'signed-by' and the distribution 'ubiquiti'
    pct exec "$VMID" -- bash -c 'echo "deb [arch=amd64 signed-by=/usr/share/keyrings/unifi-archive-keyring.gpg] https://www.ui.com/downloads/unifi/debian stable ubiquiti" | tee /etc/apt/sources.list.d/unifi.list'

    # Step 3: Final Update and Install Unifi
    echo "Installing Unifi package..."
    pct exec "$VMID" -- apt update -y
    pct exec "$VMID" -- apt install -y unifi

    # Step 4: Clean up
    pct exec "$VMID" -- apt autoremove -y
fi

# 10. Final Status Check and Instructions
STATUS=$(pct status "$VMID")

echo "--------------------------------------------------------"
echo "✅ Unifi Deployment Complete!"
echo "Container Status: $STATUS"
echo "Hostname: $CTNAME"
echo "Assigned IP: $NET_IP"
echo ""
echo "NEXT STEPS:"
echo "1. Wait 2-3 minutes for the Unifi service to fully start."
echo "2. Open your web browser to:"
echo "   https://$NET_IP:8443/"
echo "3. Log in and complete the setup wizard."
echo "--------------------------------------------------------"
