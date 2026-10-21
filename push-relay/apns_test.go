package main

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

type capturedAPNs struct {
	Proto   string
	Path    string
	Header  http.Header
	Payload []byte
}

// fakeAPNs is an HTTP/2-only TLS server that records requests and verifies
// provider tokens with the expected public key.
type fakeAPNs struct {
	t      *testing.T
	server *httptest.Server
	pub    *ecdsa.PublicKey

	mu       sync.Mutex
	captured []capturedAPNs
	respond  func(w http.ResponseWriter)
}

func newFakeAPNs(t *testing.T, pub *ecdsa.PublicKey) *fakeAPNs {
	f := &fakeAPNs{t: t, pub: pub}
	f.server = httptest.NewUnstartedServer(http.HandlerFunc(f.handle))
	f.server.EnableHTTP2 = true
	f.server.StartTLS()
	t.Cleanup(f.server.Close)
	return f
}

func (f *fakeAPNs) handle(w http.ResponseWriter, r *http.Request) {
	body, _ := io.ReadAll(r.Body)
	f.mu.Lock()
	f.captured = append(f.captured, capturedAPNs{Proto: r.Proto, Path: r.URL.Path, Header: r.Header.Clone(), Payload: body})
	respond := f.respond
	f.mu.Unlock()

	if !f.validProviderToken(r.Header.Get("Authorization")) {
		w.WriteHeader(http.StatusForbidden)
		_, _ = w.Write([]byte(`{"reason":"InvalidProviderToken"}`))
		return
	}
	if respond != nil {
		respond(w)
		return
	}
	w.Header().Set("apns-id", r.Header.Get("apns-id"))
	w.WriteHeader(http.StatusOK)
}

func (f *fakeAPNs) validProviderToken(header string) bool {
	token, ok := strings.CutPrefix(header, "bearer ")
	if !ok {
		return false
	}
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return false
	}
	var hdr struct{ Alg, Kid string }
	var claims struct {
		Iss string `json:"iss"`
		Iat int64  `json:"iat"`
	}
	h, _ := base64.RawURLEncoding.DecodeString(parts[0])
	c, _ := base64.RawURLEncoding.DecodeString(parts[1])
	if json.Unmarshal(h, &hdr) != nil || json.Unmarshal(c, &claims) != nil {
		return false
	}
	if hdr.Alg != "ES256" || hdr.Kid != "KEYID12345" || claims.Iss != "TEAMID1234" || claims.Iat == 0 {
		return false
	}
	sig, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil || len(sig) != 64 {
		return false
	}
	return verifyRawES256(f.pub, []byte(parts[0]+"."+parts[1]), sig)
}

func (f *fakeAPNs) requests() []capturedAPNs {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]capturedAPNs(nil), f.captured...)
}

func newTestAPNsClient(t *testing.T) (*APNsClient, *fakeAPNs) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	fake := newFakeAPNs(t, &key.PublicKey)
	client := NewAPNsClient(APNsConfig{
		KeyID: "KEYID12345", TeamID: "TEAMID1234", Topic: "com.termllm.app", PrivateKey: key,
		ProductionURL: fake.server.URL + "/prod", DevelopmentURL: fake.server.URL + "/dev",
	}, fake.server.Client())
	return client, fake
}

