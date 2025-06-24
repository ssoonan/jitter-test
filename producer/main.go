package main

import (
	"encoding/binary"
	"fmt"
	"net"
	"os"
	"os/signal"
	"runtime"
	"sync/atomic"
	"syscall"
	"time"
)

type Message struct {
	Sequence  uint64
	Timestamp int64
	Padding   [4080]byte // 전체 메시지를 4KB로 만들기 위한 패딩
}

type Statistics struct {
	messagesSent uint64
	bytessSent   uint64
	errors       uint64
}

var stats Statistics

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
			sequence++

		case <-sigChan:
			fmt.Println("\nShutting down producer...")
			running = false
		}
	}

	// 최종 통계 출력
	printFinalStats()
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
}
