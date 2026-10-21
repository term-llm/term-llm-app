package main

import (
	"crypto/ecdsa"
	"crypto/x509"
	"encoding/base64"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"math"
	"net"
	"net/url"
	"os"
	"strconv"
	"strings"
)

const (
	defaultAPNsTopic = "com.termllm.app"

	defaultGlobalPushBurst     = 10
	defaultGlobalPushPerMinute = 60
	defaultMaxConcurrency      = 8

	maxRateBurst     = 10_000
	maxRatePerMinute = 600_000
	maxConcurrency   = 256
	maxTokenKeysFile = 4096
)

// Config is the complete relay configuration, loaded from the environment.
type Config struct {
	ListenAddr string
	// PublicURL is the externally reachable origin (scheme://host[:port]) used
	// to build subscription endpoints and to check the VAPID "aud" claim.
	PublicURL string
	TokenKeys []TokenKey // first entry seals new tokens; all entries open tokens
	APNs      APNsConfig

	// APNsEnvironments lists the APNs gateways this deployment accepts.
	// Defaults to production only so an unconfigured relay fails closed for
	// development/sandbox registrations.
	APNsEnvironments []Environment

	AlertTitle string
	AlertBody  string

	PushBurst         int
	PushPerMinute     float64
	RegisterBurst     int
	RegisterPerMinute float64

	// GlobalPushBurst and GlobalPushPerMinute bound all outbound APNs sends
	// per process, regardless of device token or client IP.
	GlobalPushBurst     int
	GlobalPushPerMinute float64
	// MaxConcurrency is the maximum number of APNs sends in flight per process.
	MaxConcurrency int

	// ClientIPHeader, when set, names a header written by a trusted proxy
	// (e.g. Fly-Client-IP) that carries the client address for rate limiting.
	ClientIPHeader string
}

// TokenKey is a 32-byte secret used to seal subscription tokens.
type TokenKey struct {
	ID     byte
	Secret []byte
}

// APNsConfig holds the provider-token credentials for Apple Push Notification service.
type APNsConfig struct {
	KeyID      string
	TeamID     string
	Topic      string
	PrivateKey *ecdsa.PrivateKey

	ProductionURL  string
	DevelopmentURL string
}

