#!/bin/bash

REGISTRY="your-registry.com"
EXPERIMENT_BASE_DIR="experiments/k8s_dynamic_$(date +%Y%m%d_%H%M%S)"
mkdir -p $EXPERIMENT_BASE_DIR

# Node configuration
AVAILABLE_NODES=("raspberrypi" "rubkipi" "rtosubuntu-500tca-500sca")
CONSUMER_FIXED_NODE="raspberrypi"  # Fixed consumer node for different-node tests

# Function to find pod name
find_pod_name() {
    local pod_type=$1  # "consumer" or "producer"
    local yaml_file=$2
    
    # Extract pod name from YAML file
    local pod_name=""
    local in_pod_section=false
    local found_metadata=false
    
    while IFS= read -r line; do
        # Check for Pod section start
        if [[ "$line" =~ ^kind:[[:space:]]*Pod ]]; then
            in_pod_section=true
            found_metadata=false
        elif [[ "$line" =~ ^--- ]] || [[ "$line" =~ ^apiVersion: ]]; then
            in_pod_section=false
            found_metadata=false
        fi
        
        # Find metadata section
        if [[ "$in_pod_section" == "true" ]] && [[ "$line" =~ ^metadata: ]]; then
            found_metadata=true
        fi
        
        # Find name in metadata
        if [[ "$found_metadata" == "true" ]] && [[ "$line" =~ ^[[:space:]]+name:[[:space:]]*(.*) ]]; then
            local current_pod_name="${BASH_REMATCH[1]}"
            
            # Find appropriate pod by type
            if [[ "$pod_type" == "consumer" ]] && [[ "$current_pod_name" =~ consumer ]]; then
                pod_name="$current_pod_name"
                break
            elif [[ "$pod_type" == "producer" ]] && [[ "$current_pod_name" =~ producer ]]; then
                pod_name="$current_pod_name"
                break
            fi
        fi
    done < "$yaml_file"
    
    # Check if pod actually exists
    if [ ! -z "$pod_name" ] && kubectl get pod "$pod_name" &>/dev/null; then
        echo "$pod_name"
    else
        # Fallback: find by label
        local label="app=$pod_type"
        kubectl get pods -l "$label" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
    fi
}

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
        echo "Configured different-node test: consumer on $CONSUMER_FIXED_NODE, producer on $node_name"
    fi
}

