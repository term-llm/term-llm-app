package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"strings"
	"testing"
)

func TestTokenRoundTripIsDeterministic(t *testing.T) {
	sealer, err := NewTokenSealer([]TokenKey{testTokenKey(1)})
	if err != nil {
		t.Fatal(err)
	}
	sub := Subscription{Env: EnvDevelopment, DeviceToken: testDeviceToken(), VAPIDKeyHash: sha256.Sum256([]byte("server-a"))}
	tok1, err := sealer.Seal(sub)
	if err != nil {
		t.Fatal(err)
	}
	tok2, _ := sealer.Seal(sub)
	if tok1 != tok2 {
		t.Fatal("same subscription must produce the same endpoint token")
	}
	if strings.ContainsAny(tok1, "+/=") {
		t.Fatalf("token is not URL-safe: %s", tok1)
	}
	got, err := sealer.Open(tok1)
	if err != nil {
		t.Fatal(err)
	}
	if got.Env != sub.Env || !bytes.Equal(got.DeviceToken, sub.DeviceToken) || got.VAPIDKeyHash != sub.VAPIDKeyHash {
		t.Fatalf("round trip mismatch: %+v", got)
	}

	other := sub
	other.VAPIDKeyHash = sha256.Sum256([]byte("server-b"))
	tok3, _ := sealer.Seal(other)
	if tok3 == tok1 {
		t.Fatal("different servers must get different endpoints")
	}
	prod := sub
	prod.Env = EnvProduction
	if tok4, _ := sealer.Seal(prod); tok4 == tok1 {
		t.Fatal("different environments must get different endpoints")
	}
}

func TestTokenRejectsTamperingAndUnknownKeys(t *testing.T) {
	sealer, _ := NewTokenSealer([]TokenKey{testTokenKey(1)})
	tok, _ := sealer.Seal(Subscription{DeviceToken: testDeviceToken()})
	raw, _ := base64.RawURLEncoding.DecodeString(tok)

	flipped := append([]byte(nil), raw...)
	flipped[len(flipped)-1] ^= 1
	unknown := append([]byte(nil), raw...)
	unknown[0] = 9
	for name, candidate := range map[string]string{
		"tampered":    base64.RawURLEncoding.EncodeToString(flipped),
		"unknown key": base64.RawURLEncoding.EncodeToString(unknown),
		"garbage":     "not-a-token",
		"empty":       "",
		"too long":    strings.Repeat("A", maxTokenLength+1),
	} {
		if _, err := sealer.Open(candidate); err == nil {
			t.Errorf("%s token was accepted", name)
		}
	}

	otherSealer, _ := NewTokenSealer([]TokenKey{{ID: 1, Secret: bytes.Repeat([]byte{7}, 32)}})
	if _, err := otherSealer.Open(tok); err == nil {
		t.Error("token opened with a different secret")
	}
}

func TestTokenKeyRotation(t *testing.T) {
	old, _ := NewTokenSealer([]TokenKey{testTokenKey(1)})
	sub := Subscription{Env: EnvProduction, DeviceToken: testDeviceToken()}
	oldTok, _ := old.Seal(sub)

	rotated, _ := NewTokenSealer([]TokenKey{testTokenKey(2), testTokenKey(1)})
	if _, err := rotated.Open(oldTok); err != nil {
		t.Fatalf("retired key no longer opens existing endpoints: %v", err)
	}
	newTok, _ := rotated.Seal(sub)
	if newTok == oldTok {
		t.Fatal("new registrations should use the current key")
	}
	if _, err := old.Open(newTok); err == nil {
		t.Fatal("old-only sealer opened a token from the new key")
	}
}

func TestTokenRejectsBadDeviceTokenLength(t *testing.T) {
	sealer, _ := NewTokenSealer([]TokenKey{testTokenKey(1)})
	if _, err := sealer.Seal(Subscription{DeviceToken: []byte{1, 2}}); err == nil {
		t.Fatal("short device token accepted")
	}
	if _, err := sealer.Seal(Subscription{DeviceToken: make([]byte, maxDeviceTokenSize+1)}); err == nil {
		t.Fatal("long device token accepted")
	}
}
