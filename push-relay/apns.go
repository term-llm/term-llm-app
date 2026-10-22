package main

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	apnsMaxPayloadSize = 4096
	// Apple rejects provider tokens older than an hour and throttles refreshes
	// more often than every 20 minutes.
	apnsTokenRefresh = 45 * time.Minute
)

// APNsRequest is a single alert notification.
type APNsRequest struct {
	Env         Environment
	DeviceToken []byte
	Payload     []byte
	Priority    int       // 10 immediate, 5 power-considerate
	Expiration  time.Time // zero: deliver once, do not store
	CollapseID  string
	ID          string // apns-id (UUID)
}

// APNsResult reports Apple's response. Reason is empty on success.
type APNsResult struct {
	Status int
	Reason string
	APNsID string
}

type apnsSender interface {
	Send(ctx context.Context, req APNsRequest) (APNsResult, error)
}

// APNsClient sends notifications over HTTP/2 with token-based authentication.
type APNsClient struct {
	cfg  APNsConfig
	http *http.Client
	now  func() time.Time

	mu        sync.Mutex
	jwt       string
	jwtIssued time.Time
}

func NewAPNsClient(cfg APNsConfig, httpClient *http.Client) *APNsClient {
	if httpClient == nil {
		protocols := new(http.Protocols)
		protocols.SetHTTP2(true)
		// APNs only speaks HTTP/2. The sole exception is an explicit local
		// HTTP override, which exists for end-to-end fakes; in that case
		// HTTP/1.1 is the only usable protocol on a plain TCP connection.
		protocols.SetHTTP1(apnsAllowsPlainHTTP(cfg))
		httpClient = &http.Client{
			Timeout: 15 * time.Second,
			Transport: &http.Transport{
				// APNs requests carry a device token in the URL and a bearer
				// credential in a header. Ignore ambient proxy settings so
				// neither can be forwarded to an unexpected proxy.
				Proxy:               nil,
				Protocols:           protocols,
				ForceAttemptHTTP2:   true,
				TLSClientConfig:     &tls.Config{MinVersion: tls.VersionTLS12},
				TLSHandshakeTimeout: 10 * time.Second,
				IdleConnTimeout:     10 * time.Minute,
				MaxIdleConnsPerHost: 4,
			},
			// Never follow redirects with a credential-bearing request.
			CheckRedirect: func(*http.Request, []*http.Request) error {
				return http.ErrUseLastResponse
			},
		}
	}
	return &APNsClient{cfg: cfg, http: httpClient, now: time.Now}
}

// apnsAllowsPlainHTTP reports whether an operator explicitly pointed either
// APNs URL at a plain-HTTP endpoint. loadConfig restricts such endpoints to
// loopback hosts; the transport itself only uses this to permit HTTP/1.1.
func apnsAllowsPlainHTTP(cfg APNsConfig) bool {
	return strings.HasPrefix(strings.ToLower(cfg.ProductionURL), "http://") ||
		strings.HasPrefix(strings.ToLower(cfg.DevelopmentURL), "http://")
}

// transportError is a sanitized account of a failed APNs HTTP exchange.
// net/http errors embed the full request URL, which contains the device token,
// and may embed request headers. Neither is retained. Timeout reports whether
// the original failure was a timeout so callers can classify it.
type transportError struct {
	kind    string
	timeout bool
}

func (e *transportError) Error() string { return "APNs transport error: " + e.kind }

func (e *transportError) Timeout() bool { return e.timeout }

// sanitizeTransportError removes request URLs, headers and other values that
// would expose the device token or provider credential in logs or responses.
func sanitizeTransportError(err error) error {
	if err == nil {
		return nil
	}
	var sanitized *transportError
	if errors.As(err, &sanitized) {
		return sanitized
	}
	timeout := false
	var netErr net.Error
	if errors.As(err, &netErr) && netErr.Timeout() {
		timeout = true
	}
	if errors.Is(err, context.DeadlineExceeded) {
		timeout = true
	}
	kind := "request failed"
	switch {
	case errors.Is(err, context.Canceled):
		kind = "request canceled"
	case timeout:
		kind = "request timed out"
	default:
		var opErr *net.OpError
		if errors.As(err, &opErr) {
			kind = opErr.Op + " failed"
		}
	}
	return &transportError{kind: kind, timeout: timeout}
}

func (c *APNsClient) providerToken(forceRefresh bool) (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	now := c.now()
	if !forceRefresh && c.jwt != "" && now.Sub(c.jwtIssued) < apnsTokenRefresh {
		return c.jwt, nil
	}
	header, _ := json.Marshal(map[string]string{"alg": "ES256", "kid": c.cfg.KeyID})
	claims, _ := json.Marshal(map[string]any{"iss": c.cfg.TeamID, "iat": now.Unix()})
	signingInput := base64.RawURLEncoding.EncodeToString(header) + "." + base64.RawURLEncoding.EncodeToString(claims)
	sig, err := signES256(c.cfg.PrivateKey, []byte(signingInput))
	if err != nil {
		return "", err
	}
	c.jwt = signingInput + "." + base64.RawURLEncoding.EncodeToString(sig)
	c.jwtIssued = now
	return c.jwt, nil
}

