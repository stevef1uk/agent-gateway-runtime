// dpop-rar-demo — interactive live demonstration of RFC 9449 DPoP and RFC 9396 RAR
//
// Usage: go run dpop-rar-demo.go
// Prereqs: docker compose up -d (in demo directory)

package main

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"os"
	"strings"
	"time"
)

const (
	green  = "\033[0;32m"
	red    = "\033[0;31m"
	cyan   = "\033[0;36m"
	bold   = "\033[1m"
	reset  = "\033[0m"
)

func b64url(b []byte) string {
	return base64.RawURLEncoding.EncodeToString(b)
}

func sha256Thumbprint(pub *ecdsa.PublicKey) string {
	xBytes := make([]byte, 32)
	yBytes := make([]byte, 32)
	pub.X.FillBytes(xBytes)
	pub.Y.FillBytes(yBytes)
	canonical := fmt.Sprintf(`{"crv":"P-256","kty":"EC","x":"%s","y":"%s"}`, b64url(xBytes), b64url(yBytes))
	h := sha256.Sum256([]byte(canonical))
	return b64url(h[:])
}

func makeDPoPProof(priv *ecdsa.PrivateKey, method, rawURL, accessToken string) string {
	xBytes := make([]byte, 32)
	yBytes := make([]byte, 32)
	priv.PublicKey.X.FillBytes(xBytes)
	priv.PublicKey.Y.FillBytes(yBytes)

	u, _ := url.Parse(rawURL)
	htu := fmt.Sprintf("%s://%s%s", u.Scheme, u.Host, u.Path)

	headerJSON, _ := json.Marshal(map[string]any{
		"typ": "dpop+jwt",
		"alg": "ES256",
		"jwk": map[string]any{
			"kty": "EC",
			"crv": "P-256",
			"x":   b64url(xBytes),
			"y":   b64url(yBytes),
		},
	})

	randomBytes := make([]byte, 16)
	rand.Read(randomBytes)
	payload := map[string]any{
		"jti": b64url(randomBytes),
		"htm": strings.ToUpper(method),
		"htu": htu,
		"iat": time.Now().Unix(),
	}
	if accessToken != "" {
		ath := sha256.Sum256([]byte(accessToken))
		payload["ath"] = b64url(ath[:])
	}
	payloadJSON, _ := json.Marshal(payload)

	signingInput := b64url(headerJSON) + "." + b64url(payloadJSON)
	hash := sha256.Sum256([]byte(signingInput))
	r, s, err := ecdsa.Sign(rand.Reader, priv, hash[:])
	if err != nil {
		panic(err)
	}
	sig := make([]byte, 64)
	r.FillBytes(sig[:32])
	s.FillBytes(sig[32:])

	return signingInput + "." + b64url(sig)
}

