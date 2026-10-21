package main

// Demo MCP server for the Agent Gateway "MCP under the gateway" demo
// (Demo 9). Same shape as the standalone demo_mcp server: streamable-HTTP
// MCP at /mcp plus a /health endpoint. Extended with a small in-memory CRM
// store so the demo has a business-flavoured story:
//
//	add_customer · lookup_customer · list_customers   (new, demo 9)
//	add · echo · get_info                             (kept from demo_mcp)
//
// A read-only REST view (GET /customers) lets scripts prove out-of-band
// that a customer was actually created — the MCP equivalent of demoapi's
// executed_count counter.

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/mark3labs/mcp-go/mcp"
	"github.com/mark3labs/mcp-go/server"
)

// ---------------------------------------------------------------------------
// in-memory customer store
// ---------------------------------------------------------------------------

// Customer is one CRM record. JSON tags make it printable from both the MCP
// tool results and the REST view.
type Customer struct {
	ID        string `json:"id"`
	FirstName string `json:"first_name"`
	LastName  string `json:"last_name"`
	Email     string `json:"email"`
	Company   string `json:"company,omitempty"`
	CreatedAt string `json:"created_at"`
}

type customerStore struct {
	mu        sync.Mutex
	next      int
	customers map[string]Customer
}

func newCustomerStore() *customerStore {
	s := &customerStore{next: 0, customers: make(map[string]Customer)}
	// Two seeded records so lookup_customer has something to find before
	// the demo's add step.
	s.addCustomer("Ada", "Lovelace", "ada@example.com", "Analytical Engines Ltd")
	s.addCustomer("Grace", "Hopper", "grace@example.com", "Naval Systems")
	return s
}

func (s *customerStore) addCustomer(first, last, email, company string) Customer {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.next++
	c := Customer{
		ID:        fmt.Sprintf("CUST-%04d", s.next),
		FirstName: first,
		LastName:  last,
		Email:     email,
		Company:   company,
		CreatedAt: time.Now().UTC().Format(time.RFC3339),
	}
	s.customers[c.ID] = c
	return c
}

func (s *customerStore) getByID(id string) (Customer, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	c, ok := s.customers[strings.ToUpper(id)]
	return c, ok
}