func loadConfig(getenv func(string) string) (Config, error) {
	var errs []error
	cfg := Config{
		ListenAddr:          getenv("RELAY_LISTEN_ADDR"),
		AlertTitle:          envDefault(getenv, "RELAY_ALERT_TITLE", "term-llm"),
		AlertBody:           envDefault(getenv, "RELAY_ALERT_BODY", "New notification"),
		ClientIPHeader:      strings.TrimSpace(getenv("RELAY_CLIENT_IP_HEADER")),
		PushBurst:           30,
		PushPerMinute:       20,
		RegisterBurst:       20,
		RegisterPerMinute:   10,
		GlobalPushBurst:     defaultGlobalPushBurst,
		GlobalPushPerMinute: defaultGlobalPushPerMinute,
		MaxConcurrency:      defaultMaxConcurrency,
		APNs: APNsConfig{
			KeyID:          strings.TrimSpace(getenv("APNS_KEY_ID")),
			TeamID:         strings.TrimSpace(getenv("APNS_TEAM_ID")),
			Topic:          envDefault(getenv, "APNS_TOPIC", defaultAPNsTopic),
			ProductionURL:  envDefault(getenv, "APNS_PRODUCTION_URL", "https://api.push.apple.com"),
			DevelopmentURL: envDefault(getenv, "APNS_DEVELOPMENT_URL", "https://api.sandbox.push.apple.com"),
		},
	}
	if cfg.ListenAddr == "" {
		if port := strings.TrimSpace(getenv("PORT")); port != "" {
			cfg.ListenAddr = ":" + port
		} else {
			cfg.ListenAddr = ":8080"
		}
	}

	publicURL, err := normalizePublicURL(getenv("RELAY_PUBLIC_URL"))
	if err != nil {
		errs = append(errs, err)
	}
	cfg.PublicURL = publicURL

	envs, err := parseAPNsEnvironments(getenv("RELAY_APNS_ENVIRONMENTS"))
	if err != nil {
		errs = append(errs, err)
	}
	cfg.APNsEnvironments = envs

	for _, item := range []struct {
		name string
		dst  *string
	}{{"APNS_PRODUCTION_URL", &cfg.APNs.ProductionURL}, {"APNS_DEVELOPMENT_URL", &cfg.APNs.DevelopmentURL}} {
		normalized, urlErr := normalizeAPNsURL(item.name, *item.dst)
		if urlErr != nil {
			errs = append(errs, urlErr)
			continue
		}
		*item.dst = normalized
	}

	keysRaw := strings.TrimSpace(getenv("RELAY_TOKEN_KEYS"))
	keysPath := strings.TrimSpace(getenv("RELAY_TOKEN_KEYS_FILE"))
	switch {
	case keysRaw != "" && keysPath != "":
		errs = append(errs, errors.New("set exactly one of RELAY_TOKEN_KEYS or RELAY_TOKEN_KEYS_FILE"))
	case keysPath != "":
		keys, keyErr := readTokenKeysFile(keysPath)
		if keyErr != nil {
			errs = append(errs, keyErr)
			break
		}
		cfg.TokenKeys = keys
	case keysRaw != "":
		keys, keyErr := parseTokenKeys(keysRaw)
		if keyErr != nil {
			errs = append(errs, keyErr)
			break
		}
		cfg.TokenKeys = keys
	default:
		errs = append(errs, errors.New("RELAY_TOKEN_KEYS or RELAY_TOKEN_KEYS_FILE is required (generate one with `push-relay genkey`)"))
	}

	if cfg.APNs.KeyID == "" {
		errs = append(errs, errors.New("APNS_KEY_ID is required"))
	}
	if cfg.APNs.TeamID == "" {
		errs = append(errs, errors.New("APNS_TEAM_ID is required"))
	}
	pemData := getenv("APNS_PRIVATE_KEY")
	if path := strings.TrimSpace(getenv("APNS_PRIVATE_KEY_FILE")); path != "" {
		data, readErr := os.ReadFile(path)
		if readErr != nil {
			errs = append(errs, fmt.Errorf("read APNS_PRIVATE_KEY_FILE: %w", readErr))
		}
		pemData = string(data)
	}
	if strings.TrimSpace(pemData) == "" {
		errs = append(errs, errors.New("APNS_PRIVATE_KEY or APNS_PRIVATE_KEY_FILE is required"))
	} else if key, keyErr := parseAPNsPrivateKey(pemData); keyErr != nil {
		errs = append(errs, keyErr)
	} else {
		cfg.APNs.PrivateKey = key
	}

	for _, item := range []struct {
		name string
		dst  *int
	}{
		{"RELAY_PUSH_BURST", &cfg.PushBurst},
		{"RELAY_REGISTER_BURST", &cfg.RegisterBurst},
		{"RELAY_GLOBAL_PUSH_BURST", &cfg.GlobalPushBurst},
	} {
		if err := parseIntEnv(getenv, item.name, item.dst, 1, maxRateBurst); err != nil {
			errs = append(errs, err)
		}
	}
	if err := parseIntEnv(getenv, "RELAY_MAX_CONCURRENCY", &cfg.MaxConcurrency, 1, maxConcurrency); err != nil {
		errs = append(errs, err)
	}
	for _, item := range []struct {
		name string
		dst  *float64
	}{
		{"RELAY_PUSH_PER_MINUTE", &cfg.PushPerMinute},
		{"RELAY_REGISTER_PER_MINUTE", &cfg.RegisterPerMinute},
		{"RELAY_GLOBAL_PUSH_PER_MINUTE", &cfg.GlobalPushPerMinute},
	} {
		if err := parseFiniteRateEnv(getenv, item.name, item.dst); err != nil {
			errs = append(errs, err)
		}
	}
	return cfg, errors.Join(errs...)
}

func parseIntEnv(getenv func(string) string, name string, dst *int, minValue, maxValue int) error {
	raw := strings.TrimSpace(getenv(name))
	if raw == "" {
		return nil
	}
	n, err := strconv.Atoi(raw)
	if err != nil || n < minValue || n > maxValue {
		return fmt.Errorf("%s must be an integer between %d and %d", name, minValue, maxValue)
	}
	*dst = n
	return nil
}