func TestAPNsClientSendsOverHTTP2(t *testing.T) {
	client, fake := newTestAPNsClient(t)
	exp := time.Unix(1_900_000_000, 0)
	res, err := client.Send(context.Background(), APNsRequest{
		Env: EnvDevelopment, DeviceToken: testDeviceToken(), Payload: []byte(`{"aps":{}}`),
		Priority: 5, Expiration: exp, CollapseID: "c1", ID: "11111111-2222-4333-8444-555555555555",
	})
	if err != nil || res.Status != 200 || res.APNsID != "11111111-2222-4333-8444-555555555555" {
		t.Fatalf("send: %+v %v", res, err)
	}
	got := fake.requests()[0]
	if got.Proto != "HTTP/2.0" {
		t.Fatalf("APNs requires HTTP/2, got %s", got.Proto)
	}
	if got.Path != "/dev/3/device/"+hex.EncodeToString(testDeviceToken()) {
		t.Fatalf("path %s", got.Path)
	}
	for name, want := range map[string]string{
		"apns-topic": "com.termllm.app", "apns-push-type": "alert", "apns-priority": "5",
		"apns-expiration": "1900000000", "apns-collapse-id": "c1",
	} {
		if v := got.Header.Get(name); v != want {
			t.Errorf("%s = %q, want %q", name, v, want)
		}
	}

	if _, err := client.Send(context.Background(), APNsRequest{Env: EnvProduction, DeviceToken: testDeviceToken(), Payload: []byte(`{}`), Priority: 10}); err != nil {
		t.Fatal(err)
	}
	reqs := fake.requests()
	if !strings.HasPrefix(reqs[1].Path, "/prod/") || reqs[1].Header.Get("apns-expiration") != "0" {
		t.Fatalf("production request: %+v", reqs[1])
	}
	if reqs[0].Header.Get("Authorization") != reqs[1].Header.Get("Authorization") {
		t.Fatal("provider token should be reused between requests")
	}
}

func TestAPNsClientProviderTokenRefresh(t *testing.T) {
	client, fake := newTestAPNsClient(t)
	now := time.Unix(1_800_000_000, 0)
	client.now = func() time.Time { return now }
	send := func() string {
		if _, err := client.Send(context.Background(), APNsRequest{DeviceToken: testDeviceToken(), Payload: []byte(`{}`), Priority: 10}); err != nil {
			t.Fatal(err)
		}
		reqs := fake.requests()
		return reqs[len(reqs)-1].Header.Get("Authorization")
	}
	first := send()
	now = now.Add(30 * time.Minute)
	if send() != first {
		t.Fatal("token refreshed too early")
	}
	now = now.Add(20 * time.Minute)
	if send() == first {
		t.Fatal("token not refreshed after 45 minutes")
	}
}

func TestAPNsClientReportsReason(t *testing.T) {
	client, fake := newTestAPNsClient(t)
	fake.respond = func(w http.ResponseWriter) {
		w.WriteHeader(http.StatusGone)
		_, _ = w.Write([]byte(`{"reason":"Unregistered","timestamp":1800000000000}`))
	}
	res, err := client.Send(context.Background(), APNsRequest{DeviceToken: testDeviceToken(), Payload: []byte(`{}`), Priority: 10})
	if err != nil || res.Status != http.StatusGone || res.Reason != "Unregistered" {
		t.Fatalf("got %+v %v", res, err)
	}
}