func (c *APNsClient) invalidateProviderToken(token string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	// Only drop the token that failed and only if it is old enough to refresh
	// without tripping TooManyProviderTokenUpdates.
	if c.jwt == token && c.now().Sub(c.jwtIssued) >= 20*time.Minute {
		c.jwt = ""
	}
}

func signES256(key *ecdsa.PrivateKey, data []byte) ([]byte, error) {
	digest := sha256.Sum256(data)
	r, s, err := ecdsa.Sign(rand.Reader, key, digest[:])
	if err != nil {
		return nil, err
	}
	sig := make([]byte, 64)
	r.FillBytes(sig[:32])
	s.FillBytes(sig[32:])
	return sig, nil
}

func (c *APNsClient) Send(ctx context.Context, req APNsRequest) (APNsResult, error) {
	token, err := c.providerToken(false)
	if err != nil {
		return APNsResult{}, fmt.Errorf("sign APNs provider token: %w", err)
	}
	base := c.cfg.ProductionURL
	if req.Env == EnvDevelopment {
		base = c.cfg.DevelopmentURL
	}
	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, base+"/3/device/"+hex.EncodeToString(req.DeviceToken), bytes.NewReader(req.Payload))
	if err != nil {
		return APNsResult{}, sanitizeTransportError(err)
	}
	httpReq.Header.Set("Authorization", "bearer "+token)
	httpReq.Header.Set("Content-Type", "application/json")
	httpReq.Header.Set("apns-topic", c.cfg.Topic)
	httpReq.Header.Set("apns-push-type", "alert")
	httpReq.Header.Set("apns-priority", strconv.Itoa(req.Priority))
	expiration := "0"
	if !req.Expiration.IsZero() {
		expiration = strconv.FormatInt(req.Expiration.Unix(), 10)
	}
	httpReq.Header.Set("apns-expiration", expiration)
	if req.ID != "" {
		httpReq.Header.Set("apns-id", req.ID)
	}
	if req.CollapseID != "" {
		httpReq.Header.Set("apns-collapse-id", req.CollapseID)
	}

	resp, err := c.http.Do(httpReq)
	if err != nil {
		return APNsResult{}, sanitizeTransportError(err)
	}
	defer resp.Body.Close()
	if resp.ProtoMajor != 2 && httpReq.URL.Scheme == "https" {
		return APNsResult{}, &transportError{
			kind: fmt.Sprintf("unexpected HTTP/%d.%d response from APNs", resp.ProtoMajor, resp.ProtoMinor),
		}
	}
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
	result := APNsResult{Status: resp.StatusCode, APNsID: resp.Header.Get("apns-id")}
	if resp.StatusCode != http.StatusOK {
		var errBody struct {
			Reason string `json:"reason"`
		}
		_ = json.Unmarshal(body, &errBody)
		result.Reason = errBody.Reason
		if resp.StatusCode == http.StatusForbidden && (result.Reason == "ExpiredProviderToken" || result.Reason == "InvalidProviderToken") {
			c.invalidateProviderToken(token)
		}
	}
	return result, nil
}

// eventAPNsID is diagnostic identity, not a provider deduplication guarantee.
// Topic must identify one logical event, not a session. Bind it to the verified
// destination so unrelated senders/devices/environments cannot share an ID.
// Without Topic preserve manual legacy semantics: each invocation is distinct.
func eventAPNsID(sub Subscription, topic string) string {
	if topic == "" {
		return newUUID()
	}
	hash := sha256.New()
	hash.Write([]byte("term-llm apns event v1\x00"))
	hash.Write([]byte{byte(sub.Env), byte(len(sub.DeviceToken))})
	hash.Write(sub.DeviceToken)
	hash.Write(sub.VAPIDKeyHash[:])
	hash.Write([]byte(topic))
	b := hash.Sum(nil)[:16]
	b[6] = (b[6] & 0x0f) | 0x80 // UUIDv8: application-defined SHA-256 identity
	b[8] = (b[8] & 0x3f) | 0x80
	return formatUUID(b)
}

func newUUID() string {
	var b [16]byte
	_, _ = rand.Read(b[:])
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return formatUUID(b[:])
}

func formatUUID(b []byte) string {
	h := hex.EncodeToString(b)
	return h[0:8] + "-" + h[8:12] + "-" + h[12:16] + "-" + h[16:20] + "-" + h[20:32]
}