func parseFiniteRateEnv(getenv func(string) string, name string, dst *float64) error {
	raw := strings.TrimSpace(getenv(name))
	if raw == "" {
		return nil
	}
	n, err := strconv.ParseFloat(raw, 64)
	if err != nil || math.IsNaN(n) || math.IsInf(n, 0) || n <= 0 || n > maxRatePerMinute {
		return fmt.Errorf("%s must be a finite positive number no greater than %g", name, float64(maxRatePerMinute))
	}
	*dst = n
	return nil
}

// parseAPNsEnvironments parses RELAY_APNS_ENVIRONMENTS. The default is
// production only, so a deployment must opt in before it can mint sandbox
// endpoints.
func parseAPNsEnvironments(raw string) ([]Environment, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return []Environment{EnvProduction}, nil
	}
	seen := map[Environment]bool{}
	for _, part := range strings.Split(raw, ",") {
		name := strings.ToLower(strings.TrimSpace(part))
		if name == "" {
			return nil, errors.New("RELAY_APNS_ENVIRONMENTS must not contain empty entries")
		}
		env, err := parseEnvironment(name)
		if err != nil {
			return nil, fmt.Errorf("RELAY_APNS_ENVIRONMENTS: unsupported environment %q (use production or development)", name)
		}
		if seen[env] {
			return nil, fmt.Errorf("RELAY_APNS_ENVIRONMENTS must not list %s twice", env.String())
		}
		seen[env] = true
	}
	var out []Environment
	if seen[EnvProduction] {
		out = append(out, EnvProduction)
	}
	if seen[EnvDevelopment] {
		out = append(out, EnvDevelopment)
	}
	return out, nil
}

// normalizeAPNsURL validates an APNs base URL. Plain HTTP is accepted only for
// loopback hosts so tests can inject a local fake APNs. Operator overrides are
// explicit configuration; request data never selects a host.
func normalizeAPNsURL(name, raw string) (string, error) {
	raw = strings.TrimSpace(raw)
	u, err := url.Parse(raw)
	if err != nil || u.Host == "" || (u.Scheme != "https" && u.Scheme != "http") {
		return "", fmt.Errorf("%s must be an absolute http(s) URL", name)
	}
	if u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return "", fmt.Errorf("%s must not include credentials, a query or a fragment", name)
	}
	if u.Scheme == "http" {
		host := u.Hostname()
		ip := net.ParseIP(host)
		if host != "localhost" && (ip == nil || !ip.IsLoopback()) {
			return "", fmt.Errorf("%s must use https (http is only allowed for loopback test endpoints)", name)
		}
	}
	u.Path = strings.TrimRight(u.Path, "/")
	return u.String(), nil
}

// readTokenKeysFile loads RELAY_TOKEN_KEYS_FILE from an owner-only regular
// file. The contents are never included in errors.
func readTokenKeysFile(path string) ([]TokenKey, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("read RELAY_TOKEN_KEYS_FILE %s: %w", path, err)
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return nil, fmt.Errorf("read RELAY_TOKEN_KEYS_FILE %s: %w", path, err)
	}
	if !info.Mode().IsRegular() {
		return nil, fmt.Errorf("RELAY_TOKEN_KEYS_FILE %s must be a regular file", path)
	}
	if info.Mode().Perm()&0o077 != 0 {
		return nil, fmt.Errorf("RELAY_TOKEN_KEYS_FILE %s must be readable only by its owner (chmod 0400)", path)
	}
	if info.Size() > maxTokenKeysFile {
		return nil, fmt.Errorf("RELAY_TOKEN_KEYS_FILE %s must be at most %d bytes", path, maxTokenKeysFile)
	}
	data, err := io.ReadAll(io.LimitReader(file, maxTokenKeysFile+1))
	if err != nil {
		return nil, fmt.Errorf("read RELAY_TOKEN_KEYS_FILE %s: %w", path, err)
	}
	if len(data) > maxTokenKeysFile {
		return nil, fmt.Errorf("RELAY_TOKEN_KEYS_FILE %s must be at most %d bytes", path, maxTokenKeysFile)
	}
	keys, err := parseTokenKeys(string(data))
	if err != nil {
		return nil, fmt.Errorf("RELAY_TOKEN_KEYS_FILE %s: %w", path, err)
	}
	return keys, nil
}