// lookup matches one record by email (case-insensitive), by id
// (case-insensitive, with or without the CUST- prefix) or by "First Last".
// Empty query matches nothing.
func (s *customerStore) lookup(query string) (Customer, bool) {
	q := strings.TrimSpace(strings.ToLower(query))
	if q == "" {
		return Customer{}, false
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	// id first (accept "42" as well as "CUST-0042")
	if strings.HasPrefix(q, "cust-") || isDigits(q) {
		id := q
		if !strings.HasPrefix(q, "cust-") {
			id = fmt.Sprintf("cust-%04s", q)
		}
		if c, ok := s.customers[strings.ToUpper(id)]; ok {
			return c, true
		}
	}
	all := make([]Customer, 0, len(s.customers))
	for _, c := range s.customers {
		all = append(all, c)
	}
	sort.Slice(all, func(i, j int) bool { return all[i].ID < all[j].ID })
	for _, c := range all {
		if strings.ToLower(c.Email) == q ||
			strings.ToLower(c.FirstName+" "+c.LastName) == q {
			return c, true
		}
	}
	return Customer{}, false
}

func (s *customerStore) list() []Customer {
	s.mu.Lock()
	defer s.mu.Unlock()
	all := make([]Customer, 0, len(s.customers))
	for _, c := range s.customers {
		all = append(all, c)
	}
	sort.Slice(all, func(i, j int) bool { return all[i].ID < all[j].ID })
	return all
}

// remove deletes by id (case-insensitive, with or without CUST- prefix) and
// returns the removed record. This is the Demo 9 Part D surface: the gateway
// reads DELETE /customers/* as its own action ("delete"), so the delegation
// can hold every deletion for a human decision.
func (s *customerStore) remove(id string) (Customer, bool) {
	key := strings.ToUpper(strings.TrimSpace(id))
	if key != "" && isDigits(strings.TrimPrefix(strings.ToLower(key), "cust-")) {
		if !strings.HasPrefix(key, "CUST-") {
			key = fmt.Sprintf("CUST-%04s", strings.TrimPrefix(key, "CUST-"))
		}
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	c, ok := s.customers[key]
	if !ok {
		return Customer{}, false
	}
	delete(s.customers, key)
	return c, true
}

func isDigits(s string) bool {
	if s == "" {
		return false
	}
	for _, r := range s {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}

// validEmail is deliberately minimal: local@domain. Real validation stays
// with the caller.
func validEmail(e string) bool {
	at := strings.Index(e, "@")
	return at > 0 && at < len(e)-1
}

var store = newCustomerStore()

// ---------------------------------------------------------------------------
// entry point
// ---------------------------------------------------------------------------

func main() {
	host := os.Getenv("MCP_HOST")
	if host == "" {
		host = "0.0.0.0"
	}

	portStr := os.Getenv("MCP_PORT")
	if portStr == "" {
		portStr = "8091"
	}
	port, err := strconv.Atoi(portStr)
	if err != nil {
		log.Fatalf("Invalid port number: %s", portStr)
	}

	transport := os.Getenv("MCP_TRANSPORT")
	if transport == "" {
		transport = "streamable-http"
	}

	mcpServer := server.NewMCPServer(
		"Demo MCP Server",
		"1.1.0",
		server.WithToolCapabilities(true),
		server.WithResourceCapabilities(true, false),
	)

	addTools(mcpServer)
	addResources(mcpServer)

	fmt.Printf("Starting MCP server with transport=%s, host=%s, port=%d\n",
		transport, host, port)

	if transport == "streamable-http" {
		addr := fmt.Sprintf("%s:%d", host, port)

		mux := http.NewServeMux()
		// /healthz is the repo convention (compose healthcheck + ZAP scan);
		// /health is the original demo_mcp path, kept for compatibility.
		mux.HandleFunc("/health", healthHandler)
		mux.HandleFunc("/healthz", healthHandler)
		// Read-only REST view of the store: proof-of-execution for the
		// demo scripts (out of band, like `curl :8090/api/sensitive/wire`).
		mux.HandleFunc("/customers", func(w http.ResponseWriter, r *http.Request) {
			if r.Method != http.MethodGet {
				http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
				return
			}
			w.Header().Set("Content-Type", "application/json")
			json.NewEncoder(w).Encode(map[string]interface{}{
				"count":     len(store.list()),
				"customers": store.list(),
			})
		})
		// Deletion (Demo 9 Part D): a plain REST surface the gateway can
		// tell apart — DELETE /customers/{id} derives resource=/customers*,
		// action=delete, which a delegation's approval rule can hold for a
		// human decision. GET /customers stays read-only proof-of-state.
		mux.HandleFunc("/customers/", func(w http.ResponseWriter, r *http.Request) {
			if r.Method != http.MethodDelete {
				http.Error(w, "method not allowed (DELETE /customers/{id})", http.StatusMethodNotAllowed)
				return
			}
			id := strings.TrimPrefix(r.URL.Path, "/customers/")
			removed, ok := store.remove(id)
			if !ok {
				http.Error(w, `{"error":"customer not found"}`, http.StatusNotFound)
				return
			}
			w.Header().Set("Content-Type", "application/json")
			json.NewEncoder(w).Encode(map[string]interface{}{
				"removed":   removed,
				"remaining": len(store.list()),
			})
		})

		httpServer := server.NewStreamableHTTPServer(
			mcpServer,
			server.WithStateLess(true),
			server.WithEndpointPath("/mcp"),
		)
		mux.Handle("/mcp", httpServer)
		mux.Handle("/mcp/", httpServer)

		fmt.Printf("Starting Streamable HTTP server at http://%s/mcp\n", addr)
		if err := http.ListenAndServe(addr, mux); err != nil {
			log.Fatalf("Server error: %v", err)
		}
	} else if transport == "sse" {
		addr := fmt.Sprintf("%s:%d", host, port)
		fmt.Printf("Starting SSE server at http://%s/sse\n", addr)

		sseServer := server.NewSSEServer(mcpServer)
		mux := http.NewServeMux()
		mux.HandleFunc("/health", healthHandler)
		mux.Handle("/sse", sseServer.SSEHandler())
		mux.Handle("/message", sseServer.MessageHandler())
		if err := http.ListenAndServe(addr, mux); err != nil {
			log.Fatalf("Server error: %v", err)
		}
	} else if transport == "stdio" {
		fmt.Println("Starting stdio server")
		if err := server.ServeStdio(mcpServer); err != nil {
			log.Fatalf("Server error: %v", err)
		}
	} else {
		log.Fatalf("Unknown transport: %s", transport)
	}
}

func healthHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	w.Write([]byte(`{"status":"healthy"}`))
}

// ---------------------------------------------------------------------------
// tools
// ---------------------------------------------------------------------------

func addTools(s *server.MCPServer) {
	// Demo 9 business tools ----------------------------------------------
	addCustomerTool := mcp.NewTool("add_customer",
		mcp.WithDescription("Add a new customer to the CRM and return the new customer record"),
		mcp.WithString("first_name", mcp.Required(), mcp.Description("Customer's first name")),
		mcp.WithString("last_name", mcp.Required(), mcp.Description("Customer's last name")),
		mcp.WithString("email", mcp.Required(), mcp.Description("Customer's email address")),
		mcp.WithString("company", mcp.Description("Customer's company (optional)")),
	)
	s.AddTool(addCustomerTool, addCustomerHandler)

	lookupCustomerTool := mcp.NewTool("lookup_customer",
		mcp.WithDescription("Look up an existing customer by email, customer id (CUST-0001 or 1) or \"First Last\""),
		mcp.WithString("query", mcp.Required(), mcp.Description("Email, customer id or full name to look up")),
	)
	s.AddTool(lookupCustomerTool, lookupCustomerHandler)

	listCustomersTool := mcp.NewTool("list_customers",
		mcp.WithDescription("List every customer in the CRM (id, name, email, company)"),
	)
	s.AddTool(listCustomersTool, listCustomersHandler)

	// Plumbing tools kept from the original demo server --------------------
	addTool := mcp.NewTool("add",
		mcp.WithDescription("Add two numbers together"),
		mcp.WithNumber("a", mcp.Required(), mcp.Description("First number")),
		mcp.WithNumber("b", mcp.Required(), mcp.Description("Second number")),
	)
	s.AddTool(addTool, addHandler)

	echoTool := mcp.NewTool("echo",
		mcp.WithDescription("Echo back the provided message"),
		mcp.WithString("message", mcp.Required(), mcp.Description("Message to echo")),
	)
	s.AddTool(echoTool, echoHandler)

	infoTool := mcp.NewTool("get_info",
		mcp.WithDescription("Get information about this MCP server"),
	)
	s.AddTool(infoTool, infoHandler)
}

// --- demo 9 handlers --------------------------------------------------------

func addCustomerHandler(ctx context.Context, request mcp.CallToolRequest) (*mcp.CallToolResult, error) {
	args := request.GetArguments()

	first, _ := args["first_name"].(string)
	last, _ := args["last_name"].(string)
	email, _ := args["email"].(string)
	company, _ := args["company"].(string)

	if strings.TrimSpace(first) == "" {
		return mcp.NewToolResultError("parameter 'first_name' is required and must be a non-empty string"), nil
	}
	if strings.TrimSpace(last) == "" {
		return mcp.NewToolResultError("parameter 'last_name' is required and must be a non-empty string"), nil
	}
	if !validEmail(email) {
		return mcp.NewToolResultError("parameter 'email' is required and must contain a local part and a domain (name@example.com)"), nil
	}

	c := store.addCustomer(strings.TrimSpace(first), strings.TrimSpace(last),
		strings.TrimSpace(email), strings.TrimSpace(company))
	out, _ := json.Marshal(c)
	return mcp.NewToolResultText(fmt.Sprintf("Customer created: %s — name: %s %s, email: %s, company: %s; record: %s",
		c.ID, c.FirstName, c.LastName, c.Email, c.Company, out)), nil
}

func lookupCustomerHandler(ctx context.Context, request mcp.CallToolRequest) (*mcp.CallToolResult, error) {
	query, _ := request.GetArguments()["query"].(string)
	if strings.TrimSpace(query) == "" {
		return mcp.NewToolResultError("parameter 'query' is required: email, customer id (e.g. CUST-0002) or \"First Last\""), nil
	}

	c, ok := store.lookup(query)
	if !ok {
		return mcp.NewToolResultText(fmt.Sprintf("No customer found for %q. Use list_customers to see all records.", query)), nil
	}
	out, _ := json.Marshal(c)
	return mcp.NewToolResultText("Customer found: " + string(out)), nil
}

func listCustomersHandler(ctx context.Context, request mcp.CallToolRequest) (*mcp.CallToolResult, error) {
	all := store.list()
	var b strings.Builder
	fmt.Fprintf(&b, "%d customers:\n", len(all))
	for _, c := range all {
		fmt.Fprintf(&b, "- %s: %s %s <%s>", c.ID, c.FirstName, c.LastName, c.Email)
		if c.Company != "" {
			fmt.Fprintf(&b, " (%s)", c.Company)
		}
		b.WriteString("\n")
	}
	return mcp.NewToolResultText(b.String()), nil
}

// --- plumbing handlers (demo_mcp originals) ---------------------------------

func addHandler(ctx context.Context, request mcp.CallToolRequest) (*mcp.CallToolResult, error) {
	args := request.GetArguments()

	a, ok := args["a"].(float64)
	if !ok {
		return mcp.NewToolResultError("parameter 'a' is required and must be a number"), nil
	}

	b, ok := args["b"].(float64)
	if !ok {
		return mcp.NewToolResultError("parameter 'b' is required and must be a number"), nil
	}

	result := a + b
	return mcp.NewToolResultText(fmt.Sprintf("Result: %v + %v = %v", a, b, result)), nil
}

func echoHandler(ctx context.Context, request mcp.CallToolRequest) (*mcp.CallToolResult, error) {
	args := request.GetArguments()

	message, ok := args["message"].(string)
	if !ok {
		return mcp.NewToolResultError("parameter 'message' is required and must be a string"), nil
	}

	return mcp.NewToolResultText(fmt.Sprintf("You said: %s", message)), nil
}

func infoHandler(ctx context.Context, request mcp.CallToolRequest) (*mcp.CallToolResult, error) {
	info := map[string]interface{}{
		"name":          "Demo MCP Server",
		"version":       "1.1.0",
		"description":   "CRM-flavoured MCP server for the Agent Gateway MCP demo (Demo 9)",
		"tools":         []string{"add_customer", "lookup_customer", "list_customers", "add", "echo", "get_info"},
		"resources":     []string{"config://server"},
		"customers_url": "/customers",
	}
	out, _ := json.Marshal(info)
	return mcp.NewToolResultText(string(out)), nil
}

// ---------------------------------------------------------------------------
// resources
// ---------------------------------------------------------------------------

func addResources(s *server.MCPServer) {
	configResource := mcp.NewResource(
		"config://server",
		"Server Configuration",
		mcp.WithResourceDescription("Current server configuration and status"),
		mcp.WithMIMEType("application/json"),
	)
	s.AddResource(configResource, configResourceHandler)
}

func configResourceHandler(ctx context.Context, request mcp.ReadResourceRequest) ([]mcp.ResourceContents, error) {
	content := fmt.Sprintf(`{
  "server": "Demo MCP Server",
  "version": "1.1.0",
  "transport": "%s",
  "host": "%s",
  "port": "%s",
  "status": "running",
  "customers": %d
}`, os.Getenv("MCP_TRANSPORT"), os.Getenv("MCP_HOST"), os.Getenv("MCP_PORT"), len(store.list()))

	return []mcp.ResourceContents{
		mcp.TextResourceContents{
			URI:      request.Params.URI,
			MIMEType: "application/json",
			Text:     content,
		},
	}, nil
}
