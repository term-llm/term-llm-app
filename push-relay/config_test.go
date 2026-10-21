package main

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/base64"
	"encoding/pem"
	"os"
	"path/filepath"
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

func validConfigEnv(t *testing.T) map[string]string {
	t.Helper()
	return map[string]string{
		"RELAY_PUBLIC_URL": "https://push.example.com",
		"RELAY_TOKEN_KEYS": "1:" + base64.StdEncoding.EncodeToString(make([]byte, 32)),
		"APNS_KEY_ID":      "ABC123",
		"APNS_TEAM_ID":     "B6BAJ46A72",
		"APNS_PRIVATE_KEY": testP8(t),
	}
}

func loadFromEnv(env map[string]string) (Config, error) {
	return loadConfig(func(k string) string { return env[k] })
}

func TestLoadConfigDefaults(t *testing.T) {
	cfg, err := loadFromEnv(validConfigEnv(t))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.GlobalPushBurst != 10 || cfg.GlobalPushPerMinute != 60 || cfg.MaxConcurrency != 8 {
		t.Fatalf("global limits: burst=%d perMinute=%v concurrency=%d",
			cfg.GlobalPushBurst, cfg.GlobalPushPerMinute, cfg.MaxConcurrency)
	}
	if len(cfg.APNsEnvironments) != 1 || cfg.APNsEnvironments[0] != EnvProduction {
		t.Fatalf("APNs environments must default to production only: %v", cfg.APNsEnvironments)
	}
	if cfg.APNs.ProductionURL != "https://api.push.apple.com" || cfg.APNs.DevelopmentURL != "https://api.sandbox.push.apple.com" {
		t.Fatalf("APNs URLs: %+v", cfg.APNs)
	}
	if cfg.PushBurst != 30 || cfg.PushPerMinute != 20 || cfg.RegisterBurst != 20 || cfg.RegisterPerMinute != 10 {
		t.Fatalf("per-device/per-IP defaults changed: %+v", cfg)
	}
}

func TestLoadConfigGlobalLimits(t *testing.T) {
	env := validConfigEnv(t)
	env["RELAY_GLOBAL_PUSH_BURST"] = "5"
	env["RELAY_GLOBAL_PUSH_PER_MINUTE"] = "30.5"
	env["RELAY_MAX_CONCURRENCY"] = "4"
	cfg, err := loadFromEnv(env)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.GlobalPushBurst != 5 || cfg.GlobalPushPerMinute != 30.5 || cfg.MaxConcurrency != 4 {
		t.Fatalf("configured limits: %+v", cfg)
	}
}

func TestLoadConfigRejectsInvalidLimits(t *testing.T) {
	cases := []struct{ name, value string }{
		{"RELAY_GLOBAL_PUSH_BURST", "0"},
		{"RELAY_GLOBAL_PUSH_BURST", "-1"},
		{"RELAY_GLOBAL_PUSH_BURST", "10001"},
		{"RELAY_GLOBAL_PUSH_BURST", "abc"},
		{"RELAY_PUSH_BURST", "0"},
		{"RELAY_PUSH_BURST", "10001"},
		{"RELAY_REGISTER_BURST", "0"},
		{"RELAY_REGISTER_BURST", "10001"},
		{"RELAY_MAX_CONCURRENCY", "0"},
		{"RELAY_MAX_CONCURRENCY", "257"},
		{"RELAY_MAX_CONCURRENCY", "abc"},
		{"RELAY_PUSH_PER_MINUTE", "NaN"},
		{"RELAY_PUSH_PER_MINUTE", "nan"},
		{"RELAY_PUSH_PER_MINUTE", "Inf"},
		{"RELAY_PUSH_PER_MINUTE", "+Inf"},
		{"RELAY_PUSH_PER_MINUTE", "-Inf"},
		{"RELAY_PUSH_PER_MINUTE", "0"},
		{"RELAY_PUSH_PER_MINUTE", "-1"},
		{"RELAY_PUSH_PER_MINUTE", "600001"},
		{"RELAY_REGISTER_PER_MINUTE", "NaN"},
		{"RELAY_REGISTER_PER_MINUTE", "Inf"},
		{"RELAY_REGISTER_PER_MINUTE", "-Inf"},
		{"RELAY_GLOBAL_PUSH_PER_MINUTE", "NaN"},
		{"RELAY_GLOBAL_PUSH_PER_MINUTE", "Inf"},
		{"RELAY_GLOBAL_PUSH_PER_MINUTE", "-Inf"},
		{"RELAY_GLOBAL_PUSH_PER_MINUTE", "0"},
		{"RELAY_GLOBAL_PUSH_PER_MINUTE", "600001"},
	}
	for _, tc := range cases {
		env := validConfigEnv(t)
		env[tc.name] = tc.value
		if _, err := loadFromEnv(env); err == nil || !strings.Contains(err.Error(), tc.name) {
			t.Errorf("%s=%q: error %v", tc.name, tc.value, err)
		}
	}
}

