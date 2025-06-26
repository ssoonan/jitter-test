#!/usr/bin/env python3
import pandas as pd
import matplotlib.pyplot as plt
import numpy as np

# Load data
df = pd.read_csv('stress_experiment_results.csv')
print(f"Loaded {len(df)} rows of data")
print(f"Producer nodes: {df['producer_node'].unique()}")
print(f"CPU levels: {sorted(df['cpu_level'].unique())}")

# Group by node and CPU level, taking the mean of duplicates
df_grouped = df.groupby(['producer_node', 'cpu_level']).agg({
    'p50': 'mean',
    'p99': 'mean', 
    'p999': 'mean',
    'mean': 'mean',
    'stddev': 'mean',
    'samples': 'sum',
    'errors': 'sum'
}).reset_index()

print(f"After grouping: {len(df_grouped)} rows")
print("Grouped data preview:")
print(df_grouped[['producer_node', 'cpu_level', 'p50', 'p99', 'p999', 'mean']].to_string())

# Set style and colors
plt.style.use('default')
colors = ['#1f77b4', '#ff7f0e', '#2ca02c', '#d62728', '#9467bd']

# Create figure with subplots
fig, axes = plt.subplots(2, 2, figsize=(16, 12))
fig.suptitle('Container Latency Under CPU Stress - Node Comparison', fontsize=16, fontweight='bold')

nodes = df_grouped['producer_node'].unique()
print(f"\nNodes to plot: {nodes}")

# Plot 1: CPU stress impact on P99 latency by node
ax1 = axes[0, 0]
for i, node in enumerate(nodes):
    node_df = df_grouped[df_grouped['producer_node'] == node].sort_values('cpu_level')
    
    # Friendly node names
    label = 'Raspberry Pi' if 'raspberrypi' in node else 'Ubuntu Server'
    
    ax1.plot(node_df['cpu_level'], node_df['p99'], 
             marker='o', linewidth=2.5, markersize=8, 
             label=label, color=colors[i])
             
ax1.set_xlabel('CPU Load (%)', fontsize=12)
ax1.set_ylabel('P99 Latency (μs)', fontsize=12)
ax1.set_title('CPU Stress Impact on P99 Latency', fontsize=14, fontweight='bold')
ax1.grid(True, alpha=0.3)
ax1.legend(fontsize=11)
ax1.set_xticks([10, 30, 50, 70, 90])

# Plot 2: CPU stress impact on mean latency by node
ax2 = axes[0, 1]
for i, node in enumerate(nodes):
    node_df = df_grouped[df_grouped['producer_node'] == node].sort_values('cpu_level')
    
    # Friendly node names
    label = 'Raspberry Pi' if 'raspberrypi' in node else 'Ubuntu Server'
    
    ax2.plot(node_df['cpu_level'], node_df['mean'], 
             marker='s', linewidth=2.5, markersize=8, 
             label=label, color=colors[i])
ax2.set_xlabel('CPU Load (%)', fontsize=12)
ax2.set_ylabel('Mean Latency (μs)', fontsize=12)
ax2.set_title('CPU Stress Impact on Mean Latency', fontsize=14, fontweight='bold')
ax2.grid(True, alpha=0.3)
ax2.legend(fontsize=11)
ax2.set_xticks([10, 30, 50, 70, 90])

# Plot 3: Latency percentiles comparison (Raspberry Pi)
ax3 = axes[1, 0]
metrics = ['p50', 'p99', 'p999']
metric_labels = ['P50 (Median)', 'P99', 'P99.9']
markers = ['o', '^', 's']

# Use raspberrypi data for percentile comparison
rpi_data = df_grouped[df_grouped['producer_node'] == 'raspberrypi'].sort_values('cpu_level')

for i, (metric, label, marker) in enumerate(zip(metrics, metric_labels, markers)):
    ax3.plot(rpi_data['cpu_level'], rpi_data[metric], 
             marker=marker, linewidth=2.5, markersize=8, 
             label=label, color=colors[i])
ax3.set_xlabel('CPU Load (%)', fontsize=12)
ax3.set_ylabel('Latency (μs)', fontsize=12)
ax3.set_title('Latency Percentiles - Raspberry Pi', fontsize=14, fontweight='bold')
ax3.grid(True, alpha=0.3)
ax3.legend(fontsize=11)
ax3.set_xticks([10, 30, 50, 70, 90])

# Plot 4: Node Performance Comparison (Bar Chart)
ax4 = axes[1, 1]
metrics = ['p50', 'p99', 'p999']
metric_labels = ['P50', 'P99', 'P99.9']

# Calculate average latency across all CPU levels for each node
node_averages = df_grouped.groupby('producer_node')[metrics].mean()

# Friendly node names
node_labels = ['Raspberry Pi', 'Ubuntu Server']
x = np.arange(len(nodes))
width = 0.25

for i, (metric, label) in enumerate(zip(metrics, metric_labels)):
    values = [node_averages.loc[node, metric] for node in nodes]
    ax4.bar(x + i*width, values, width, label=label, color=colors[i], alpha=0.8)

ax4.set_xlabel('Node', fontsize=12)
ax4.set_ylabel('Average Latency (μs)', fontsize=12)
ax4.set_title('Average Latency Comparison by Node', fontsize=14, fontweight='bold')
ax4.set_xticks(x + width)
ax4.set_xticklabels(node_labels, fontsize=10)
ax4.legend(fontsize=11)
ax4.grid(True, alpha=0.3, axis='y')

plt.tight_layout()
print("\nSaving plot to stress_experiment_results.png...")
plt.savefig('stress_experiment_results.png', dpi=300, bbox_inches='tight')
print("Plot saved successfully!")

# Also create a simple version for display
plt.figure(figsize=(12, 8))
for i, node in enumerate(nodes):
    node_df = df_grouped[df_grouped['producer_node'] == node].sort_values('cpu_level')
    label = 'Raspberry Pi' if 'raspberrypi' in node else 'Ubuntu Server'
    plt.plot(node_df['cpu_level'], node_df['p99'], 
             marker='o', linewidth=3, markersize=10, 
             label=f'{label} (P99)', color=colors[i])

plt.xlabel('CPU Load (%)', fontsize=14)
plt.ylabel('P99 Latency (μs)', fontsize=14)
plt.title('CPU Stress Impact on P99 Latency by Node', fontsize=16, fontweight='bold')
plt.grid(True, alpha=0.3)
plt.legend(fontsize=12)
plt.xticks([10, 30, 50, 70, 90])
plt.tight_layout()
plt.savefig('simple_p99_comparison.png', dpi=300, bbox_inches='tight')
plt.show()