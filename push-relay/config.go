package main

import (
	"crypto/ecdsa"
	"crypto/x509"
	"encoding/base64"
	"encoding/pem"
	"errors"
	"fmt"
	"net"
	"net/url"
	"os"
	"strconv"
	"strings"
)

const defaultAPNsTopic = "com.termllm.app"

// Config is the complete relay configuration, loaded from the environment.
type Config struct {
	ListenAddr string
	// PublicURL is the externally reachable origin (scheme://host[:port]) used
	// to build subscription endpoints and to check the VAPID "aud" claim.
	PublicURL string
	TokenKeys []TokenKey // first entry seals new tokens; all entries open tokens
	APNs      APNsConfig

	AlertTitle string
	AlertBody  string

	PushBurst         int
	PushPerMinute     float64
	RegisterBurst     int
	RegisterPerMinute float64

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
		ListenAddr:        getenv("RELAY_LISTEN_ADDR"),
		AlertTitle:        envDefault(getenv, "RELAY_ALERT_TITLE", "term-llm"),
		AlertBody:         envDefault(getenv, "RELAY_ALERT_BODY", "New notification"),
		ClientIPHeader:    strings.TrimSpace(getenv("RELAY_CLIENT_IP_HEADER")),
		PushBurst:         30,
		PushPerMinute:     20,
		RegisterBurst:     20,
		RegisterPerMinute: 10,
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

	keys, err := parseTokenKeys(getenv("RELAY_TOKEN_KEYS"))
	if err != nil {
		errs = append(errs, err)
	}
	cfg.TokenKeys = keys

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
	}{{"RELAY_PUSH_BURST", &cfg.PushBurst}, {"RELAY_REGISTER_BURST", &cfg.RegisterBurst}} {
		if raw := strings.TrimSpace(getenv(item.name)); raw != "" {
			n, convErr := strconv.Atoi(raw)
			if convErr != nil || n < 1 {
				errs = append(errs, fmt.Errorf("%s must be a positive integer", item.name))
				continue
			}
			*item.dst = n
		}
	}
	for _, item := range []struct {
		name string
		dst  *float64
	}{{"RELAY_PUSH_PER_MINUTE", &cfg.PushPerMinute}, {"RELAY_REGISTER_PER_MINUTE", &cfg.RegisterPerMinute}} {
		if raw := strings.TrimSpace(getenv(item.name)); raw != "" {
			n, convErr := strconv.ParseFloat(raw, 64)
			if convErr != nil || n <= 0 {
				errs = append(errs, fmt.Errorf("%s must be a positive number", item.name))
				continue
			}
			*item.dst = n
		}
	}
	return cfg, errors.Join(errs...)
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
	for _, part := range strings.Split(raw, ",") {
		part = strings.TrimSpace(part)
		idText, secretText, ok := strings.Cut(part, ":")
		if !ok {
			return nil, errors.New("RELAY_TOKEN_KEYS entries must look like id:base64secret")
		}
		id, err := strconv.ParseUint(strings.TrimSpace(idText), 10, 8)
		if err != nil {
			return nil, fmt.Errorf("RELAY_TOKEN_KEYS key id %q must be 0-255", idText)
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
