// Package config loads and validates the push relay's operator configuration.
//
// Every value that could broaden the relay's authority (Apple endpoint, topic,
// credentials) is either fixed by the binary or validated here. Configuration
// errors deliberately never include file contents or secrets.
package config

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/x509"
	"encoding/pem"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const (
	// DefaultAddr is deliberately loopback-only. Remote exposure must be an
	// explicit operator decision, normally through a TLS reverse proxy.
	DefaultAddr = "127.0.0.1:8768"

	DefaultAPNSTimeout     = 10 * time.Second
	DefaultShutdownTimeout = 10 * time.Second
	DefaultMaxConcurrent   = 16

	maxKeyFileBytes   = 16 << 10
	maxTokenFileBytes = 1024
	minTokenLength    = 32
	maxTokenLength    = 512
	minTokenDistinct  = 8
)

var (
	keyIDPattern = regexp.MustCompile(`^[A-Za-z0-9]{1,64}$`)
	topicPattern = regexp.MustCompile(`^[A-Za-z0-9._-]{1,255}$`)
)

// Config is the fully validated process configuration.
type Config struct {
	// Addr is the HTTP listen address. It defaults to 127.0.0.1:8768.
	Addr string

	// APNSKey is the PKCS#8 P-256 signing key used for provider JWTs.
	APNSKey *ecdsa.PrivateKey
	// APNSKeyID and APNSTeamID identify the Apple provider token.
	APNSKeyID  string
	APNSTeamID string
	// APNSTopic is the fixed bundle topic for every notification.
	APNSTopic string

	// Token is the shared bearer credential for POST /v1/push. It is kept in
	// memory only and is never logged or returned.
	Token []byte

	APNSTimeout     time.Duration
	ShutdownTimeout time.Duration
	MaxConcurrent   int
}

// Load reads configuration from the supplied environment lookup. It is
// intended to be called once at startup; a returned error is fatal.
func Load(getenv func(string) string) (Config, error) {
	keyPath := strings.TrimSpace(getenv("APNS_KEY_FILE"))
	if keyPath == "" {
		return Config{}, fmt.Errorf("APNS_KEY_FILE is required")
	}
	keyPath, err := resolveCredentialPath(getenv, keyPath, "APNS_KEY_FILE")
	if err != nil {
		return Config{}, err
	}
	keyID := strings.TrimSpace(getenv("APNS_KEY_ID"))
	if !keyIDPattern.MatchString(keyID) {
		return Config{}, fmt.Errorf("APNS_KEY_ID is required and must be 1-64 ASCII letters or digits")
	}
	teamID := strings.TrimSpace(getenv("APNS_TEAM_ID"))
	if !keyIDPattern.MatchString(teamID) {
		return Config{}, fmt.Errorf("APNS_TEAM_ID is required and must be 1-64 ASCII letters or digits")
	}
	topic := strings.TrimSpace(getenv("APNS_TOPIC"))
	if !topicPattern.MatchString(topic) {
		return Config{}, fmt.Errorf("APNS_TOPIC is required and must be 1-255 characters of letters, digits, dot, underscore, or hyphen")
	}
	tokenPath := strings.TrimSpace(getenv("RELAY_TOKEN_FILE"))
	if tokenPath == "" {
		return Config{}, fmt.Errorf("RELAY_TOKEN_FILE is required")
	}
	tokenPath, err = resolveCredentialPath(getenv, tokenPath, "RELAY_TOKEN_FILE")
	if err != nil {
		return Config{}, err
	}

	addr, err := parseAddr(getenv("RELAY_ADDR"))
	if err != nil {
		return Config{}, err
	}
	key, err := loadSigningKey(keyPath)
	if err != nil {
		return Config{}, err
	}
	token, err := loadRelayToken(tokenPath)
	if err != nil {
		return Config{}, err
	}
	apnsTimeout, err := durationValue(getenv, "APNS_TIMEOUT", DefaultAPNSTimeout, time.Second, 60*time.Second)
	if err != nil {
		return Config{}, err
	}
	shutdownTimeout, err := durationValue(getenv, "RELAY_SHUTDOWN_TIMEOUT", DefaultShutdownTimeout, time.Second, 60*time.Second)
	if err != nil {
		return Config{}, err
	}
	maxConcurrent, err := intValue(getenv, "RELAY_MAX_CONCURRENCY", DefaultMaxConcurrent, 1, 128)
	if err != nil {
		return Config{}, err
	}

	return Config{
		Addr:            addr,
		APNSKey:         key,
		APNSKeyID:       keyID,
		APNSTeamID:      teamID,
		APNSTopic:       topic,
		Token:           token,
		APNSTimeout:     apnsTimeout,
		ShutdownTimeout: shutdownTimeout,
		MaxConcurrent:   maxConcurrent,
	}, nil
}

