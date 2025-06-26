#!/bin/bash

EXPERIMENT_BASE_DIR="experiments/stress_$(date +%Y%m%d_%H%M%S)"
mkdir -p $EXPERIMENT_BASE_DIR

# Configuration
CPU_LEVELS=(10 30 50 70 90)
NETWORK_BANDWIDTH_LEVELS=(10 50 100 500 1000)  # Mbps
PRODUCER_NODES=("raspberrypi" "rtosubuntu-500tca-500sca")
SCENARIOS=("same-node-with-service" "different-node-with-service")
# SCENARIOS=("same-node-no-service" "same-node-with-service" "different-node-no-service" "different-node-with-service")
EXPERIMENT_DURATION=300  # 5 minutes per experiment

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to log with timestamp
log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1"
}

warning() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARNING:${NC} $1"
}

# Function to find pod name
find_pod_name() {
    local pod_type=$1
    local yaml_file=$2
    
    local pod_name=""
    local in_pod_section=false
    local found_metadata=false
    
    while IFS= read -r line; do
        if [[ "$line" =~ ^kind:[[:space:]]*Pod ]]; then
            in_pod_section=true
            found_metadata=false
        elif [[ "$line" =~ ^--- ]] || [[ "$line" =~ ^apiVersion: ]]; then
            in_pod_section=false
            found_metadata=false
        fi
        
        if [[ "$in_pod_section" == "true" ]] && [[ "$line" =~ ^metadata: ]]; then
            found_metadata=true
        fi
        
        if [[ "$found_metadata" == "true" ]] && [[ "$line" =~ ^[[:space:]]+name:[[:space:]]*(.*) ]]; then
            local current_pod_name="${BASH_REMATCH[1]}"
            
            if [[ "$pod_type" == "consumer" ]] && [[ "$current_pod_name" =~ consumer ]]; then
                pod_name="$current_pod_name"
                break
            elif [[ "$pod_type" == "producer" ]] && [[ "$current_pod_name" =~ producer ]]; then
                pod_name="$current_pod_name"
                break
            elif [[ "$pod_type" == "stress-cpu" ]] && [[ "$current_pod_name" =~ stress-cpu ]]; then
                pod_name="$current_pod_name"
                break
            elif [[ "$pod_type" == "iperf3-server" ]] && [[ "$current_pod_name" =~ iperf3-server ]]; then
                pod_name="$current_pod_name"
                break
            elif [[ "$pod_type" == "iperf3-client" ]] && [[ "$current_pod_name" =~ iperf3-client ]]; then
                pod_name="$current_pod_name"
                break
            fi
        fi
    done < "$yaml_file"
    
    if [ ! -z "$pod_name" ] && kubectl get pod "$pod_name" &>/dev/null; then
        echo "$pod_name"
    else
        local label="app=$pod_type"
        kubectl get pods -l "$label" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
    fi
}

# Function to wait for pod ready
wait_for_pod() {
    local pod_name=$1
    local max_wait=120
    local wait_time=0
    
    while [ $wait_time -lt $max_wait ]; do
        local pod_status=$(kubectl get pod "$pod_name" -o jsonpath='{.status.phase}' 2>/dev/null)
        if [ "$pod_status" == "Running" ]; then
            return 0
        fi
        sleep 5
        wait_time=$((wait_time + 5))
    done
    
    return 1
}

# Function to apply CPU stress
apply_cpu_stress() {
    local node=$1
    local cpu_level=$2
    local exp_dir=$3
    
    log "Applying CPU stress on node $node at $cpu_level% utilization"
    
    # Create stress-ng pod manifest
    cat > $exp_dir/stress-cpu-$node.yaml <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: stress-cpu-$node
spec:
  nodeSelector:
    kubernetes.io/hostname: $node
  containers:
  - name: stress-ng
    image: colinianking/stress-ng
    command: ["stress-ng"]
    args:
      - "--cpu"
      - "0"  # Use all available CPUs
      - "--cpu-load"
      - "$cpu_level"
      - "--timeout"
      - "${EXPERIMENT_DURATION}s"
      - "--metrics-brief"
    resources:
      requests:
        cpu: "100m"
        memory: "128Mi"
      limits:
        cpu: "2000m"
        memory: "256Mi"
EOF

    kubectl apply -f $exp_dir/stress-cpu-$node.yaml
    
    # Wait for stress pod to be ready
    local stress_pod="stress-cpu-$node"
    if wait_for_pod "$stress_pod"; then
        log "CPU stress pod ready on $node"
    else
        warning "CPU stress pod may not be ready on $node"
    fi
}

