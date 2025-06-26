# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Container Latency Test is a distributed network latency measurement system designed to evaluate Round-Trip Time (RTT) and jitter characteristics in containerized environments. It uses a producer-consumer pattern where the producer sends 4KB messages and measures the RTT based on acknowledgments from the consumer.

## Common Development Commands

### Build Commands
```bash
# Build multi-platform Docker images and push to registry
make build

# Build Go binaries locally
cd consumer && go build -o consumer main.go
cd producer && go build -o producer main.go
```

### Run Commands
```bash
# Run locally without containers
make run-local

# Run with Docker Compose
docker-compose up

# Run full Kubernetes experiment suite (basic)
./run_k8s_experiments.sh

# Run dynamic node experiments
./run_k8s_experiments_dynamic.sh

# Run stress experiments with CPU and network load
./run_stress_experiments.sh

# Run quick stress test
./scripts/quick_stress_test.sh <scenario> <node> <cpu%> <bandwidth_mbps> [duration]

# Monitor running experiments
./scripts/monitor_stress_experiment.sh

# Run localhost performance test
./run_localhost_test.sh         # x86/amd64
./run_localhost_test_arm.sh     # ARM
```

### Kubernetes Deployment
```bash
# Deploy specific scenarios
kubectl apply -f k8s/same-node-no-service.yaml
kubectl apply -f k8s/same-node-with-service.yaml
kubectl apply -f k8s/different-node-no-service.yaml
kubectl apply -f k8s/different-node-with-service.yaml

# Check status
kubectl get pods -o wide
kubectl logs -f <pod-name>
```

## Architecture

### Component Interaction
- **Producer**: Sends 4KB messages at configurable intervals (default 10ms), tracks send times, calculates RTT statistics
- **Consumer**: Listens on TCP port 8080, immediately acknowledges received messages, tracks packet loss

### Communication Protocol
- TCP-based with binary encoding (BigEndian)
- Message structure: sequence number (uint64) + timestamp (int64) + padding
- TCP optimizations: Nagle disabled, 64KB buffers, persistent connections

### Key Design Patterns
- CPU thread locking for consistent performance
- Lock-free statistics collection using sync.Map
- Real-time percentile analysis (P50, P90, P99, P99.9)
- Automatic reconnection and retry logic
- Graceful shutdown handling (SIGINT, SIGTERM)

### Deployment Scenarios
1. **Same Node Without Service**: Direct pod-to-pod on same host
2. **Same Node With Service**: Through Kubernetes Service on same host  
3. **Different Nodes Without Service**: Direct pod-to-pod across network
4. **Different Nodes With Service**: Through Kubernetes Service across network

### Environment Variables
- Consumer: `LISTEN_PORT=8080`
- Producer: `TARGET_ADDRESS=consumer:8080`, `SEND_INTERVAL_MS=10`

## Development Notes
- Multi-architecture support (amd64, arm64)
- Experiments output to `experiments/` directory
- Resource limits: 1 CPU, 256Mi memory per pod
- Uses `taskset` for CPU affinity in localhost tests
- Dynamic node selection: same-node tests place both pods on specified node, different-node tests place consumer on `rtosubuntu-500tca-500sca` and producer on specified node
- Stress testing uses `alexeiled/stress-ng` for multi-arch CPU stress and `iperf3` for network congestion