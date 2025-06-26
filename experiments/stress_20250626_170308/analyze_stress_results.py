#!/usr/bin/env python3
import os
import re
import pandas as pd
import json

def extract_latency_stats(log_file):
    """Extract latency statistics from producer log file"""
    if not os.path.exists(log_file):
        return None
        
    with open(log_file, 'r') as f:
        content = f.read()
    
    stats = {}
    
    # Extract various percentiles and mean from the last RTT statistics block
    patterns = {
        'p50': r'P50 \(median\):\s*([\d.]+)\s*μs',
        'p90': r'P90:\s*([\d.]+)\s*μs',
        'p99': r'P99:\s*([\d.]+)\s*μs',
        'p999': r'P99\.9:\s*([\d.]+)\s*μs',
        'mean': r'Mean:\s*([\d.]+)\s*μs',
        'stddev': r'StdDev:\s*([\d.]+)\s*μs',
        'min': r'Min:\s*([\d.]+)\s*μs',
        'max': r'Max:\s*([\d.]+)\s*μs',
        'samples': r'Samples:\s*(\d+)'
    }
    
    # Find all RTT statistics blocks and use the last one (final results)
    rtt_blocks = re.findall(r'=== RTT Statistics.*?====================================', content, re.DOTALL)
    if rtt_blocks:
        last_block = rtt_blocks[-1]
        for metric, pattern in patterns.items():
            match = re.search(pattern, last_block)
            if match:
                if metric == 'samples':
                    stats[metric] = int(match.group(1))
                else:
                    stats[metric] = float(match.group(1))
    
    # Extract total messages sent
    msg_matches = re.findall(r'Messages:\s*(\d+)', content)
    if msg_matches:
        stats['total_messages'] = int(msg_matches[-1])
    
    # Extract error count
    error_matches = re.findall(r'Errors:\s*(\d+)', content)
    if error_matches:
        stats['errors'] = int(error_matches[-1])
    
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
        # Use producer_final.log as it contains the RTT statistics
        producer_log = os.path.join(exp_dir, 'producer_final.log')
        if os.path.exists(producer_log):
            stats = extract_latency_stats(producer_log)
            if stats:
                params = parse_experiment_name(exp_dir)
                result = {**params, **stats}
                results.append(result)
            else:
                print(f"Warning: No stats extracted from {producer_log}")
        else:
            print(f"Warning: producer_final.log not found in {exp_dir}")

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
            
            # Show impact of CPU stress (for 0 bandwidth - CPU stress only)
            cpu_impact = node_df[node_df['bandwidth'] == 0][['cpu_level', 'p50', 'p99', 'p999', 'mean', 'samples']]
            if not cpu_impact.empty:
                cpu_impact = cpu_impact.sort_values('cpu_level')
                print("\n    CPU Stress Impact (no network congestion):")
                print(cpu_impact.to_string(index=False, float_format='%.2f'))
            
            # Show node statistics summary
            print(f"\n    Summary for {node}:")
            summary = node_df.groupby('cpu_level').agg({
                'p50': 'mean',
                'p99': 'mean', 
                'p999': 'mean',
                'mean': 'mean',
                'samples': 'mean',
                'errors': 'sum'
            }).round(2)
            print(summary.to_string())
    
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

# Plot 1: CPU stress impact on P99 latency (bandwidth = 0)
ax1 = axes[0, 0]
for scenario in df['scenario'].unique():
    scenario_df = df[(df['scenario'] == scenario) & (df['bandwidth'] == 0)]
    if not scenario_df.empty:
        scenario_df = scenario_df.groupby('cpu_level')['p99'].mean().reset_index()
        ax1.plot(scenario_df['cpu_level'], scenario_df['p99'], marker='o', label=scenario)
ax1.set_xlabel('CPU Load (%)')
ax1.set_ylabel('P99 Latency (μs)')
ax1.set_title('CPU Stress Impact on P99 Latency')
ax1.legend()

# Plot 2: CPU stress impact on mean latency
ax2 = axes[0, 1]
for scenario in df['scenario'].unique():
    scenario_df = df[(df['scenario'] == scenario) & (df['bandwidth'] == 0)]
    if not scenario_df.empty:
        scenario_df = scenario_df.groupby('cpu_level')['mean'].mean().reset_index()
        ax2.plot(scenario_df['cpu_level'], scenario_df['mean'], marker='o', label=scenario)
ax2.set_xlabel('CPU Load (%)')
ax2.set_ylabel('Mean Latency (μs)')
ax2.set_title('CPU Stress Impact on Mean Latency')
ax2.legend()

# Plot 3: Node comparison - P99 latency
ax3 = axes[1, 0]
node_comparison = df[df['bandwidth'] == 0].groupby(['producer_node', 'cpu_level'])['p99'].mean().reset_index()
for node in node_comparison['producer_node'].unique():
    node_df = node_comparison[node_comparison['producer_node'] == node]
    ax3.plot(node_df['cpu_level'], node_df['p99'], marker='o', label=node)
ax3.set_xlabel('CPU Load (%)')
ax3.set_ylabel('P99 Latency (μs)')
ax3.set_title('Node Performance Comparison (P99)')
ax3.legend()

# Plot 4: Latency distribution by scenario
ax4 = axes[1, 1]
scenarios = df['scenario'].unique()
cpu_levels = [10, 30, 50, 70, 90]
metrics = ['p50', 'p99', 'p999']
colors = ['blue', 'orange', 'red']

for i, metric in enumerate(metrics):
    scenario_means = []
    for scenario in scenarios:
        scenario_data = df[(df['scenario'] == scenario) & (df['bandwidth'] == 0)]
        mean_val = scenario_data[metric].mean()
        scenario_means.append(mean_val)
    
    x_pos = range(len(scenarios))
    ax4.bar([x + i*0.25 for x in x_pos], scenario_means, 0.25, label=metric, color=colors[i], alpha=0.7)

ax4.set_xlabel('Scenario')
ax4.set_ylabel('Latency (μs)')
ax4.set_title('Average Latency by Scenario')
ax4.set_xticks(range(len(scenarios)))
ax4.set_xticklabels(scenarios, rotation=45, ha='right')
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

