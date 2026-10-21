package config

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/pem"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const strongToken = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"

func TestLoadValidWithDefaults(t *testing.T) {
	dir := t.TempDir()
	keyPath := writeKeyFile(t, dir, "key.p8", generateKey(t, elliptic.P256()))
	tokenPath := writeFile(t, dir, "relay-token", []byte(strongToken+"\n"), 0o600)

	cfg, err := Load(mapEnv(map[string]string{
		"APNS_KEY_FILE":    keyPath,
		"APNS_KEY_ID":      "KEYID12345",
		"APNS_TEAM_ID":     "TEAMID1234",
		"APNS_TOPIC":       "com.example.app",
		"RELAY_TOKEN_FILE": tokenPath,
	}))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.Addr != DefaultAddr {
		t.Fatalf("Addr = %q, want %q", cfg.Addr, DefaultAddr)
	}
	if cfg.APNSTimeout != DefaultAPNSTimeout || cfg.ShutdownTimeout != DefaultShutdownTimeout {
		t.Fatalf("unexpected timeouts: %v %v", cfg.APNSTimeout, cfg.ShutdownTimeout)
	}
	if cfg.MaxConcurrent != DefaultMaxConcurrent {
		t.Fatalf("MaxConcurrent = %d, want %d", cfg.MaxConcurrent, DefaultMaxConcurrent)
	}
	if string(cfg.Token) != strongToken {
		t.Fatalf("token was not trimmed correctly")
	}
	if cfg.APNSKey == nil || cfg.APNSKey.Curve != elliptic.P256() {
		t.Fatalf("unexpected key")
	}
}

func TestLoadCustomValues(t *testing.T) {
	dir := t.TempDir()
	keyPath := writeKeyFile(t, dir, "key.p8", generateKey(t, elliptic.P256()))
	tokenPath := writeFile(t, dir, "relay-token", []byte(strongToken), 0o400)

	cfg, err := Load(mapEnv(map[string]string{
		"APNS_KEY_FILE":          keyPath,
		"APNS_KEY_ID":            "KEYID12345",
		"APNS_TEAM_ID":           "TEAMID1234",
		"APNS_TOPIC":             "com.example.app",
		"RELAY_TOKEN_FILE":       tokenPath,
		"RELAY_ADDR":             "127.0.0.1:9999",
		"APNS_TIMEOUT":           "3s",
		"RELAY_SHUTDOWN_TIMEOUT": "4s",
		"RELAY_MAX_CONCURRENCY":  "2",
	}))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.Addr != "127.0.0.1:9999" || cfg.APNSTimeout != 3*time.Second || cfg.ShutdownTimeout != 4*time.Second || cfg.MaxConcurrent != 2 {
		t.Fatalf("unexpected config: %+v", cfg)
	}
}

func TestLoadRequiresEnvironment(t *testing.T) {
	dir := t.TempDir()
	keyPath := writeKeyFile(t, dir, "key.p8", generateKey(t, elliptic.P256()))
	tokenPath := writeFile(t, dir, "relay-token", []byte(strongToken), 0o600)
	base := map[string]string{
		"APNS_KEY_FILE":    keyPath,
		"APNS_KEY_ID":      "KEYID12345",
		"APNS_TEAM_ID":     "TEAMID1234",
		"APNS_TOPIC":       "com.example.app",
		"RELAY_TOKEN_FILE": tokenPath,
	}

	for _, name := range []string{"APNS_KEY_FILE", "APNS_KEY_ID", "APNS_TEAM_ID", "APNS_TOPIC", "RELAY_TOKEN_FILE"} {
		t.Run(name, func(t *testing.T) {
			env := cloneMap(base)
			delete(env, name)
			if _, err := Load(mapEnv(env)); err == nil {
				t.Fatalf("Load accepted missing %s", name)
			}
		})
	}
}

func TestLoadRejectsUnsafeKey(t *testing.T) {
	tokenPath := writeFile(t, t.TempDir(), "relay-token", []byte(strongToken), 0o600)

	cases := map[string][]byte{
		"not pem":        []byte("garbage"),
		"wrong pem type": pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: []byte{1}}),
		"invalid pkcs8":  pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: []byte{1, 2, 3}}),
		"rsa key":        marshalPKCS8(t, generateRSAKey(t)),
		"p384 key":       marshalPKCS8(t, generateKey(t, elliptic.P384())),
	}

	for name, data := range cases {
		t.Run(name, func(t *testing.T) {
			dir := t.TempDir()
			keyPath := writeFile(t, dir, "key.p8", data, 0o600)
			_, err := Load(mapEnv(map[string]string{
				"APNS_KEY_FILE":    keyPath,
				"APNS_KEY_ID":      "KEYID12345",
				"APNS_TEAM_ID":     "TEAMID1234",
				"APNS_TOPIC":       "com.example.app",
				"RELAY_TOKEN_FILE": tokenPath,
			}))
			if err == nil {
				t.Fatal("Load accepted unsafe key")
			}
			if strings.Contains(err.Error(), string(data)) {
				t.Fatal("error leaked key material")
			}
		})
	}
}

