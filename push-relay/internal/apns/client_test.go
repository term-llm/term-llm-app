package apns

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

const testTopic = "com.example.app"

func TestSendHTTP2HeadersPayloadAndJWT(t *testing.T) {
	key := generateTestKey(t)
	client, err := NewClient(key, "KEYID12345", "TEAMID1234", testTopic, 2*time.Second)
	if err != nil {
		t.Fatalf("NewClient: %v", err)
	}

	deviceToken := strings.Repeat("a1", 36) // 72 hex chars: deliberately not 64
	payload, err := BuildPayload("Build finished", "Your task is ready.", map[string]json.RawMessage{
		"conversation_id": json.RawMessage(`"abc123"`),
		"unread":          json.RawMessage(`3`),
	})
	if err != nil {
		t.Fatalf("BuildPayload: %v", err)
	}

	type captured struct {
		proto   int
		method  string
		path    string
		rawPath string
		query   string
		headers http.Header
		body    []byte
	}
	requests := make(chan captured, 1)
	server := newH2Server(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		requests <- captured{
			proto:   r.ProtoMajor,
			method:  r.Method,
			path:    r.URL.Path,
			rawPath: r.URL.RawPath,
			query:   r.URL.RawQuery,
			headers: r.Header.Clone(),
			body:    body,
		}
		w.WriteHeader(http.StatusOK)
	}))
	configureClient(t, client, server, true)

	result, err := client.Send(context.Background(), Sandbox, deviceToken, payload)
	if err != nil {
		t.Fatalf("Send: %v", err)
	}
	if result.Status != http.StatusOK {
		t.Fatalf("status = %d, want 200", result.Status)
	}

	request := <-requests
	if request.proto != 2 {
		t.Fatalf("request used HTTP/%d, want HTTP/2", request.proto)
	}
	if request.method != http.MethodPost {
		t.Fatalf("method = %s, want POST", request.method)
	}
	if request.path != "/3/device/"+deviceToken || request.rawPath != "" || request.query != "" {
		t.Fatalf("unexpected request path: %q raw=%q query=%q", request.path, request.rawPath, request.query)
	}
	if got := request.headers.Get("apns-topic"); got != testTopic {
		t.Fatalf("apns-topic = %q", got)
	}
	if got := request.headers.Get("apns-push-type"); got != "alert" {
		t.Fatalf("apns-push-type = %q", got)
	}
	if got := request.headers.Get("apns-priority"); got != "10" {
		t.Fatalf("apns-priority = %q", got)
	}
	if got := request.headers.Get("apns-expiration"); got != "0" {
		t.Fatalf("apns-expiration = %q", got)
	}
	if got := request.headers.Get("Content-Type"); got != "application/json" {
		t.Fatalf("Content-Type = %q", got)
	}

	scheme, providerToken, ok := strings.Cut(request.headers.Get("Authorization"), " ")
	if !ok || !strings.EqualFold(scheme, "bearer") {
		t.Fatalf("unexpected Authorization scheme")
	}
	verifyProviderToken(t, providerToken, key, "KEYID12345", "TEAMID1234")

	var decoded map[string]json.RawMessage
	if err := json.Unmarshal(request.body, &decoded); err != nil {
		t.Fatalf("payload is not JSON: %v", err)
	}
	var aps struct {
		Alert struct {
			Title string `json:"title"`
			Body  string `json:"body"`
		} `json:"alert"`
		Sound string `json:"sound"`
	}
	if err := json.Unmarshal(decoded["aps"], &aps); err != nil {
		t.Fatalf("decode aps: %v", err)
	}
	if aps.Alert.Title != "Build finished" || aps.Alert.Body != "Your task is ready." || aps.Sound != "default" {
		t.Fatalf("unexpected aps payload: %+v", aps)
	}
	if string(decoded["conversation_id"]) != `"abc123"` || string(decoded["unread"]) != "3" {
		t.Fatalf("custom data was not preserved: %s", request.body)
	}
}

func TestDefaultEndpointsAreFixedAppleHosts(t *testing.T) {
	client, err := NewClient(generateTestKey(t), "KEYID12345", "TEAMID1234", testTopic, time.Second)
	if err != nil {
		t.Fatalf("NewClient: %v", err)
	}
	if got := client.endpoints[Sandbox]; got != "https://api.sandbox.push.apple.com" {
		t.Fatalf("sandbox endpoint = %q", got)
	}
	if got := client.endpoints[Production]; got != "https://api.push.apple.com" {
		t.Fatalf("production endpoint = %q", got)
	}
}