func TestLoadConfigAPNsEnvironments(t *testing.T) {
	for raw, want := range map[string][]Environment{
		"production":             {EnvProduction},
		"PRODUCTION":             {EnvProduction},
		"development":            {EnvDevelopment},
		"sandbox":                {EnvDevelopment},
		"production,development": {EnvProduction, EnvDevelopment},
		" development ":          {EnvDevelopment},
	} {
		env := validConfigEnv(t)
		env["RELAY_APNS_ENVIRONMENTS"] = raw
		cfg, err := loadFromEnv(env)
		if err != nil {
			t.Errorf("%q: %v", raw, err)
			continue
		}
		if len(cfg.APNsEnvironments) != len(want) {
			t.Errorf("%q: got %v, want %v", raw, cfg.APNsEnvironments, want)
			continue
		}
		for i := range want {
			if cfg.APNsEnvironments[i] != want[i] {
				t.Errorf("%q: got %v, want %v", raw, cfg.APNsEnvironments, want)
				break
			}
		}
	}
	for _, raw := range []string{"staging", "production,", "production,,development", "production,production", "sandbox,development"} {
		env := validConfigEnv(t)
		env["RELAY_APNS_ENVIRONMENTS"] = raw
		if _, err := loadFromEnv(env); err == nil || !strings.Contains(err.Error(), "RELAY_APNS_ENVIRONMENTS") {
			t.Errorf("%q: error %v", raw, err)
		}
	}
}

func TestLoadConfigAPNsURLs(t *testing.T) {
	for name, want := range map[string]string{
		"https://api.push.apple.com/":       "https://api.push.apple.com",
		"http://127.0.0.1:1234/fake/":       "http://127.0.0.1:1234/fake",
		"https://api.push.apple.com/prod/":  "https://api.push.apple.com/prod",
		"http://localhost:1234/":            "http://localhost:1234",
		"https://[::1]:1234/sandbox-prefix": "https://[::1]:1234/sandbox-prefix",
	} {
		env := validConfigEnv(t)
		env["APNS_PRODUCTION_URL"] = name
		cfg, err := loadFromEnv(env)
		if err != nil || cfg.APNs.ProductionURL != want {
			t.Errorf("%q: got %q, %v", name, cfg.APNs.ProductionURL, err)
		}
	}
	for _, raw := range []string{"api.push.apple.com", "ftp://api.push.apple.com", "http://api.push.apple.com", "https://api.push.apple.com/?x=1", "https://user:pass@api.push.apple.com"} {
		env := validConfigEnv(t)
		env["APNS_DEVELOPMENT_URL"] = raw
		if _, err := loadFromEnv(env); err == nil || !strings.Contains(err.Error(), "APNS_DEVELOPMENT_URL") {
			t.Errorf("%q: error %v", raw, err)
		}
	}
}

func TestLoadConfigTokenKeysFile(t *testing.T) {
	dir := t.TempDir()
	secret1 := base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{1}, 32))
	secret2 := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{2}, 32))
	path := filepath.Join(dir, "endpoint-token-keys")
	if err := os.WriteFile(path, []byte("2:"+secret1+"\n1:"+secret2+"\n"), 0o400); err != nil {
		t.Fatal(err)
	}
	env := validConfigEnv(t)
	delete(env, "RELAY_TOKEN_KEYS")
	env["RELAY_TOKEN_KEYS_FILE"] = path
	cfg, err := loadFromEnv(env)
	if err != nil {
		t.Fatal(err)
	}
	if len(cfg.TokenKeys) != 2 || cfg.TokenKeys[0].ID != 2 || cfg.TokenKeys[1].ID != 1 {
		t.Fatalf("token keys: %+v", cfg.TokenKeys)
	}

	both := validConfigEnv(t)
	both["RELAY_TOKEN_KEYS_FILE"] = path
	if _, err := loadFromEnv(both); err == nil || !strings.Contains(err.Error(), "exactly one") {
		t.Fatalf("both key sources accepted: %v", err)
	}

	if err := os.Chmod(path, 0o644); err != nil {
		t.Fatal(err)
	}
	_, err = loadFromEnv(env)
	if err == nil || !strings.Contains(err.Error(), "readable only by its owner") {
		t.Fatalf("group-readable key file accepted: %v", err)
	}
	if strings.Contains(err.Error(), secret1) || strings.Contains(err.Error(), secret2) {
		t.Fatalf("error leaked key material: %v", err)
	}

	if err := os.Chmod(path, 0o400); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(strings.Repeat("a", maxTokenKeysFile+1)), 0o400); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, 0o400); err != nil {
		t.Fatal(err)
	}
	if _, err := loadFromEnv(env); err == nil || !strings.Contains(err.Error(), "at most") {
		t.Fatalf("oversized key file accepted: %v", err)
	}

	if err := os.Chmod(path, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, nil, 0o400); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, 0o400); err != nil {
		t.Fatal(err)
	}
	if _, err := loadFromEnv(env); err == nil {
		t.Fatal("empty key file accepted")
	}

	env["RELAY_TOKEN_KEYS_FILE"] = dir
	if _, err := loadFromEnv(env); err == nil || !strings.Contains(err.Error(), "regular file") {
		t.Fatalf("directory accepted: %v", err)
	}

	duplicate := filepath.Join(dir, "duplicate-keys")
	if err := os.WriteFile(duplicate, []byte("1:"+secret1+"\n1:"+secret2+"\n"), 0o400); err != nil {
		t.Fatal(err)
	}
	env["RELAY_TOKEN_KEYS_FILE"] = duplicate
	_, err = loadFromEnv(env)
	if err == nil {
		t.Fatal("duplicate key file accepted")
	}
	if strings.Contains(err.Error(), secret1) || strings.Contains(err.Error(), secret2) {
		t.Fatalf("error leaked key material: %v", err)
	}
}

func TestLoadConfigRequiresTokenKeySource(t *testing.T) {
	env := validConfigEnv(t)
	delete(env, "RELAY_TOKEN_KEYS")
	if _, err := loadFromEnv(env); err == nil || !strings.Contains(err.Error(), "RELAY_TOKEN_KEYS") {
		t.Fatalf("missing key source: %v", err)
	}
}