func TestLoadRejectsLoosePermissions(t *testing.T) {
	dir := t.TempDir()
	keyPath := writeFile(t, dir, "key.p8", marshalPKCS8(t, generateKey(t, elliptic.P256())), 0o644)
	tokenPath := writeFile(t, dir, "relay-token", []byte(strongToken), 0o600)

	_, err := Load(mapEnv(map[string]string{
		"APNS_KEY_FILE":    keyPath,
		"APNS_KEY_ID":      "KEYID12345",
		"APNS_TEAM_ID":     "TEAMID1234",
		"APNS_TOPIC":       "com.example.app",
		"RELAY_TOKEN_FILE": tokenPath,
	}))
	if err == nil || !strings.Contains(err.Error(), "chmod") {
		t.Fatalf("Load error = %v, want permission guidance", err)
	}

	tokenPath = writeFile(t, dir, "loose-token", []byte(strongToken), 0o640)
	keyPath = writeFile(t, dir, "good-key.p8", marshalPKCS8(t, generateKey(t, elliptic.P256())), 0o600)
	_, err = Load(mapEnv(map[string]string{
		"APNS_KEY_FILE":    keyPath,
		"APNS_KEY_ID":      "KEYID12345",
		"APNS_TEAM_ID":     "TEAMID1234",
		"APNS_TOPIC":       "com.example.app",
		"RELAY_TOKEN_FILE": tokenPath,
	}))
	if err == nil {
		t.Fatal("Load accepted group-readable token")
	}
}

func TestLoadRejectsWeakTokens(t *testing.T) {
	dir := t.TempDir()
	keyPath := writeKeyFile(t, dir, "key.p8", generateKey(t, elliptic.P256()))

	for name, token := range map[string]string{
		"short":    "too-short",
		"space":    "0123456789abcdefghijkl mnopqrstuvwxyzABCDEF",
		"repeated": strings.Repeat("a", 64),
		"newline":  "0123456789abcdefghijklmnopqrstuvwxyzABCDEF\nmore",
		"too-long": strings.Repeat("0123456789abcdef", 40),
		"control":  "0123456789abcdefghijklmnopqrstuvwxyzABC\x01DEF",
	} {
		t.Run(name, func(t *testing.T) {
			tokenPath := writeFile(t, t.TempDir(), "relay-token", []byte(token), 0o600)
			_, err := Load(mapEnv(map[string]string{
				"APNS_KEY_FILE":    keyPath,
				"APNS_KEY_ID":      "KEYID12345",
				"APNS_TEAM_ID":     "TEAMID1234",
				"APNS_TOPIC":       "com.example.app",
				"RELAY_TOKEN_FILE": tokenPath,
			}))
			if err == nil {
				t.Fatal("Load accepted weak token")
			}
			if strings.Contains(err.Error(), token) {
				t.Fatal("error leaked token")
			}
		})
	}
}

func TestLoadRejectsBadAddress(t *testing.T) {
	dir := t.TempDir()
	keyPath := writeKeyFile(t, dir, "key.p8", generateKey(t, elliptic.P256()))
	tokenPath := writeFile(t, dir, "relay-token", []byte(strongToken), 0o600)
	base := map[string]string{
		"APNS_KEY_FILE":    keyPath,
		"APNS_KEY_ID":      "KEYID12345",
		"APNS_TEAM_ID":     "TEAMID1234",
		"APNS_TOPIC":       "com.example.app",
		"RELAY_TOKEN_FILE": tokenPath,
	}

	for _, addr := range []string{":8768", "127.0.0.1", "127.0.0.1:0", "127.0.0.1:65536", "127.0.0.1:http", "127.0.0.1:8768 extra"} {
		t.Run(addr, func(t *testing.T) {
			env := cloneMap(base)
			env["RELAY_ADDR"] = addr
			if _, err := Load(mapEnv(env)); err == nil {
				t.Fatalf("Load accepted RELAY_ADDR=%q", addr)
			}
		})
	}
}

