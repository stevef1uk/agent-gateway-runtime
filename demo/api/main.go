// Command demoapi is a tiny stand-in for a customer's protected API. It is
// deliberately plain — no licence, no encryption: it represents the customer's
// own service sitting behind Agent Gateway, not a vendor-delivered component.
//
// Since 1.0.5 it emulates a small **Payments API**: supplier master records,
// an accounts-payable invoice inbox and payment execution. The human-delegation
// demo (demo/human-delegation-demo.sh) drives it end to end:
//
//	GET  /invoices/{id}    read an invoice (the "read invoice" beat — auto-allowed)
//	GET  /suppliers/{id}   read the supplier master record (auto-allowed)
//	POST /payments         execute a payment (the gateway HELDs this until a
//	                        human approves; the API only ever sees executed calls)
//	POST /invoices         register an invoice — used out of band by the demo
//	                        script to play the AP inbox / ERP receiving an invoice
//
// An invoice may carry a remittance note and a "remit-to" IBAN that differs
// from the supplier's verified record — that is the prompt-injection / fraud
// scenario: the API exposes the mismatch as data
// (beneficiary_matches_supplier), but it never decides anything itself.
// On execution the API enforces its own final backstop: a payment whose
// beneficiary does not match the supplier record is refused (409), even if a
// human had approved it.
//
// It keeps the original synthetic-echo response shape for every other path and
// a per-path call counter shown in every response, so a scripted demo can
// PROVE that the upstream executed exactly once, only after a human approval —
// during the held phase the counter (and therefore the API) never moves.
//
// Actor delegation headers set by the gateway (X-Auth-User, X-Auth-Agent,
// X-Delegation-ID, X-Request-ID) are echoed back, showing what a real
// downstream sees.
package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

type supplier struct {
	SupplierID       string `json:"supplier_id"`
	Name             string `json:"name"`
	IBAN             string `json:"iban"`
	BIC              string `json:"bic"`
	VATID            string `json:"vat_id"`
	Verified         bool   `json:"verified"`
	IBANOnFileSince  string `json:"iban_on_file_since"`
	Country          string `json:"country"`
}

type invoice struct {
	InvoiceID         string  `json:"invoice_id"`
	SupplierID        string  `json:"supplier_id"`
	Amount            float64 `json:"amount"`
	Currency          string  `json:"currency"`
	Issued            string  `json:"issued"`
	Due               string  `json:"due"`
	Reference         string  `json:"reference,omitempty"`
	RemitToBeneficiary string `json:"remit_to_beneficiary,omitempty"`
	RemitToIBAN       string  `json:"remit_to_iban,omitempty"`
	RemittanceNote    string  `json:"remittance_note,omitempty"`
	Status            string  `json:"status"`
	PaidWithPaymentID string  `json:"paid_with_payment_id,omitempty"`
}

type paymentRequest struct {
	InvoiceID   string  `json:"invoice_id"`
	SupplierID  string  `json:"supplier_id"`
	Amount      float64 `json:"amount"`
	Currency    string  `json:"currency"`
	Beneficiary string  `json:"beneficiary"`
	IBAN        string  `json:"iban"`
}

type api struct {
	mu        sync.Mutex
	started   time.Time
	calls     map[string]int
	suppliers map[string]*supplier
	invoices  map[string]*invoice
	payments  []map[string]any
	paySeq    int
}

func orDash(s string) string {
	if s == "" {
		return "-"
	}
	return s
}

// normIBAN compares IBANs ignoring case and the spaces/grouping humans add.
func normIBAN(s string) string {
	return strings.ToUpper(strings.ReplaceAll(strings.TrimSpace(s), " ", ""))
}

func seedSuppliers() map[string]*supplier {
	return map[string]*supplier{
		"SUP-4021": {
			SupplierID:      "SUP-4021",
			Name:            "Nordwind Logistics GmbH",
			IBAN:            "DE89 3704 0044 0532 0130 00",
			BIC:             "COBADEFFXXX",
			VATID:           "DE302476119",
			Verified:        true,
			IBANOnFileSince: "2023-11-02",
			Country:         "DE",
		},
		"SUP-4088": {
			SupplierID:      "SUP-4088",
			Name:            "Baltica Freight Sp. z o.o.",
			IBAN:            "PL61 1090 1014 0000 0712 1981 2874",
			BIC:             "WBKPLPWXXX",
			VATID:           "PL5213345678",
			Verified:        true,
			IBANOnFileSince: "2024-04-18",
			Country:         "PL",
		},
	}
}

