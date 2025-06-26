package main

import (
	"encoding/binary"
	"fmt"
	"math"
	"net"
	"os"
	"os/signal"
	"runtime"
	"sort"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

type Message struct {
	Sequence  uint64
	Timestamp int64
	Padding   [4080]byte // 전체 메시지를 4KB로 만들기 위한 패딩
}

type AckMessage struct {
	Sequence uint64
}

type Statistics struct {
	messagesSent uint64
	bytessSent   uint64
	errors       uint64
}

type RTTStats struct {
	mu         sync.Mutex
	samples    []float64
	count      int64
	sum        float64
	sumSquared float64
	min        float64
	max        float64
}

func NewRTTStats() *RTTStats {
	return &RTTStats{
		samples: make([]float64, 0, 100000),
		min:     math.MaxFloat64,
		max:     0,
	}
}

func (s *RTTStats) Add(rtt float64) {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.samples = append(s.samples, rtt)
	s.count++
	s.sum += rtt
	s.sumSquared += rtt * rtt

	if rtt < s.min {
		s.min = rtt
	}
	if rtt > s.max {
		s.max = rtt
	}
}

func (s *RTTStats) Calculate() {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.count == 0 {
		fmt.Println("No RTT samples collected")
		return
	}

	mean := s.sum / float64(s.count)
	variance := (s.sumSquared / float64(s.count)) - (mean * mean)
	stddev := math.Sqrt(variance)

	// 샘플 정렬 (백분위수 계산용)
	sort.Float64s(s.samples)

	p50 := s.samples[len(s.samples)*50/100]
	p90 := s.samples[len(s.samples)*90/100]
	p99 := s.samples[len(s.samples)*99/100]
	p999 := s.samples[len(s.samples)*999/1000]

	fmt.Printf("\n=== RTT Statistics (microseconds) ===")
	fmt.Printf("\nSamples: %d", s.count)
	fmt.Printf("\nMean: %.2f μs", mean)
	fmt.Printf("\nStdDev: %.2f μs", stddev)
	fmt.Printf("\nMin: %.2f μs", s.min)
	fmt.Printf("\nMax: %.2f μs", s.max)
	fmt.Printf("\nPercentiles:")
	fmt.Printf("\n  P50 (median): %.2f μs", p50)
	fmt.Printf("\n  P90: %.2f μs", p90)
	fmt.Printf("\n  P99: %.2f μs", p99)
	fmt.Printf("\n  P99.9: %.2f μs", p999)
	fmt.Printf("\n=====================================\n")
}

var stats Statistics
var rttStats *RTTStats
var sendTimes sync.Map // map[uint64]time.Time to track send times

func main() {
	// CPU 코어 고정 (선택사항)
	runtime.LockOSThread()

	// 환경 변수에서 설정 읽기
	targetAddr := os.Getenv("TARGET_ADDRESS")
	if targetAddr == "" {
		targetAddr = "consumer-service:8080"
	}

	sendInterval := os.Getenv("SEND_INTERVAL_MS")
	if sendInterval == "" {
		sendInterval = "10" // 기본값: 10ms (100Hz)
	}

	intervalMs, err := time.ParseDuration(sendInterval + "ms")
	if err != nil {
		fmt.Printf("Invalid send interval: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("Producer starting...\n")
	fmt.Printf("Target address: %s\n", targetAddr)
	fmt.Printf("Send interval: %v\n", intervalMs)

	// 연결 재시도 로직
	var conn net.Conn
	for retries := 0; retries < 30; retries++ {
		conn, err = net.Dial("tcp", targetAddr)
		if err == nil {
			break
		}
		fmt.Printf("Connection failed (attempt %d/30): %v\n", retries+1, err)
		time.Sleep(2 * time.Second)
	}

	if conn == nil {
		fmt.Printf("Failed to connect after 30 attempts\n")
		os.Exit(1)
	}

	defer conn.Close()
	fmt.Printf("Connected to %s\n", targetAddr)

	// TCP 옵션 설정
	if tcpConn, ok := conn.(*net.TCPConn); ok {
		tcpConn.SetNoDelay(true)      // Nagle 알고리즘 비활성화
		tcpConn.SetWriteBuffer(65536) // 64KB 버퍼
	}

	// 시그널 핸들러 설정
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

	// RTT 통계 초기화
	rttStats = NewRTTStats()

	// ACK 수신 고루틴 시작
	go receiveAcks(conn)

	// 통계 출력 고루틴
	go printStatistics()

	// 메시지 전송 루프
	sequence := uint64(0)
	ticker := time.NewTicker(intervalMs)
	defer ticker.Stop()

	running := true
	for running {
		select {
		case <-ticker.C:
			// 그래서 어떤 메시지를 어떻게 보내는가?를 이해할 필요가 있음
			msg := Message{
				Sequence:  sequence,
				Timestamp: time.Now().UnixNano(),
			}

			// 네트워크 바이트 순서로 전송
			err := binary.Write(conn, binary.BigEndian, msg)
			if err != nil {
				atomic.AddUint64(&stats.errors, 1)
				fmt.Printf("Send error: %v\n", err)
				// 연결이 끊어진 경우 재연결 시도
				conn.Close()
				conn, err = net.Dial("tcp", targetAddr)
				if err != nil {
					fmt.Printf("Reconnection failed: %v\n", err)
					running = false
					break
				}
				if tcpConn, ok := conn.(*net.TCPConn); ok {
					tcpConn.SetNoDelay(true)
					tcpConn.SetWriteBuffer(65536)
				}
				continue
			}

			atomic.AddUint64(&stats.messagesSent, 1)
			atomic.AddUint64(&stats.bytessSent, uint64(binary.Size(msg)))
			// RTT 측정을 위해 전송 시간 저장
			sendTimes.Store(sequence, time.Now())
			sequence++

		case <-sigChan:
			fmt.Println("\nShutting down producer...")
			running = false
		}
	}

	// 최종 통계 출력
	printFinalStats()
}

func receiveAcks(conn net.Conn) {
	for {
		var ack AckMessage
		err := binary.Read(conn, binary.BigEndian, &ack)
		if err != nil {
			fmt.Printf("Error reading ACK: %v\n", err)
			return
		}

		// 전송 시간 조회
		if sendTimeI, ok := sendTimes.LoadAndDelete(ack.Sequence); ok {
			sendTime := sendTimeI.(time.Time)
			rtt := float64(time.Since(sendTime).Microseconds())
			rttStats.Add(rtt)
		}
	}
}

func printStatistics() {
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()

	lastMessages := uint64(0)
	lastBytes := uint64(0)
	lastTime := time.Now()

	for range ticker.C {
		currentMessages := atomic.LoadUint64(&stats.messagesSent)
		currentBytes := atomic.LoadUint64(&stats.bytessSent)
		currentErrors := atomic.LoadUint64(&stats.errors)
		currentTime := time.Now()

		duration := currentTime.Sub(lastTime).Seconds()
		messageRate := float64(currentMessages-lastMessages) / duration
		throughput := float64(currentBytes-lastBytes) / duration / 1024 / 1024 // MB/s

		fmt.Printf("[Stats] Messages: %d | Rate: %.2f msg/s | Throughput: %.2f MB/s | Errors: %d\n",
			currentMessages, messageRate, throughput, currentErrors)

		// RTT 통계 출력
		rttStats.Calculate()

		lastMessages = currentMessages
		lastBytes = currentBytes
		lastTime = currentTime
	}
}

func printFinalStats() {
	fmt.Printf("\nFinal Statistics:\n")
	fmt.Printf("Total messages sent: %d\n", stats.messagesSent)
	fmt.Printf("Total bytes sent: %d\n", stats.bytessSent)
	fmt.Printf("Total errors: %d\n", stats.errors)
	
	// Final RTT statistics
	rttStats.Calculate()
}