func TestLoadRejectsBadIdentifiers(t *testing.T) {
	dir := t.TempDir()
	keyPath := writeKeyFile(t, dir, "key.p8", generateKey(t, elliptic.P256()))
	tokenPath := writeFile(t, dir, "relay-token", []byte(strongToken), 0o600)
	base := map[string]string{
		"APNS_KEY_FILE":    keyPath,
		"APNS_KEY_ID":      "KEYID12345",
		"APNS_TEAM_ID":     "TEAMID1234",
		"APNS_TOPIC":       "com.example.app",
		"RELAY_TOKEN_FILE": tokenPath,
	}

	for name, value := range map[string]string{
		"APNS_KEY_ID":  "bad key id",
		"APNS_TEAM_ID": "TEAM/ID",
		"APNS_TOPIC":   "com.example.app\ninjected",
	} {
		t.Run(name, func(t *testing.T) {
			env := cloneMap(base)
			env[name] = value
			if _, err := Load(mapEnv(env)); err == nil {
				t.Fatalf("Load accepted %s=%q", name, value)
			}
		})
	}
}

func TestLoadRejectsBadOptionalValues(t *testing.T) {
	dir := t.TempDir()
	keyPath := writeKeyFile(t, dir, "key.p8", generateKey(t, elliptic.P256()))
	tokenPath := writeFile(t, dir, "relay-token", []byte(strongToken), 0o600)
	base := map[string]string{
		"APNS_KEY_FILE":    keyPath,
		"APNS_KEY_ID":      "KEYID12345",
		"APNS_TEAM_ID":     "TEAMID1234",
		"APNS_TOPIC":       "com.example.app",
		"RELAY_TOKEN_FILE": tokenPath,
	}

	for name, value := range map[string]string{
		"APNS_TIMEOUT":           "0s",
		"RELAY_SHUTDOWN_TIMEOUT": "forever",
		"RELAY_MAX_CONCURRENCY":  "0",
	} {
		t.Run(name, func(t *testing.T) {
			env := cloneMap(base)
			env[name] = value
			if _, err := Load(mapEnv(env)); err == nil {
				t.Fatalf("Load accepted %s=%q", name, value)
			}
		})
	}
}

func TestCredentialDirectoryExpansion(t *testing.T) {
	dir := t.TempDir()
	writeKeyFile(t, dir, "apns-key.p8", generateKey(t, elliptic.P256()))
	writeFile(t, dir, "relay-token", []byte(strongToken), 0o400)

	cfg, err := Load(mapEnv(map[string]string{
		"APNS_KEY_FILE":         "%d/apns-key.p8",
		"RELAY_TOKEN_FILE":      "%d/relay-token",
		"CREDENTIALS_DIRECTORY": dir,
		"APNS_KEY_ID":           "KEYID12345",
		"APNS_TEAM_ID":          "TEAMID1234",
		"APNS_TOPIC":            "com.example.app",
	}))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if string(cfg.Token) != strongToken {
		t.Fatal("unexpected token")
	}

	_, err = Load(mapEnv(map[string]string{
		"APNS_KEY_FILE":         "%d/../escape",
		"RELAY_TOKEN_FILE":      "%d/relay-token",
		"CREDENTIALS_DIRECTORY": dir,
		"APNS_KEY_ID":           "KEYID12345",
		"APNS_TEAM_ID":          "TEAMID1234",
		"APNS_TOPIC":            "com.example.app",
	}))
	if err == nil {
		t.Fatal("Load accepted escaping credential path")
	}

	_, err = Load(mapEnv(map[string]string{
		"APNS_KEY_FILE":    "%d/apns-key.p8",
		"RELAY_TOKEN_FILE": "%d/relay-token",
		"APNS_KEY_ID":      "KEYID12345",
		"APNS_TEAM_ID":     "TEAMID1234",
		"APNS_TOPIC":       "com.example.app",
	}))
	if err == nil {
		t.Fatal("Load accepted percent-d without CREDENTIALS_DIRECTORY")
	}
}

func generateKey(t *testing.T, curve elliptic.Curve) *ecdsa.PrivateKey {
	t.Helper()
	key, err := ecdsa.GenerateKey(curve, rand.Reader)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	return key
}

func generateRSAKey(t *testing.T) *rsa.PrivateKey {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 1024)
	if err != nil {
		t.Fatalf("generate RSA key: %v", err)
	}
	return key
}

func marshalPKCS8(t *testing.T, key any) []byte {
	t.Helper()
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatalf("marshal key: %v", err)
	}
	return pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})
}

func writeKeyFile(t *testing.T, dir, name string, key *ecdsa.PrivateKey) string {
	t.Helper()
	return writeFile(t, dir, name, marshalPKCS8(t, key), 0o600)
}

func writeFile(t *testing.T, dir, name string, data []byte, mode os.FileMode) string {
	t.Helper()
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, data, mode); err != nil {
		t.Fatalf("write %s: %v", name, err)
	}
	return path
}

func mapEnv(values map[string]string) func(string) string {
	return func(name string) string { return values[name] }
}

func cloneMap(values map[string]string) map[string]string {
	clone := make(map[string]string, len(values))
	for key, value := range values {
		clone[key] = value
	}
	return clone
}
