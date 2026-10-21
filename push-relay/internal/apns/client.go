// Package apns builds notification payloads and sends them directly to Apple's
// fixed HTTP/2 APNs endpoints. It performs no application-level retries and does
// not follow redirects; callers receive either an accepted status, a structured
// APNs rejection, or a sanitized transport error.
package apns

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"time"
	"unicode/utf8"
)

const (
	// MaxPayloadBytes is Apple's maximum notification payload for the alert
	// push type.
	MaxPayloadBytes = 4096

	// Apple documents device tokens as variable length and explicitly says not
	// to assume a size. These bounds are defensive only: they keep an
	// authenticated caller from supplying an unbounded path segment while
	// accepting every plausible hex-encoded token length. APNs tokens are
	// canonically hexadecimal, and an odd length cannot be a byte string.
	MinDeviceTokenHexLength = 32
	MaxDeviceTokenHexLength = 512

	maxAPNSErrorBodyBytes = 8 << 10
)

var (
	ErrInvalidEnvironment = errors.New("invalid APNs environment")
	ErrInvalidDeviceToken = errors.New("invalid device token")
	ErrInvalidPayload     = errors.New("invalid notification payload")
	ErrPayloadTooLarge    = fmt.Errorf("notification payload exceeds %d bytes", MaxPayloadBytes)
	ErrReservedPayloadKey = errors.New(`notification data must not contain the reserved key "aps"`)
)

// Environment selects exactly one of Apple's fixed endpoints. It is supplied
// explicitly per request; there is no implicit production fallback.
type Environment string

const (
	Sandbox    Environment = "sandbox"
	Production Environment = "production"
)

var defaultEndpoints = map[Environment]string{
	Sandbox:    "https://api.sandbox.push.apple.com",
	Production: "https://api.push.apple.com",
}

func ParseEnvironment(raw string) (Environment, error) {
	switch Environment(raw) {
	case Sandbox:
		return Sandbox, nil
	case Production:
		return Production, nil
	default:
		return "", ErrInvalidEnvironment
	}
}

// ValidateDeviceToken enforces a bounded, even-length hexadecimal token. It
// intentionally does not require Apple's commonly observed 64 characters.
func ValidateDeviceToken(token string) error {
	if len(token) < MinDeviceTokenHexLength || len(token) > MaxDeviceTokenHexLength || len(token)%2 != 0 {
		return ErrInvalidDeviceToken
	}
	for i := 0; i < len(token); i++ {
		c := token[i]
		if (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F') {
			continue
		}
		return ErrInvalidDeviceToken
	}
	return nil
}

type alertPayload struct {
	Title string `json:"title"`
	Body  string `json:"body"`
}

type apsPayload struct {
	Alert alertPayload `json:"alert"`
	Sound string       `json:"sound"`
}

// BuildPayload creates the final JSON body. The aps dictionary is always owned
// by the relay so callers cannot override alert, sound, or any other APNs
// control key.
func BuildPayload(title, body string, data map[string]json.RawMessage) ([]byte, error) {
	if !utf8.ValidString(title) || !utf8.ValidString(body) || strings.TrimSpace(title) == "" || strings.TrimSpace(body) == "" {
		return nil, ErrInvalidPayload
	}
	if _, reserved := data["aps"]; reserved {
		return nil, ErrReservedPayloadKey
	}

	aps, err := json.Marshal(apsPayload{
		Alert: alertPayload{Title: title, Body: body},
		Sound: "default",
	})
	if err != nil {
		return nil, fmt.Errorf("marshal aps payload: %w", err)
	}

	payload := make(map[string]json.RawMessage, len(data)+1)
	payload["aps"] = aps
	for key, value := range data {
		if key == "aps" {
			return nil, ErrReservedPayloadKey
		}
		if !json.Valid(value) {
			return nil, fmt.Errorf("%w: data value for key %q is not valid JSON", ErrInvalidPayload, key)
		}
		payload[key] = value
	}

	encoded, err := json.Marshal(payload)
	if err != nil {
		return nil, fmt.Errorf("marshal notification payload: %w", err)
	}
	if len(encoded) > MaxPayloadBytes {
		return nil, ErrPayloadTooLarge
	}
	return encoded, nil
}

// Result reports Apple's accepted status. A 2xx response means APNs accepted
// the notification for delivery; it is not proof that a phone displayed it.
type Result struct {
	Status int
}

// RejectError is a structured, sanitized APNs rejection. It retains Apple's
// HTTP status and reason but never contains the request URL, device token, or
// authorization header.
type RejectError struct {
	Status        int
	Reason        string
	DeviceInvalid bool
}

func (e *RejectError) Error() string {
	if e.Reason == "" {
		return fmt.Sprintf("apns rejected request with status %d", e.Status)
	}
	return fmt.Sprintf("apns rejected request with status %d reason %q", e.Status, e.Reason)
}

// TransportError is a sanitized transport failure. The underlying error is
// intentionally not retained because net/http errors include the full APNs URL,
// which contains the device token.
type TransportError struct {
	Timeout  bool
	Protocol bool
}

func (e *TransportError) Error() string {
	switch {
	case e.Timeout:
		return "apns transport timeout"
	case e.Protocol:
		return "apns response was not HTTP/2"
	default:
		return "apns transport failure"
	}
}

// Client sends notifications with a fixed topic and provider credentials.
type Client struct {
	signer     *tokenSigner
	topic      string
	timeout    time.Duration
	httpClient *http.Client
	endpoints  map[Environment]string
}