// resolveCredentialPath supports the LoadCredential layout used by the supplied
// unit, where APNS_KEY_FILE and RELAY_TOKEN_FILE name files below systemd's
// per-service credentials directory. A literal "%d/<single-file-name>" value is
// accepted in case the unit's Environment= value reaches the process without
// systemd resolving it; an already-resolved absolute path is passed through.
// Only a single file name is allowed below the credentials directory so this
// compatibility path cannot escape it.
func resolveCredentialPath(getenv func(string) string, path, label string) (string, error) {
	const prefix = "%d/"
	if !strings.HasPrefix(path, prefix) {
		return path, nil
	}
	directory := strings.TrimSpace(getenv("CREDENTIALS_DIRECTORY"))
	if directory == "" {
		return "", fmt.Errorf("%s uses %%d but CREDENTIALS_DIRECTORY is not set", label)
	}
	name := strings.TrimPrefix(path, prefix)
	if name == "" || name == "." || name == ".." || strings.ContainsAny(name, `/\`) {
		return "", fmt.Errorf("%s must name a single file below the credentials directory", label)
	}
	return filepath.Join(directory, name), nil
}

func parseAddr(raw string) (string, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		raw = DefaultAddr
	}
	if strings.IndexFunc(raw, func(r rune) bool { return r <= ' ' }) >= 0 {
		return "", fmt.Errorf("RELAY_ADDR must not contain whitespace or control characters")
	}
	host, port, err := net.SplitHostPort(raw)
	if err != nil {
		return "", fmt.Errorf("RELAY_ADDR must be host:port: %w", err)
	}
	if host == "" {
		return "", fmt.Errorf("RELAY_ADDR must include an explicit host (use 0.0.0.0 only if remote exposure is intentional)")
	}
	number, err := strconv.Atoi(port)
	if err != nil || number < 1 || number > 65535 {
		return "", fmt.Errorf("RELAY_ADDR port must be a number between 1 and 65535")
	}
	return raw, nil
}

func loadSigningKey(path string) (*ecdsa.PrivateKey, error) {
	data, err := readPrivateFile(path, maxKeyFileBytes, "APNS_KEY_FILE")
	if err != nil {
		return nil, err
	}
	block, rest := pem.Decode(data)
	if block == nil {
		return nil, fmt.Errorf("APNS_KEY_FILE does not contain a PEM block")
	}
	if block.Type != "PRIVATE KEY" {
		return nil, fmt.Errorf("APNS_KEY_FILE must contain a PKCS#8 PRIVATE KEY block")
	}
	if len(bytes.TrimSpace(rest)) != 0 {
		return nil, fmt.Errorf("APNS_KEY_FILE must contain exactly one PKCS#8 PRIVATE KEY block")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("APNS_KEY_FILE is not a valid PKCS#8 private key")
	}
	key, ok := parsed.(*ecdsa.PrivateKey)
	if !ok {
		return nil, fmt.Errorf("APNS_KEY_FILE must contain an ECDSA private key")
	}
	if key.Curve != elliptic.P256() {
		return nil, fmt.Errorf("APNS_KEY_FILE must contain a P-256 private key")
	}
	if _, err := key.ECDH(); err != nil {
		return nil, fmt.Errorf("APNS_KEY_FILE contains an invalid P-256 private key")
	}
	return key, nil
}

func loadRelayToken(path string) ([]byte, error) {
	data, err := readPrivateFile(path, maxTokenFileBytes, "RELAY_TOKEN_FILE")
	if err != nil {
		return nil, err
	}
	token := bytes.TrimSpace(data)
	if len(token) < minTokenLength || len(token) > maxTokenLength {
		return nil, fmt.Errorf("RELAY_TOKEN_FILE must contain a token of %d-%d bytes", minTokenLength, maxTokenLength)
	}
	seen := make(map[byte]struct{}, len(token))
	for _, b := range token {
		if b < 0x21 || b > 0x7e {
			return nil, fmt.Errorf("RELAY_TOKEN_FILE token must contain only printable ASCII without whitespace")
		}
		seen[b] = struct{}{}
	}
	if len(seen) < minTokenDistinct {
		return nil, fmt.Errorf("RELAY_TOKEN_FILE token is not sufficiently distinct; generate it with a cryptographic random source")
	}
	return append([]byte(nil), token...), nil
}

// readPrivateFile opens a secret file, checks that it is a regular file with no
// group/other access, and reads it with a hard size bound.
func readPrivateFile(path string, max int64, label string) ([]byte, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("%s cannot be opened: %w", label, err)
	}
	defer file.Close()

	info, err := file.Stat()
	if err != nil {
		return nil, fmt.Errorf("%s cannot be inspected: %w", label, err)
	}
	if !info.Mode().IsRegular() {
		return nil, fmt.Errorf("%s must be a regular file", label)
	}
	if info.Mode().Perm()&0o077 != 0 {
		return nil, fmt.Errorf("%s must not be accessible by group or others (use chmod 600 or 400)", label)
	}
	if info.Size() <= 0 || info.Size() > max {
		return nil, fmt.Errorf("%s has an invalid size", label)
	}

	data, err := io.ReadAll(io.LimitReader(file, max+1))
	if err != nil {
		return nil, fmt.Errorf("%s cannot be read: %w", label, err)
	}
	if int64(len(data)) > max {
		return nil, fmt.Errorf("%s is too large", label)
	}
	return data, nil
}

func durationValue(getenv func(string) string, name string, fallback, min, max time.Duration) (time.Duration, error) {
	raw := strings.TrimSpace(getenv(name))
	if raw == "" {
		return fallback, nil
	}
	value, err := time.ParseDuration(raw)
	if err != nil || value < min || value > max {
		return 0, fmt.Errorf("%s must be a duration between %s and %s", name, min, max)
	}
	return value, nil
}

func intValue(getenv func(string) string, name string, fallback, min, max int) (int, error) {
	raw := strings.TrimSpace(getenv(name))
	if raw == "" {
		return fallback, nil
	}
	value, err := strconv.Atoi(raw)
	if err != nil || value < min || value > max {
		return 0, fmt.Errorf("%s must be an integer between %d and %d", name, min, max)
	}
	return value, nil
}
