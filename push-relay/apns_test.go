package main

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
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
