# Distributed Inference System - Setup Manual

## Problem Statement

### Objective
Set up a **distributed system** to test parallel inference processing across multiple virtual machines. The goal is to validate that the Crop Detection and Monitoring application can scale horizontally by distributing workload across multiple worker nodes before deploying to a production cloud environment (Kubernetes).

### Current Architecture Limitation
The existing `cdmap/national_worker.py` uses `ThreadPoolExecutor` for local parallelism - all processing runs on a **single machine**, limited by its resources.

### Target Architecture
```
┌──────────────────────────────────────────────────────────────────┐
│                    MASTER (Ubuntu Server)                        │
│  RabbitMQ + Redis + MinIO + PostgreSQL + Backend API             │
└────────────────────────────┬─────────────────────────────────────┘
                             │ RabbitMQ Queue
        ┌────────────────────┼────────────────────┐
        ▼                    ▼                    ▼
┌───────────────┐    ┌───────────────┐    ┌───────────────┐
│   WORKER VM1  │    │   WORKER VM2  │    │   WORKER VM3  │
│  cdmap worker │    │  cdmap worker │    │  cdmap worker │
│  (8 CPU, 16GB)│    │  (8 CPU, 16GB)│    │  (8 CPU, 16GB)│
└───────────────┘    └───────────────┘    └───────────────┘
```

---

## System Specifications

### Host Server (Master Node)
| Component | Specification |
|-----------|---------------|
| **CPU** | 128 cores |
| **RAM** | 377 GB |
| **Disk** | 374 GB available |
| **OS** | Ubuntu 24.04 (Noble) |
| **Virtualization** | KVM/QEMU supported |

### Worker VMs (Created)
| Setting | Value |
|---------|-------|
| **VMs Created** | 3 (worker1, worker2, worker3) |
| **CPUs per VM** | 8 cores |
| **RAM per VM** | 16 GB |
| **Disk per VM** | 50 GB |
| **OS** | Ubuntu 22.04 (Jammy) |
| **Base Image** | Ubuntu Cloud Image |

### Worker VM IPs (Current)
| VM | IP Address |
|----|------------|
| worker1 | 192.168.122.22 |
| worker2 | 192.168.122.88 |
| worker3 | 192.168.122.140 |



---

## Setup Steps

### Step 1: Install KVM/QEMU

#### What is KVM/QEMU?

**KVM (Kernel-based Virtual Machine)** is a Linux kernel module that turns the host into a hypervisor, enabling hardware-accelerated virtualization. It leverages the CPU's virtualization extensions (Intel VT-x or AMD-V) to run virtual machines at near-native performance.

**QEMU (Quick Emulator)** is a userspace emulator that works with KVM to provide device emulation (disks, network, etc.) for virtual machines.

**Why KVM for this project?**
- Full isolation between VMs (simulates real cloud nodes)
- Hardware-level performance (unlike containers)
- Compatible with cloud deployment (same concepts as AWS/GCP/OpenStack)
- Each VM is an independent system with its own OS, network, and storage

**Related Tools:**
| Tool | Purpose |
|------|--------|
| `libvirtd` | Daemon that manages VMs, networks, and storage |
| `virsh` | CLI for VM management |
| `virt-install` | Tool to create new VMs |
| `cloud-init` | Automated VM configuration on first boot |

```bash
sudo apt update
sudo apt install -y qemu-kvm libvirt-daemon-system libvirt-clients \
    bridge-utils virtinst cloud-image-utils genisoimage

sudo usermod -aG libvirt $USER
sudo usermod -aG kvm $USER
sudo systemctl enable libvirtd
sudo systemctl start libvirtd
```

> **Issue Encountered**: `libvirtd.service` failed with `--listen parameter not permitted with systemd activation sockets`

**Reason**: Modern Ubuntu uses systemd socket activation for libvirtd. The `--listen` flag (used for remote TCP connections) conflicts with systemd's socket-based activation. Since we only need local VM management, TCP listening is unnecessary.

**Solution**:
```bash
# Remove --listen from startup args
sudo sed -i 's/LIBVIRTD_ARGS=.*/LIBVIRTD_ARGS=""/' /etc/default/libvirtd

# Disable TCP/TLS listening in config
sudo sed -i 's/^listen_tcp.*/# listen_tcp = 0/' /etc/libvirt/libvirtd.conf
sudo sed -i 's/^listen_tls.*/# listen_tls = 0/' /etc/libvirt/libvirtd.conf

# Reload and restart
sudo systemctl daemon-reload
sudo systemctl start libvirtd.service
```

