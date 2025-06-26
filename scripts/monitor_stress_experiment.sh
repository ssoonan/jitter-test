#!/bin/bash

# Script to monitor running stress experiments in real-time
# Usage: ./monitor_stress_experiment.sh

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

clear

while true; do
    # Clear screen and move cursor to top
    printf '\033[2J\033[H'
    
    echo -e "${GREEN}=== Container Latency Stress Test Monitor ===${NC}"
    echo -e "Time: $(date '+%Y-%m-%d %H:%M:%S')\n"
    
    # Show running pods
    echo -e "${BLUE}Active Pods:${NC}"
    kubectl get pods -o wide | grep -E "(consumer|producer|stress-|iperf3-)" | while read line; do
        if echo "$line" | grep -q "Running"; then
            echo -e "${GREEN}✓${NC} $line"
        else
            echo -e "${YELLOW}⚠${NC} $line"
        fi
    done
    
    echo -e "\n${BLUE}Node Resource Usage:${NC}"
    kubectl top nodes 2>/dev/null || echo "Metrics not available"
    
    echo -e "\n${BLUE}Pod Resource Usage:${NC}"
    kubectl top pods 2>/dev/null | grep -E "(consumer|producer|stress-|iperf3-)" || echo "No stress pods running"
    
    # Show latest latency stats from producer
    echo -e "\n${BLUE}Latest Latency Statistics:${NC}"
    # Try different producer pod labels in correct order
    producer_pod=$(kubectl get pods -l app=producer-diff -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ -z "$producer_pod" ]; then
        producer_pod=$(kubectl get pods -l app=producer -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    fi
    
    if [ ! -z "$producer_pod" ]; then
        kubectl logs $producer_pod --tail=20 2>/dev/null | grep -E "(RTT Statistics|P50|P99|Mean|Packet loss)" | tail -5
    else
        echo "No producer pod running"
    fi
    
    # Show stress-ng output if available
    echo -e "\n${BLUE}CPU Stress Status:${NC}"
    stress_pod=$(kubectl get pods -l app=stress-cpu -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ -z "$stress_pod" ]; then
        # Try the quick test stress pod
        stress_pod=$(kubectl get pods --field-selector metadata.name=stress-cpu-quick -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    fi
    
    if [ ! -z "$stress_pod" ]; then
        kubectl logs $stress_pod --tail=5 2>/dev/null | grep -E "(stress-ng|cpu)" || echo "Waiting for stress output..."
    else
        echo "No CPU stress pod running"
    fi
    
    # Show iperf3 status if available  
    iperf_client=$(kubectl get pods -l app=iperf3-client -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ -z "$iperf_client" ]; then
        # Try the quick test iperf3 client pod
        iperf_client=$(kubectl get pods --field-selector metadata.name=iperf3-client-quick -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    fi
    
    if [ ! -z "$iperf_client" ]; then
        echo -e "\n${BLUE}Network Stress Status:${NC}"
        kubectl logs $iperf_client --tail=3 2>/dev/null | grep -E "(Mbits/sec|bandwidth)" || echo "Waiting for iperf3 output..."
    fi
    
    echo -e "\n${YELLOW}Press Ctrl+C to exit${NC}"
    
    # Update every 5 seconds
    sleep 5
done