# Function to apply network congestion
apply_network_congestion() {
    local node=$1
    local bandwidth=$2
    local exp_dir=$3
    
    log "Applying network congestion on node $node with bandwidth limit ${bandwidth}Mbps"
    
    # Create iperf3 server pod
    cat > $exp_dir/iperf3-server-$node.yaml <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: iperf3-server-$node
  labels:
    app: iperf3-server
spec:
  nodeSelector:
    kubernetes.io/hostname: $node
  containers:
  - name: iperf3
    image: networkstatic/iperf3:latest
    command: ["iperf3"]
    args: ["-s", "-p", "5201"]
    ports:
    - containerPort: 5201
EOF

    # Create iperf3 client pod (will run on consumer node)
    cat > $exp_dir/iperf3-client-$node.yaml <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: iperf3-client-$node
spec:
  containers:
  - name: iperf3
    image: networkstatic/iperf3:latest
    command: ["sh", "-c"]
    args:
      - |
        SERVER_IP=\$(getent hosts iperf3-server-$node | awk '{ print \$1 }')
        if [ -z "\$SERVER_IP" ]; then
          echo "Failed to resolve iperf3-server-$node"
          exit 1
        fi
        echo "Connecting to iperf3 server at \$SERVER_IP"
        iperf3 -c \$SERVER_IP -p 5201 -b ${bandwidth}M -t $EXPERIMENT_DURATION
EOF

    kubectl apply -f $exp_dir/iperf3-server-$node.yaml
    
    # Wait for server to be ready
    local server_pod="iperf3-server-$node"
    if wait_for_pod "$server_pod"; then
        log "iperf3 server ready on $node"
        sleep 5  # Give server time to start listening
        kubectl apply -f $exp_dir/iperf3-client-$node.yaml
    else
        warning "iperf3 server pod may not be ready on $node"
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
        log "Configured same-node test: both pods on $node_name"
    elif [[ "$scenario_type" == "different-node" ]]; then
        # For different-node tests: consumer fixed, producer dynamic
        sed -i "s/PRODUCER_NODE_PLACEHOLDER/$node_name/g" "$target_yaml"
        log "Configured different-node test: consumer on rtosubuntu-500tca-500sca, producer on $node_name"
    fi
}

