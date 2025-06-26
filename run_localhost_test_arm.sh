#!/bin/bash

# 실험 디렉토리 생성
EXPERIMENT_DIR="experiments/localhost_$(date +%Y%m%d_%H%M%S)"
mkdir -p $EXPERIMENT_DIR

echo "Starting localhost experiment..."
echo "Results will be saved to: $EXPERIMENT_DIR"

# CPU 코어 할당 (예: consumer는 코어 2, producer는 코어 3)
# taskset을 사용하여 CPU 친화도 설정

# Consumer 시작 (백그라운드)
taskset -c 2 ./consumer_arm > ../$EXPERIMENT_DIR/consumer.log 2>&1 &
CONSUMER_PID=$!

# Consumer가 준비될 때까지 대기
sleep 5

# Producer 시작
TARGET_ADDRESS=localhost:8080 taskset -c 3 ./producer_arm > ../$EXPERIMENT_DIR/producer.log 2>&1 &
PRODUCER_PID=$!

echo "Consumer PID: $CONSUMER_PID"
echo "Producer PID: $PRODUCER_PID"

# 10분 동안 실행
echo "Running for 10 minutes..."
sleep 600

# 프로세스 종료
echo "Stopping processes..."
kill -TERM $PRODUCER_PID
sleep 2
kill -TERM $CONSUMER_PID

# 시스템 정보 수집
echo "Collecting system information..."
echo "=== System Info ===" > $EXPERIMENT_DIR/system_info.txt
date >> $EXPERIMENT_DIR/system_info.txt
uname -a >> $EXPERIMENT_DIR/system_info.txt
cat /proc/cpuinfo | grep "model name" | head -1 >> $EXPERIMENT_DIR/system_info.txt
free -h >> $EXPERIMENT_DIR/system_info.txt

echo "Experiment completed. Results in: $EXPERIMENT_DIR"