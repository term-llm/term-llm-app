package main

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/hkdf"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
)

// Environment selects the APNs gateway a device token belongs to. Builds
// signed with a development profile (run from Xcode) use the sandbox;
// TestFlight, App Store and Ad Hoc builds use production.
type Environment byte

const (
	EnvProduction  Environment = 0
	EnvDevelopment Environment = 1
)

func (e Environment) String() string {
	if e == EnvDevelopment {
		return "development"
	}
	return "production"
}

func parseEnvironment(s string) (Environment, error) {
	switch s {
	case "production":
		return EnvProduction, nil
	case "development", "sandbox":
		return EnvDevelopment, nil
	}
	return 0, fmt.Errorf("environment must be \"production\" or \"development\"")
}

// Subscription is everything the relay needs to deliver a push. It is sealed
// into the endpoint URL so the relay stores no per-device state.
type Subscription struct {
	Env         Environment
	DeviceToken []byte
	// VAPIDKeyHash is SHA-256 of the uncompressed P-256 application server
	// key. Only pushes signed by that key are forwarded.
	VAPIDKeyHash [32]byte
}

const (
	tokenVersion       = 1
	tokenNonceSize     = 12
	minDeviceTokenSize = 8
	maxDeviceTokenSize = 100
	maxTokenLength     = 512
	tokenAADPrefix     = "term-llm push relay token v1"
)

var errInvalidToken = errors.New("invalid subscription token")

type tokenCipher struct {
	aead     cipher.AEAD
	nonceKey []byte
}

// TokenSealer encrypts subscriptions into opaque URL-safe tokens.
//
// Encryption is deterministic (the nonce is an HMAC of the plaintext), so the
// same device, environment and server key always produce the same endpoint.
// term-llm upserts subscriptions by endpoint, so re-registering on every app
// launch does not create duplicates. Reusing a nonce only ever happens with an
// identical plaintext, which reveals equality and nothing else.
type TokenSealer struct {
	current byte
	keys    map[byte]tokenCipher
}

func NewTokenSealer(keys []TokenKey) (*TokenSealer, error) {
	if len(keys) == 0 {
		return nil, errors.New("at least one token key is required")
	}
	s := &TokenSealer{current: keys[0].ID, keys: make(map[byte]tokenCipher, len(keys))}
	for _, k := range keys {
		if len(k.Secret) != 32 {
			return nil, fmt.Errorf("token key %d must be 32 bytes", k.ID)
		}
		encKey, err := hkdf.Key(sha256.New, k.Secret, nil, "term-llm push relay token encryption v1", 32)
		if err != nil {
			return nil, err
		}
		nonceKey, err := hkdf.Key(sha256.New, k.Secret, nil, "term-llm push relay token nonce v1", 32)
		if err != nil {
			return nil, err
		}
		block, err := aes.NewCipher(encKey)
		if err != nil {
			return nil, err
		}
		aead, err := cipher.NewGCM(block)
		if err != nil {
			return nil, err
		}
		s.keys[k.ID] = tokenCipher{aead: aead, nonceKey: nonceKey}
	}
	return s, nil
}

func tokenAAD(keyID byte) []byte {
	return append([]byte(tokenAADPrefix), keyID)
}

func (s *TokenSealer) Seal(sub Subscription) (string, error) {
	if len(sub.DeviceToken) < minDeviceTokenSize || len(sub.DeviceToken) > maxDeviceTokenSize {
		return "", errors.New("device token has an invalid length")
	}
	plaintext := make([]byte, 0, 2+32+len(sub.DeviceToken))
	plaintext = append(plaintext, tokenVersion, byte(sub.Env))
	plaintext = append(plaintext, sub.VAPIDKeyHash[:]...)
	plaintext = append(plaintext, sub.DeviceToken...)

	c := s.keys[s.current]
	mac := hmac.New(sha256.New, c.nonceKey)
	mac.Write(plaintext)
	nonce := mac.Sum(nil)[:tokenNonceSize]

	out := make([]byte, 0, 1+tokenNonceSize+len(plaintext)+c.aead.Overhead())
	out = append(out, s.current)
	out = append(out, nonce...)
	out = c.aead.Seal(out, nonce, plaintext, tokenAAD(s.current))
	return base64.RawURLEncoding.EncodeToString(out), nil
}

func (s *TokenSealer) Open(token string) (Subscription, error) {
	if len(token) == 0 || len(token) > maxTokenLength {
		return Subscription{}, errInvalidToken
	}
	raw, err := base64.RawURLEncoding.DecodeString(token)
	if err != nil || len(raw) < 1+tokenNonceSize {
		return Subscription{}, errInvalidToken
	}
	c, ok := s.keys[raw[0]]
	if !ok {
		return Subscription{}, errInvalidToken
	}
	plaintext, err := c.aead.Open(nil, raw[1:1+tokenNonceSize], raw[1+tokenNonceSize:], tokenAAD(raw[0]))
	if err != nil || len(plaintext) < 2+32+minDeviceTokenSize || plaintext[0] != tokenVersion {
		return Subscription{}, errInvalidToken
	}
	env := Environment(plaintext[1])
	if env != EnvProduction && env != EnvDevelopment {
		return Subscription{}, errInvalidToken
	}
	sub := Subscription{Env: env, DeviceToken: plaintext[34:]}
	copy(sub.VAPIDKeyHash[:], plaintext[2:34])
	return sub, nil
}
