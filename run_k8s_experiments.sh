#!/bin/bash

REGISTRY="your-registry.com"
EXPERIMENT_BASE_DIR="experiments/k8s_$(date +%Y%m%d_%H%M%S)"
mkdir -p $EXPERIMENT_BASE_DIR

# 함수: Pod 이름 찾기
find_pod_name() {
    local pod_type=$1  # "consumer" or "producer"
    local yaml_file=$2
    
    # YAML 파일에서 해당 타입의 Pod 이름 추출
    # Pod 정의를 찾고, 그 다음에 오는 name을 추출
    local pod_name=""
    local in_pod_section=false
    local found_metadata=false
    
    while IFS= read -r line; do
        # Pod 섹션 시작 확인
        if [[ "$line" =~ ^kind:[[:space:]]*Pod ]]; then
            in_pod_section=true
            found_metadata=false
        elif [[ "$line" =~ ^--- ]] || [[ "$line" =~ ^apiVersion: ]]; then
            in_pod_section=false
            found_metadata=false
        fi
        
        # metadata 섹션 찾기
        if [[ "$in_pod_section" == "true" ]] && [[ "$line" =~ ^metadata: ]]; then
            found_metadata=true
        fi
        
        # metadata 내의 name 찾기
        if [[ "$found_metadata" == "true" ]] && [[ "$line" =~ ^[[:space:]]+name:[[:space:]]*(.*) ]]; then
            local current_pod_name="${BASH_REMATCH[1]}"
            
            # consumer 또는 producer 타입에 맞는 Pod 찾기
            if [[ "$pod_type" == "consumer" ]] && [[ "$current_pod_name" =~ consumer ]]; then
                pod_name="$current_pod_name"
                break
            elif [[ "$pod_type" == "producer" ]] && [[ "$current_pod_name" =~ producer ]]; then
                pod_name="$current_pod_name"
                break
            fi
        fi
    done < "$yaml_file"
    
    # Pod이 실제로 존재하는지 확인
    if [ ! -z "$pod_name" ] && kubectl get pod "$pod_name" &>/dev/null; then
        echo "$pod_name"
    else
        # Pod이 없으면 레이블로 찾기 (fallback)
        local label="app=$pod_type"
        kubectl get pods -l "$label" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
    fi
}