# Function to run stress experiment
run_stress_experiment() {
    local yaml_file=$1
    local scenario=$2
    local producer_node=$3
    local cpu_level=$4
    local bandwidth=$5
    
    local experiment_name="${scenario}_node-${producer_node}_cpu-${cpu_level}_bw-${bandwidth}"
    log "========================================="
    log "Starting experiment: $experiment_name"
    log "Producer Node: $producer_node"
    log "CPU Load: $cpu_level%"
    log "Network Bandwidth: ${bandwidth}Mbps"
    log "========================================="
    
    # Create experiment directory
    local exp_dir="$EXPERIMENT_BASE_DIR/$experiment_name"
    mkdir -p $exp_dir
    
    # Determine scenario type
    local scenario_type="different-node"  # default
    if [[ "$scenario" == *"same-node"* ]]; then
        scenario_type="same-node"
    fi
    
    # Prepare YAML with dynamic node configuration
    prepare_yaml_with_nodes "$yaml_file" "$exp_dir/deployment.yaml" "$scenario_type" "$producer_node"
    
    # Apply the main workload
    kubectl apply -f $exp_dir/deployment.yaml
    
    # Wait for main pods to be ready
    log "Waiting for workload pods to be ready..."
    local consumer_pod=$(find_pod_name "consumer" "$exp_dir/deployment.yaml")
    local producer_pod=$(find_pod_name "producer" "$exp_dir/deployment.yaml")
    
    if [ ! -z "$consumer_pod" ] && wait_for_pod "$consumer_pod"; then
        log "Consumer pod ready: $consumer_pod"
    else
        error "Consumer pod not ready"
    fi
    
    if [ ! -z "$producer_pod" ] && wait_for_pod "$producer_pod"; then
        log "Producer pod ready: $producer_pod"
    else
        error "Producer pod not ready"
    fi
    
    # Apply stress conditions
    apply_cpu_stress $producer_node $cpu_level $exp_dir
    
    # Apply network congestion only if bandwidth is less than 1000 Mbps
    if [ $bandwidth -lt 1000 ]; then
        apply_network_congestion $producer_node $bandwidth $exp_dir
    fi
    
    # Start log collection
    if [ ! -z "$consumer_pod" ]; then
        kubectl logs -f $consumer_pod > $exp_dir/consumer.log 2>&1 &
        CONSUMER_LOG_PID=$!
    fi
    
    if [ ! -z "$producer_pod" ]; then
        kubectl logs -f $producer_pod > $exp_dir/producer.log 2>&1 &
        PRODUCER_LOG_PID=$!
    fi
    
    # Collect stress logs
    kubectl logs -f stress-cpu-$producer_node > $exp_dir/stress-cpu.log 2>&1 &
    STRESS_LOG_PID=$!
    
    if [ $bandwidth -lt 1000 ]; then
        kubectl logs -f iperf3-client-$producer_node > $exp_dir/iperf3-client.log 2>&1 &
        IPERF_LOG_PID=$!
    fi
    
    # Record experiment info
    cat > $exp_dir/experiment_info.txt <<EOF
Experiment: $experiment_name
Start time: $(date)
Duration: $EXPERIMENT_DURATION seconds
Consumer Pod: $consumer_pod
Producer Pod: $producer_pod
Producer Node: $producer_node
CPU Stress Level: $cpu_level%
Network Bandwidth Limit: ${bandwidth}Mbps
EOF
    
    # Monitor resource usage during experiment
    log "Running experiment for $EXPERIMENT_DURATION seconds..."
    
    # Collect metrics every 30 seconds
    for i in $(seq 0 30 $EXPERIMENT_DURATION); do
        if [ $i -gt 0 ]; then
            sleep 30
        fi
        echo "=== Metrics at ${i}s ===" >> $exp_dir/resource_metrics.txt
        kubectl top nodes >> $exp_dir/resource_metrics.txt 2>&1
        echo "" >> $exp_dir/resource_metrics.txt
        kubectl top pods >> $exp_dir/resource_metrics.txt 2>&1
        echo "" >> $exp_dir/resource_metrics.txt
    done
    
    # Stop log collection
    [ ! -z "$CONSUMER_LOG_PID" ] && kill $CONSUMER_LOG_PID 2>/dev/null
    [ ! -z "$PRODUCER_LOG_PID" ] && kill $PRODUCER_LOG_PID 2>/dev/null
    [ ! -z "$STRESS_LOG_PID" ] && kill $STRESS_LOG_PID 2>/dev/null
    [ ! -z "$IPERF_LOG_PID" ] && kill $IPERF_LOG_PID 2>/dev/null
    
    # Collect final logs
    kubectl logs $consumer_pod --tail=1000 > $exp_dir/consumer_final.log 2>&1
    kubectl logs $producer_pod --tail=1000 > $exp_dir/producer_final.log 2>&1
    kubectl describe pods > $exp_dir/pod_descriptions.txt
    kubectl get events --field-selector involvedObject.kind=Pod > $exp_dir/pod_events.txt
    
    # Cleanup
    kubectl delete -f $exp_dir/deployment.yaml
    kubectl delete -f $exp_dir/stress-cpu-$producer_node.yaml 2>/dev/null
    kubectl delete -f $exp_dir/iperf3-server-$producer_node.yaml 2>/dev/null
    kubectl delete -f $exp_dir/iperf3-client-$producer_node.yaml 2>/dev/null
    
    log "Experiment completed: $experiment_name"
    
    # Wait before next experiment
    sleep 30
}

# Main execution
log "Starting stress experiments"
log "Base directory: $EXPERIMENT_BASE_DIR"

# Check if required tools are available
if ! command -v kubectl &> /dev/null; then
    error "kubectl not found. Please install kubectl."
    exit 1
fi

