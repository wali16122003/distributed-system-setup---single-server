#!/bin/bash
# =============================================================================
# KVM Distributed Inference Testing Environment Setup
# Server: 128 CPUs, 377GB RAM
# =============================================================================

set -e

echo "=========================================="
echo "KVM Distributed Testing Environment Setup"
echo "=========================================="

# VM Configuration - Adjust as needed
NUM_WORKERS=3
VM_CPUS=8          # CPUs per worker VM
VM_RAM=16384       # RAM per worker VM (MB) = 16GB
VM_DISK=50         # Disk per worker VM (GB)

# Paths
ISO_DIR="/var/lib/libvirt/images"
CLOUD_IMG="jammy-server-cloudimg-amd64.img"
CLOUD_IMG_URL="https://cloud-images.ubuntu.com/jammy/current/${CLOUD_IMG}"

# =============================================================================
# STEP 1: Install KVM and Dependencies
# =============================================================================
echo ""
echo "[STEP 1] Installing KVM and dependencies..."
echo ""

sudo apt update
sudo apt install -y \
    qemu-kvm \
    libvirt-daemon-system \
    libvirt-clients \
    bridge-utils \
    virtinst \
    cloud-image-utils \
    genisoimage

# Add user to required groups
sudo usermod -aG libvirt $USER
sudo usermod -aG kvm $USER

# Enable and start libvirtd
sudo systemctl enable libvirtd
sudo systemctl start libvirtd

echo "✅ KVM installed successfully"

# =============================================================================
# STEP 2: Download Ubuntu Cloud Image
# =============================================================================
echo ""
echo "[STEP 2] Downloading Ubuntu cloud image..."
echo ""

sudo mkdir -p ${ISO_DIR}
cd ${ISO_DIR}

if [ ! -f "${CLOUD_IMG}" ]; then
    sudo wget -O ${CLOUD_IMG} ${CLOUD_IMG_URL}
    echo "✅ Cloud image downloaded"
else
    echo "ℹ️  Cloud image already exists"
fi

# =============================================================================
# STEP 3: Generate SSH Key (if not exists)
# =============================================================================
echo ""
echo "[STEP 3] Setting up SSH keys..."
echo ""

if [ ! -f ~/.ssh/id_rsa.pub ]; then
    ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N ""
    echo "✅ SSH key generated"
else
    echo "ℹ️  SSH key already exists"
fi

SSH_PUB_KEY=$(sudo cat /root/.ssh/id_rsa.pub)
# Create fixed user-data with password enabled
cat > ~/vm-configs/user-data << EOF
#cloud-config
hostname: worker
manage_etc_hosts: true
users:
  - name: worker
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    plain_text_passwd: 'worker123'
    ssh_authorized_keys:
      - ${SSH_PUB_KEY}
ssh_pwauth: true
packages:
  - docker.io
  - docker-compose
  - python3-pip
runcmd:
  - systemctl enable docker
  - systemctl start docker
  - usermod -aG docker worker
EOF
echo "Updated user-data with password: worker123"

# =============================================================================
# STEP 4: Create cloud-init configuration
# =============================================================================
echo ""
echo "[STEP 4] Creating cloud-init configuration..."
echo ""

# Create directory for cloud-init configs
mkdir -p ~/vm-configs

# Create user-data for workers
cat > ~/vm-configs/user-data << EOF
#cloud-config
hostname: worker
manage_etc_hosts: true

users:
  - name: worker
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - ${SSH_PUB_KEY}

packages:
  - docker.io
  - docker-compose
  - python3-pip
  - git

runcmd:
  - systemctl enable docker
  - systemctl start docker
  - usermod -aG docker worker
  - echo "VM setup complete" > /var/log/vm-setup-complete

final_message: "Cloud-init finished. System ready."
EOF

# Create meta-data template (will be customized per VM)
cat > ~/vm-configs/meta-data-template << 'EOF'
instance-id: INSTANCE_ID
local-hostname: HOSTNAME
EOF

echo "✅ Cloud-init configuration created"

# =============================================================================
# STEP 5: Create Worker VMs
# =============================================================================
echo ""
echo "[STEP 5] Creating ${NUM_WORKERS} worker VMs..."
echo ""