// handler builds the demo API: the health endpoint plus the payments API and
// the counting echo. A minimal security-header wrapper resolves what the
// scanner flagged on this service (nosniff missing, Cross-Origin-*-Policy
// missing); the demo API never embeds cross-origin resources, so the strict
// defaults are safe.
func handler() http.Handler {
	a := &api{
		started:   time.Now(),
		calls:     map[string]int{},
		suppliers: seedSuppliers(),
		invoices:  map[string]*invoice{},
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(rw http.ResponseWriter, _ *http.Request) {
		rw.Header().Set("Content-Type", "application/json")
		_, _ = rw.Write([]byte(`{"status":"ok","service":"demoapi","payments_api":true}`))
	})
	mux.HandleFunc("/", a.handle)
	return secureHeaders(mux)
}

// secureHeaders sets the defensive response headers ZAP's scan looks for on
// every response (mirrors the values used by the gateway stack's shared
// httpx.SecureHeaders middleware).
func secureHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(rw http.ResponseWriter, r *http.Request) {
		h := rw.Header()
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("Cross-Origin-Resource-Policy", "same-origin")
		h.Set("Cross-Origin-Opener-Policy", "same-origin")
		h.Set("Cross-Origin-Embedder-Policy", "require-corp")
		next.ServeHTTP(rw, r)
	})
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

// handle records the invocation, logs it to stdout (kubectl logs shows one
// line per EXECUTED call only — a held action produces nothing here), and
// dispatches to the payments API or the counting echo.
func (a *api) handle(rw http.ResponseWriter, r *http.Request) {
	a.mu.Lock()
	a.calls[r.URL.Path]++
	n := a.calls[r.URL.Path]
	a.mu.Unlock()

	log.Printf("executed method=%s path=%s count=%d user=%s agent=%s delegation=%s request=%s",
		r.Method, r.URL.Path, n,
		orDash(r.Header.Get("X-Auth-User")),
		orDash(r.Header.Get("X-Auth-Agent")),
		orDash(r.Header.Get("X-Delegation-ID")),
		orDash(r.Header.Get("X-Request-ID")))

	rw.Header().Set("Content-Type", "application/json")
	rw.Header().Set("X-Demoapi-Call-Count", strconv.Itoa(n))

	switch {
	case r.Method == http.MethodGet && strings.HasPrefix(r.URL.Path, "/suppliers/"):
		a.supplierGet(rw, r)
	case r.Method == http.MethodPost && r.URL.Path == "/invoices":
		a.invoicePost(rw, r, n)
	case r.Method == http.MethodGet && strings.HasPrefix(r.URL.Path, "/invoices/"):
		a.invoiceGet(rw, r, n)
	case r.Method == http.MethodPost && r.URL.Path == "/payments":
		a.paymentPost(rw, r, n)
	case r.Method == http.MethodGet && r.URL.Path == "/payments":
		a.paymentsGet(rw, r, n)
	case r.Method == http.MethodGet && (strings.HasPrefix(r.URL.Path, "/v1/search") || strings.Contains(r.URL.Path, "geocoding")):
		a.geocodingGet(rw, r, n)
	default:
		a.echo(rw, r, n)
	}
}

// geocodingGet proxies or responds to geocoding search queries, proving the
// request was executed behind the Agent Gateway with verified actor headers.
func (a *api) geocodingGet(rw http.ResponseWriter, r *http.Request, n int) {
	qs := r.URL.RawQuery
	if qs == "" {
		qs = "name=Berlin&count=5&language=en&format=json"
	}
	openMeteoURL := "https://geocoding-api.open-meteo.com/v1/search?" + qs
	client := &http.Client{Timeout: 4 * time.Second}
	resp, err := client.Get(openMeteoURL)
	if err == nil && resp.StatusCode == http.StatusOK {
		defer resp.Body.Close()
		var res map[string]any
		if err := json.NewDecoder(resp.Body).Decode(&res); err == nil {
			res["executed_count"] = n
			res["note"] = "executed BEHIND the Agent Gateway"
			res["service"] = "demoapi (open-meteo)"
			res["actor_headers"] = actorHeaders(r)
			writeJSON(rw, http.StatusOK, res)
			return
		}
	}
	writeJSON(rw, http.StatusOK, map[string]any{
		"status":            "ok",
		"service":           "demoapi (geocoding)",
		"executed_count":    n,
		"path":              r.URL.Path,
		"note":              "executed BEHIND the Agent Gateway",
		"actor_headers":     actorHeaders(r),
		"generationtime_ms": 0.15,
		"results": []map[string]any{
			{
				"id":           2950159,
				"name":         "Berlin",
				"latitude":     52.52437,
				"longitude":    13.41053,
				"elevation":    74.0,
				"feature_code": "PPLC",
				"country_code": "DE",
				"country":      "Germany",
				"admin1":       "Land Berlin",
				"timezone":     "Europe/Berlin",
				"population":   3644826,
			},
		},
	})
}

