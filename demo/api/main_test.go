package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func echo(t *testing.T, ts *httptest.Server) map[string]any {
	t.Helper()
	resp, err := http.Post(ts.URL+"/orders", "application/json", nil)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var m map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&m); err != nil {
		t.Fatal(err)
	}
	return m
}

// TestCounterProvesExecutionOrder: the response carries executed_count, the
// demo's proof that the upstream ran only when the gateway allowed a call
// through — a held (202) action never reaches it.
func TestCounterProvesExecutionOrder(t *testing.T) {
	ts := httptest.NewServer(handler())
	defer ts.Close()

	first := echo(t, ts)
	second := echo(t, ts)
	if first["executed_count"] != float64(1) || second["executed_count"] != float64(2) {
		t.Fatalf("counter wrong: %v then %v", first["executed_count"], second["executed_count"])
	}
	if first["status"] != "ok" || first["path"] != "/orders" {
		t.Fatalf("echo shape: %v", first)
	}
	// the counter header should agree with the body
}