# Function to run experiment
run_experiment() {
    local yaml_file=$1
    local experiment_name=$2
    local duration=$3
    local scenario_type=$4
    local node_name=$5
    
    echo "========================================="
    echo "Starting experiment: $experiment_name"
    echo "Node configuration: $node_name"
    echo "========================================="
    
    # Create experiment directory
    local exp_dir="$EXPERIMENT_BASE_DIR/$experiment_name"
    mkdir -p $exp_dir
    
    # Prepare YAML with dynamic node configuration
    local dynamic_yaml="$exp_dir/deployment.yaml"
    prepare_yaml_with_nodes "$yaml_file" "$dynamic_yaml" "$scenario_type" "$node_name"
    
    # Apply YAML
    kubectl apply -f "$dynamic_yaml"
    
    # Wait for pods to be ready
    echo "Waiting for pods to be ready..."
    
    local max_wait=60
    local wait_time=0
    local pods_ready=false
    
    while [ $wait_time -lt $max_wait ]; do
        # Check pod names from YAML file
        local temp_consumer=$(find_pod_name "consumer" "$dynamic_yaml")
        local temp_producer=$(find_pod_name "producer" "$dynamic_yaml")
        
        if [ ! -z "$temp_consumer" ] && [ ! -z "$temp_producer" ]; then
            # Check if both pods are running
            local consumer_status=$(kubectl get pod "$temp_consumer" -o jsonpath='{.status.phase}' 2>/dev/null)
            local producer_status=$(kubectl get pod "$temp_producer" -o jsonpath='{.status.phase}' 2>/dev/null)
            
            if [ "$consumer_status" == "Running" ] && [ "$producer_status" == "Running" ]; then
                echo "Both pods are running!"
                pods_ready=true
                break
            fi
        fi
        
        echo "Waiting for pods... ($wait_time/$max_wait seconds)"
        sleep 5
        wait_time=$((wait_time + 5))
    done
    
    if [ "$pods_ready" != "true" ]; then
        echo "WARNING: Pods may not be fully ready after $max_wait seconds"
    fi
    
    # Additional wait for containers to fully start
    sleep 5
    
    # Save pod status
    kubectl get pods -o wide > $exp_dir/pod_status.txt
    
    # Find pod names
    echo "Finding pods..."
    
    # Consumer Pod
    consumer_pod=$(find_pod_name "consumer" "$dynamic_yaml")
    if [ ! -z "$consumer_pod" ]; then
        echo "Found consumer pod: $consumer_pod"
    else
        echo "WARNING: Consumer pod not found"
    fi
    
    # Producer Pod
    producer_pod=$(find_pod_name "producer" "$dynamic_yaml")
    if [ ! -z "$producer_pod" ]; then
        echo "Found producer pod: $producer_pod"
    else
        echo "WARNING: Producer pod not found"
    fi
    
    # Start log streaming
    if [ ! -z "$consumer_pod" ]; then
        echo "Starting log collection for consumer: $consumer_pod"
        kubectl logs -f $consumer_pod > $exp_dir/consumer.log 2>&1 &
        CONSUMER_LOG_PID=$!
    fi
    
    if [ ! -z "$producer_pod" ]; then
        echo "Starting log collection for producer: $producer_pod"
        kubectl logs -f $producer_pod > $exp_dir/producer.log 2>&1 &
        PRODUCER_LOG_PID=$!
    fi
    
    # Record experiment info
    cat > $exp_dir/experiment_info.txt <<EOF
Experiment: $experiment_name
Start time: $(date)
Duration: $duration seconds
Consumer Pod: $consumer_pod
Producer Pod: $producer_pod
Node Configuration: $node_name ($scenario_type)
EOF

    # Save pod descriptions
    kubectl describe pods > $exp_dir/pod_descriptions.txt
    
    # Save all pods list
    kubectl get pods --all-namespaces > $exp_dir/all_pods.txt
    
    # Run for specified duration
    echo "Running experiment for $duration seconds..."
    
    # Progress indicator
    for i in $(seq 1 $((duration/60))); do
        echo "Progress: $i/$((duration/60)) minutes..."
        sleep 60
    done
    
    # Handle remaining time
    remaining=$((duration % 60))
    if [ $remaining -gt 0 ]; then
        sleep $remaining
    fi
    
    # Stop log collection
    if [ ! -z "$CONSUMER_LOG_PID" ]; then
        kill $CONSUMER_LOG_PID 2>/dev/null
    fi
    if [ ! -z "$PRODUCER_LOG_PID" ]; then
        kill $PRODUCER_LOG_PID 2>/dev/null
    fi
    
    # Collect final logs
    if [ ! -z "$consumer_pod" ]; then
        kubectl logs $consumer_pod --tail=1000 > $exp_dir/consumer_final.log 2>&1
    fi
    
    if [ ! -z "$producer_pod" ]; then
        kubectl logs $producer_pod --tail=1000 > $exp_dir/producer_final.log 2>&1
    fi
    
    # Save pod events
    kubectl get events --field-selector involvedObject.kind=Pod > $exp_dir/pod_events.txt
    
    # Save resource usage
    kubectl top pods > $exp_dir/resource_usage.txt 2>&1
    
    # Cleanup
    kubectl delete -f "$dynamic_yaml"
    
    echo "Experiment completed: $experiment_name"
    echo "Results saved to: $exp_dir"
    echo "Consumer pod was: $consumer_pod"
    echo "Producer pod was: $producer_pod"
    
    # Wait before next experiment
    sleep 30
}

# Build and push images (optional)
# echo "Building and pushing Docker images..."
# make build

# Run experiments for each node and scenario
echo "Starting dynamic node experiments..."
echo "Available nodes: ${AVAILABLE_NODES[@]}"
echo "Consumer fixed node (for different-node tests): $CONSUMER_FIXED_NODE"
echo ""

# Same-node experiments
for node in "${AVAILABLE_NODES[@]}"; do
    echo "Testing same-node scenarios on: $node"
    
    if [ -f "k8s/same-node-no-service.yaml" ]; then
        run_experiment "k8s/same-node-no-service.yaml" "same_node_no_service_${node}" 600 "same-node" "$node"
    fi
    
    if [ -f "k8s/same-node-with-service.yaml" ]; then
        run_experiment "k8s/same-node-with-service.yaml" "same_node_with_service_${node}" 600 "same-node" "$node"
    fi
done

# Different-node experiments (producer on different nodes, consumer fixed)
for node in "${AVAILABLE_NODES[@]}"; do
    if [ "$node" != "$CONSUMER_FIXED_NODE" ]; then
        echo "Testing different-node scenarios with producer on: $node"
        
        if [ -f "k8s/different-node-no-service.yaml" ]; then
            run_experiment "k8s/different-node-no-service.yaml" "different_node_no_service_producer_${node}" 600 "different-node" "$node"
        fi
        
        if [ -f "k8s/different-node-with-service.yaml" ]; then
            run_experiment "k8s/different-node-with-service.yaml" "different_node_with_service_producer_${node}" 600 "different-node" "$node"
        fi
    fi
done

# Generate results summary
echo "========================================="
echo "All experiments completed!"
echo "Results directory: $EXPERIMENT_BASE_DIR"
echo "========================================="