func actorHeaders(r *http.Request) map[string]string {
	return map[string]string{
		"X-Auth-User":     r.Header.Get("X-Auth-User"),
		"X-Auth-Agent":    r.Header.Get("X-Auth-Agent"),
		"X-Delegation-ID": r.Header.Get("X-Delegation-ID"),
		"X-Request-ID":    r.Header.Get("X-Request-ID"),
	}
}

// writeJSON is the shared response envelope; every handler funnels through it.
func writeJSON(rw http.ResponseWriter, code int, body map[string]any) {
	rw.WriteHeader(code)
	_ = json.NewEncoder(rw).Encode(body)
}

// echo is the original behavior: every unlisted path gets the counting echo.
// Demos 1–4 depend on this shape ("/orders", "/api/sensitive/payment", …).
func (a *api) echo(rw http.ResponseWriter, r *http.Request, n int) {
	_ = json.NewEncoder(rw).Encode(map[string]any{
		"status":         "ok",
		"service":        "demoapi",
		"executed_count": n,
		"path":           r.URL.Path,
		"note":           "executed BEHIND the Agent Gateway",
		"actor_headers":  actorHeaders(r),
	})
}

// supplierGet serves the supplier master record — the "bank details on file"
// a human (or a careful agent) compares a payment against.
func (a *api) supplierGet(rw http.ResponseWriter, r *http.Request) {
	id := strings.TrimPrefix(r.URL.Path, "/suppliers/")
	a.mu.Lock()
	s := a.suppliers[id]
	a.mu.Unlock()
	if s == nil {
		writeJSON(rw, http.StatusNotFound, map[string]any{
			"status": "not_found", "error": "unknown supplier " + id, "service": "demoapi",
		})
		return
	}
	writeJSON(rw, http.StatusOK, map[string]any{
		"status":        "ok",
		"service":       "demoapi",
		"supplier":      s,
		"actor_headers": actorHeaders(r),
	})
}

// invoicePost registers an invoice — the AP inbox. The demo script calls it
// OUT OF BAND (direct, not through the gateway): invoices arrive from the ERP,
// agents never inject them. Re-registering the same invoice resets it to
// "received" so a demo rerun starts clean.
func (a *api) invoicePost(rw http.ResponseWriter, r *http.Request, n int) {
	var inv invoice
	if err := json.NewDecoder(r.Body).Decode(&inv); err != nil {
		writeJSON(rw, http.StatusBadRequest, map[string]any{
			"status": "bad_request", "error": err.Error(), "service": "demoapi",
		})
		return
	}
	if inv.InvoiceID == "" || inv.SupplierID == "" || inv.Amount <= 0 {
		writeJSON(rw, http.StatusUnprocessableEntity, map[string]any{
			"status": "invalid_invoice", "error": "invoice_id, supplier_id and a positive amount are required", "service": "demoapi",
		})
		return
	}
	a.mu.Lock()
	if inv.Status == "" {
		inv.Status = "received"
	}
	inv.PaidWithPaymentID = "" // a re-received invoice is payable again
	a.invoices[inv.InvoiceID] = &inv
	a.mu.Unlock()

	writeJSON(rw, http.StatusOK, map[string]any{
		"status":         "ok",
		"service":        "demoapi",
		"executed_count": n,
		"invoice":        inv,
		"note":           "invoice received into the AP inbox (out of band — agents do not have this path)",
		"actor_headers":  actorHeaders(r),
	})
}