---

### Step 2: Download Ubuntu Cloud Image

```bash
cd /var/lib/libvirt/images/
sudo wget https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img
```

---

### Step 3: Create VMs with Cloud-Init (Initial Attempt)

Created cloud-init user-data:
```yaml
#cloud-config
users:
  - name: worker
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - <SSH_PUBLIC_KEY>
packages:
  - docker.io
  - docker-compose
```

> **Issue Encountered**: Cloud-init `DataSourceNone` - the VMs couldn't read the cloud-init ISO

---

### Step 4: Use virt-customize (Working Solution)

Bypassed cloud-init by directly customizing the base image:

```bash
sudo apt install -y libguestfs-tools

# Create working copy
sudo cp /var/lib/libvirt/images/jammy-server-cloudimg-amd64.img \
    /var/lib/libvirt/images/ubuntu-base.qcow2

# Customize image with user/password
sudo virt-customize -a /var/lib/libvirt/images/ubuntu-base.qcow2 \
  --root-password password:root123 \
  --run-command 'useradd -m -s /bin/bash -G sudo worker || true' \
  --password worker:password:worker123 \
  --run-command 'echo "worker ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers' \
  --run-command 'mkdir -p /home/worker/.ssh && chmod 700 /home/worker/.ssh' \
  --ssh-inject worker:file:/root/.ssh/id_rsa.pub \
  --run-command 'chown -R worker:worker /home/worker/.ssh' \
  --run-command 'sed -i "s/PasswordAuthentication no/PasswordAuthentication yes/" /etc/ssh/sshd_config'
```

---

### Step 5: Create Worker VMs

```bash
for i in 1 2 3; do
  sudo qemu-img create -f qcow2 -F qcow2 \
    -b /var/lib/libvirt/images/ubuntu-base.qcow2 \
    /var/lib/libvirt/images/worker${i}.qcow2 50G
  
  sudo virt-install \
    --name worker${i} \
    --memory 16384 \
    --vcpus 8 \
    --disk /var/lib/libvirt/images/worker${i}.qcow2,format=qcow2 \
    --os-variant ubuntu22.04 \
    --network network=default \
    --graphics none \
    --console pty,target_type=serial \
    --noautoconsole \
    --import
done
```

---

### Step 6: Fix Networking in VMs

> **Issue Encountered**: Network interface `enp1s0` was DOWN, no IP address

**Solution** (run inside VM via `virsh console`):
```bash
sudo ip link set enp1s0 up
sudo dhclient enp1s0
```

> **Issue Encountered**: DNS resolution failed (`Temporary failure resolving`)

**Solution**:
```bash
sudo systemctl stop systemd-resolved
sudo rm /etc/resolv.conf
echo "nameserver 8.8.8.8" | sudo tee /etc/resolv.conf
echo "nameserver 8.8.4.4" | sudo tee -a /etc/resolv.conf
echo "127.0.0.1 ubuntu" | sudo tee -a /etc/hosts
```

---

### Step 7: Expand VM Disk

> **Issue Encountered**: Cloud image has only 2GB root partition, Docker install failed with `No space left on device`

**Solution** (run inside each VM):
```bash
sudo growpart /dev/vda 1
sudo resize2fs /dev/vda1
df -h  # Should now show ~50GB
```

---

### Step 8: Install Docker in VMs

```bash
# Wait for any running apt process to finish
sudo killall apt apt-get 2>/dev/null
sleep 5

# Clean up locks if needed
sudo rm -f /var/lib/apt/lists/lock
sudo rm -f /var/lib/dpkg/lock*
sudo dpkg --configure -a

# Install Docker and Docker Compose
sudo apt update
sudo apt install -y docker.io docker-compose
sudo systemctl enable docker
sudo systemctl start docker
sudo usermod -aG docker worker
```

---

### Step 8b: CDMAP Docker Configuration

The `deploy_workers.sh` script creates a Dockerfile with required dependencies for OpenCV and GDAL:

```dockerfile
FROM python:3.10-slim

WORKDIR /app

# Install system dependencies (including OpenCV requirements)
RUN apt-get update && apt-get install -y \
    gdal-bin \
    libgdal-dev \
    python3-gdal \
    git \
    libgl1 \
    libglib2.0-0 \
    && rm -rf /var/lib/apt/lists/*

# Set GDAL environment
ENV CPLUS_INCLUDE_PATH=/usr/include/gdal
ENV C_INCLUDE_PATH=/usr/include/gdal

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .
RUN mkdir -p /app/output /app/result

CMD ["python", "main.py"]
```