func TestSendSelectsRequestedEnvironment(t *testing.T) {
	var sandboxHits atomic.Int32
	var productionHits atomic.Int32
	sandboxServer := newH2Server(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		sandboxHits.Add(1)
		w.WriteHeader(http.StatusOK)
	}))
	productionServer := newH2Server(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		productionHits.Add(1)
		w.WriteHeader(http.StatusOK)
	}))

	client, _ := NewClient(generateTestKey(t), "KEYID12345", "TEAMID1234", testTopic, 2*time.Second)
	pool := x509.NewCertPool()
	pool.AddCert(sandboxServer.Certificate())
	pool.AddCert(productionServer.Certificate())
	protocols := new(http.Protocols)
	protocols.SetHTTP2(true)
	protocols.SetHTTP1(false)
	client.httpClient = &http.Client{
		Transport: &http.Transport{
			TLSClientConfig:   &tls.Config{RootCAs: pool, MinVersion: tls.VersionTLS12},
			ForceAttemptHTTP2: true,
			Protocols:         protocols,
		},
		Timeout: 2 * time.Second,
	}
	client.endpoints[Sandbox] = sandboxServer.URL
	client.endpoints[Production] = productionServer.URL

	payload, _ := BuildPayload("title", "body", nil)
	token := strings.Repeat("ab", 32)
	if _, err := client.Send(context.Background(), Production, token, payload); err != nil {
		t.Fatalf("Send production: %v", err)
	}
	if productionHits.Load() != 1 || sandboxHits.Load() != 0 {
		t.Fatalf("production hits=%d sandbox hits=%d", productionHits.Load(), sandboxHits.Load())
	}
	if _, err := client.Send(context.Background(), Sandbox, token, payload); err != nil {
		t.Fatalf("Send sandbox: %v", err)
	}
	if productionHits.Load() != 1 || sandboxHits.Load() != 1 {
		t.Fatalf("production hits=%d sandbox hits=%d", productionHits.Load(), sandboxHits.Load())
	}
}

func TestSendAPNSRejectionIsStructuredAndSanitized(t *testing.T) {
	client, _ := NewClient(generateTestKey(t), "KEYID12345", "TEAMID1234", testTopic, 2*time.Second)
	server := newH2Server(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		_, _ = io.WriteString(w, `{"reason":"BadDeviceToken"}`)
	}))
	configureClient(t, client, server, true)

	token := strings.Repeat("ab", 32)
	payload, _ := BuildPayload("title", "body", nil)
	_, err := client.Send(context.Background(), Sandbox, token, payload)
	var rejection *RejectError
	if !errors.As(err, &rejection) {
		t.Fatalf("error = %v, want RejectError", err)
	}
	if rejection.Status != http.StatusBadRequest || rejection.Reason != "BadDeviceToken" || !rejection.DeviceInvalid {
		t.Fatalf("unexpected rejection: %+v", rejection)
	}
	if strings.Contains(err.Error(), token) || strings.Contains(err.Error(), server.URL) || strings.Contains(err.Error(), "http") {
		t.Fatalf("rejection leaked transport details: %v", err)
	}
}

func TestSendDoesNotRetryAPNSErrors(t *testing.T) {
	var attempts atomic.Int32
	client, _ := NewClient(generateTestKey(t), "KEYID12345", "TEAMID1234", testTopic, 2*time.Second)
	server := newH2Server(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		attempts.Add(1)
		w.WriteHeader(http.StatusServiceUnavailable)
		_, _ = io.WriteString(w, `{"reason":"ServiceUnavailable"}`)
	}))
	configureClient(t, client, server, true)

	payload, _ := BuildPayload("title", "body", nil)
	_, err := client.Send(context.Background(), Sandbox, strings.Repeat("ab", 32), payload)
	var rejection *RejectError
	if !errors.As(err, &rejection) {
		t.Fatalf("error = %v, want RejectError", err)
	}
	if rejection.DeviceInvalid {
		t.Fatal("ServiceUnavailable must not mark the device invalid")
	}
	if attempts.Load() != 1 {
		t.Fatalf("APNs attempts = %d, want exactly 1", attempts.Load())
	}
}

func TestSendTimeoutDoesNotRetry(t *testing.T) {
	var attempts atomic.Int32
	client, _ := NewClient(generateTestKey(t), "KEYID12345", "TEAMID1234", testTopic, 100*time.Millisecond)
	server := newH2Server(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		attempts.Add(1)
		<-r.Context().Done()
	}))
	configureClient(t, client, server, true)
	client.httpClient.Timeout = 100 * time.Millisecond

	payload, _ := BuildPayload("title", "body", nil)
	_, err := client.Send(context.Background(), Sandbox, strings.Repeat("ab", 32), payload)
	var transport *TransportError
	if !errors.As(err, &transport) || !transport.Timeout {
		t.Fatalf("error = %v, want timeout TransportError", err)
	}
	if attempts.Load() != 1 {
		t.Fatalf("APNs attempts = %d, want exactly 1", attempts.Load())
	}
}

