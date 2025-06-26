#!/bin/bash

# Quick stress test script for testing specific configurations
# Usage: ./quick_stress_test.sh <scenario> <producer_node> <cpu_level> <bandwidth_mbps> [duration]

if [ $# -lt 4 ]; then
    echo "Usage: $0 <scenario> <producer_node> <cpu_level> <bandwidth_mbps> [duration_seconds]"
    echo ""
    echo "Scenarios:"
    echo "  - same-node-no-service"
    echo "  - same-node-with-service"
    echo "  - different-node-no-service"
    echo "  - different-node-with-service"
    echo ""
    echo "Producer nodes:"
    echo "  - raspberrypi"
    echo "  - rtosubuntu-500tca-500sca"
    echo ""
    echo "Example: $0 different-node-with-service raspberrypi 50 100 60"
    exit 1
fi

SCENARIO=$1
PRODUCER_NODE=$2
CPU_LEVEL=$3
BANDWIDTH=$4
DURATION=${5:-60}  # Default 60 seconds

YAML_FILE="k8s/${SCENARIO}.yaml"
EXP_DIR="experiments/quick_test_$(date +%Y%m%d_%H%M%S)"

if [ ! -f "$YAML_FILE" ]; then
    echo "Error: YAML file not found: $YAML_FILE"
    exit 1
fi

echo "Running quick stress test:"
echo "  Scenario: $SCENARIO"
echo "  Producer Node: $PRODUCER_NODE"
echo "  CPU Level: $CPU_LEVEL%"
echo "  Bandwidth: ${BANDWIDTH}Mbps"
echo "  Duration: ${DURATION}s"
echo ""

# Create experiment directory
mkdir -p $EXP_DIR

# Function to prepare YAML with dynamic node selection
prepare_yaml_with_nodes() {
    local original_yaml=$1
    local target_yaml=$2
    local scenario_type=$3  # "same-node" or "different-node"
    local node_name=$4
    
    cp "$original_yaml" "$target_yaml"
    
    if [[ "$scenario_type" == "same-node" ]]; then
        # For same-node tests: both producer and consumer on the same node
        sed -i "s/NODE_NAME_PLACEHOLDER/$node_name/g" "$target_yaml"
        echo "Configured same-node test: both pods on $node_name"
    elif [[ "$scenario_type" == "different-node" ]]; then
        # For different-node tests: consumer fixed, producer dynamic
        sed -i "s/PRODUCER_NODE_PLACEHOLDER/$node_name/g" "$target_yaml"
        echo "Configured different-node test: consumer on rubikpi, producer on $node_name"
    fi
}

# Determine scenario type
SCENARIO_TYPE="different-node"  # default
if [[ "$SCENARIO" == *"same-node"* ]]; then
    SCENARIO_TYPE="same-node"
fi

# Prepare YAML with dynamic node configuration
prepare_yaml_with_nodes "$YAML_FILE" "$EXP_DIR/deployment.yaml" "$SCENARIO_TYPE" "$PRODUCER_NODE"

# Apply main workload
echo "Deploying main workload..."
kubectl apply -f $EXP_DIR/deployment.yaml

# Wait for pods
echo "Waiting for pods to be ready..."
sleep 10

# Apply CPU stress
echo "Applying CPU stress at $CPU_LEVEL%..."
cat > $EXP_DIR/stress-cpu.yaml <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: stress-cpu-quick
  labels:
    app: stress-cpu
spec:
  nodeSelector:
    kubernetes.io/hostname: $PRODUCER_NODE
  containers:
  - name: stress-ng
    image: colinianking/stress-ng
    command: ["stress-ng"]
    args:
      - "--cpu"
      - "0"
      - "--cpu-load"
      - "$CPU_LEVEL"
      - "--timeout"
      - "${DURATION}s"
      - "--metrics-brief"
EOF

kubectl apply -f $EXP_DIR/stress-cpu.yaml

# Apply network stress if bandwidth < 1000
if [ $BANDWIDTH -lt 1000 ]; then
    echo "Applying network bandwidth limit of ${BANDWIDTH}Mbps..."
    
    # Create iperf3 server
    cat > $EXP_DIR/iperf3-server.yaml <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: iperf3-server-quick
  labels:
    app: iperf3-server
spec:
  nodeSelector:
    kubernetes.io/hostname: $PRODUCER_NODE
  containers:
  - name: iperf3
    image: networkstatic/iperf3:latest
    command: ["iperf3"]
    args: ["-s", "-p", "5201"]
EOF

    kubectl apply -f $EXP_DIR/iperf3-server.yaml
    sleep 5
    
    # Wait for iperf3 server to be ready
    echo "Waiting for iperf3 server to be ready..."
    sleep 10
    
    # Create iperf3 client
    cat > $EXP_DIR/iperf3-client.yaml <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: iperf3-client-quick
  labels:
    app: iperf3-client
spec:
  containers:
  - name: iperf3
    image: networkstatic/iperf3:latest
    command: ["sh", "-c"]
    args:
      - |
        sleep 5
        # Try to resolve server IP
        SERVER_IP=\$(getent hosts iperf3-server-quick.default.svc.cluster.local | awk '{ print \$1 }')
        if [ -z "\$SERVER_IP" ]; then
          echo "Trying to resolve iperf3-server-quick directly..."
          SERVER_IP=\$(getent hosts iperf3-server-quick | awk '{ print \$1 }')
        fi
        if [ -z "\$SERVER_IP" ]; then
          echo "Failed to resolve iperf3 server, using service name"
          SERVER_IP="iperf3-server-quick"
        fi
        echo "Connecting to iperf3 server at \$SERVER_IP"
        iperf3 -c \$SERVER_IP -p 5201 -b ${BANDWIDTH}M -t $DURATION || echo "iperf3 test completed"
    resources:
      requests:
        cpu: "100m"
        memory: "64Mi"
      limits:
        cpu: "500m"
        memory: "128Mi"
EOF

    kubectl apply -f $EXP_DIR/iperf3-client.yaml
fi

# Start monitoring in background
echo ""
echo "Starting monitoring..."
./scripts/monitor_stress_experiment.sh &
MONITOR_PID=$!

# Wait for experiment duration
echo "Running experiment for ${DURATION}s..."
sleep $DURATION

# Stop monitoring
kill $MONITOR_PID 2>/dev/null

# Wait a bit more for final results
echo "Waiting for final results..."
sleep 5

# Collect results
echo ""
echo "Collecting results..."

# Get pod names based on scenario
if [[ "$SCENARIO" == *"same-node"* ]]; then
    CONSUMER_POD=$(kubectl get pods -l app=consumer-same -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    PRODUCER_POD=$(kubectl get pods -l app=producer-same -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
else
    CONSUMER_POD=$(kubectl get pods -l app=consumer-diff -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    PRODUCER_POD=$(kubectl get pods -l app=producer-diff -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
fi

# Save logs with better error handling
if [ -n "$CONSUMER_POD" ]; then
    kubectl logs $CONSUMER_POD > $EXP_DIR/consumer.log 2>&1
    echo "Consumer logs saved from pod: $CONSUMER_POD"
else
    echo "Warning: Consumer pod not found"
    echo "Consumer pod not found" > $EXP_DIR/consumer.log
fi

if [ -n "$PRODUCER_POD" ]; then
    kubectl logs $PRODUCER_POD > $EXP_DIR/producer.log 2>&1
    echo "Producer logs saved from pod: $PRODUCER_POD"
else
    echo "Warning: Producer pod not found"
    echo "Producer pod not found" > $EXP_DIR/producer.log
fi
kubectl logs stress-cpu-quick > $EXP_DIR/stress-cpu.log 2>&1

if [ $BANDWIDTH -lt 1000 ]; then
    kubectl logs iperf3-client-quick > $EXP_DIR/iperf3-client.log 2>&1
fi

# Save resource usage
kubectl top nodes > $EXP_DIR/node_resources.txt 2>&1
kubectl top pods > $EXP_DIR/pod_resources.txt 2>&1

# Extract key metrics
echo ""
echo "=== Quick Test Results ==="
echo "Experiment directory: $EXP_DIR"
echo ""

# Pod placement verification
echo "Pod Placement:"
if [ -n "$CONSUMER_POD" ]; then
    CONSUMER_NODE=$(kubectl get pod $CONSUMER_POD -o jsonpath='{.spec.nodeName}' 2>/dev/null)
    echo "  Consumer: $CONSUMER_POD on node $CONSUMER_NODE"
fi
if [ -n "$PRODUCER_POD" ]; then
    PRODUCER_NODE=$(kubectl get pod $PRODUCER_POD -o jsonpath='{.spec.nodeName}' 2>/dev/null)
    echo "  Producer: $PRODUCER_POD on node $PRODUCER_NODE"
fi
echo ""

echo "Latency Statistics:"
if [ -f "$EXP_DIR/producer.log" ] && [ -s "$EXP_DIR/producer.log" ]; then
    # Try different patterns for latency statistics
    if grep -q "RTT Statistics" "$EXP_DIR/producer.log"; then
        tail -30 "$EXP_DIR/producer.log" | grep -A 10 "RTT Statistics" | tail -10
    elif grep -q "P50" "$EXP_DIR/producer.log"; then
        tail -20 "$EXP_DIR/producer.log" | grep -E "(P50|P90|P99|Mean|Packet loss|RTT)" | tail -5
    else
        echo "  Searching for latency data..."
        tail -20 "$EXP_DIR/producer.log" | grep -E "(latency|rtt|RTT|ms|μs)" | tail -5
        if [ $? -ne 0 ]; then
            echo "  No latency statistics found. Producer log contents:"
            tail -10 "$EXP_DIR/producer.log"
        fi
    fi
else
    echo "  Producer log not available or empty"
fi

# Cleanup
echo ""
echo "Cleaning up..."
kubectl delete -f $EXP_DIR/deployment.yaml
kubectl delete -f $EXP_DIR/stress-cpu.yaml
if [ $BANDWIDTH -lt 1000 ]; then
    kubectl delete -f $EXP_DIR/iperf3-server.yaml
    kubectl delete -f $EXP_DIR/iperf3-client.yaml
fi

echo ""
echo "Quick test completed! Results saved to: $EXP_DIR"