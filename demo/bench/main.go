// Command bench measures Agent Gateway enforcement performance for two paths:
//
//   - an ALLOWED passthrough: authorized by the policy decision point and then
//     proxied downstream to the upstream API (expect 200);
//   - a DENIED passthrough: refused at the enforcement point before any
//     upstream call is made (expect 403).
//
// It is self-contained: mock-connector SSO sign-in -> scoped delegation ->
// short-lived access token -> concurrent load. Results are per-path latency
// percentiles and throughput.
//
// Defaults target the demo compose stack (gateway :8080, console :8083,
// authz :8081, tokensvc :8082). Point it elsewhere with the -gateway/-web/
// -authz/-tokensvc flags.
//
//	cd demo/bench && go run .
//	cd demo/bench && go run . -c 50 -d 20s
//	cd demo/bench && go run . -gateway http://192.168.1.74:30080 -web http://192.168.1.74:30083 ...
//
// Or use the comparison driver / Makefile from the repository root:
//
//	make bench          # both engines (built-in, then OPA)
//	./demo/bench-engines.sh -c 50 -d 30s
package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"math"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"os"
	"runtime"
	"sort"
	"strings"
	"sync"
	"text/tabwriter"
	"time"
)

type options struct {
	web      string
	gateway  string
	authz    string
	tokensvc string

	allowPath, allowMethod, allowBody string
	denyPath, denyMethod, denyBody    string
	allowExpect, denyExpect           int

	agentID     string
	engineLabel string
	tokenTTL    time.Duration
	concurrency int
	duration    time.Duration
	warmup      time.Duration

	asJSON bool
}

func main() {
	o := options{}
	flag.StringVar(&o.web, "web", "http://localhost:8083", "console base URL (SSO sign-in)")
	flag.StringVar(&o.gateway, "gateway", "http://localhost:8080", "gateway base URL (the system under test)")
	flag.StringVar(&o.authz, "authz", "http://localhost:8081", "authz base URL (delegation creation)")
	flag.StringVar(&o.tokensvc, "tokensvc", "http://localhost:8082", "tokensvc base URL (token minting)")

	flag.StringVar(&o.allowPath, "allow-path", "/orders", "ALLOWED passthrough path (proxied downstream)")
	flag.StringVar(&o.allowMethod, "allow-method", http.MethodPost, "ALLOWED passthrough method")
	flag.StringVar(&o.allowBody, "allow-body", `{"amount":100,"supplier":"acme"}`, "ALLOWED passthrough request body")
	flag.StringVar(&o.denyPath, "deny-path", "/mail/send", "DENIED passthrough path (refused at the gateway)")
	flag.StringVar(&o.denyMethod, "deny-method", http.MethodPost, "DENIED passthrough method")
	flag.StringVar(&o.denyBody, "deny-body", `{}`, "DENIED passthrough request body")
	flag.IntVar(&o.allowExpect, "allow-expect", http.StatusOK, "expected status for the allowed path")
	flag.IntVar(&o.denyExpect, "deny-expect", http.StatusForbidden, "expected status for the denied path")

	flag.StringVar(&o.agentID, "agent-id", "bench-agent", "agent id used for the benchmark delegation")
	flag.StringVar(&o.engineLabel, "engine", "", "policy-engine label for the report (default: auto-detect from authz; \"opa\" runs through OPA/Rego)")
	flag.DurationVar(&o.tokenTTL, "token-ttl", 30*time.Minute, "access-token TTL")
	flag.IntVar(&o.concurrency, "c", 20, "concurrency (parallel in-flight requests)")
	flag.DurationVar(&o.duration, "d", 10*time.Second, "measured duration per path")
	flag.DurationVar(&o.warmup, "w", 2*time.Second, "warmup duration (discarded) per path")
	flag.BoolVar(&o.asJSON, "json", false, "emit machine-readable JSON instead of a table")
	flag.Parse()

	if err := run(o); err != nil {
		fmt.Fprintln(os.Stderr, "bench: "+err.Error())
		os.Exit(1)
	}
}