func TestSendRejectsNonHTTP2Response(t *testing.T) {
	var attempts atomic.Int32
	client, _ := NewClient(generateTestKey(t), "KEYID12345", "TEAMID1234", testTopic, 2*time.Second)
	server := newH1Server(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		attempts.Add(1)
		w.WriteHeader(http.StatusOK)
	}))
	configureClient(t, client, server, false)

	payload, _ := BuildPayload("title", "body", nil)
	_, err := client.Send(context.Background(), Sandbox, strings.Repeat("ab", 32), payload)
	var transport *TransportError
	if !errors.As(err, &transport) || !transport.Protocol {
		t.Fatalf("error = %v, want protocol TransportError", err)
	}
	if attempts.Load() != 1 {
		t.Fatalf("APNs attempts = %d, want exactly 1", attempts.Load())
	}
}

func TestSendRejectsInvalidInputsWithoutNetwork(t *testing.T) {
	var attempts atomic.Int32
	client, _ := NewClient(generateTestKey(t), "KEYID12345", "TEAMID1234", testTopic, 2*time.Second)
	server := newH2Server(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		attempts.Add(1)
		w.WriteHeader(http.StatusOK)
	}))
	configureClient(t, client, server, true)

	goodToken := strings.Repeat("ab", 32)
	goodPayload, _ := BuildPayload("title", "body", nil)
	oversized := []byte(`{"aps":{"alert":{"title":"a"}},"big":"` + strings.Repeat("a", MaxPayloadBytes) + `"}`)

	cases := []struct {
		name        string
		environment Environment
		token       string
		payload     []byte
		want        error
	}{
		{"environment", "staging", goodToken, goodPayload, ErrInvalidEnvironment},
		{"device token", Sandbox, "not-hex", goodPayload, ErrInvalidDeviceToken},
		{"empty payload", Sandbox, goodToken, nil, ErrInvalidPayload},
		{"oversized payload", Sandbox, goodToken, oversized, ErrPayloadTooLarge},
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			if _, err := client.Send(context.Background(), testCase.environment, testCase.token, testCase.payload); !errors.Is(err, testCase.want) {
				t.Fatalf("error = %v, want %v", err, testCase.want)
			}
		})
	}
	if attempts.Load() != 0 {
		t.Fatalf("APNs attempts = %d, want 0", attempts.Load())
	}
}

func TestValidateDeviceTokenAllowsVariableEvenLength(t *testing.T) {
	valid := []string{
		strings.Repeat("ab", 16),  // 32
		strings.Repeat("ab", 32),  // 64, canonical
		strings.Repeat("ab", 36),  // 72, variable
		strings.Repeat("AB", 256), // 512, upper bound
	}
	for _, token := range valid {
		if err := ValidateDeviceToken(token); err != nil {
			t.Fatalf("ValidateDeviceToken(%d chars) = %v", len(token), err)
		}
	}
	invalid := []string{
		"",
		strings.Repeat("a", 31),
		strings.Repeat("a", 33),
		strings.Repeat("a", 514),
		strings.Repeat("zz", 32),
		"../../etc/passwd",
		strings.Repeat("ab", 32) + "\n",
	}
	for _, token := range invalid {
		if err := ValidateDeviceToken(token); err == nil {
			t.Fatalf("ValidateDeviceToken(%q) accepted invalid token", token)
		}
	}
}

func TestBuildPayload(t *testing.T) {
	payload, err := BuildPayload("Hello <world>", "Line one\nLine two", map[string]json.RawMessage{
		"nested": json.RawMessage(`{"ok":true}`),
	})
	if err != nil {
		t.Fatalf("BuildPayload: %v", err)
	}
	if len(payload) > MaxPayloadBytes {
		t.Fatalf("payload is %d bytes", len(payload))
	}
	var decoded map[string]json.RawMessage
	if err := json.Unmarshal(payload, &decoded); err != nil {
		t.Fatalf("decode payload: %v", err)
	}
	var aps apsPayload
	if err := json.Unmarshal(decoded["aps"], &aps); err != nil {
		t.Fatalf("decode aps: %v", err)
	}
	if aps.Alert.Title != "Hello <world>" || aps.Alert.Body != "Line one\nLine two" || aps.Sound != "default" {
		t.Fatalf("unexpected aps: %+v", aps)
	}
	if string(decoded["nested"]) != `{"ok":true}` {
		t.Fatalf("nested data changed: %s", decoded["nested"])
	}
}

