#!/bin/bash
# =============================================================================
# Monitor Distributed Workers
# Shows real-time status of all workers
# =============================================================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Load inventory
source ~/vm-configs/inventory.txt 2>/dev/null || {
    echo "❌ Run kvm_setup.sh first"
    exit 1
}

# Get workers
WORKERS=($(grep "^worker" ~/vm-configs/inventory.txt | cut -d'=' -f2))
WORKER_USER="worker"

clear
echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║        DISTRIBUTED CDMAP WORKER MONITOR                      ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

while true; do
    # Move cursor to line 5
    tput cup 4 0
    
    echo -e "${YELLOW}Last Updated: $(date '+%Y-%m-%d %H:%M:%S')${NC}"
    echo ""
    echo "┌─────────────┬──────────────────┬────────────┬─────────────────────────┐"
    echo "│ Worker      │ IP Address       │ Status     │ Container Status        │"
    echo "├─────────────┼──────────────────┼────────────┼─────────────────────────┤"
    
    for i in "${!WORKERS[@]}"; do
        IP=${WORKERS[$i]}
        WORKER_NAME="worker$((i+1))"
        
        # Check SSH connectivity
        if ssh -o ConnectTimeout=2 -o BatchMode=yes ${WORKER_USER}@${IP} "exit" 2>/dev/null; then
            SSH_STATUS="${GREEN}Online${NC}"
            
            # Get Docker container status
            CONTAINER_STATUS=$(ssh -o ConnectTimeout=5 ${WORKER_USER}@${IP} \
                "docker ps --filter 'name=cdmap' --format '{{.Status}}'" 2>/dev/null | head -1)
            
            if [[ -z "$CONTAINER_STATUS" ]]; then
                CONTAINER_STATUS="${YELLOW}Not Running${NC}"
            elif [[ "$CONTAINER_STATUS" == *"Up"* ]]; then
                CONTAINER_STATUS="${GREEN}${CONTAINER_STATUS}${NC}"
            else
                CONTAINER_STATUS="${RED}${CONTAINER_STATUS}${NC}"
            fi
        else
            SSH_STATUS="${RED}Offline${NC}"
            CONTAINER_STATUS="${RED}N/A${NC}"
        fi
        
        printf "│ %-11s │ %-16s │ %-20b │ %-33b │\n" \
            "$WORKER_NAME" "$IP" "$SSH_STATUS" "$CONTAINER_STATUS"
    done
    
    echo "└─────────────┴──────────────────┴────────────┴─────────────────────────┘"
    echo ""
    
    # Check RabbitMQ queue
    echo -e "${BLUE}RabbitMQ Queue Status:${NC}"
    QUEUE_INFO=$(curl -s -u "${RABBITMQ_USER}:${RABBITMQ_PASSWORD}" \
        "http://localhost:15672/api/queues/%2F/cdmap_national" 2>/dev/null)
    
    if [[ -n "$QUEUE_INFO" ]]; then
        MESSAGES=$(echo $QUEUE_INFO | python3 -c "import sys,json; print(json.load(sys.stdin).get('messages', 0))" 2>/dev/null || echo "?")
        CONSUMERS=$(echo $QUEUE_INFO | python3 -c "import sys,json; print(json.load(sys.stdin).get('consumers', 0))" 2>/dev/null || echo "?")
        echo "  Queue: cdmap_national | Messages: ${MESSAGES} | Consumers: ${CONSUMERS}"
    else
        echo "  Unable to fetch queue info"
    fi
    echo ""
    
    echo -e "${YELLOW}Press Ctrl+C to exit${NC}"
    
    sleep 5
done