# 함수: 실험 실행
run_experiment() {
    local yaml_file=$1
    local experiment_name=$2
    local duration=$3
    
    echo "========================================="
    echo "Starting experiment: $experiment_name"
    echo "========================================="
    
    # 실험별 디렉토리 생성
    local exp_dir="$EXPERIMENT_BASE_DIR/$experiment_name"
    mkdir -p $exp_dir
    
    # YAML 파일 복사 (나중에 참조용)
    cp $yaml_file $exp_dir/deployment.yaml
    
    # YAML 적용
    kubectl apply -f $yaml_file
    
    # Pod이 Running 상태가 될 때까지 대기
    echo "Waiting for pods to be ready..."
    
    # 최대 60초 동안 Pod이 준비될 때까지 대기
    local max_wait=60
    local wait_time=0
    local pods_ready=false
    
    while [ $wait_time -lt $max_wait ]; do
        # YAML 파일에서 Pod 이름들 미리 확인
        local temp_consumer=$(find_pod_name "consumer" "$yaml_file")
        local temp_producer=$(find_pod_name "producer" "$yaml_file")
        
        if [ ! -z "$temp_consumer" ] && [ ! -z "$temp_producer" ]; then
            # 두 Pod이 모두 Running 상태인지 확인
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
    
    # 추가로 5초 대기 (컨테이너가 완전히 시작되도록)
    sleep 5
    
    # Pod 상태 확인 및 저장
    kubectl get pods -o wide > $exp_dir/pod_status.txt
    
    # YAML 파일에서 정의된 Pod 이름들 추출
    echo "Finding pods..."
    
    # Consumer Pod 찾기
    consumer_pod=$(find_pod_name "consumer" "$yaml_file")
    if [ ! -z "$consumer_pod" ]; then
        echo "Found consumer pod: $consumer_pod"
    else
        echo "WARNING: Consumer pod not found in YAML or cluster"
    fi
    
    # Producer Pod 찾기
    producer_pod=$(find_pod_name "producer" "$yaml_file")
    if [ ! -z "$producer_pod" ]; then
        echo "Found producer pod: $producer_pod"
    else
        echo "WARNING: Producer pod not found in YAML or cluster"
    fi
    
    # 로그 스트리밍 시작
    if [ ! -z "$consumer_pod" ]; then
        echo "Starting log collection for consumer: $consumer_pod"
        kubectl logs -f $consumer_pod > $exp_dir/consumer.log 2>&1 &
        CONSUMER_LOG_PID=$!
    else
        echo "WARNING: Consumer pod not found"
    fi
    
    if [ ! -z "$producer_pod" ]; then
        echo "Starting log collection for producer: $producer_pod"
        kubectl logs -f $producer_pod > $exp_dir/producer.log 2>&1 &
        PRODUCER_LOG_PID=$!
    else
        echo "WARNING: Producer pod not found"
    fi
    
    # 실험 정보 기록
    cat > $exp_dir/experiment_info.txt <<EOF
Experiment: $experiment_name
Start time: $(date)
Duration: $duration seconds
Consumer Pod: $consumer_pod
Producer Pod: $producer_pod
EOF
    
    # Pod 상세 정보 저장
    kubectl describe pods > $exp_dir/pod_descriptions.txt
    
    # 현재 실행 중인 모든 Pod 목록 저장
    kubectl get pods --all-namespaces > $exp_dir/all_pods.txt
    
    # 지정된 시간 동안 실행
    echo "Running experiment for $duration seconds..."
    
    # 진행 상황 표시
    for i in $(seq 1 $((duration/60))); do
        echo "Progress: $i/$((duration/60)) minutes..."
        sleep 60
    done
    
    # 남은 시간 처리
    remaining=$((duration % 60))
    if [ $remaining -gt 0 ]; then
        sleep $remaining
    fi
    
    # 로그 수집 중지
    if [ ! -z "$CONSUMER_LOG_PID" ]; then
        kill $CONSUMER_LOG_PID 2>/dev/null
    fi
    if [ ! -z "$PRODUCER_LOG_PID" ]; then
        kill $PRODUCER_LOG_PID 2>/dev/null
    fi
    
    # 최종 Pod 로그 수집 (tail로 마지막 부분만)
    if [ ! -z "$consumer_pod" ]; then
        kubectl logs $consumer_pod --tail=1000 > $exp_dir/consumer_final.log 2>&1
    fi
    
    if [ ! -z "$producer_pod" ]; then
        kubectl logs $producer_pod --tail=1000 > $exp_dir/producer_final.log 2>&1
    fi
    
    # Pod 이벤트 저장
    kubectl get events --field-selector involvedObject.kind=Pod > $exp_dir/pod_events.txt
    
    # 리소스 사용량 저장
    kubectl top pods > $exp_dir/resource_usage.txt 2>&1
    
    # 리소스 정리
    kubectl delete -f $yaml_file
    
    echo "Experiment completed: $experiment_name"
    echo "Results saved to: $exp_dir"
    echo "Consumer pod was: $consumer_pod"
    echo "Producer pod was: $producer_pod"
    
    # 다음 실험 전 대기
    sleep 30
}

# 이미지 빌드 및 푸시
# echo "Building and pushing Docker images..."
# make build

# 실험 실행
run_experiment "k8s/same-node-no-service.yaml" "same_node_no_service" 600
# run_experiment "k8s/same-node-with-service.yaml" "same_node_with_service" 600
# run_experiment "k8s/different-node-no-service.yaml" "different_node_no_service" 600
# run_experiment "k8s/different-node-with-service.yaml" "different_node_with_service" 600

# # 결과 요약 생성
# echo "========================================="
# echo "All experiments completed!"
# echo "Results directory: $EXPERIMENT_BASE_DIR"
# echo "========================================="