func run(o options) error {
	client := newClient(o.concurrency)

	// --- setup: SSO -> delegation -> access token --------------------------
	idToken, sub, err := mockSignIn(client, o.web)
	if err != nil {
		return fmt.Errorf("mock SSO sign-in: %w", err)
	}
	delegID, secret, err := createDelegation(client, o.authz, idToken, o.agentID, o.allowPath)
	if err != nil {
		return fmt.Errorf("create delegation: %w", err)
	}
	token, err := mintToken(client, o.tokensvc, delegID, secret, o.tokenTTL)
	if err != nil {
		return fmt.Errorf("mint token: %w", err)
	}

	// Which policy engine is authz actually using? The decision carries a
	// policy_id ("basic" for the built-in engine, "opa" for Rego). Auto-detect
	// unless the caller pinned a label.
	engine := o.engineLabel
	if engine == "" {
		if e, derr := detectEngine(client, o.authz, delegID, o.agentID, sub, o.allowPath); derr == nil && e != "" {
			engine = e
		} else {
			engine = "unknown"
		}
	}

	allowed := pathSpec{name: "allowed", method: o.allowMethod, path: o.allowPath, body: o.allowBody, expect: o.allowExpect}
	denied := pathSpec{name: "denied", method: o.denyMethod, path: o.denyPath, body: o.denyBody, expect: o.denyExpect}

	// --- preflight: confirm each path behaves as configured -----------------
	for _, ps := range []*pathSpec{&allowed, &denied} {
		code, body, err := probe(client, o.gateway, token, *ps)
		if err != nil {
			return fmt.Errorf("preflight %s %s: %w", ps.name, ps.path, err)
		}
		if code != ps.expect {
			return fmt.Errorf("preflight %s %s: want %d, got %d (%s)\n"+
				"(check the delegation scope: the allowed path must be delegated and the denied path must not)",
				ps.name, ps.path, ps.expect, code, truncate(body, 200))
		}
	}

	rep := report{
		Gateway: o.gateway, Engine: engine, Delegation: delegID,
		Concurrency: o.concurrency, DurationMS: o.duration.Milliseconds(), WarmupMS: o.warmup.Milliseconds(),
	}

	if !o.asJSON {
		fmt.Printf("Agent Gateway benchmark\n")
		fmt.Printf("  gateway      %s\n", o.gateway)
		fmt.Printf("  engine       %s\n", engine)
		fmt.Printf("  delegation   %s (subject %s, agent %s)\n", delegID, short(sub), o.agentID)
		fmt.Printf("  concurrency  %d    duration %s    warmup %s    go %s\n\n",
			o.concurrency, o.duration, o.warmup, runtime.Version())
	}

	// --- warmup (discarded) -------------------------------------------------
	for _, ps := range []pathSpec{allowed, denied} {
		wctx, cancel := context.WithTimeout(context.Background(), o.warmup)
		_, _, _ = load(wctx, client, o.gateway, token, ps, o.concurrency)
		cancel()
	}

	// --- measure ------------------------------------------------------------
	results := make([]result, 0, 2)
	for _, ps := range []pathSpec{allowed, denied} {
		mctx, cancel := context.WithTimeout(context.Background(), o.duration)
		start := time.Now()
		lat, statuses, errs := load(mctx, client, o.gateway, token, ps, o.concurrency)
		elapsed := time.Since(start)
		cancel()
		results = append(results, summarize(ps, lat, statuses, errs, elapsed))
	}
	rep.Results = results

	client.CloseIdleConnections()

	if o.asJSON {
		return emitJSON(rep)
	}
	emitTable(rep)
	return nil
}

// report is the full machine-readable benchmark result.
type report struct {
	Gateway     string   `json:"gateway"`
	Engine      string   `json:"engine"`
	Delegation  string   `json:"delegation"`
	Concurrency int      `json:"concurrency"`
	DurationMS  int64    `json:"duration_ms"`
	WarmupMS    int64    `json:"warmup_ms"`
	Results     []result `json:"results"`
}

