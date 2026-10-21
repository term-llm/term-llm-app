package apns

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestProviderTokenIsValidES256JWT(t *testing.T) {
	key := generateTestKey(t)
	signer := newTokenSigner(key, "KEYID12345", "TEAMID1234")
	fixed := time.Unix(1_700_000_000, 0)
	signer.now = func() time.Time { return fixed }

	token, err := signer.token()
	if err != nil {
		t.Fatalf("token: %v", err)
	}
	issuedAt := verifyProviderToken(t, token, key, "KEYID12345", "TEAMID1234")
	if issuedAt != fixed.Unix() {
		t.Fatalf("iat = %d, want %d", issuedAt, fixed.Unix())
	}
}

func TestProviderTokenCacheLifetime(t *testing.T) {
	key := generateTestKey(t)
	signer := newTokenSigner(key, "KEYID12345", "TEAMID1234")
	fixed := time.Unix(1_700_000_000, 0)
	current := fixed
	signer.now = func() time.Time { return current }

	first, err := signer.token()
	if err != nil {
		t.Fatalf("first token: %v", err)
	}
	second, err := signer.token()
	if err != nil {
		t.Fatalf("second token: %v", err)
	}
	if first != second {
		t.Fatal("token was not cached")
	}

	current = fixed.Add(49 * time.Minute)
	stillCached, err := signer.token()
	if err != nil {
		t.Fatalf("cached token: %v", err)
	}
	if stillCached != first {
		t.Fatal("token expired before 50 minutes")
	}

	current = fixed.Add(51 * time.Minute)
	refreshed, err := signer.token()
	if err != nil {
		t.Fatalf("refreshed token: %v", err)
	}
	if refreshed == first {
		t.Fatal("token was not refreshed after 50 minutes")
	}
	if issuedAt := verifyProviderToken(t, refreshed, key, "KEYID12345", "TEAMID1234"); issuedAt != current.Unix() {
		t.Fatalf("refreshed iat = %d, want %d", issuedAt, current.Unix())
	}

	// A backward clock movement must not extend the cached token indefinitely.
	current = fixed
	afterRollback, err := signer.token()
	if err != nil {
		t.Fatalf("rollback token: %v", err)
	}
	if afterRollback == refreshed {
		t.Fatal("token was reused after clock rollback")
	}
}

func TestProviderTokenConcurrentCaching(t *testing.T) {
	key := generateTestKey(t)
	signer := newTokenSigner(key, "KEYID12345", "TEAMID1234")
	signer.now = func() time.Time { return time.Unix(1_700_000_000, 0) }

	const goroutines = 32
	tokens := make(chan string, goroutines)
	var wait sync.WaitGroup
	for i := 0; i < goroutines; i++ {
		wait.Add(1)
		go func() {
			defer wait.Done()
			token, err := signer.token()
			if err != nil {
				t.Errorf("token: %v", err)
				return
			}
			tokens <- token
		}()
	}
	wait.Wait()
	close(tokens)

	var first string
	for token := range tokens {
		if first == "" {
			first = token
			continue
		}
		if token != first {
			t.Fatal("concurrent callers received different cached tokens")
		}
	}
}

func verifyProviderToken(t *testing.T, token string, key *ecdsa.PrivateKey, keyID, teamID string) int64 {
	t.Helper()
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		t.Fatalf("JWT has %d segments, want 3", len(parts))
	}
	encoding := base64.RawURLEncoding

	headerJSON, err := encoding.DecodeString(parts[0])
	if err != nil {
		t.Fatalf("decode header: %v", err)
	}
	var header struct {
		Algorithm string `json:"alg"`
		KeyID     string `json:"kid"`
	}
	if err := json.Unmarshal(headerJSON, &header); err != nil {
		t.Fatalf("unmarshal header: %v", err)
	}
	if header.Algorithm != "ES256" || header.KeyID != keyID {
		t.Fatalf("unexpected header: %+v", header)
	}

	claimsJSON, err := encoding.DecodeString(parts[1])
	if err != nil {
		t.Fatalf("decode claims: %v", err)
	}
	var claims struct {
		Issuer   string `json:"iss"`
		IssuedAt int64  `json:"iat"`
	}
	if err := json.Unmarshal(claimsJSON, &claims); err != nil {
		t.Fatalf("unmarshal claims: %v", err)
	}
	if claims.Issuer != teamID || claims.IssuedAt == 0 {
		t.Fatalf("unexpected claims: %+v", claims)
	}

	signature, err := encoding.DecodeString(parts[2])
	if err != nil {
		t.Fatalf("decode signature: %v", err)
	}
	if len(signature) != 64 {
		t.Fatalf("signature is %d bytes, want raw 64-byte r||s", len(signature))
	}
	r, s, ok := splitRawSignature(signature)
	if !ok {
		t.Fatal("signature is not a raw 64-byte ECDSA signature")
	}
	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	if !ecdsa.Verify(&key.PublicKey, digest[:], r, s) {
		t.Fatal("JWT signature did not verify")
	}
	return claims.IssuedAt
}

func generateTestKey(t *testing.T) *ecdsa.PrivateKey {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	return key
}