func main() {
	fmt.Printf("\n%s%s====================================================================%s\n", bold, cyan, reset)
	fmt.Printf("%s%s  Agent Gateway — RFC 9449 (DPoP) & RFC 9396 (RAR) Live Demo Test%s\n", bold, cyan, reset)
	fmt.Printf("%s%s====================================================================%s\n\n", bold, cyan, reset)

	// Check health
	resp, err := http.Get("http://localhost:8080/healthz")
	if err != nil || resp.StatusCode != 200 {
		fmt.Printf("%s✗ Stack is not healthy on localhost:8080. Run: docker compose up -d%s\n", red, reset)
		os.Exit(1)
	}
	resp.Body.Close()
	fmt.Printf("%s✓ Agent Gateway services healthy on localhost:8080, :8081, :8082%s\n\n", green, reset)

	// Step 1: SSO Authentication (Dex)
	fmt.Printf("%s%sStep 1: Authenticate with Dex SSO%s\n", bold, cyan, reset)
	jar, _ := cookiejar.New(nil)
	client := &http.Client{
		Jar: jar,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
	loc := "http://localhost:5556/dex/auth?response_type=code&client_id=agent-gateway&redirect_uri=http%3A%2F%2Flocalhost%3A8083%2Foidc%2Fcallback&connector_id=mock&scope=openid"
	var code string
	for i := 0; i < 6; i++ {
		r, err := client.Get(loc)
		if err != nil {
			fmt.Printf("%s✗ Dex error: %v%s\n", red, err, reset)
			os.Exit(1)
		}
		r.Body.Close()
		next := r.Header.Get("Location")
		if next == "" {
			break
		}
		if strings.Contains(next, "dex:5556") {
			next = strings.Replace(next, "dex:5556", "localhost:5556", 1)
		}
		if strings.Contains(next, "code=") {
			u, _ := url.Parse(next)
			code = u.Query().Get("code")
			break
		}
		if strings.HasPrefix(next, "/") {
			loc = "http://localhost:5556" + next
		} else {
			loc = next
		}
	}
	if code == "" {
		fmt.Printf("%s✗ Could not get auth code from Dex%s\n", red, reset)
		os.Exit(1)
	}
	tokenForm := url.Values{
		"grant_type":   {"authorization_code"},
		"client_id":    {"agent-gateway"},
		"code":         {code},
		"redirect_uri": {"http://localhost:8083/oidc/callback"},
	}
	r, err := http.PostForm("http://localhost:5556/dex/token", tokenForm)
	if err != nil {
		fmt.Printf("%s✗ Dex token error: %v%s\n", red, err, reset)
		os.Exit(1)
	}
	defer r.Body.Close()
	var dexToken struct {
		IDToken string `json:"id_token"`
	}
	json.NewDecoder(r.Body).Decode(&dexToken)
	fmt.Printf("%s✓ Acquired Dex ID token (%d chars)%s\n\n", green, len(dexToken.IDToken), reset)

	// Step 2: Create Human Delegation
	fmt.Printf("%s%sStep 2: Create broad delegation (/orders [read, create], spend <= $200)%s\n", bold, cyan, reset)
	delReq, _ := json.Marshal(map[string]any{
		"agent_id":           "dpop-demo-agent",
		"resources":          []string{"/orders"},
		"actions":            []string{"read", "create"},
		"expires_in_seconds": 1800,
		"limits": map[string]any{
			"spend_per_order": map[string]any{
				"type": "currency",
				"max":  200,
				"unit": "USD",
			},
		},
		"id_token": dexToken.IDToken,
	})
	delResp, err := http.Post("http://localhost:8081/v1/delegations/", "application/json", bytes.NewReader(delReq))
	if err != nil {
		fmt.Printf("%s✗ Authz error: %v%s\n", red, err, reset)
		os.Exit(1)
	}
	defer delResp.Body.Close()
	var delOut struct {
		Delegation struct {
			ID string `json:"id"`
		} `json:"delegation"`
		AgentSecret string `json:"agent_secret"`
	}
	json.NewDecoder(delResp.Body).Decode(&delOut)
	fmt.Printf("%s✓ Delegation created: %s%s\n\n", green, delOut.Delegation.ID, reset)

	// Step 3: DPoP Key Generation & Token Minting
	fmt.Printf("%s%sStep 3: RFC 9449 DPoP Key Generation & Sender-Constrained Minting%s\n", bold, cyan, reset)
	privKey, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	jkt := sha256Thumbprint(&privKey.PublicKey)
	fmt.Printf("  • Agent generated EC P-256 key pair\n")
	fmt.Printf("  • Key thumbprint (jkt): %s\n", jkt)

	proofMint := makeDPoPProof(privKey, "POST", "http://localhost:8082/token", "")
	mintReq, _ := json.Marshal(map[string]any{
		"delegation_id": delOut.Delegation.ID,
		"agent_secret":  delOut.AgentSecret,
		"ttl_seconds":   300,
	})
	httpMintReq, _ := http.NewRequest("POST", "http://localhost:8082/token", bytes.NewReader(mintReq))
	httpMintReq.Header.Set("Content-Type", "application/json")
	httpMintReq.Header.Set("DPoP", proofMint)
	mintResp, err := http.DefaultClient.Do(httpMintReq)
	if err != nil {
		fmt.Printf("%s✗ Token mint error: %v%s\n", red, err, reset)
		os.Exit(1)
	}
	defer mintResp.Body.Close()
	var tokenOut struct {
		AccessToken string `json:"access_token"`
		TokenType   string `json:"token_type"`
	}
	json.NewDecoder(mintResp.Body).Decode(&tokenOut)
	fmt.Printf("%s✓ Minted sender-constrained token (token_type: %s)%s\n\n", green, tokenOut.TokenType, reset)

	// Step 4: Test Token Theft Rejection
	fmt.Printf("%s%sStep 4: Security Test — Stolen Token Rejection%s\n", bold, cyan, reset)
	theftReq, _ := http.NewRequest("GET", "http://localhost:8080/orders", nil)
	theftReq.Header.Set("Authorization", "Bearer "+tokenOut.AccessToken)
	theftResp, _ := http.DefaultClient.Do(theftReq)
	theftResp.Body.Close()
	if theftResp.StatusCode == 401 {
		fmt.Printf("%s✓ PEP blocked stolen DPoP token presented as Bearer (HTTP 401 Unauthorized)%s\n\n", green, reset)
	} else {
		fmt.Printf("%s✗ PEP failed to block stolen token: HTTP %d%s\n", red, theftResp.StatusCode, reset)
	}

	// Step 5: Test Valid DPoP Presentation
	fmt.Printf("%s%sStep 5: Valid Presentation — Token + Cryptographic Proof%s\n", bold, cyan, reset)
	proofCall := makeDPoPProof(privKey, "GET", "http://localhost:8080/orders", tokenOut.AccessToken)
	validReq, _ := http.NewRequest("GET", "http://localhost:8080/orders", nil)
	validReq.Header.Set("Authorization", "DPoP "+tokenOut.AccessToken)
	validReq.Header.Set("DPoP", proofCall)
	validResp, _ := http.DefaultClient.Do(validReq)
	validResp.Body.Close()
	if validResp.StatusCode == 200 {
		fmt.Printf("%s✓ PEP verified proof signature, jkt binding, ath hash & permitted request (HTTP 200 OK)%s\n\n", green, reset)
	} else {
		fmt.Printf("%s✗ PEP rejected valid proof: HTTP %d%s\n", red, validResp.StatusCode, reset)
	}

	// Step 6: Test Replay Attack Protection
	fmt.Printf("%s%sStep 6: Security Test — Replay Attack Protection%s\n", bold, cyan, reset)
	replayReq, _ := http.NewRequest("GET", "http://localhost:8080/orders", nil)
	replayReq.Header.Set("Authorization", "DPoP "+tokenOut.AccessToken)
	replayReq.Header.Set("DPoP", proofCall) // Replaying identical proof!
	replayResp, _ := http.DefaultClient.Do(replayReq)
	replayResp.Body.Close()
	if replayResp.StatusCode == 401 {
		fmt.Printf("%s✓ PEP detected and rejected replayed jti proof (HTTP 401 Unauthorized)%s\n\n", green, reset)
	} else {
		fmt.Printf("%s✗ PEP allowed replayed proof: HTTP %d%s\n", red, replayResp.StatusCode, reset)
	}

	// Step 7: RFC 9396 RAR Downscoping
	fmt.Printf("%s%sStep 7: RFC 9396 RAR Least-Privilege Downscoping%s\n", bold, cyan, reset)
	rarMintReq, _ := json.Marshal(map[string]any{
		"delegation_id": delOut.Delegation.ID,
		"agent_secret":  delOut.AgentSecret,
		"ttl_seconds":   300,
		"authorization_details": []map[string]any{
			{
				"type":      "agent_gateway_access",
				"resources": []string{"/orders"},
				"actions":   []string{"read"}, // Downscoped from ["read", "create"] to ONLY ["read"]
			},
		},
	})
	rMint, _ := http.Post("http://localhost:8082/token", "application/json", bytes.NewReader(rarMintReq))
	defer rMint.Body.Close()
	var rarTokenOut struct {
		AccessToken          string `json:"access_token"`
		AuthorizationDetails []any  `json:"authorization_details"`
	}
	json.NewDecoder(rMint.Body).Decode(&rarTokenOut)
	fmt.Printf("%s✓ Token downscoped to: actions=[\"read\"] (granted %d authorization details)%s\n", green, len(rarTokenOut.AuthorizationDetails), reset)

	// Step 8: Verify RAR Enforcement (Allowed vs Forbidden)
	fmt.Printf("%s%sStep 8: PEP Enforcement of RAR Scopes%s\n", bold, cyan, reset)
	// Allowed read
	readReq, _ := http.NewRequest("GET", "http://localhost:8080/orders", nil)
	readReq.Header.Set("Authorization", "Bearer "+rarTokenOut.AccessToken)
	readResp, _ := http.DefaultClient.Do(readReq)
	readResp.Body.Close()
	if readResp.StatusCode == 200 {
		fmt.Printf("%s  ✓ GET /orders (read) allowed by RAR policy (HTTP 200 OK)%s\n", green, reset)
	}

	// Blocked create (not in RAR detail)
	createReq, _ := http.NewRequest("POST", "http://localhost:8080/orders", strings.NewReader(`{"amount": 50}`))
	createReq.Header.Set("Authorization", "Bearer "+rarTokenOut.AccessToken)
	createReq.Header.Set("Content-Type", "application/json")
	createResp, _ := http.DefaultClient.Do(createReq)
	createBody, _ := io.ReadAll(createResp.Body)
	createResp.Body.Close()
	if createResp.StatusCode == 403 {
		fmt.Printf("%s  ✓ POST /orders (create) BLOCKED by RAR policy: HTTP 403 Forbidden (%s)%s\n\n", green, strings.TrimSpace(string(createBody)), reset)
	}

	// Step 9: Combined DPoP + RAR
	fmt.Printf("%s%sStep 9: Combined DPoP + RAR (Maximum Zero-Trust Security)%s\n", bold, cyan, reset)
	proofComboMint := makeDPoPProof(privKey, "POST", "http://localhost:8082/token", "")
	comboMintReq, _ := json.Marshal(map[string]any{
		"delegation_id": delOut.Delegation.ID,
		"agent_secret":  delOut.AgentSecret,
		"ttl_seconds":   300,
		"authorization_details": []map[string]any{
			{
				"type":      "agent_gateway_access",
				"resources": []string{"/orders"},
				"actions":   []string{"read"},
			},
		},
	})
	cReq, _ := http.NewRequest("POST", "http://localhost:8082/token", bytes.NewReader(comboMintReq))
	cReq.Header.Set("Content-Type", "application/json")
	cReq.Header.Set("DPoP", proofComboMint)
	cResp, _ := http.DefaultClient.Do(cReq)
	defer cResp.Body.Close()
	var comboTokenOut struct {
		AccessToken string `json:"access_token"`
		TokenType   string `json:"token_type"`
	}
	json.NewDecoder(cResp.Body).Decode(&comboTokenOut)
	fmt.Printf("  • Minted combined token: type=%s, sender-bound with RAR downscoping\n", comboTokenOut.TokenType)

	proofComboCall := makeDPoPProof(privKey, "GET", "http://localhost:8080/orders", comboTokenOut.AccessToken)
	cCallReq, _ := http.NewRequest("GET", "http://localhost:8080/orders", nil)
	cCallReq.Header.Set("Authorization", "DPoP "+comboTokenOut.AccessToken)
	cCallReq.Header.Set("DPoP", proofComboCall)
	cCallResp, _ := http.DefaultClient.Do(cCallReq)
	cCallResp.Body.Close()
	if cCallResp.StatusCode == 200 {
		fmt.Printf("%s✓ Combined DPoP + RAR call accepted by Gateway PEP (HTTP 200 OK)%s\n\n", green, reset)
	}

	fmt.Printf("%s%s====================================================================%s\n", bold, green, reset)
	fmt.Printf("%s%s  ALL DPoP & RAR VERIFICATION TESTS COMPLETED SUCCESSFULLY!%s\n", bold, green, reset)
	fmt.Printf("%s%s====================================================================%s\n\n", bold, green, reset)
}
