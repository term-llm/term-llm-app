package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/base64"
	"encoding/pem"
	"strings"
	"testing"
)

func testP8(t *testing.T) string {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	return string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}))
}

func TestLoadConfig(t *testing.T) {
	p8 := testP8(t)
	env := map[string]string{
		"PORT":             "9000",
		"RELAY_PUBLIC_URL": "https://Push.Example.com/",
		"RELAY_TOKEN_KEYS": "2:" + base64.StdEncoding.EncodeToString(make([]byte, 32)) + ", 1:" + base64.RawURLEncoding.EncodeToString(make([]byte, 32)),
		"APNS_KEY_ID":      "ABC123",
		"APNS_TEAM_ID":     "B6BAJ46A72",
		"APNS_PRIVATE_KEY": base64.StdEncoding.EncodeToString([]byte(p8)),
	}
	cfg, err := loadConfig(func(k string) string { return env[k] })
	if err != nil {
		t.Fatal(err)
	}
	if cfg.ListenAddr != ":9000" || cfg.PublicURL != "https://push.example.com" || cfg.APNs.Topic != defaultAPNsTopic {
		t.Fatalf("unexpected config: %+v", cfg)
	}
	if len(cfg.TokenKeys) != 2 || cfg.TokenKeys[0].ID != 2 || cfg.APNs.PrivateKey == nil {
		t.Fatalf("keys not parsed: %+v", cfg.TokenKeys)
	}

	env["APNS_PRIVATE_KEY"] = p8
	if _, err := loadConfig(func(k string) string { return env[k] }); err != nil {
		t.Fatalf("raw PEM rejected: %v", err)
	}
}

func TestLoadConfigReportsAllProblems(t *testing.T) {
	_, err := loadConfig(func(string) string { return "" })
	if err == nil {
		t.Fatal("empty config accepted")
	}
	for _, want := range []string{"RELAY_PUBLIC_URL", "RELAY_TOKEN_KEYS", "APNS_KEY_ID", "APNS_TEAM_ID", "APNS_PRIVATE_KEY"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error does not mention %s: %v", want, err)
		}
	}
}

func TestNormalizePublicURL(t *testing.T) {
	for raw, want := range map[string]string{
		"https://push.term-llm.com":  "https://push.term-llm.com",
		"https://push.term-llm.com/": "https://push.term-llm.com",
		"http://localhost:8080":      "http://localhost:8080",
		"http://127.0.0.1:8080":      "http://127.0.0.1:8080",
	} {
		if got, err := normalizePublicURL(raw); err != nil || got != want {
			t.Errorf("%s: got %q, %v", raw, got, err)
		}
	}
	for _, raw := range []string{"http://push.term-llm.com", "https://push.term-llm.com/relay", "ftp://x", "push.term-llm.com", "https://u:p@x.com"} {
		if _, err := normalizePublicURL(raw); err == nil {
			t.Errorf("%s accepted", raw)
		}
	}
}

func TestParseTokenKeysRejectsBadInput(t *testing.T) {
	key := base64.StdEncoding.EncodeToString(make([]byte, 32))
	for _, raw := range []string{"abc", "1:short", "300:" + key, "1:" + key + ",1:" + key} {
		if _, err := parseTokenKeys(raw); err == nil {
			t.Errorf("%q accepted", raw)
		}
	}
}