func envDefault(getenv func(string) string, name, fallback string) string {
	if v := strings.TrimSpace(getenv(name)); v != "" {
		return v
	}
	return fallback
}

// normalizePublicURL requires an HTTPS origin with no path. Plain HTTP is
// accepted only for loopback hosts, for local development.
func normalizePublicURL(raw string) (string, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return "", errors.New("RELAY_PUBLIC_URL is required (e.g. https://push.term-llm.com)")
	}
	u, err := url.Parse(raw)
	if err != nil || u.Host == "" {
		return "", fmt.Errorf("RELAY_PUBLIC_URL %q is not an absolute URL", raw)
	}
	if (u.Path != "" && u.Path != "/") || u.RawQuery != "" || u.Fragment != "" || u.User != nil {
		return "", errors.New("RELAY_PUBLIC_URL must be an origin without a path, query or credentials")
	}
	switch u.Scheme {
	case "https":
	case "http":
		host := u.Hostname()
		ip := net.ParseIP(host)
		if host != "localhost" && (ip == nil || !ip.IsLoopback()) {
			return "", errors.New("RELAY_PUBLIC_URL must use https (http is only allowed for loopback hosts)")
		}
	default:
		return "", errors.New("RELAY_PUBLIC_URL must use https")
	}
	return u.Scheme + "://" + strings.ToLower(u.Host), nil
}

// parseTokenKeys parses "id:base64secret[,id:base64secret...]". The first key
// seals new tokens; keep retired keys listed so existing endpoints keep working.
func parseTokenKeys(raw string) ([]TokenKey, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil, errors.New("RELAY_TOKEN_KEYS is required (generate one with `push-relay genkey`)")
	}
	var keys []TokenKey
	seen := map[byte]bool{}
	for _, part := range strings.FieldsFunc(raw, func(r rune) bool {
		return r == ',' || r == '\n' || r == '\r'
	}) {
		part = strings.TrimSpace(part)
		idText, secretText, ok := strings.Cut(part, ":")
		if !ok {
			return nil, errors.New("RELAY_TOKEN_KEYS entries must look like id:base64secret")
		}
		id, err := strconv.ParseUint(strings.TrimSpace(idText), 10, 8)
		if err != nil {
			return nil, errors.New("RELAY_TOKEN_KEYS key ids must be decimal numbers from 0 to 255")
		}
		secret, err := decodeBase64Any(strings.TrimSpace(secretText))
		if err != nil || len(secret) != 32 {
			return nil, fmt.Errorf("RELAY_TOKEN_KEYS key %d must be 32 bytes of base64", id)
		}
		if seen[byte(id)] {
			return nil, fmt.Errorf("RELAY_TOKEN_KEYS key id %d is duplicated", id)
		}
		seen[byte(id)] = true
		keys = append(keys, TokenKey{ID: byte(id), Secret: secret})
	}
	return keys, nil
}

// parseAPNsPrivateKey accepts the .p8 PEM text, or the same text base64-encoded
// (convenient for single-line secret stores).
func parseAPNsPrivateKey(data string) (*ecdsa.PrivateKey, error) {
	data = strings.TrimSpace(data)
	if !strings.HasPrefix(data, "-----BEGIN") {
		decoded, err := decodeBase64Any(data)
		if err != nil {
			return nil, errors.New("APNs private key must be PEM (.p8) text or base64-encoded PEM")
		}
		data = string(decoded)
	}
	block, _ := pem.Decode([]byte(data))
	if block == nil {
		return nil, errors.New("APNs private key is not valid PEM")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("parse APNs private key: %w", err)
	}
	key, ok := parsed.(*ecdsa.PrivateKey)
	if !ok || key.Curve.Params().Name != "P-256" {
		return nil, errors.New("APNs private key must be a P-256 ECDSA key")
	}
	return key, nil
}

// decodeBase64Any accepts standard or URL-safe base64, padded or not.
func decodeBase64Any(s string) ([]byte, error) {
	s = strings.TrimRight(strings.TrimSpace(s), "=")
	if strings.ContainsAny(s, "-_") {
		return base64.RawURLEncoding.DecodeString(s)
	}
	return base64.RawStdEncoding.DecodeString(s)
}
