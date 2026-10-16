// Command demoapi is a tiny stand-in for a customer's protected API. It is
// deliberately plain — no licence, no encryption: it represents the customer's
// own service sitting behind Agent Gateway, not a vendor-delivered component.
//
// It mirrors the gateway's synthetic-echo response shape and adds a per-path
// call counter shown in every response, so a scripted demo can PROVE that the
// upstream executed exactly once, only after a human approval — during the
// held phase the counter (and therefore the API) never moves.
//
// Actor delegation headers set by the gateway (X-Auth-User, X-Auth-Agent,
// X-Delegation-ID, X-Request-ID) are echoed back, showing what a real
// downstream sees.
package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"strconv"
	"sync"
	"time"
)

type api struct {
	mu      sync.Mutex
	started time.Time
	calls   map[string]int
}

// handler builds the demo API: the health endpoint plus the counting echo.
func handler() http.Handler {
	a := &api{started: time.Now(), calls: map[string]int{}}
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(rw http.ResponseWriter, _ *http.Request) {
		rw.Header().Set("Content-Type", "application/json")
		_, _ = rw.Write([]byte(`{"status":"ok","service":"demoapi"}`))
	})
	mux.HandleFunc("/", a.handle)
	return mux
}

func main() {
	addr := os.Getenv("DEMOAPI_ADDR")
	if addr == "" {
		addr = ":8090"
	}
	log.Printf("demoapi listening on %s", addr)
	srv := &http.Server{Addr: addr, Handler: handler(), ReadTimeout: 5 * time.Second, WriteTimeout: 10 * time.Second}
	log.Fatal(srv.ListenAndServe())
}

// handle records the invocation and answers with the counter inline.
func (a *api) handle(rw http.ResponseWriter, r *http.Request) {
	a.mu.Lock()
	a.calls[r.URL.Path]++
	n := a.calls[r.URL.Path]
	a.mu.Unlock()

	rw.Header().Set("Content-Type", "application/json")
	rw.Header().Set("X-Demoapi-Call-Count", strconv.Itoa(n))
	_ = json.NewEncoder(rw).Encode(map[string]any{
		"status":         "ok",
		"service":        "demoapi",
		"executed_count": n,
		"path":           r.URL.Path,
		"note":           "executed BEHIND the Agent Gateway",
		"actor_headers": map[string]string{
			"X-Auth-User":     r.Header.Get("X-Auth-User"),
			"X-Auth-Agent":    r.Header.Get("X-Auth-Agent"),
			"X-Delegation-ID": r.Header.Get("X-Delegation-ID"),
			"X-Request-ID":    r.Header.Get("X-Request-ID"),
		},
	})
}