# Create summary of experiments to run
total_experiments=$((${#SCENARIOS[@]} * ${#PRODUCER_NODES[@]} * ${#CPU_LEVELS[@]} * ${#NETWORK_BANDWIDTH_LEVELS[@]}))
log "Total experiments to run: $total_experiments"
log "Estimated total time: $((total_experiments * (EXPERIMENT_DURATION + 30) / 60)) minutes"

# Run experiments
experiment_count=0
for scenario in "${SCENARIOS[@]}"; do
    yaml_file="k8s/${scenario}.yaml"
    
    if [ ! -f "$yaml_file" ]; then
        warning "YAML file not found: $yaml_file, skipping..."
        continue
    fi
    
    for producer_node in "${PRODUCER_NODES[@]}"; do
        for cpu_level in "${CPU_LEVELS[@]}"; do
            for bandwidth in "${NETWORK_BANDWIDTH_LEVELS[@]}"; do
                experiment_count=$((experiment_count + 1))
                log "Progress: $experiment_count/$total_experiments"
                
                run_stress_experiment "$yaml_file" "$scenario" "$producer_node" "$cpu_level" "$bandwidth"
            done
        done
    done
done

# Create analysis script
cat > $EXPERIMENT_BASE_DIR/analyze_stress_results.py << 'EOF'
#!/usr/bin/env python3
import os
import re
import pandas as pd
import json

def extract_latency_stats(log_file):
    """Extract latency statistics from log file"""
    if not os.path.exists(log_file):
        return None
        
    with open(log_file, 'r') as f:
        content = f.read()
    
    stats = {}
    
    # Extract various percentiles and mean
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
            # Take the average of all matches
            values = [float(x) for x in matches]
            stats[metric] = sum(values) / len(values)
    
    # Extract packet loss
    loss_match = re.search(r'Packet loss:\s*([\d.]+)%', content)
    if loss_match:
        stats['packet_loss'] = float(loss_match.group(1))
    
    return stats

def parse_experiment_name(exp_name):
    """Parse experiment name to extract parameters"""
    parts = exp_name.split('_')
    params = {}
    
    for part in parts:
        if 'node-' in part:
            params['producer_node'] = part.split('-', 1)[1]
        elif 'cpu-' in part:
            params['cpu_level'] = int(part.split('-')[1])
        elif 'bw-' in part:
            params['bandwidth'] = int(part.split('-')[1])
    
    # Extract scenario
    scenario_parts = []
    for part in parts:
        if 'node-' not in part and 'cpu-' not in part and 'bw-' not in part:
            scenario_parts.append(part)
    params['scenario'] = '_'.join(scenario_parts)
    
    return params

# Analyze all experiments
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

# Create DataFrame
if results:
    df = pd.DataFrame(results)
    
    # Save raw results
    df.to_csv('stress_experiment_results.csv', index=False)
    
    # Display summary statistics
    print("\n=== Stress Experiment Results Summary ===\n")
    
    # Group by scenario and show impact of CPU stress
    for scenario in df['scenario'].unique():
        print(f"\nScenario: {scenario}")
        scenario_df = df[df['scenario'] == scenario]
        
        for node in scenario_df['producer_node'].unique():
            print(f"\n  Producer Node: {node}")
            node_df = scenario_df[scenario_df['producer_node'] == node]
            
            # Show impact of CPU stress (at max bandwidth)
            max_bw = node_df['bandwidth'].max()
            cpu_impact = node_df[node_df['bandwidth'] == max_bw][['cpu_level', 'p50', 'p99', 'p999', 'mean']]
            cpu_impact = cpu_impact.sort_values('cpu_level')
            print("\n    CPU Stress Impact (at max bandwidth):")
            print(cpu_impact.to_string(index=False))
            
            # Show impact of network congestion (at median CPU level)
            median_cpu = 50
            if median_cpu in node_df['cpu_level'].values:
                net_impact = node_df[node_df['cpu_level'] == median_cpu][['bandwidth', 'p50', 'p99', 'p999', 'mean']]
                net_impact = net_impact.sort_values('bandwidth')
                print(f"\n    Network Congestion Impact (at {median_cpu}% CPU):")
                print(net_impact.to_string(index=False))
    
    # Create visualization script
    with open('visualize_results.py', 'w') as f:
        f.write('''#!/usr/bin/env python3
import pandas as pd
import matplotlib.pyplot as plt
import seaborn as sns

# Load data
df = pd.read_csv('stress_experiment_results.csv')

# Set style
plt.style.use('seaborn-v0_8-darkgrid')
sns.set_palette("husl")

# Create figure with subplots
fig, axes = plt.subplots(2, 2, figsize=(15, 12))
fig.suptitle('Container Latency Under Stress Conditions', fontsize=16)

# Plot 1: CPU stress impact on P99 latency
ax1 = axes[0, 0]
for scenario in df['scenario'].unique():
    scenario_df = df[(df['scenario'] == scenario) & (df['bandwidth'] == 1000)]
    scenario_df = scenario_df.groupby('cpu_level')['p99'].mean().reset_index()
    ax1.plot(scenario_df['cpu_level'], scenario_df['p99'], marker='o', label=scenario)
ax1.set_xlabel('CPU Load (%)')
ax1.set_ylabel('P99 Latency (μs)')
ax1.set_title('CPU Stress Impact on P99 Latency')
ax1.legend()

# Plot 2: Network congestion impact on P99 latency
ax2 = axes[0, 1]
for scenario in df['scenario'].unique():
    scenario_df = df[(df['scenario'] == scenario) & (df['cpu_level'] == 50)]
    scenario_df = scenario_df.groupby('bandwidth')['p99'].mean().reset_index()
    ax2.plot(scenario_df['bandwidth'], scenario_df['p99'], marker='o', label=scenario)
ax2.set_xlabel('Network Bandwidth (Mbps)')
ax2.set_ylabel('P99 Latency (μs)')
ax2.set_title('Network Congestion Impact on P99 Latency')
ax2.set_xscale('log')
ax2.legend()

# Plot 3: Heatmap of P99 latency
ax3 = axes[1, 0]
pivot_data = df[df['scenario'] == 'different-node-with-service'].pivot_table(
    values='p99', index='cpu_level', columns='bandwidth', aggfunc='mean'
)
sns.heatmap(pivot_data, annot=True, fmt='.0f', cmap='YlOrRd', ax=ax3)
ax3.set_title('P99 Latency Heatmap (Different Node with Service)')
ax3.set_xlabel('Network Bandwidth (Mbps)')
ax3.set_ylabel('CPU Load (%)')

# Plot 4: Node comparison
ax4 = axes[1, 1]
node_comparison = df[df['bandwidth'] == 1000].groupby(['producer_node', 'cpu_level'])['p99'].mean().reset_index()
for node in node_comparison['producer_node'].unique():
    node_df = node_comparison[node_comparison['producer_node'] == node]
    ax4.plot(node_df['cpu_level'], node_df['p99'], marker='o', label=node)
ax4.set_xlabel('CPU Load (%)')
ax4.set_ylabel('P99 Latency (μs)')
ax4.set_title('Node Performance Comparison')
ax4.legend()

plt.tight_layout()
plt.savefig('stress_experiment_results.png', dpi=300)
plt.show()
''')
    
    print("\n\nResults saved to:")
    print(f"  - stress_experiment_results.csv")
    print(f"  - Run 'python3 visualize_results.py' to generate plots")
    
else:
    print("No results found to analyze")

EOF

chmod +x $EXPERIMENT_BASE_DIR/analyze_stress_results.py

# Create summary
cat > $EXPERIMENT_BASE_DIR/summary.txt <<EOF
Stress Experiment Summary
========================
Date: $(date)
Base Directory: $EXPERIMENT_BASE_DIR

Experiment Configuration:
- CPU Stress Levels: ${CPU_LEVELS[@]}%
- Network Bandwidth Levels: ${NETWORK_BANDWIDTH_LEVELS[@]} Mbps
- Producer Nodes: ${PRODUCER_NODES[@]}
- Scenarios: ${SCENARIOS[@]}
- Duration per experiment: $EXPERIMENT_DURATION seconds
- Total experiments: $total_experiments

To analyze results:
cd $EXPERIMENT_BASE_DIR
python3 analyze_stress_results.py
EOF

log "========================================="
log "All stress experiments completed!"
log "Results directory: $EXPERIMENT_BASE_DIR"
log "========================================="
log ""
log "Run the following to analyze results:"
log "cd $EXPERIMENT_BASE_DIR && python3 analyze_stress_results.py"
