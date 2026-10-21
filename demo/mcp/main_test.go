package main

import (
	"testing"
)

// The store is the server's real state; these tests cover the behaviours
// the Demo 9 script relies on: seeded records, the id scheme, lookup by
// email / id / name, and email validation.

func TestStoreSeedsAndAdds(t *testing.T) {
	s := newCustomerStore()
	if got := len(s.list()); got != 2 {
		t.Fatalf("expected 2 seeded customers, got %d", got)
	}

	c := s.addCustomer("Jane", "Doe", "jane@example.com", "")
	if c.ID != "CUST-0003" {
		t.Fatalf("expected sequential id CUST-0003, got %s", c.ID)
	}
	if got := len(s.list()); got != 3 {
		t.Fatalf("expected 3 customers after add, got %d", got)
	}
}

func TestLookup(t *testing.T) {
	s := newCustomerStore()
	s.addCustomer("Jane", "Doe", "jane@example.com", "Acme")

	cases := []struct {
		query string
		want  string // "" = expect no match
	}{
		{"ada@example.com", "CUST-0001"},
		{"ADA@EXAMPLE.COM", "CUST-0001"},
		{"CUST-0002", "CUST-0002"},
		{"2", "CUST-0002"}, // bare numeric id
		{"grace hopper", "CUST-0002"},
		{"jane@example.com", "CUST-0003"},
		{"nobody@example.com", ""},
		{"CUST-9999", ""},
		{"", ""},
	}
	for _, tc := range cases {
		c, ok := s.lookup(tc.query)
		if tc.want == "" && ok {
			t.Errorf("lookup(%q) unexpectedly matched %s", tc.query, c.ID)
		}
		if tc.want != "" && (!ok || c.ID != tc.want) {
			t.Errorf("lookup(%q) = %v, ok=%v; want %s", tc.query, c, ok, tc.want)
		}
	}
}

func TestRemove(t *testing.T) {
	s := newCustomerStore()
	c, ok := s.remove("CUST-0001")
	if !ok || c.ID != "CUST-0001" {
		t.Fatalf("remove(CUST-0001) = %v ok=%v", c, ok)
	}
	if got := len(s.list()); got != 1 {
		t.Fatalf("expected 1 customer after remove, got %d", got)
	}
	// bare numeric id, then a miss
	if _, ok := s.remove("2"); !ok {
		t.Error("remove(\"2\") should match CUST-0002")
	}
	if _, ok := s.remove("CUST-9999"); ok {
		t.Error("remove of unknown id must fail")
	}
	if _, ok := s.remove("grace"); ok {
		t.Error("remove by name must not delete anything")
	}
}

func TestValidEmail(t *testing.T) {
	cases := map[string]bool{
		"jane@example.com": true,
		"@example.com":     false,
		"jane@":            false,
		"jane":             false,
		"":                 false,
	}
	for in, want := range cases {
		if got := validEmail(in); got != want {
			t.Errorf("validEmail(%q) = %v, want %v", in, got, want)
		}
	}
}

func TestLookupBareNumID(t *testing.T) {
	// covers the CUST-%04s branch for single-digit ids
	s := newCustomerStore()
	if c, ok := s.lookup("1"); !ok || c.ID != "CUST-0001" {
		t.Fatalf("lookup(\"1\") = %v ok=%v; want CUST-0001", c, ok)
	}
}