type pathSpec struct {
	name   string
	method string
	path   string
	body   string
	expect int
}

type result struct {
	Name     string         `json:"name"`
	Method   string         `json:"method"`
	Path     string         `json:"path"`
	Expect   int            `json:"expect"`
	Requests int            `json:"requests"`
	Errors   int            `json:"errors"`
	RPS      float64        `json:"rps"`
	MeanMS   float64        `json:"mean_ms"`
	P50MS    float64        `json:"p50_ms"`
	P90MS    float64        `json:"p90_ms"`
	P99MS    float64        `json:"p99_ms"`
	MaxMS    float64        `json:"max_ms"`
	Statuses map[string]int `json:"statuses"`
}

func summarize(ps pathSpec, lat []time.Duration, statuses map[int]int, errs int, elapsed time.Duration) result {
	sort.Slice(lat, func(i, j int) bool { return lat[i] < lat[j] })
	r := result{
		Name: ps.name, Method: ps.method, Path: ps.path, Expect: ps.expect,
		Requests: len(lat), Errors: errs,
		Statuses: map[string]int{},
	}
	secs := elapsed.Seconds()
	if secs > 0 {
		r.RPS = float64(len(lat)) / secs
	}
	if len(lat) > 0 {
		var sum time.Duration
		for _, d := range lat {
			sum += d
		}
		r.MeanMS = ms(sum / time.Duration(len(lat)))
		r.P50MS = ms(percentile(lat, 50))
		r.P90MS = ms(percentile(lat, 90))
		r.P99MS = ms(percentile(lat, 99))
		r.MaxMS = ms(lat[len(lat)-1])
	}
	for code, n := range statuses {
		r.Statuses[fmt.Sprintf("%d", code)] = n
	}
	return r
}

func emitTable(rep report) {
	tw := tabwriter.NewWriter(os.Stdout, 0, 2, 2, ' ', 0)
	fmt.Fprintf(tw, "engine=%s gateway=%s\n", rep.Engine, rep.Gateway)
	fmt.Fprintln(tw, "path\tconc\treqs\trps\tmean\tp50\tp90\tp99\tmax\terrors\tstatus")
	for _, r := range rep.Results {
		fmt.Fprintf(tw, "%s %s %s\t%d\t%d\t%.1f\t%s\t%s\t%s\t%s\t%s\t%d\t%s\n",
			r.Name, r.Method, r.Path, rep.Concurrency, r.Requests, r.RPS,
			msStr(r.MeanMS), msStr(r.P50MS), msStr(r.P90MS), msStr(r.P99MS), msStr(r.MaxMS),
			r.Errors, statusStr(r.Statuses))
	}
	tw.Flush()
	fmt.Println()
	fmt.Println("allowed = JWT verify + authz decision + proxied upstream; denied = JWT verify + authz decision (no upstream).")
}

func emitJSON(rep report) error {
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	return enc.Encode(rep)
}

// detectEngine asks authz for a decision and reports which policy engine
// produced it (policy_id: "basic" for the built-in engine, "opa" for Rego).
func detectEngine(client *http.Client, authz, delegID, agentID, userID, resource string) (string, error) {
	payload := map[string]any{
		"delegation_id": delegID,
		"agent_id":      agentID,
		"user_id":       userID,
		"resource":      resource,
		"action":        "create",
	}
	var out struct {
		PolicyID string `json:"policy_id"`
	}
	if err := postJSON(client, authz+"/v1/check", payload, nil, &out); err != nil {
		return "", err
	}
	return out.PolicyID, nil
}

// --- load generation --------------------------------------------------------

