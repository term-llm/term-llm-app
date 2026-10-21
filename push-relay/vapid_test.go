package main

import (
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"strings"
	"testing"
	"time"
)

func TestVerifyVAPID(t *testing.T) {
	const aud = "https://push.example.com"
	now := time.Unix(1_800_000_000, 0)
	key := newVAPIDKey(t)
	other := newVAPIDKey(t)

	hash, err := verifyVAPID(key.header(t, validClaims(aud, now)), aud, now)
	if err != nil {
		t.Fatalf("valid header rejected: %v", err)
	}
	if hash != sha256.Sum256(key.raw) {
		t.Fatal("returned hash is not SHA-256 of the signing key")
	}
	// Trailing slash in aud and case-insensitive scheme are tolerated.
	h := key.header(t, map[string]any{"aud": aud + "/", "exp": now.Add(time.Hour).Unix()})
	if _, err := verifyVAPID(strings.Replace(h, "vapid", "VAPID", 1), aud, now); err != nil {
		t.Fatalf("variant header rejected: %v", err)
	}

	if _, err := verifyVAPID("", aud, now); !errors.Is(err, errVAPIDMissing) {
		t.Fatalf("missing header: %v", err)
	}
	signedByOther := strings.Replace(other.header(t, validClaims(aud, now)), "k="+other.encoded(), "k="+key.encoded(), 1)
	cases := map[string]string{
		"wrong scheme":   "WebPush " + key.jwt(t, map[string]any{"alg": "ES256"}, validClaims(aud, now)),
		"no key":         "vapid t=" + key.jwt(t, map[string]any{"alg": "ES256"}, validClaims(aud, now)),
		"wrong audience": key.header(t, validClaims("https://evil.example.com", now)),
		"expired":        key.header(t, map[string]any{"aud": aud, "exp": now.Add(-2 * time.Minute).Unix()}),
		"too long-lived": key.header(t, map[string]any{"aud": aud, "exp": now.Add(25 * time.Hour).Unix()}),
		"missing exp":    key.header(t, map[string]any{"aud": aud}),
		"wrong signer":   signedByOther,
		"alg none":       "vapid t=" + key.jwt(t, map[string]any{"alg": "none"}, validClaims(aud, now)) + ", k=" + key.encoded(),
		"bad key":        "vapid t=" + key.jwt(t, map[string]any{"alg": "ES256"}, validClaims(aud, now)) + ", k=AAAA",
		"malformed jwt":  "vapid t=abc.def, k=" + key.encoded(),
	}
	for name, header := range cases {
		if _, err := verifyVAPID(header, aud, now); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}

func TestParseApplicationServerKey(t *testing.T) {
	key := newVAPIDKey(t)
	if _, _, err := parseApplicationServerKey(key.encoded()); err != nil {
		t.Fatalf("base64url key rejected: %v", err)
	}
	if _, _, err := parseApplicationServerKey(key.encoded() + "="); err != nil {
		t.Fatalf("padded key rejected: %v", err)
	}
	bad := append([]byte(nil), key.raw...)
	bad[64] ^= 1 // no longer on the curve
	offCurve := base64.RawURLEncoding.EncodeToString(bad)
	for _, candidate := range []string{"", "!!!", "BAAA", strings.Repeat("A", 87), offCurve} {
		if _, _, err := parseApplicationServerKey(candidate); err == nil {
			t.Errorf("%q accepted", candidate)
		}
	}
}
