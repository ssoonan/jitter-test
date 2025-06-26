package main

import (
	"encoding/binary"
	"fmt"
	"net"
	"os"
	"os/signal"
	"runtime"
	"syscall"
)

type Message struct {
	Sequence  uint64
	Timestamp int64
	Padding   [4080]byte
}

type AckMessage struct {
	Sequence uint64
}

func handleConnection(conn net.Conn) {
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

		// ACK 메시지 전송
		ack := AckMessage{Sequence: msg.Sequence}
		err = binary.Write(conn, binary.BigEndian, ack)
		if err != nil {
			fmt.Printf("Failed to send ACK: %v\n", err)
		}

		// 패킷 손실 감지
		if packetsReceived > 0 && msg.Sequence != lastSequence+1 {
			lost := msg.Sequence - lastSequence - 1
			packetsLost += lost
			fmt.Printf("Packet loss detected: %d packets lost (sequence %d -> %d)\n",
				lost, lastSequence, msg.Sequence)
		}

		packetsReceived++
		lastSequence = msg.Sequence

		// 주기적 상태 출력
		if packetsReceived%1000 == 0 {
			lossRate := float64(packetsLost) / float64(packetsReceived+packetsLost) * 100
			fmt.Printf("Received: %d packets | Lost: %d (%.2f%%)\n",
				packetsReceived, packetsLost, lossRate)
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

	// 시그널 핸들러
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

	// 연결 수락 고루틴
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				fmt.Printf("Accept error: %v\n", err)
				continue
			}

			// 각 연결을 별도 고루틴에서 처리
			go handleConnection(conn)
		}
	}()

	// 시그널 대기
	<-sigChan
	fmt.Println("\nShutting down consumer...")
}