func load(ctx context.Context, client *http.Client, gateway, token string, ps pathSpec, conc int) ([]time.Duration, map[int]int, int) {
	deadline, _ := ctx.Deadline()
	var body []byte
	if ps.body != "" {
		body = []byte(ps.body)
	}

	latCh := make([][]time.Duration, conc)
	stCh := make([]map[int]int, conc)
	errCh := make([]int, conc)

	var wg sync.WaitGroup
	for w := 0; w < conc; w++ {
		wg.Add(1)
		go func(w int) {
			defer wg.Done()
			var lats []time.Duration
			local := map[int]int{}
			target := gateway + ps.path
			for time.Now().Before(deadline) {
				var rdr io.Reader
				if body != nil {
					rdr = bytes.NewReader(body)
				}
				req, err := http.NewRequestWithContext(ctx, ps.method, target, rdr)
				if err != nil {
					errCh[w]++
					continue
				}
				req.Header.Set("Authorization", "Bearer "+token)
				if body != nil {
					req.Header.Set("Content-Type", "application/json")
				}
				t0 := time.Now()
				resp, err := client.Do(req)
				d := time.Since(t0)
				if err != nil {
					// A request still in flight when the phase deadline fires
					// is expected; it is not a failure of the system under test.
					if ctx.Err() != nil || errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
						continue
					}
					errCh[w]++
					continue
				}
				_, _ = io.Copy(io.Discard, resp.Body)
				_ = resp.Body.Close()
				lats = append(lats, d)
				local[resp.StatusCode]++
			}
			latCh[w] = lats
			stCh[w] = local
		}(w)
	}
	wg.Wait()

	total := 0
	for _, l := range latCh {
		total += len(l)
	}
	lat := make([]time.Duration, 0, total)
	statuses := map[int]int{}
	errs := 0
	for w := 0; w < conc; w++ {
		lat = append(lat, latCh[w]...)
		for code, n := range stCh[w] {
			statuses[code] += n
		}
		errs += errCh[w]
	}
	return lat, statuses, errs
}