> **Note**: The `libgl1` and `libglib2.0-0` packages are required for OpenCV. Without them, you'll get `ImportError: libGL.so.1: cannot open shared object file`

---

### Step 9: Fix SSH Host Keys (Required for Remote Access)

> **Issue Encountered**: SSH service fails with `no hostkeys available -- exiting`

**Solution** (run inside each VM via `virsh console`):
```bash
# Generate SSH host keys
sudo ssh-keygen -A

# Start SSH service
sudo systemctl restart ssh
sudo systemctl enable ssh

# Verify SSH is running
sudo systemctl status ssh
```

After this, you should be able to SSH from the host:
```bash
sudo ssh worker@<VM_IP>
```

---

## Useful Commands

### VM Management
```bash
virsh list --all              # List all VMs
virsh start worker1           # Start a VM
virsh shutdown worker1        # Graceful shutdown
virsh destroy worker1         # Force stop
virsh undefine worker1        # Remove VM definition
virsh console worker1         # Console access (Ctrl+] to exit)
virsh domifaddr worker1       # Get VM IP address
```

### SSH Access
```bash
sudo ssh worker@192.168.122.116  # SSH to worker1
sudo ssh worker@192.168.122.53   # SSH to worker2
sudo ssh worker@192.168.122.83   # SSH to worker3
```

### VM Credentials
- **Username**: `worker`
- **Password**: `worker123`
- **Root Password**: `root123`

---

## Scripts in this Directory

| Script | Purpose |
|--------|---------|
| `kvm_setup.sh` | Creates 3 worker VMs with KVM |
| `deploy_workers.sh` | Deploys cdmap workers to VMs |
| `monitor_workers.sh` | Real-time worker status dashboard |

---

### Step 10: Run deploy_workers.sh

Before running the deployment script, ensure the following prerequisites are met:

#### Prerequisites

1. **Update VM inventory** with current IPs:
```bash
sudo bash -c 'cat > /root/vm-configs/inventory.txt << EOF
worker1=<WORKER1_IP>
worker2=<WORKER2_IP>
worker3=<WORKER3_IP>
EOF'
```

2. **Fix .env files** - Quote any values with spaces or special characters:
```bash
# Values with spaces need double quotes
SMTP_PASSWORD="utda ptud dkvo tsbc"

# Angle brackets need quoting
AWS_S3_URL_TEMPLATE="http://localhost:9000/data-bank/<path>"
```

3. **Verify SSH connectivity** to all VMs:
```bash
sudo ssh -o StrictHostKeyChecking=no worker@<VM_IP> "echo OK"
```

#### Running the Script

```bash
cd /path/to/Crop_Detection_and_Monitoring
sudo ./scripts/deploy_workers.sh
```

> **Note**: The script expects the project at `PROJECT_DIR` (line 16). Update this path if your project is in a different location.

#### Common Issues

| Issue | Solution |
|-------|----------|
| `.env` syntax error | Quote values with spaces/special chars |
| `Permission denied` (Docker) | Script now uses `sudo docker-compose` |
| `No route to host` | Update inventory.txt with current VM IPs |
| `Connection refused` (SSH) | Run `sudo ssh-keygen -A` inside VM |

---

## Deploying CDMAP Microservices

### Step 11: Deploy Workers to All Nodes

```bash
# Run from the project root
cd /home/hpc/Videos/Crop_Detection_and_Monitoring
sudo ./scripts/deploy_workers.sh
```

The script will:
1. Copy cdmap code to all worker VMs
2. Create `.env` with RabbitMQ/Redis/MinIO credentials
3. Copy service account keys and ML models
4. Build Docker images
5. Start worker containers

### Updating Code on Workers

| Change Type | Command |
|-------------|---------|
| Python code only | `rsync + docker-compose restart` |
| requirements.txt | Full redeploy (rebuild image) |
| Dockerfile changes | Full redeploy (rebuild image) |

**Quick code sync** (Python files only):
```bash
for IP in 192.168.122.22 192.168.122.88 192.168.122.140; do
  rsync -avz --exclude '__pycache__' cdmap/ worker@$IP:~/cdmap/
  sudo ssh worker@$IP "cd ~/cdmap && sudo docker-compose restart"
done
```

