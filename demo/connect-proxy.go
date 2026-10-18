// connect-proxy — local CONNECT proxy that adds Bearer auth and forwards to an upstream proxy.
// Build: go build -o connect-proxy connect-proxy.go
// Run:   ./connect-proxy "http://172.21.0.1:8088" "<agent_token>"
// Then:  HTTPS_PROXY=http://127.0.0.1:8888 NODE_USE_ENV_PROXY=1 <command>

package main

import (
	"bufio"
	"fmt"
	"io"
	"log"
	"net"
	"net/url"
	"os"
	"strings"
)

func main() {
	if len(os.Args) < 3 {
		log.Fatal("usage: connect-proxy <target> <token>")
	}
	target := os.Args[1]
	token := os.Args[2]

	targetURL, _ := url.Parse(target)
	upstream := targetURL.Host

	listener, err := net.Listen("tcp", ":8888")
	if err != nil {
		log.Fatal(err)
	}
	defer listener.Close()

	log.Printf("CONNECT proxy listening on :8888 -> %s", upstream)

	for {
		conn, err := listener.Accept()
		if err != nil {
			log.Printf("accept error: %v", err)
			continue
		}
		go handleConnection(conn, upstream, token)
	}
}

func handleConnection(client net.Conn, upstream, token string) {
	defer client.Close()

	reader := bufio.NewReader(client)
	reqLine, err := reader.ReadString('\n')
	if err != nil {
		return
	}

	if !strings.HasPrefix(reqLine, "CONNECT ") {
		handleHTTP(client, reader, reqLine, upstream, token)
		return
	}

	// Read CONNECT headers
	for {
		line, err := reader.ReadString('\n')
		if err != nil || line == "\r\n" || line == "\n" {
			break
		}
	}

	// Extract destination from CONNECT line
	dest := strings.TrimSpace(strings.TrimPrefix(reqLine, "CONNECT "))
	dest = strings.Split(dest, " ")[0]

	// Connect to upstream proxy
	upstreamConn, err := net.Dial("tcp", upstream)
	if err != nil {
		log.Printf("dial upstream: %v", err)
		client.Write([]byte("HTTP/1.1 502 Bad Gateway\r\n\r\n"))
		return
	}
	defer upstreamConn.Close()

	// Send CONNECT to upstream with Proxy-Authorization
	connectReq := fmt.Sprintf("CONNECT %s HTTP/1.1\r\nHost: %s\r\n", dest, dest)
	if token != "" {
		connectReq += fmt.Sprintf("Proxy-Authorization: Bearer %s\r\n", token)
	}
	connectReq += "\r\n"

	_, err = upstreamConn.Write([]byte(connectReq))
	if err != nil {
		log.Printf("write connect: %v", err)
		return
	}

	// Read upstream response
	upstreamReader := bufio.NewReader(upstreamConn)
	respLine, _ := upstreamReader.ReadString('\n')
	log.Printf("upstream response: %s", strings.TrimSpace(respLine))

	// Consume headers
	for {
		line, _ := upstreamReader.ReadString('\n')
		if line == "\r\n" || line == "\n" || line == "" {
			break
		}
	}

	// Check if successful
	if !strings.Contains(respLine, "200") {
		client.Write([]byte(respLine))
		io.Copy(client, upstreamReader)
		return
	}

	// Send 200 to client
	client.Write([]byte("HTTP/1.1 200 Connection established\r\n\r\n"))

	// Tunnel established - copy both directions
	go io.Copy(client, upstreamConn)
	io.Copy(upstreamConn, client)
}

func handleHTTP(client net.Conn, reader *bufio.Reader, reqLine string, upstream, token string) {
	log.Printf("HTTP request: %s", strings.TrimSpace(reqLine))

	upstreamConn, err := net.Dial("tcp", upstream)
	if err != nil {
		log.Printf("dial upstream: %v", err)
		return
	}
	defer upstreamConn.Close()

	upstreamConn.Write([]byte(reqLine))

	for {
		line, err := reader.ReadString('\n')
		if err != nil || line == "\r\n" || line == "\n" {
			if token != "" && !strings.Contains(reqLine, "Proxy-Authorization") {
				upstreamConn.Write([]byte(fmt.Sprintf("Proxy-Authorization: Bearer %s\r\n", token)))
			}
			upstreamConn.Write([]byte(line))
			break
		}
		upstreamConn.Write([]byte(line))
	}

	io.Copy(upstreamConn, reader)
	io.Copy(client, upstreamConn)
}