for i in $(seq 1 $NUM_WORKERS); do
    VM_NAME="worker${i}"
    echo "Creating ${VM_NAME}..."
    
    # Create disk image from cloud base
    if [ ! -f "${ISO_DIR}/${VM_NAME}.qcow2" ]; then
        sudo qemu-img create -f qcow2 -F qcow2 -b ${ISO_DIR}/${CLOUD_IMG} ${ISO_DIR}/${VM_NAME}.qcow2 ${VM_DISK}G
    fi
    
    # Resize disk
    sudo qemu-img resize ${ISO_DIR}/${VM_NAME}.qcow2 ${VM_DISK}G 2>/dev/null || true
    
    # Create per-VM meta-data
    sed "s/INSTANCE_ID/${VM_NAME}/g; s/HOSTNAME/${VM_NAME}/g" ~/vm-configs/meta-data-template > ~/vm-configs/meta-data-${VM_NAME}
    
    # Create cloud-init ISO
    sudo genisoimage -output ${ISO_DIR}/${VM_NAME}-cloud-init.iso -volid cidata -joliet -rock \
        ~/vm-configs/user-data ~/vm-configs/meta-data-${VM_NAME} 2>/dev/null
    
    # Check if VM already exists
    if sudo virsh list --all | grep -q "${VM_NAME}"; then
        echo "ℹ️  ${VM_NAME} already exists, skipping..."
        continue
    fi
    
    # Create VM
    sudo virt-install \
        --name ${VM_NAME} \
        --memory ${VM_RAM} \
        --vcpus ${VM_CPUS} \
        --disk ${ISO_DIR}/${VM_NAME}.qcow2,format=qcow2 \
        --disk ${ISO_DIR}/${VM_NAME}-cloud-init.iso,device=cdrom \
        --os-variant ubuntu22.04 \
        --network network=default \
        --graphics none \
        --console pty,target_type=serial \
        --noautoconsole \
        --import
    
    echo "✅ ${VM_NAME} created"
done

# Wait for VMs to boot
echo ""
echo "⏳ Waiting 60 seconds for VMs to boot and get DHCP addresses..."
sleep 60

# =============================================================================
# STEP 6: Get VM IP Addresses
# =============================================================================
echo ""
echo "[STEP 6] Getting VM IP addresses..."
echo ""

declare -A VM_IPS

for i in $(seq 1 $NUM_WORKERS); do
    VM_NAME="worker${i}"
    IP=$(sudo virsh domifaddr ${VM_NAME} 2>/dev/null | grep -oP '192\.168\.\d+\.\d+' | head -1)
    
    if [ -z "$IP" ]; then
        echo "⚠️  Waiting for ${VM_NAME} to get IP..."
        sleep 30
        IP=$(sudo virsh domifaddr ${VM_NAME} 2>/dev/null | grep -oP '192\.168\.\d+\.\d+' | head -1)
    fi
    
    VM_IPS[${VM_NAME}]=$IP
    echo "${VM_NAME}: ${IP}"
done

# =============================================================================
# STEP 7: Create hosts file entries
# =============================================================================
echo ""
echo "[STEP 7] Creating hosts file entries..."
echo ""

HOSTS_ENTRIES=""
for VM_NAME in "${!VM_IPS[@]}"; do
    HOSTS_ENTRIES+="${VM_IPS[$VM_NAME]}  ${VM_NAME}\n"
done

echo -e "Add the following to /etc/hosts on the master:"
echo "----------------------------------------"
echo -e "$HOSTS_ENTRIES"
echo "----------------------------------------"

# =============================================================================
# STEP 8: Create inventory file for easy access
# =============================================================================
echo ""
echo "[STEP 8] Creating inventory file..."
echo ""

cat > ~/vm-configs/inventory.txt << EOF
# Distributed Inference Worker Inventory
# Generated: $(date)

# Master Node (this machine)
MASTER_IP=$(hostname -I | awk '{print $1}')

# Worker VMs
EOF

for VM_NAME in "${!VM_IPS[@]}"; do
    echo "${VM_NAME}=${VM_IPS[$VM_NAME]}" >> ~/vm-configs/inventory.txt
done

echo "✅ Inventory saved to ~/vm-configs/inventory.txt"

# =============================================================================
# STEP 9: Test SSH connectivity
# =============================================================================
echo ""
echo "[STEP 9] Testing SSH connectivity..."
echo ""

for VM_NAME in "${!VM_IPS[@]}"; do
    IP=${VM_IPS[$VM_NAME]}
    echo -n "Testing ${VM_NAME} (${IP})... "
    
    if ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no worker@${IP} "echo OK" 2>/dev/null; then
        echo "✅ Connected"
    else
        echo "⚠️  Connection failed (VM may still be initializing)"
    fi
done

# =============================================================================
# SUMMARY
# =============================================================================
echo ""
echo "=========================================="
echo "SETUP COMPLETE!"
echo "=========================================="
echo ""
echo "Created ${NUM_WORKERS} worker VMs:"
for VM_NAME in "${!VM_IPS[@]}"; do
    echo "  - ${VM_NAME}: ${VM_IPS[$VM_NAME]} (${VM_CPUS} CPUs, ${VM_RAM}MB RAM)"
done
echo ""
echo "SSH into workers:"
for VM_NAME in "${!VM_IPS[@]}"; do
    echo "  ssh worker@${VM_IPS[$VM_NAME]}"
done
echo ""
echo "Useful commands:"
echo "  virsh list --all          # List all VMs"
echo "  virsh start worker1       # Start a VM"
echo "  virsh shutdown worker1    # Graceful shutdown"
echo "  virsh destroy worker1     # Force stop"
echo "  virsh console worker1     # Console access (Ctrl+] to exit)"
echo ""