// invoiceGet serves an invoice enriched with the beneficiary check every
// downstream consumer can do but nothing here acts on: does the invoice's
// "remit-to" IBAN match the supplier record? The data is the evidence; the
// decision stays with the human at the gateway.
func (a *api) invoiceGet(rw http.ResponseWriter, r *http.Request, n int) {
	id := strings.TrimPrefix(r.URL.Path, "/invoices/")
	a.mu.Lock()
	inv := a.invoices[id]
	var sup *supplier
	if inv != nil {
		sup = a.suppliers[inv.SupplierID]
	}
	a.mu.Unlock()
	if inv == nil {
		writeJSON(rw, http.StatusNotFound, map[string]any{
			"status": "not_found", "error": "unknown invoice " + id, "service": "demoapi",
		})
		return
	}
	match := map[string]any{
		"status":         "ok",
		"service":        "demoapi",
		"executed_count": n,
		"invoice":        inv,
		"actor_headers":  actorHeaders(r),
	}
	if sup != nil {
		match["supplier_record_iban"] = sup.IBAN
		if inv.RemitToIBAN != "" {
			match["beneficiary_matches_supplier"] = normIBAN(inv.RemitToIBAN) == normIBAN(sup.IBAN)
		}
	}
	writeJSON(rw, http.StatusOK, match)
}

// paymentPost EXECUTES a payment. The gateway only lets a call through here
// once the delegating human approved that exact action — but the API keeps
// controls of its own: the invoice must exist, the amount must match, the
// invoice must not already be paid, and the beneficiary IBAN must match the
// supplier record (the backstop that holds even if every layer above it failed).
func (a *api) paymentPost(rw http.ResponseWriter, r *http.Request, n int) {
	var pr paymentRequest
	if err := json.NewDecoder(r.Body).Decode(&pr); err != nil {
		writeJSON(rw, http.StatusBadRequest, map[string]any{
			"status": "bad_request", "error": err.Error(), "service": "demoapi",
		})
		return
	}

	a.mu.Lock()
	inv := a.invoices[pr.InvoiceID]
	sup := a.suppliers[pr.SupplierID]
	if inv == nil {
		a.mu.Unlock()
		writeJSON(rw, http.StatusNotFound, map[string]any{
			"status": "not_found", "error": "unknown invoice " + pr.InvoiceID, "service": "demoapi",
		})
		return
	}
	if inv.Status == "paid" {
		a.mu.Unlock()
		writeJSON(rw, http.StatusConflict, map[string]any{
			"status": "already_paid", "error": "invoice " + pr.InvoiceID + " was already paid",
			"paid_with_payment_id": inv.PaidWithPaymentID, "service": "demoapi",
		})
		return
	}
	if pr.Amount != inv.Amount || (pr.Currency != "" && inv.Currency != "" && pr.Currency != inv.Currency) {
		a.mu.Unlock()
		writeJSON(rw, http.StatusConflict, map[string]any{
			"status": "amount_mismatch", "error": "payment amount does not match the invoice",
			"invoiced_amount": inv.Amount, "proposed_amount": pr.Amount, "service": "demoapi",
		})
		return
	}
	if sup != nil && pr.IBAN != "" && normIBAN(pr.IBAN) != normIBAN(sup.IBAN) {
		a.mu.Unlock()
		writeJSON(rw, http.StatusConflict, map[string]any{
			"status": "beneficiary_mismatch",
			"error":  "proposed beneficiary does not match the supplier record on file — payment refused by the API's own control",
			"supplier_record_iban": sup.IBAN, "proposed_iban": pr.IBAN, "service": "demoapi",
		})
		return
	}

	a.paySeq++
	payID := fmt.Sprintf("PAY-2026-%06d", a.paySeq)
	inv.Status = "paid"
	inv.PaidWithPaymentID = payID
	record := map[string]any{
		"status":        "executed",
		"service":       "demoapi",
		"payment_id":    payID,
		"invoice_id":    pr.InvoiceID,
		"supplier_id":   pr.SupplierID,
		"beneficiary":   pr.Beneficiary,
		"iban":          pr.IBAN,
		"amount":        pr.Amount,
		"currency":      pr.Currency,
		"executed_count": n,
		"note":          "executed BEHIND the Agent Gateway",
		"actor_headers": actorHeaders(r),
	}
	a.payments = append(a.payments, record)
	a.mu.Unlock()

	writeJSON(rw, http.StatusOK, record)
}

// paymentsGet lists executed payments and repeats the per-path counter — the
// demo's exactly-once evidence, readable out of band.
func (a *api) paymentsGet(rw http.ResponseWriter, r *http.Request, n int) {
	a.mu.Lock()
	list := append([]map[string]any{}, a.payments...)
	a.mu.Unlock()
	writeJSON(rw, http.StatusOK, map[string]any{
		"status":         "ok",
		"service":        "demoapi",
		"executed_count": n,
		"payments":       list,
		"actor_headers":  actorHeaders(r),
	})
}
