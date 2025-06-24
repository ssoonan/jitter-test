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
	"syscall"
	"time"
)

type Message struct {
	Sequence  uint64
	Timestamp int64
	Padding   [4080]byte
}

type LatencyStats struct {
	mu         sync.Mutex
	samples    []float64
	count      int64
	sum        float64
	sumSquared float64
	min        float64
	max        float64
}

func NewLatencyStats() *LatencyStats {
	return &LatencyStats{
		samples: make([]float64, 0, 100000),
		min:     math.MaxFloat64,
		max:     0,
	}
}

func (s *LatencyStats) Add(latency float64) {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.samples = append(s.samples, latency)
	s.count++
	s.sum += latency
	s.sumSquared += latency * latency

	if latency < s.min {
		s.min = latency
	}
	if latency > s.max {
		s.max = latency
	}
}

func (s *LatencyStats) Calculate() {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.count == 0 {
		fmt.Println("No samples collected")
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

	fmt.Printf("\n=== Latency Statistics (microseconds) ===\n")
	fmt.Printf("Samples: %d\n", s.count)
	fmt.Printf("Mean: %.2f μs\n", mean)
	fmt.Printf("StdDev: %.2f μs\n", stddev)
	fmt.Printf("Min: %.2f μs\n", s.min)
	fmt.Printf("Max: %.2f μs\n", s.max)
	fmt.Printf("Percentiles:\n")
	fmt.Printf("  P50 (median): %.2f μs\n", p50)
	fmt.Printf("  P90: %.2f μs\n", p90)
	fmt.Printf("  P99: %.2f μs\n", p99)
	fmt.Printf("  P99.9: %.2f μs\n", p999)
	fmt.Printf("=========================================\n")
}

func (s *LatencyStats) Reset() {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.samples = s.samples[:0]
	s.count = 0
	s.sum = 0
	s.sumSquared = 0
	s.min = math.MaxFloat64
	s.max = 0
}

func handleConnection(conn net.Conn, stats *LatencyStats) {
	defer conn.Close()

	// TCP 옵션 설정
	if tcpConn, ok := conn.(*net.TCPConn); ok {
		tcpConn.SetNoDelay(true)
		tcpConn.SetReadBuffer(65536)
	}

	fmt.Printf("New connection from %s\n", conn.RemoteAddr())

	var msg Message
	lastSequence := uint64(0)
	packetsReceived := uint64(0)
	packetsLost := uint64(0)

	for {
		err := binary.Read(conn, binary.BigEndian, &msg)
		if err != nil {
			fmt.Printf("Connection closed: %v\n", err)
			break
		}

		// 지연시간 계산 (마이크로초)
		now := time.Now().UnixNano()
		latency := float64(now-msg.Timestamp) / 1000.0

		// 패킷 손실 감지
		if packetsReceived > 0 && msg.Sequence != lastSequence+1 {
			lost := msg.Sequence - lastSequence - 1
			packetsLost += lost
			fmt.Printf("Packet loss detected: %d packets lost (sequence %d -> %d)\n",
				lost, lastSequence, msg.Sequence)
		}

		stats.Add(latency)
		packetsReceived++
		lastSequence = msg.Sequence

		// 주기적 상태 출력
		if packetsReceived%1000 == 0 {
			lossRate := float64(packetsLost) / float64(packetsReceived+packetsLost) * 100
			fmt.Printf("Received: %d packets | Lost: %d (%.2f%%) | Latest latency: %.2f μs\n",
				packetsReceived, packetsLost, lossRate, latency)
		}
	}

	fmt.Printf("Connection statistics - Received: %d, Lost: %d\n",
		packetsReceived, packetsLost)
}

func main() {
	runtime.LockOSThread()

	// 환경 변수에서 포트 읽기
	port := os.Getenv("LISTEN_PORT")
	if port == "" {
		port = "8080"
	}

	fmt.Printf("Consumer starting on port %s...\n", port)

	// TCP 리스너 생성
	listener, err := net.Listen("tcp", ":"+port)
	if err != nil {
		fmt.Printf("Failed to listen: %v\n", err)
		os.Exit(1)
	}
	defer listener.Close()

	fmt.Printf("Listening on %s\n", listener.Addr())

	// 통계 객체 생성
	stats := NewLatencyStats()

	// 시그널 핸들러
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

	// 주기적 통계 출력
	statsTicker := time.NewTicker(10 * time.Second)
	defer statsTicker.Stop()

	go func() {
		for range statsTicker.C {
			stats.Calculate()
		}
	}()

	// 연결 수락 고루틴
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				fmt.Printf("Accept error: %v\n", err)
				continue
			}

			// 각 연결을 별도 고루틴에서 처리
			go handleConnection(conn, stats)
		}
	}()

	// 시그널 대기
	<-sigChan
	fmt.Println("\nShutting down consumer...")

	// 최종 통계 출력
	stats.Calculate()
}