---

## How RabbitMQ Connects Everything

### Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           HEAD NODE (Master)                            │
│  ┌──────────┐     ┌──────────┐     ┌──────────┐     ┌──────────┐       │
│  │ Frontend │────▶│ Backend  │────▶│ RabbitMQ │     │  MinIO   │       │
│  │ (Next.js)│     │ (Node.js)│     │  Queue   │     │   (S3)   │       │
│  └──────────┘     └──────────┘     └────┬─────┘     └──────────┘       │
│                                         │                               │
└─────────────────────────────────────────┼───────────────────────────────┘
                                          │
                    ┌─────────────────────┼─────────────────────┐
                    │                     │                     │
                    ▼                     ▼                     ▼
            ┌──────────────┐      ┌──────────────┐      ┌──────────────┐
            │   Worker 1   │      │   Worker 2   │      │   Worker 3   │
            │ (192.168.x.x)│      │ (192.168.x.x)│      │ (192.168.x.x)│
            │              │      │              │      │              │
            │  cdmap       │      │  cdmap       │      │  cdmap       │
            │  container   │      │  container   │      │  container   │
            └──────────────┘      └──────────────┘      └──────────────┘
```

### Message Flow

1. **User submits job** via Frontend → Backend API
2. **Backend publishes task** to RabbitMQ queue (`cdmap:start`)
3. **RabbitMQ distributes** task to ONE available worker (round-robin)
4. **Worker processes** the task (downloads data, runs inference)
5. **Worker uploads results** to MinIO (S3)
6. **Worker publishes completion** to callback queue (`cdmap:callback`)
7. **Backend receives callback** and updates database

### Why RabbitMQ?

| Feature | Benefit |
|---------|---------|
| **Competing consumers** | Multiple workers can process tasks in parallel |
| **Round-robin delivery** | Tasks automatically distributed among workers |
| **Message persistence** | Tasks survive RabbitMQ restarts |
| **Acknowledgments** | Failed tasks can be requeued |
| **Decoupling** | Workers don't need to know about each other |

### Worker Configuration

Each worker connects to RabbitMQ on the master node:

```env
# Worker .env (auto-generated by deploy_workers.sh)
RABBITMQ_HOST=10.19.10.156   # Master IP
RABBITMQ_PORT=5672
RABBITMQ_USER=rabbitmq
RABBITMQ_PASSWORD=W2freBxen6l3EZ

REDIS_HOST=10.19.10.156
AWS_S3_ENDPOINT=http://10.19.10.156:9000
```

### Verifying Connections

1. **RabbitMQ Dashboard**: http://localhost:15672 (guest/guest)
   - **Connections tab**: Should show 3 worker connections
   - **Queues tab**: Shows `cdmap:start` and `cdmap:callback`

2. **Check worker logs**:
```bash
sudo ssh worker@192.168.122.22 "sudo docker logs cdmap_cdmap-worker_1 2>&1 | tail -20"
```

### Scaling Workers

To add more workers:
1. Create new VM with `kvm_setup.sh` (or manually)
2. Add IP to `/root/vm-configs/inventory.txt`
3. Run `deploy_workers.sh` again

---

## Next Steps

1. ✅ VMs created and running
2. ✅ Network connectivity working
3. ✅ Disk expanded to 50GB
4. ✅ Install Docker on all VMs
5. ⏳ Deploy cdmap workers via `deploy_workers.sh`
6. ⏳ Test distributed inference processing
7. ⏳ Measure performance (single vs multi-worker)

---

## Lessons Learned
 
| Issue | Root Cause | Solution |
|-------|------------|----------|
| libvirtd failed to start | `--listen` parameter conflict with systemd | Remove from config |
| Cloud-init not working | DataSourceNone - ISO not detected | Use virt-customize instead |
| VM network down | Interface not brought up automatically | Manual `ip link set up` + `dhclient` |
| DNS resolution failed | systemd-resolved blocking | Use static `/etc/resolv.conf` |
| Disk full (2GB) | Cloud image default partition size | `growpart` + `resize2fs` |
| apt lock error | Another apt process running | `killall apt` and remove lock files |
| SSH no hostkeys | Host keys not generated | `sudo ssh-keygen -A` |
| OpenCV libGL missing | Docker slim image | Add `libgl1` to Dockerfile |
| Worker .env missing | Container not mounting file | Restart with `docker-compose down/up` |
```