// NewClient validates the provider material and prepares an HTTP/2-only APNs
// transport. The caller must own the process configuration; there is no API for
// selecting a custom endpoint.
func NewClient(key *ecdsa.PrivateKey, keyID, teamID, topic string, timeout time.Duration) (*Client, error) {
	if key == nil || key.Curve != elliptic.P256() {
		return nil, fmt.Errorf("APNs client requires a P-256 private key")
	}
	if _, err := key.ECDH(); err != nil {
		return nil, fmt.Errorf("APNs client requires a valid P-256 private key")
	}
	if strings.TrimSpace(keyID) == "" || strings.TrimSpace(teamID) == "" || strings.TrimSpace(topic) == "" {
		return nil, fmt.Errorf("APNs client requires key ID, team ID, and topic")
	}
	if timeout <= 0 {
		return nil, fmt.Errorf("APNs timeout must be positive")
	}

	endpoints := make(map[Environment]string, len(defaultEndpoints))
	for environment, endpoint := range defaultEndpoints {
		endpoints[environment] = endpoint
	}

	return &Client{
		signer:     newTokenSigner(key, keyID, teamID),
		topic:      topic,
		timeout:    timeout,
		httpClient: newHTTPClient(timeout),
		endpoints:  endpoints,
	}, nil
}

func newHTTPClient(timeout time.Duration) *http.Client {
	protocols := new(http.Protocols)
	protocols.SetHTTP1(false)
	protocols.SetHTTP2(true)

	transport := &http.Transport{
		// Do not silently follow ambient proxy configuration for a fixed
		// credential-bearing Apple endpoint.
		Proxy:                 nil,
		ForceAttemptHTTP2:     true,
		Protocols:             protocols,
		TLSClientConfig:       &tls.Config{MinVersion: tls.VersionTLS12},
		DialContext:           (&net.Dialer{Timeout: 5 * time.Second, KeepAlive: 30 * time.Second}).DialContext,
		TLSHandshakeTimeout:   5 * time.Second,
		ResponseHeaderTimeout: timeout,
		IdleConnTimeout:       90 * time.Second,
		MaxIdleConns:          8,
		MaxIdleConnsPerHost:   8,
	}

	return &http.Client{
		Transport: transport,
		Timeout:   timeout,
		CheckRedirect: func(*http.Request, []*http.Request) error {
			// Never replay a bearer token or payload to another location.
			return errors.New("apns redirects are not allowed")
		},
	}
}

// Send posts one notification and makes exactly one application-level attempt.
// It does not retry after an APNs response or a redirect. The HTTP/2 transport
// may transparently retry an HTTP/2 stream when it can prove the stream was not
// processed; this relay does not promise exactly-once delivery either way.
func (c *Client) Send(ctx context.Context, environment Environment, deviceToken string, payload []byte) (Result, error) {
	endpoint, ok := c.endpoints[environment]
	if !ok {
		return Result{}, ErrInvalidEnvironment
	}
	if err := ValidateDeviceToken(deviceToken); err != nil {
		return Result{}, err
	}
	if len(payload) == 0 || len(payload) > MaxPayloadBytes || !json.Valid(payload) {
		if len(payload) > MaxPayloadBytes {
			return Result{}, ErrPayloadTooLarge
		}
		return Result{}, ErrInvalidPayload
	}

	providerToken, err := c.signer.token()
	if err != nil {
		return Result{}, err
	}

	requestCtx, cancel := context.WithTimeout(ctx, c.timeout)
	defer cancel()

	request, err := http.NewRequestWithContext(requestCtx, http.MethodPost, endpoint+"/3/device/"+deviceToken, bytes.NewReader(payload))
	if err != nil {
		return Result{}, &TransportError{}
	}
	request.Header.Set("Authorization", "bearer "+providerToken)
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("apns-topic", c.topic)
	request.Header.Set("apns-push-type", "alert")
	request.Header.Set("apns-priority", "10")
	request.Header.Set("apns-expiration", "0")

	response, err := c.httpClient.Do(request)
	if err != nil {
		return Result{}, classifyTransportError(err)
	}
	defer response.Body.Close()

	if response.ProtoMajor != 2 {
		return Result{}, &TransportError{Protocol: true}
	}

	body, _ := io.ReadAll(io.LimitReader(response.Body, maxAPNSErrorBodyBytes))
	if response.StatusCode >= 200 && response.StatusCode < 300 {
		return Result{Status: response.StatusCode}, nil
	}

	reason := parseAPNSReason(body)
	return Result{}, &RejectError{
		Status:        response.StatusCode,
		Reason:        reason,
		DeviceInvalid: isDeviceInvalidReason(reason),
	}
}

func classifyTransportError(err error) *TransportError {
	var netErr net.Error
	if errors.Is(err, context.DeadlineExceeded) || (errors.As(err, &netErr) && netErr.Timeout()) {
		return &TransportError{Timeout: true}
	}
	return &TransportError{}
}

func parseAPNSReason(body []byte) string {
	var response struct {
		Reason string `json:"reason"`
	}
	if err := json.Unmarshal(body, &response); err != nil {
		return ""
	}
	reason := strings.TrimSpace(response.Reason)
	if len(reason) == 0 || len(reason) > 64 {
		return ""
	}
	for i := 0; i < len(reason); i++ {
		c := reason[i]
		if (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-' {
			continue
		}
		return ""
	}
	return reason
}

func isDeviceInvalidReason(reason string) bool {
	switch reason {
	case "BadDeviceToken", "DeviceTokenNotForTopic", "Unregistered", "ExpiredToken":
		return true
	default:
		return false
	}
}

// CloseIdleConnections releases pooled APNs connections during shutdown.
func (c *Client) CloseIdleConnections() {
	c.httpClient.CloseIdleConnections()
}
