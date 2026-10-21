package apns

import (
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"math/big"
	"sync"
	"time"
)

const (
	// APNs requires provider tokens to be refreshed no more often than every
	// 20 minutes and no less often than every 60 minutes. Fifty minutes keeps
	// a comfortable margin on both sides.
	providerTokenLifetime = 50 * time.Minute
)

type tokenSigner struct {
	key    *ecdsa.PrivateKey
	keyID  string
	teamID string

	now func() time.Time
	ttl time.Duration

	mu       sync.Mutex
	cached   string
	issuedAt time.Time
}

func newTokenSigner(key *ecdsa.PrivateKey, keyID, teamID string) *tokenSigner {
	return &tokenSigner{
		key:    key,
		keyID:  keyID,
		teamID: teamID,
		now:    time.Now,
		ttl:    providerTokenLifetime,
	}
}

// token returns a cached ES256 provider JWT, signing a new one when the cached
// token reaches the end of its intended lifetime. The cache is mutex-protected
// so concurrent APNs calls share at most one signing operation per lifetime.
func (s *tokenSigner) token() (string, error) {
	now := s.now()

	s.mu.Lock()
	defer s.mu.Unlock()

	if s.cached != "" {
		age := now.Sub(s.issuedAt)
		if age >= 0 && age < s.ttl {
			return s.cached, nil
		}
	}

	signed, err := signProviderToken(s.key, s.keyID, s.teamID, now)
	if err != nil {
		return "", err
	}
	s.cached = signed
	s.issuedAt = now
	return signed, nil
}

func signProviderToken(key *ecdsa.PrivateKey, keyID, teamID string, now time.Time) (string, error) {
	header, err := json.Marshal(struct {
		Algorithm string `json:"alg"`
		KeyID     string `json:"kid"`
	}{
		Algorithm: "ES256",
		KeyID:     keyID,
	})
	if err != nil {
		return "", fmt.Errorf("marshal APNs token header: %w", err)
	}
	claims, err := json.Marshal(struct {
		Issuer   string `json:"iss"`
		IssuedAt int64  `json:"iat"`
	}{
		Issuer:   teamID,
		IssuedAt: now.Unix(),
	})
	if err != nil {
		return "", fmt.Errorf("marshal APNs token claims: %w", err)
	}

	encoding := base64.RawURLEncoding
	signingInput := encoding.EncodeToString(header) + "." + encoding.EncodeToString(claims)
	digest := sha256.Sum256([]byte(signingInput))

	r, s, err := ecdsa.Sign(rand.Reader, key, digest[:])
	if err != nil {
		return "", fmt.Errorf("sign APNs token: %w", err)
	}
	signature := make([]byte, 64)
	r.FillBytes(signature[:32])
	s.FillBytes(signature[32:])

	return signingInput + "." + encoding.EncodeToString(signature), nil
}

// splitRawSignature is used by tests and keeps the fixed-width JWS encoding
// explicit: ES256 signatures are r || s, each padded to 32 bytes.
func splitRawSignature(signature []byte) (r, s *big.Int, ok bool) {
	if len(signature) != 64 {
		return nil, nil, false
	}
	return new(big.Int).SetBytes(signature[:32]), new(big.Int).SetBytes(signature[32:]), true
}