func TestBuildPayloadRejectsUnsafeInput(t *testing.T) {
	if _, err := BuildPayload("title", "body", map[string]json.RawMessage{"aps": json.RawMessage(`{"sound":"none"}`)}); !errors.Is(err, ErrReservedPayloadKey) {
		t.Fatalf("aps override error = %v", err)
	}
	if _, err := BuildPayload("title", "body", map[string]json.RawMessage{"bad": json.RawMessage(`{`)}); !errors.Is(err, ErrInvalidPayload) {
		t.Fatalf("invalid raw JSON error = %v", err)
	}
	if _, err := BuildPayload("", "body", nil); !errors.Is(err, ErrInvalidPayload) {
		t.Fatalf("empty title error = %v", err)
	}
	if _, err := BuildPayload("title", "   ", nil); !errors.Is(err, ErrInvalidPayload) {
		t.Fatalf("empty body error = %v", err)
	}
	if _, err := BuildPayload(string([]byte{0xff}), "body", nil); !errors.Is(err, ErrInvalidPayload) {
		t.Fatalf("invalid UTF-8 title error = %v", err)
	}
	if _, err := BuildPayload("title", strings.Repeat("a", MaxPayloadBytes+1), nil); !errors.Is(err, ErrPayloadTooLarge) {
		t.Fatalf("oversize error = %v", err)
	}
}

func TestNewClientValidation(t *testing.T) {
	key := generateTestKey(t)
	if _, err := NewClient(nil, "KEYID12345", "TEAMID1234", testTopic, time.Second); err == nil {
		t.Fatal("NewClient accepted nil key")
	}
	if _, err := NewClient(key, "", "TEAMID1234", testTopic, time.Second); err == nil {
		t.Fatal("NewClient accepted empty key ID")
	}
	if _, err := NewClient(key, "KEYID12345", "", testTopic, time.Second); err == nil {
		t.Fatal("NewClient accepted empty team ID")
	}
	if _, err := NewClient(key, "KEYID12345", "TEAMID1234", "", time.Second); err == nil {
		t.Fatal("NewClient accepted empty topic")
	}
	if _, err := NewClient(key, "KEYID12345", "TEAMID1234", testTopic, 0); err == nil {
		t.Fatal("NewClient accepted zero timeout")
	}
}

func TestProductionTransportIsHTTP2Only(t *testing.T) {
	client, err := NewClient(generateTestKey(t), "KEYID12345", "TEAMID1234", testTopic, time.Second)
	if err != nil {
		t.Fatalf("NewClient: %v", err)
	}
	transport, ok := client.httpClient.Transport.(*http.Transport)
	if !ok {
		t.Fatalf("transport type = %T", client.httpClient.Transport)
	}
	if transport.Protocols == nil || transport.Protocols.HTTP1() || !transport.Protocols.HTTP2() {
		t.Fatal("production transport must allow HTTP/2 and not HTTP/1")
	}
	if !transport.ForceAttemptHTTP2 {
		t.Fatal("production transport must force HTTP/2")
	}
	if transport.Proxy != nil {
		t.Fatal("production transport must not use an ambient proxy")
	}
	if transport.TLSClientConfig == nil || transport.TLSClientConfig.MinVersion != tls.VersionTLS12 {
		t.Fatal("production transport must require TLS 1.2 or newer")
	}
}

func newH2Server(t *testing.T, handler http.Handler) *httptest.Server {
	t.Helper()
	server := httptest.NewUnstartedServer(handler)
	server.EnableHTTP2 = true
	server.StartTLS()
	t.Cleanup(server.Close)
	return server
}

func newH1Server(t *testing.T, handler http.Handler) *httptest.Server {
	t.Helper()
	server := httptest.NewUnstartedServer(handler)
	server.EnableHTTP2 = false
	server.StartTLS()
	t.Cleanup(server.Close)
	return server
}

func configureClient(t *testing.T, client *Client, server *httptest.Server, http2 bool) {
	t.Helper()
	pool := x509.NewCertPool()
	pool.AddCert(server.Certificate())

	protocols := new(http.Protocols)
	if http2 {
		protocols.SetHTTP2(true)
		protocols.SetHTTP1(false)
	} else {
		protocols.SetHTTP1(true)
		protocols.SetHTTP2(false)
	}
	transport := &http.Transport{
		TLSClientConfig:   &tls.Config{RootCAs: pool, MinVersion: tls.VersionTLS12},
		ForceAttemptHTTP2: http2,
		Protocols:         protocols,
	}
	client.httpClient = &http.Client{Transport: transport, Timeout: 2 * time.Second}
	client.endpoints[Sandbox] = server.URL
	client.endpoints[Production] = server.URL
}
