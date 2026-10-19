// connect-proxy — local CONNECT proxy that adds Bearer auth and forwards to an
// upstream (Agent Gateway) proxy, optionally chaining through a parent proxy
// (OpenShell's supervisor proxy).
//
// Auto-refreshes the agent token from TokenSvc when the old one expires.
//
// Build: go build -o connect-proxy connect-proxy.go
// Run:   ./connect-proxy <agw-proxy-url> <tokensvc-url> <delegation-id> <agent-secret> [parent-proxy-url]
//
// Example (inside an OpenShell sandbox, chaining through its supervisor proxy):
//   ./connect-proxy http://172.21.0.1:8088 http://172.21.0.1:8082/token <del-id> <secret> http://10.200.0.1:3128
// Then:
//   HTTPS_PROXY=http://127.0.0.1:8888 NODE_USE_ENV_PROXY=1 <command>

package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"
)

type TokenManager struct {
	tokensvcURL  string
	delegationID string
	agentSecret  string
	mu           sync.RWMutex
	currentToken string
	lastFetch    time.Time
	refreshEvery time.Duration
	client       *http.Client
}

func NewTokenManager(tokensvcURL, delegationID, agentSecret, parentProxy string) *TokenManager {
	// If a parent proxy is set (OpenShell's supervisor proxy), route token
	// requests through it; otherwise talk to TokenSvc directly.
	transport := &http.Transport{}
	if parentProxy != "" {
		if pu, err := url.Parse(parentProxy); err == nil {
			transport.Proxy = http.ProxyURL(pu)
		}
	}
	return &TokenManager{
		tokensvcURL:  tokensvcURL,
		delegationID: delegationID,
		agentSecret:  agentSecret,
		refreshEvery: 5 * time.Minute,
		client:       &http.Client{Timeout: 10 * time.Second, Transport: transport},
	}
}

func (tm *TokenManager) Get() string {
	tm.mu.RLock()
	if tm.currentToken != "" && time.Since(tm.lastFetch) < tm.refreshEvery {
		t := tm.currentToken
		tm.mu.RUnlock()
		return t
	}
	tm.mu.RUnlock()
	return tm.refresh()
}

func (tm *TokenManager) refresh() string {
	tm.mu.Lock()
	defer tm.mu.Unlock()

	if tm.currentToken != "" && time.Since(tm.lastFetch) < tm.refreshEvery {
		return tm.currentToken
	}

	body, _ := json.Marshal(map[string]any{
		"delegation_id": tm.delegationID,
		"ttl_seconds":   600,
		"agent_secret":  tm.agentSecret,
	})
	resp, err := tm.client.Post(tm.tokensvcURL, "application/json", bytes.NewReader(body))
	if err != nil {
		log.Printf("token refresh failed: %v (keeping old token)", err)
		return tm.currentToken
	}
	defer resp.Body.Close()

	var data struct {
		AccessToken string `json:"access_token"`
		Token       string `json:"token"`
	}
	json.NewDecoder(resp.Body).Decode(&data)
	tok := data.AccessToken
	if tok == "" {
		tok = data.Token
	}
	if tok == "" {
		log.Printf("token refresh returned empty token (HTTP %d)", resp.StatusCode)
		return tm.currentToken
	}

	tm.currentToken = tok
	tm.lastFetch = time.Now()
	log.Printf("token refreshed (HTTP %d, next refresh in %v)", resp.StatusCode, tm.refreshEvery)
	return tok
}

// dialUpstream opens a TCP connection to the AGW proxy, chaining through the
// parent proxy (OpenShell's supervisor) when one is configured. It returns the
// connection plus the bufio.Reader used to parse the parent's CONNECT response,
// so callers keep reading through the same buffer and never lose early bytes.
func dialUpstream(agwHost, parentProxy string) (net.Conn, *bufio.Reader, error) {
	if parentProxy == "" {
		c, err := net.Dial("tcp", agwHost)
		if err != nil {
			return nil, nil, err
		}
		return c, bufio.NewReader(c), nil
	}
	pu, err := url.Parse(parentProxy)
	if err != nil {
		return nil, nil, fmt.Errorf("bad parent proxy url: %w", err)
	}
	pc, err := net.Dial("tcp", pu.Host)
	if err != nil {
		return nil, nil, fmt.Errorf("dial parent proxy: %w", err)
	}
	req := fmt.Sprintf("CONNECT %s HTTP/1.1\r\nHost: %s\r\n\r\n", agwHost, agwHost)
	if _, err := pc.Write([]byte(req)); err != nil {
		pc.Close()
		return nil, nil, err
	}
	br := bufio.NewReader(pc)
	line, _ := br.ReadString('\n')
	if !strings.Contains(line, "200") {
		pc.Close()
		return nil, nil, fmt.Errorf("parent proxy refused CONNECT to %s: %s", agwHost, strings.TrimSpace(line))
	}
	for {
		l, _ := br.ReadString('\n')
		if l == "\r\n" || l == "\n" || l == "" {
			break
		}
	}
	return pc, br, nil
}

