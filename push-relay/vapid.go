package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"math/big"
	"strings"
	"time"
)

const (
	vapidMaxLifetime = 24 * time.Hour // RFC 8292 §2
	vapidClockSkew   = time.Minute
)

var (
	errVAPIDMissing = errors.New("missing VAPID authorization")
	errVAPIDInvalid = errors.New("invalid VAPID authorization")
)

// parseApplicationServerKey decodes and validates an uncompressed P-256 public
// key as used for VAPID (65 bytes, base64url).
func parseApplicationServerKey(encoded string) ([]byte, *ecdsa.PublicKey, error) {
	raw, err := decodeBase64Any(encoded)
	if err != nil {
		return nil, nil, errors.New("application server key is not base64")
	}
	pub, err := ecdsa.ParseUncompressedPublicKey(elliptic.P256(), raw)
	if err != nil {
		return nil, nil, errors.New("application server key is not an uncompressed P-256 public key")
	}
	return raw, pub, nil
}

// verifyVAPID checks an RFC 8292 `Authorization: vapid t=<jwt>, k=<key>`
// header and returns SHA-256 of the signing key on success.
func verifyVAPID(header, audience string, now time.Time) ([32]byte, error) {
	var zero [32]byte
	header = strings.TrimSpace(header)
	if header == "" {
		return zero, errVAPIDMissing
	}
	scheme, params, ok := strings.Cut(header, " ")
	if !ok || !strings.EqualFold(scheme, "vapid") {
		return zero, errVAPIDInvalid
	}
	var token, key string
	for _, part := range strings.Split(params, ",") {
		name, value, ok := strings.Cut(strings.TrimSpace(part), "=")
		if !ok {
			return zero, errVAPIDInvalid
		}
		value = strings.Trim(strings.TrimSpace(value), `"`)
		switch strings.ToLower(strings.TrimSpace(name)) {
		case "t":
			token = value
		case "k":
			key = value
		}
	}
	if token == "" || key == "" || len(token) > 2048 {
		return zero, errVAPIDInvalid
	}
	rawKey, pub, err := parseApplicationServerKey(key)
	if err != nil {
		return zero, errVAPIDInvalid
	}
	if err := verifyES256JWT(token, pub, audience, now); err != nil {
		return zero, err
	}
	return sha256.Sum256(rawKey), nil
}

func verifyES256JWT(token string, pub *ecdsa.PublicKey, audience string, now time.Time) error {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return errVAPIDInvalid
	}
	headerJSON, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return errVAPIDInvalid
	}
	var hdr struct {
		Alg string `json:"alg"`
	}
	if json.Unmarshal(headerJSON, &hdr) != nil || hdr.Alg != "ES256" {
		return errVAPIDInvalid
	}
	sig, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil || len(sig) != 64 || !verifyRawES256(pub, []byte(parts[0]+"."+parts[1]), sig) {
		return errVAPIDInvalid
	}

	claimsJSON, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return errVAPIDInvalid
	}
	var claims struct {
		Aud json.RawMessage `json:"aud"`
		Exp *json.Number    `json:"exp"`
	}
	dec := json.NewDecoder(strings.NewReader(string(claimsJSON)))
	dec.UseNumber()
	if dec.Decode(&claims) != nil || claims.Exp == nil {
		return errVAPIDInvalid
	}
	var aud string
	if json.Unmarshal(claims.Aud, &aud) != nil || !strings.EqualFold(strings.TrimRight(aud, "/"), audience) {
		return errVAPIDInvalid
	}
	expFloat, err := claims.Exp.Float64()
	if err != nil {
		return errVAPIDInvalid
	}
	exp := time.Unix(int64(expFloat), 0)
	if !exp.After(now.Add(-vapidClockSkew)) || exp.After(now.Add(vapidMaxLifetime+vapidClockSkew)) {
		return errVAPIDInvalid
	}
	return nil
}

// verifyRawES256 checks a JOSE ES256 signature (r||s, 64 bytes).
func verifyRawES256(pub *ecdsa.PublicKey, signingInput, sig []byte) bool {
	digest := sha256.Sum256(signingInput)
	r := new(big.Int).SetBytes(sig[:32])
	s := new(big.Int).SetBytes(sig[32:])
	return ecdsa.Verify(pub, digest[:], r, s)
}