// probe issues a single request to validate a path before the timed run.
func probe(client *http.Client, gateway, token string, ps pathSpec) (int, string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	var body io.Reader
	if ps.body != "" {
		body = strings.NewReader(ps.body)
	}
	req, err := http.NewRequestWithContext(ctx, ps.method, gateway+ps.path, body)
	if err != nil {
		return 0, "", err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	if ps.body != "" {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := client.Do(req)
	if err != nil {
		return 0, "", err
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(b), nil
}

// --- setup helpers ----------------------------------------------------------

func newClient(conc int) *http.Client {
	return &http.Client{
		Timeout: 30 * time.Second,
		Transport: &http.Transport{
			MaxIdleConns:        conc * 4,
			MaxIdleConnsPerHost: conc * 4,
			IdleConnTimeout:     90 * time.Second,
			DisableCompression:  true,
		},
	}
}

// mockSignIn performs the mock-connector OIDC flow against the console's Dex
// proxy and returns the ID token and its subject.
func mockSignIn(client *http.Client, web string) (string, string, error) {
	jar, _ := cookiejar.New(nil)
	// This transport intentionally does not follow redirects: we walk the
	// chain manually to capture the authorization code.
	c := *client
	c.Jar = jar
	c.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }

	redirect := web + "/oidc/callback"
	loc := fmt.Sprintf("%s/oidc/idp/dex/auth?response_type=code&client_id=agent-gateway&redirect_uri=%s&connector_id=mock&scope=openid",
		web, url.QueryEscape(redirect))

	code := ""
	for i := 0; i < 8 && code == ""; i++ {
		req, _ := http.NewRequest(http.MethodGet, loc, nil)
		resp, err := c.Do(req)
		if err != nil {
			return "", "", err
		}
		resp.Body.Close()
		next := resp.Header.Get("Location")
		if next == "" {
			break
		}
		if u, perr := url.Parse(next); perr == nil && u.Query().Get("code") != "" {
			code = u.Query().Get("code")
			break
		}
		if strings.HasPrefix(next, "/") {
			loc = web + next
		} else {
			loc = next
		}
	}
	if code == "" {
		return "", "", fmt.Errorf("SSO redirect chain did not produce a code")
	}

	form := url.Values{
		"grant_type":   {"authorization_code"},
		"client_id":    {"agent-gateway"},
		"code":         {code},
		"redirect_uri": {redirect},
	}
	resp, err := c.PostForm(web+"/oidc/idp/dex/token", form)
	if err != nil {
		return "", "", err
	}
	defer resp.Body.Close()
	var tok struct {
		IDToken string `json:"id_token"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&tok); err != nil {
		return "", "", err
	}
	if tok.IDToken == "" {
		return "", "", fmt.Errorf("no id_token in token response")
	}
	return tok.IDToken, jwtSubject(tok.IDToken), nil
}

func createDelegation(client *http.Client, authz, idToken, agentID, allowedPath string) (string, string, error) {
	payload := map[string]any{
		"id_token":           idToken,
		"agent_id":           agentID,
		"resources":          []string{allowedPath},
		"actions":            []string{"read", "create"},
		"expires_in_seconds": 1800,
	}
	var out struct {
		Delegation struct {
			ID string `json:"id"`
		} `json:"delegation"`
		AgentSecret string `json:"agent_secret"`
	}
	if err := postJSON(client, authz+"/v1/delegations/", payload, nil, &out); err != nil {
		return "", "", err
	}
	if out.Delegation.ID == "" || out.AgentSecret == "" {
		return "", "", fmt.Errorf("delegation response missing id/agent_secret")
	}
	return out.Delegation.ID, out.AgentSecret, nil
}

func mintToken(client *http.Client, tokensvc, delegID, secret string, ttl time.Duration) (string, error) {
	payload := map[string]any{
		"delegation_id": delegID,
		"ttl_seconds":   int(ttl.Seconds()),
		"agent_secret":  secret,
	}
	var out struct {
		AccessToken string `json:"access_token"`
	}
	if err := postJSON(client, tokensvc+"/token", payload, nil, &out); err != nil {
		return "", err
	}
	if out.AccessToken == "" {
		return "", fmt.Errorf("token response missing access_token")
	}
	return out.AccessToken, nil
}

func postJSON(client *http.Client, endpoint string, payload any, headers map[string]string, into any) error {
	b, _ := json.Marshal(payload)
	req, err := http.NewRequest(http.MethodPost, endpoint, bytes.NewReader(b))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode/100 != 2 {
		return fmt.Errorf("%s -> %d: %s", endpoint, resp.StatusCode, truncate(string(body), 200))
	}
	if into != nil {
		if err := json.Unmarshal(body, into); err != nil {
			return fmt.Errorf("decode %s: %w", endpoint, err)
		}
	}
	return nil
}

func jwtSubject(token string) string {
	parts := strings.Split(token, ".")
	if len(parts) < 2 {
		return ""
	}
	raw, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return ""
	}
	var claims struct {
		Sub string `json:"sub"`
	}
	_ = json.Unmarshal(raw, &claims)
	return claims.Sub
}

// --- small utils ------------------------------------------------------------

func percentile(sorted []time.Duration, p float64) time.Duration {
	if len(sorted) == 0 {
		return 0
	}
	idx := int(math.Ceil(p/100*float64(len(sorted)))) - 1
	if idx < 0 {
		idx = 0
	}
	if idx >= len(sorted) {
		idx = len(sorted) - 1
	}
	return sorted[idx]
}

func ms(d time.Duration) float64 { return float64(d) / float64(time.Millisecond) }

func msStr(v float64) string {
	if v >= 100 {
		return fmt.Sprintf("%.0fms", v)
	}
	return fmt.Sprintf("%.2fms", v)
}

func statusStr(m map[string]int) string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	parts := make([]string, 0, len(keys))
	for _, k := range keys {
		parts = append(parts, fmt.Sprintf("%s:%d", k, m[k]))
	}
	return strings.Join(parts, " ")
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}

func short(s string) string {
	if len(s) <= 12 {
		return s
	}
	return s[:12] + "…"
}