func main() {
	if len(os.Args) < 5 {
		log.Fatal("usage: connect-proxy <agw-proxy-url> <tokensvc-url> <delegation-id> <agent-secret> [parent-proxy-url]")
	}
	target := os.Args[1]
	tokensvc := os.Args[2]
	delegationID := os.Args[3]
	agentSecret := os.Args[4]
	parentProxy := ""
	if len(os.Args) >= 6 {
		parentProxy = os.Args[5]
	}

	targetURL, err := url.Parse(target)
	if err != nil {
		log.Fatalf("bad upstream URL: %v", err)
	}
	upstream := targetURL.Host

	tm := NewTokenManager(tokensvc, delegationID, agentSecret, parentProxy)
	tm.Get()

	listener, err := net.Listen("tcp", ":8888")
	if err != nil {
		log.Fatal(err)
	}
	defer listener.Close()

	if parentProxy != "" {
		log.Printf("CONNECT proxy listening on :8888 -> %s via parent %s (tokensvc: %s)", upstream, parentProxy, tokensvc)
	} else {
		log.Printf("CONNECT proxy listening on :8888 -> %s (tokensvc: %s)", upstream, tokensvc)
	}

	for {
		conn, err := listener.Accept()
		if err != nil {
			log.Printf("accept error: %v", err)
			continue
		}
		go handleConnection(conn, upstream, parentProxy, tm)
	}
}

func handleConnection(client net.Conn, upstream, parentProxy string, tm *TokenManager) {
	defer client.Close()

	reader := bufio.NewReader(client)
	reqLine, err := reader.ReadString('\n')
	if err != nil {
		return
	}

	if !strings.HasPrefix(reqLine, "CONNECT ") {
		handleHTTP(client, reader, reqLine, upstream, parentProxy, tm)
		return
	}

	// Consume client CONNECT headers.
	for {
		line, err := reader.ReadString('\n')
		if err != nil || line == "\r\n" || line == "\n" {
			break
		}
	}

	dest := strings.TrimSpace(strings.TrimPrefix(reqLine, "CONNECT "))
	dest = strings.Split(dest, " ")[0]

	upstreamConn, upstreamReader, err := dialUpstream(upstream, parentProxy)
	if err != nil {
		log.Printf("upstream: %v", err)
		client.Write([]byte("HTTP/1.1 502 Bad Gateway\r\n\r\n"))
		return
	}
	defer upstreamConn.Close()

	token := tm.Get()
	respLine, upstreamReader, err := sendConnect(upstreamConn, upstreamReader, dest, token)
	if err != nil {
		return
	}
	log.Printf("upstream response: %s", strings.TrimSpace(respLine))

	// Stale token? Refresh once and retry.
	if strings.Contains(respLine, "401") || strings.Contains(respLine, "407") {
		log.Printf("upstream rejected token (%s) — refreshing and retrying", strings.TrimSpace(respLine))
		upstreamConn.Close()
		tm.refresh()

		upstreamConn, upstreamReader, err = dialUpstream(upstream, parentProxy)
		if err != nil {
			log.Printf("re-dial upstream: %v", err)
			client.Write([]byte("HTTP/1.1 502 Bad Gateway\r\n\r\n"))
			return
		}
		defer upstreamConn.Close()

		token = tm.Get()
		respLine, upstreamReader, err = sendConnect(upstreamConn, upstreamReader, dest, token)
		if err != nil {
			return
		}
		log.Printf("upstream retry response: %s", strings.TrimSpace(respLine))
	}

	if !strings.Contains(respLine, "200") {
		client.Write([]byte(respLine))
		io.Copy(client, upstreamReader)
		return
	}

	client.Write([]byte("HTTP/1.1 200 Connection established\r\n\r\n"))

	go io.Copy(client, upstreamConn)
	io.Copy(upstreamConn, client)
}

// sendConnect writes a CONNECT to the (already-open) AGW proxy connection and
// reads back the status line + headers through the caller-supplied reader.
func sendConnect(conn net.Conn, br *bufio.Reader, dest, token string) (string, *bufio.Reader, error) {
	req := fmt.Sprintf("CONNECT %s HTTP/1.1\r\nHost: %s\r\n", dest, dest)
	if token != "" {
		req += fmt.Sprintf("Proxy-Authorization: Bearer %s\r\n", token)
	}
	req += "\r\n"
	if _, err := conn.Write([]byte(req)); err != nil {
		return "", nil, err
	}
	line, _ := br.ReadString('\n')
	for {
		l, _ := br.ReadString('\n')
		if l == "\r\n" || l == "\n" || l == "" {
			break
		}
	}
	return line, br, nil
}

func handleHTTP(client net.Conn, reader *bufio.Reader, reqLine, upstream, parentProxy string, tm *TokenManager) {
	log.Printf("HTTP request: %s", strings.TrimSpace(reqLine))

	upstreamConn, _, err := dialUpstream(upstream, parentProxy)
	if err != nil {
		log.Printf("dial upstream: %v", err)
		return
	}
	defer upstreamConn.Close()

	token := tm.Get()
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