# # 간단한 결과 분석 스크립트 생성
# cat > $EXPERIMENT_BASE_DIR/analyze_results.py << 'EOF'
# #!/usr/bin/env python3
# import os
# import re
# import sys

# def extract_latency_stats(log_file):
#     """로그 파일에서 레이턴시 통계 추출"""
#     if not os.path.exists(log_file):
#         return None
        
#     with open(log_file, 'r') as f:
#         content = f.read()
    
#     # 여러 패턴으로 통계 추출 시도
#     stats = {}
    
#     # P50 (median) 추출
#     p50_matches = re.findall(r'P50.*?:\s*([\d.]+)\s*μs', content)
#     if p50_matches:
#         stats['p50'] = [float(x) for x in p50_matches]
    
#     # P99 추출
#     p99_matches = re.findall(r'P99\s*:\s*([\d.]+)\s*μs', content)
#     if p99_matches:
#         stats['p99'] = [float(x) for x in p99_matches]
    
#     # P99.9 추출
#     p999_matches = re.findall(r'P99\.9\s*:\s*([\d.]+)\s*μs', content)
#     if p999_matches:
#         stats['p999'] = [float(x) for x in p999_matches]
    
#     # Mean 추출
#     mean_matches = re.findall(r'Mean:\s*([\d.]+)\s*μs', content)
#     if mean_matches:
#         stats['mean'] = [float(x) for x in mean_matches]
    
#     return stats if stats else None

# # 각 실험 디렉토리 분석
# results = {}
# for exp_dir in sorted(os.listdir('.')):
#     if os.path.isdir(exp_dir) and exp_dir not in ['__pycache__', '.git']:
#         consumer_log = os.path.join(exp_dir, 'consumer.log')
#         if os.path.exists(consumer_log):
#             stats = extract_latency_stats(consumer_log)
#             if stats:
#                 results[exp_dir] = stats
#                 print(f"\n{exp_dir}:")
#                 for metric, values in stats.items():
#                     if values:
#                         avg = sum(values) / len(values)
#                         print(f"  {metric}: avg={avg:.2f} μs, "
#                               f"min={min(values):.2f} μs, "
#                               f"max={max(values):.2f} μs, "
#                               f"samples={len(values)}")

# # 비교 테이블 생성
# if results:
#     print("\n\nComparison Table:")
#     print("-" * 80)
#     print(f"{'Experiment':<30} {'P50 avg':<15} {'P99 avg':<15} {'P99.9 avg':<15}")
#     print("-" * 80)
#     for exp, stats in sorted(results.items()):
#         p50_avg = sum(stats.get('p50', [0])) / len(stats.get('p50', [1])) if 'p50' in stats else 0
#         p99_avg = sum(stats.get('p99', [0])) / len(stats.get('p99', [1])) if 'p99' in stats else 0
#         p999_avg = sum(stats.get('p999', [0])) / len(stats.get('p999', [1])) if 'p999' in stats else 0
#         print(f"{exp:<30} {p50_avg:<15.2f} {p99_avg:<15.2f} {p999_avg:<15.2f}")
# EOF

# chmod +x $EXPERIMENT_BASE_DIR/analyze_results.py

# # 실험 요약 파일 생성
# cat > $EXPERIMENT_BASE_DIR/summary.txt <<EOF
# Experiment Summary
# ==================
# Date: $(date)
# Base Directory: $EXPERIMENT_BASE_DIR

# Experiments conducted:
# 1. same_node_no_service - Same node without Kubernetes Service
# 2. same_node_with_service - Same node with Kubernetes Service  
# 3. different_node_no_service - Different nodes without Service
# 4. different_node_with_service - Different nodes with Service

# Each experiment ran for 600 seconds (10 minutes).

# To analyze results:
# cd $EXPERIMENT_BASE_DIR
# python3 analyze_results.py
# EOF

# echo ""
# echo "Run the following to analyze results:"
# echo "cd $EXPERIMENT_BASE_DIR && python3 analyze_results.py"