func TestNewUUID(t *testing.T) {
	id := newUUID()
	if len(id) != 36 || id[14] != '4' || !strings.ContainsAny(id[19:20], "89ab") {
		t.Fatalf("not a v4 UUID: %s", id)
	}
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

// Transport failures must not leak the request URL (device token) or headers
// (provider credential), while still exposing whether the failure timed out.
func TestAPNsClientSanitizesTransportErrors(t *testing.T) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tokenHex := hex.EncodeToString(testDeviceToken())
	cfg := APNsConfig{
		KeyID: "KEYID12345", TeamID: "TEAMID1234", Topic: "com.termllm.app", PrivateKey: key,
		ProductionURL: "https://api.push.apple.com", DevelopmentURL: "https://api.push.apple.com",
	}
	cases := []struct {
		name        string
		failure     func(*http.Request) error
		wantTimeout bool
	}{
		{
			name: "timeout",
			failure: func(r *http.Request) error {
				return &url.Error{Op: "Post", URL: r.URL.String(), Err: context.DeadlineExceeded}
			},
			wantTimeout: true,
		},
		{
			name: "cancelled",
			failure: func(r *http.Request) error {
				return &url.Error{Op: "Post", URL: r.URL.String(), Err: context.Canceled}
			},
		},
		{
			name: "dial",
			failure: func(r *http.Request) error {
				return &url.Error{Op: "Post", URL: r.URL.String(), Err: &net.OpError{Op: "dial", Net: "tcp", Err: errors.New("connection refused")}}
			},
		},
		{
			name: "headers",
			failure: func(r *http.Request) error {
				return fmt.Errorf("Post %q Authorization: %s: boom", r.URL.String(), r.Header.Get("Authorization"))
			},
		},
	}
	for _, tc := range cases {
		client := NewAPNsClient(cfg, &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
			return nil, tc.failure(r)
		})})
		_, sendErr := client.Send(context.Background(), APNsRequest{
			Env: EnvProduction, DeviceToken: testDeviceToken(), Payload: []byte(`{}`), Priority: 10,
		})
		if sendErr == nil {
			t.Fatalf("%s: transport failure returned nil", tc.name)
		}
		msg := sendErr.Error()
		for _, secret := range []string{tokenHex, "api.push.apple.com", "Authorization", "bearer", "TEAMID1234"} {
			if strings.Contains(msg, secret) {
				t.Fatalf("%s: error leaked %q: %s", tc.name, secret, msg)
			}
		}
		var timeout interface{ Timeout() bool }
		if !errors.As(sendErr, &timeout) {
			t.Fatalf("%s: timeout classification lost: %T", tc.name, sendErr)
		}
		if timeout.Timeout() != tc.wantTimeout {
			t.Fatalf("%s: Timeout() = %v, want %v", tc.name, timeout.Timeout(), tc.wantTimeout)
		}
	}
}

func TestDefaultAPNsClientHardening(t *testing.T) {
	client := NewAPNsClient(APNsConfig{}, nil)
	transport, ok := client.http.Transport.(*http.Transport)
	if !ok {
		t.Fatalf("default transport %T", client.http.Transport)
	}
	if transport.Proxy != nil {
		t.Fatal("default APNs transport must not use an ambient proxy")
	}
	if !transport.ForceAttemptHTTP2 {
		t.Fatal("default APNs transport must attempt HTTP/2")
	}
	if transport.TLSClientConfig == nil || transport.TLSClientConfig.MinVersion < tls.VersionTLS12 {
		t.Fatal("default APNs transport must require TLS 1.2 or newer")
	}
	if transport.Protocols == nil || !transport.Protocols.HTTP2() || transport.Protocols.HTTP1() {
		t.Fatalf("default APNs transport must allow HTTP/2 only, got %v", transport.Protocols)
	}
	if client.http.CheckRedirect == nil {
		t.Fatal("default APNs client must define a redirect policy")
	}
	req, _ := http.NewRequest(http.MethodPost, "https://api.push.apple.com/3/device/abcd", nil)
	if err := client.http.CheckRedirect(req, nil); !errors.Is(err, http.ErrUseLastResponse) {
		t.Fatalf("redirect policy returned %v", err)
	}
}

// An explicit loopback HTTP override is the only case where HTTP/1.1 is
// permitted, so local end-to-end fakes keep working.
func TestAPNsClientAllowsExplicitLocalHTTP(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("apns-id", r.Header.Get("apns-id"))
		w.WriteHeader(http.StatusOK)
	}))
	t.Cleanup(server.Close)

	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	client := NewAPNsClient(APNsConfig{
		KeyID: "KEYID12345", TeamID: "TEAMID1234", Topic: "com.termllm.app", PrivateKey: key,
		ProductionURL: server.URL, DevelopmentURL: server.URL,
	}, nil)
	transport, ok := client.http.Transport.(*http.Transport)
	if !ok || transport.Protocols == nil || !transport.Protocols.HTTP1() || !transport.Protocols.HTTP2() {
		t.Fatalf("local HTTP override should permit both protocols: %v", client.http.Transport)
	}
	res, err := client.Send(context.Background(), APNsRequest{
		DeviceToken: testDeviceToken(), Payload: []byte(`{}`), Priority: 10,
	})
	if err != nil || res.Status != http.StatusOK {
		t.Fatalf("local HTTP fake: %+v %v", res, err)
	}
}

