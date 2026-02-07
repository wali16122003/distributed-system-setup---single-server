#!/bin/bash
# =============================================================================
# Deploy CDMAP Workers to VMs
# Run this AFTER kvm_setup.sh has created the VMs
# =============================================================================

set -e

# Load VM inventory
source ~/vm-configs/inventory.txt 2>/dev/null || {
    echo "❌ Run kvm_setup.sh first to create VMs"
    exit 1
}

# Configuration
PROJECT_DIR="/home/hpc/Videos/Crop_Detection_and_Monitoring"
CDMAP_DIR="${PROJECT_DIR}/cdmap"
WORKER_USER="worker"

echo "=========================================="
echo "Deploying CDMAP Workers to VMs"
echo "=========================================="

# Get worker IPs from inventory
WORKERS=($(grep "^worker" ~/vm-configs/inventory.txt | cut -d'=' -f2))

if [ ${#WORKERS[@]} -eq 0 ]; then
    echo "❌ No workers found in inventory"
    exit 1
fi

echo "Found ${#WORKERS[@]} workers: ${WORKERS[*]}"
echo ""

# Get master node IP (this machine)
MASTER_IP=$(hostname -I | awk '{print $1}')
echo "Master IP: ${MASTER_IP}"

# =============================================================================
# STEP 1: Copy cdmap code to each worker
# =============================================================================
echo ""
echo "[STEP 1] Copying cdmap code to workers..."
echo ""

for i in "${!WORKERS[@]}"; do
    IP=${WORKERS[$i]}
    WORKER_NUM=$((i+1))
    echo "Copying to worker${WORKER_NUM} (${IP})..."
    
    # Create directory on remote
    ssh ${WORKER_USER}@${IP} "mkdir -p ~/cdmap"
    
    # Copy cdmap directory
    rsync -avz --progress \
        --exclude '__pycache__' \
        --exclude '*.pyc' \
        --exclude 'output/*' \
        --exclude 'result/*' \
        ${CDMAP_DIR}/ ${WORKER_USER}@${IP}:~/cdmap/
    
    echo "✅ Copied to worker${WORKER_NUM}"
done

# =============================================================================
# STEP 2: Create worker .env file
# =============================================================================
echo ""
echo "[STEP 2] Creating .env configuration..."
echo ""

# Read credentials from master .env
source ${PROJECT_DIR}/.env

cat > /tmp/worker.env << EOF
# Worker Configuration - Auto-generated
RABBITMQ_HOST=${MASTER_IP}
RABBITMQ_PORT=5672
RABBITMQ_USER=${RABBITMQ_USER}
RABBITMQ_PASSWORD=${RABBITMQ_PASSWORD}

REDIS_HOST=${MASTER_IP}
REDIS_PORT=6379
REDIS_PASSWORD=${REDIS_PASSWORD}

AWS_S3_ENDPOINT=http://${MASTER_IP}:9000
AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}
S3_BUCKET=data-bank
EOF

# Copy .env to each worker
for i in "${!WORKERS[@]}"; do
    IP=${WORKERS[$i]}
    scp /tmp/worker.env ${WORKER_USER}@${IP}:~/cdmap/.env
done

echo "✅ Environment files copied"

# =============================================================================
# STEP 3: Create Dockerfile for distributed worker
# =============================================================================
echo ""
echo "[STEP 3] Creating worker Dockerfile..."
echo ""

cat > /tmp/Dockerfile.distributed << 'EOF'
FROM python:3.10-slim

WORKDIR /app

# Install system dependencies
RUN apt-get update && apt-get install -y \
    gdal-bin \
    libgdal-dev \
    python3-gdal \
    git \
    && rm -rf /var/lib/apt/lists/*

# Set GDAL environment
ENV CPLUS_INCLUDE_PATH=/usr/include/gdal
ENV C_INCLUDE_PATH=/usr/include/gdal

# Copy requirements and install
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY . .

# Create output directories
RUN mkdir -p /app/output /app/result

# Default command - run the national worker
CMD ["python", "main.py"]
EOF

# Copy Dockerfile to each worker
for i in "${!WORKERS[@]}"; do
    IP=${WORKERS[$i]}
    scp /tmp/Dockerfile.distributed ${WORKER_USER}@${IP}:~/cdmap/Dockerfile
done

echo "✅ Dockerfiles copied"

# =============================================================================
# STEP 4: Create docker-compose for workers
# =============================================================================
echo ""
echo "[STEP 4] Creating docker-compose configuration..."
echo ""

cat > /tmp/docker-compose.worker.yaml << 'EOF'
version: "3.8"

services:
  cdmap-worker:
    build:
      context: .
      dockerfile: Dockerfile
    env_file: .env
    volumes:
      - ./service-account-key.json:/app/service-account-key.json:ro
      - ./models:/app/models:ro
      - worker_output:/app/output
      - worker_result:/app/result
    restart: unless-stopped
    deploy:
      resources:
        limits:
          memory: 14G

volumes:
  worker_output:
  worker_result:
EOF

# Copy docker-compose to each worker
for i in "${!WORKERS[@]}"; do
    IP=${WORKERS[$i]}
    scp /tmp/docker-compose.worker.yaml ${WORKER_USER}@${IP}:~/cdmap/docker-compose.yaml
done

echo "✅ Docker-compose files copied"

# =============================================================================
# STEP 5: Distribute different service account keys
# =============================================================================
echo ""
echo "[STEP 5] Distributing service account keys..."
echo ""

# Check for multiple keys
KEY_FILES=($(ls ${CDMAP_DIR}/service-account-key*.json ${CDMAP_DIR}/worker*.json 2>/dev/null || true))

if [ ${#KEY_FILES[@]} -eq 0 ]; then
    echo "⚠️  No service account keys found, using single key"
    KEY_FILES=(${CDMAP_DIR}/service-account-key.json)
fi

echo "Found ${#KEY_FILES[@]} service account keys"

for i in "${!WORKERS[@]}"; do
    IP=${WORKERS[$i]}
    KEY_IDX=$((i % ${#KEY_FILES[@]}))
    KEY_FILE=${KEY_FILES[$KEY_IDX]}
    
    echo "Copying $(basename ${KEY_FILE}) to worker$((i+1))"
    scp ${KEY_FILE} ${WORKER_USER}@${IP}:~/cdmap/service-account-key.json
done

echo "✅ Service account keys distributed"

# =============================================================================
# STEP 6: Copy ML models
# =============================================================================
echo ""
echo "[STEP 6] Copying ML models..."
echo ""

for i in "${!WORKERS[@]}"; do
    IP=${WORKERS[$i]}
    echo "Copying models to worker$((i+1)) (${IP})..."
    
    rsync -avz --progress \
        ${CDMAP_DIR}/models/ ${WORKER_USER}@${IP}:~/cdmap/models/
done

echo "✅ Models copied"

# =============================================================================
# STEP 7: Build and start workers
# =============================================================================
echo ""
echo "[STEP 7] Building and starting workers on VMs..."
echo ""

for i in "${!WORKERS[@]}"; do
    IP=${WORKERS[$i]}
    WORKER_NUM=$((i+1))
    echo "Starting worker${WORKER_NUM} (${IP})..."
    
    ssh ${WORKER_USER}@${IP} "cd ~/cdmap && sudo docker-compose build && sudo docker-compose up -d"
    
    echo "✅ worker${WORKER_NUM} started"
done

# =============================================================================
# STEP 8: Verify workers are running
# =============================================================================
echo ""
echo "[STEP 8] Verifying workers..."
echo ""

sleep 10

for i in "${!WORKERS[@]}"; do
    IP=${WORKERS[$i]}
    WORKER_NUM=$((i+1))
    echo -n "worker${WORKER_NUM} (${IP}): "
    
    STATUS=$(ssh ${WORKER_USER}@${IP} "sudo docker-compose -f ~/cdmap/docker-compose.yaml ps --format '{{.Status}}'" 2>/dev/null | head -1)
    
    if [[ "$STATUS" == *"Up"* ]]; then
        echo "✅ Running"
    else
        echo "⚠️  ${STATUS:-Not running}"
    fi
done

# =============================================================================
# SUMMARY
# =============================================================================
echo ""
echo "=========================================="
echo "DEPLOYMENT COMPLETE!"
echo "=========================================="
echo ""
echo "Workers deployed:"
for i in "${!WORKERS[@]}"; do
    echo "  - worker$((i+1)): ${WORKERS[$i]}"
done
echo ""
echo "View worker logs:"
for i in "${!WORKERS[@]}"; do
    echo "  ssh ${WORKER_USER}@${WORKERS[$i]} 'sudo docker logs -f cdmap-cdmap-worker-1'"
done
echo ""
echo "Stop all workers:"
for i in "${!WORKERS[@]}"; do
    echo "  ssh ${WORKER_USER}@${WORKERS[$i]} 'cd ~/cdmap && sudo docker-compose down'"
done
echo ""
echo "🚀 Workers are now listening on RabbitMQ queue: cdmap_national"
echo "   Submit a job via the API to test distributed processing!"