# Create analysis script
cat > $EXPERIMENT_BASE_DIR/analyze_dynamic_results.py << 'EOF'
#!/usr/bin/env python3
import os
import re
import pandas as pd

def extract_latency_stats(log_file):
    """Extract latency statistics from log file"""
    if not os.path.exists(log_file):
        return None
        
    with open(log_file, 'r') as f:
        content = f.read()
    
    stats = {}
    
    # Extract various metrics
    patterns = {
        'p50': r'P50.*?:\s*([\d.]+)\s*μs',
        'p90': r'P90.*?:\s*([\d.]+)\s*μs', 
        'p99': r'P99\s*:\s*([\d.]+)\s*μs',
        'p999': r'P99\.9\s*:\s*([\d.]+)\s*μs',
        'mean': r'Mean:\s*([\d.]+)\s*μs',
        'stddev': r'StdDev:\s*([\d.]+)\s*μs'
    }
    
    for metric, pattern in patterns.items():
        matches = re.findall(pattern, content)
        if matches:
            values = [float(x) for x in matches]
            stats[metric] = sum(values) / len(values)
    
    # Extract packet loss
    loss_match = re.search(r'Packet loss:\s*([\d.]+)%', content)
    if loss_match:
        stats['packet_loss'] = float(loss_match.group(1))
    
    return stats

def parse_experiment_name(exp_name):
    """Parse experiment name to extract parameters"""
    params = {}
    
    if 'same_node' in exp_name:
        params['test_type'] = 'same_node'
        if 'no_service' in exp_name:
            params['service_type'] = 'no_service'
        else:
            params['service_type'] = 'with_service'
        
        # Extract node name
        parts = exp_name.split('_')
        if len(parts) >= 4:
            params['node'] = parts[-1]
    
    elif 'different_node' in exp_name:
        params['test_type'] = 'different_node'
        if 'no_service' in exp_name:
            params['service_type'] = 'no_service'
        else:
            params['service_type'] = 'with_service'
            
        # Extract producer node
        if 'producer_' in exp_name:
            producer_part = exp_name.split('producer_')[-1]
            params['producer_node'] = producer_part
    
    return params

# Analyze experiments
results = []
for exp_dir in sorted(os.listdir('.')):
    if os.path.isdir(exp_dir) and exp_dir not in ['__pycache__', '.git']:
        consumer_log = os.path.join(exp_dir, 'consumer.log')
        if os.path.exists(consumer_log):
            stats = extract_latency_stats(consumer_log)
            if stats:
                params = parse_experiment_name(exp_dir)
                result = {**params, **stats}
                results.append(result)

# Create DataFrame and analyze
if results:
    df = pd.DataFrame(results)
    df.to_csv('dynamic_node_results.csv', index=False)
    
    print("\n=== Dynamic Node Experiment Results ===\n")
    
    # Same-node comparison
    same_node_df = df[df['test_type'] == 'same_node']
    if not same_node_df.empty:
        print("Same-Node Performance Comparison:")
        print("-" * 50)
        for service in same_node_df['service_type'].unique():
            service_df = same_node_df[same_node_df['service_type'] == service]
            print(f"\n{service}:")
            comparison = service_df[['node', 'p50', 'p99', 'p999', 'mean']].sort_values('node')
            print(comparison.to_string(index=False))
    
    # Different-node comparison
    diff_node_df = df[df['test_type'] == 'different_node']
    if not diff_node_df.empty:
        print("\n\nDifferent-Node Performance Comparison:")
        print("-" * 50)
        for service in diff_node_df['service_type'].unique():
            service_df = diff_node_df[diff_node_df['service_type'] == service]
            print(f"\n{service}:")
            comparison = service_df[['producer_node', 'p50', 'p99', 'p999', 'mean']].sort_values('producer_node')
            print(comparison.to_string(index=False))
    
    print(f"\n\nDetailed results saved to: dynamic_node_results.csv")
    
else:
    print("No experiment results found to analyze")
EOF

chmod +x $EXPERIMENT_BASE_DIR/analyze_dynamic_results.py

# Create summary file
cat > $EXPERIMENT_BASE_DIR/summary.txt <<EOF
Dynamic Node Experiment Summary
==============================
Date: $(date)
Base Directory: $EXPERIMENT_BASE_DIR

Node Configuration:
- Available nodes: ${AVAILABLE_NODES[@]}
- Consumer fixed node (different-node tests): $CONSUMER_FIXED_NODE

Experiments conducted:
1. Same-node tests: Both pods on each available node
2. Different-node tests: Consumer fixed, producer on different nodes

Each experiment ran for 600 seconds (10 minutes).

To analyze results:
cd $EXPERIMENT_BASE_DIR
python3 analyze_dynamic_results.py
EOF

echo ""
echo "Run the following to analyze results:"
echo "cd $EXPERIMENT_BASE_DIR && python3 analyze_dynamic_results.py"