// HTTPS responses must be HTTP/2. A downgraded response is treated as a
// transport failure rather than an Apple result.
func TestAPNsClientRejectsHTTP1FromHTTPS(t *testing.T) {
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	server.EnableHTTP2 = false
	server.StartTLS()
	t.Cleanup(server.Close)

	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	client := NewAPNsClient(APNsConfig{
		KeyID: "KEYID12345", TeamID: "TEAMID1234", Topic: "com.termllm.app", PrivateKey: key,
		ProductionURL: server.URL, DevelopmentURL: server.URL,
	}, server.Client())
	res, sendErr := client.Send(context.Background(), APNsRequest{
		DeviceToken: testDeviceToken(), Payload: []byte(`{}`), Priority: 10,
	})
	if sendErr == nil || res.Status != 0 {
		t.Fatalf("HTTP/1.1 response accepted: %+v %v", res, sendErr)
	}
	if !strings.Contains(sendErr.Error(), "unexpected HTTP/1.1") {
		t.Fatalf("unexpected error: %v", sendErr)
	}
	if strings.Contains(sendErr.Error(), hex.EncodeToString(testDeviceToken())) {
		t.Fatalf("error leaked device token: %v", sendErr)
	}
}

// A redirect response must be returned to the caller, not followed with the
// device token and provider credential.
func TestAPNsClientDoesNotFollowRedirects(t *testing.T) {
	var probeHit atomic.Bool
	probe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		probeHit.Store(true)
		w.WriteHeader(http.StatusOK)
	}))
	t.Cleanup(probe.Close)

	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	fake := newFakeAPNs(t, &key.PublicKey)
	fake.respond = func(w http.ResponseWriter) {
		w.Header().Set("Location", probe.URL)
		w.WriteHeader(http.StatusFound)
	}
	client := NewAPNsClient(APNsConfig{
		KeyID: "KEYID12345", TeamID: "TEAMID1234", Topic: "com.termllm.app", PrivateKey: key,
		ProductionURL: fake.server.URL + "/prod", DevelopmentURL: fake.server.URL + "/dev",
	}, nil)
	// Trust the fake APNs certificate while keeping the production redirect
	// policy from NewAPNsClient.
	client.http.Transport = fake.server.Client().Transport

	res, err := client.Send(context.Background(), APNsRequest{
		DeviceToken: testDeviceToken(), Payload: []byte(`{}`), Priority: 10,
	})
	if err != nil {
		t.Fatal(err)
	}
	if res.Status != http.StatusFound {
		t.Fatalf("redirect status %d", res.Status)
	}
	if probeHit.Load() {
		t.Fatal("APNs client followed a redirect with credentials")
	}
}

type lockedBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *lockedBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *lockedBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

// Even a sender that returns a URL-bearing error must not cause the server to
// log the device token or provider credential.
func TestServerDoesNotLogTransportSecrets(t *testing.T) {
	var logs lockedBuffer
	logger := slog.New(slog.NewTextHandler(&logs, nil))
	tokenHex := hex.EncodeToString(testDeviceToken())
	sender := &fakeSender{err: fmt.Errorf(
		"Post \"https://api.push.apple.com/3/device/%s\": Authorization: bearer provider-secret", tokenHex)}
	_, ts := startRelayWithLogger(t, nil, sender, logger)
	key := newVAPIDKey(t)
	endpoint := registerOK(t, ts.URL, key, "production")

	if resp := push(t, endpoint, pushOpts{auth: key.header(t, validClaims(ts.URL, time.Now()))}); resp.StatusCode != http.StatusBadGateway {
		t.Fatalf("send failure: %d", resp.StatusCode)
	}
	output := logs.String()
	if output == "" {
		t.Fatal("expected a log entry")
	}
	for _, secret := range []string{tokenHex, "provider-secret", "Authorization", "bearer", "api.push.apple.com"} {
		if strings.Contains(output, secret) {
			t.Fatalf("logs leaked %q: %s", secret, output)
		}
	}
	if !strings.Contains(output, "APNs transport error") {
		t.Fatalf("sanitized error missing from logs: %s", output)
	}
}
