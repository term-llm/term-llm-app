package main

import (
	"bytes"
	"crypto/ecdh"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	webpush "github.com/SherClockHolmes/webpush-go"
)

// TestWebPushGoEndToEnd drives the relay with webpush-go (the library term-llm
// uses), through the real APNs client to a fake HTTP/2 APNs, then decrypts
// the forwarded payload exactly as the iOS Notification Service Extension
// would.
func TestWebPushGoEndToEnd(t *testing.T) {
	apnsClient, fake := newTestAPNsClient(t)

	ts := httptest.NewUnstartedServer(nil)
	cfg := testConfig("http://" + ts.Listener.Addr().String())
	sealer, err := NewTokenSealer(cfg.TokenKeys)
	if err != nil {
		t.Fatal(err)
	}
	ts.Config.Handler = NewServer(cfg, sealer, apnsClient, slog.New(slog.NewTextHandler(io.Discard, nil))).Handler()
	ts.Start()
	t.Cleanup(ts.Close)

	// term-llm server VAPID keys.
	vapidPrivate, vapidPublic, err := webpush.GenerateVAPIDKeys()
	if err != nil {
		t.Fatal(err)
	}

	// The app: device keys for decryption and a relay registration.
	uaPrivate, err := ecdh.P256().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	authSecret := make([]byte, 16)
	_, _ = rand.Read(authSecret)
	regBody, _ := json.Marshal(map[string]string{
		"device_token":           hex.EncodeToString(testDeviceToken()),
		"environment":            "production",
		"application_server_key": vapidPublic,
	})
	resp, err := http.Post(ts.URL+"/v1/register", "application/json", bytes.NewReader(regBody))
	if err != nil {
		t.Fatal(err)
	}
	var reg struct{ Endpoint string }
	_ = json.NewDecoder(resp.Body).Decode(&reg)
	resp.Body.Close()
	if reg.Endpoint == "" {
		t.Fatalf("register failed: %d", resp.StatusCode)
	}

	sub := &webpush.Subscription{
		Endpoint: reg.Endpoint,
		Keys: webpush.Keys{
			P256dh: base64.RawURLEncoding.EncodeToString(uaPrivate.PublicKey().Bytes()),
			Auth:   base64.RawURLEncoding.EncodeToString(authSecret),
		},
	}
	message := []byte(`{"version":1,"event_id":"completion:resp-1:sub-1","session_id":"s1","outcome":"completed","title":"Response complete","body":"Your term-llm response is ready.","url":"/ui/chat/s1"}`)
	send := func(recordSize uint32) *http.Response {
		t.Helper()
		resp, err := webpush.SendNotification(message, sub, &webpush.Options{
			Subscriber: "admin@example.com", VAPIDPublicKey: vapidPublic, VAPIDPrivateKey: vapidPrivate,
			TTL: 300, Topic: "s1", Urgency: webpush.UrgencyHigh, RecordSize: recordSize,
		})
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		return resp
	}

	// webpush-go's default pads to 4096 bytes, which cannot fit in an APNs
	// payload after base64. The relay must reject it rather than truncate.
	if resp := send(0); resp.StatusCode != http.StatusRequestEntityTooLarge {
		t.Fatalf("default record size: got %d, want 413", resp.StatusCode)
	}
	if n := len(fake.requests()); n != 0 {
		t.Fatalf("oversized message reached APNs (%d requests)", n)
	}

	resp = send(2048)
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("record size 2048: status %d", resp.StatusCode)
	}
	if !strings.HasPrefix(resp.Header.Get("Location"), ts.URL+"/v1/messages/") {
		t.Fatalf("Location %q", resp.Header.Get("Location"))
	}

	reqs := fake.requests()
	if len(reqs) != 1 {
		t.Fatalf("APNs received %d requests", len(reqs))
	}
	got := reqs[0]
	if got.Proto != "HTTP/2.0" || got.Header.Get("apns-collapse-id") != "s1" || got.Header.Get("apns-priority") != "10" {
		t.Fatalf("APNs request: %s %v", got.Proto, got.Header)
	}
	if len(got.Payload) > apnsMaxPayloadSize {
		t.Fatalf("APNs payload is %d bytes", len(got.Payload))
	}
	var apnsPayload struct {
		WebPush struct {
			Body string `json:"body"`
		} `json:"webpush"`
	}
	if err := json.Unmarshal(got.Payload, &apnsPayload); err != nil {
		t.Fatal(err)
	}
	ciphertext, err := base64.StdEncoding.DecodeString(apnsPayload.WebPush.Body)
	if err != nil {
		t.Fatal(err)
	}
	plaintext, err := decryptWebPush(ciphertext, uaPrivate, authSecret)
	if err != nil {
		t.Fatalf("decrypt: %v", err)
	}
	if !bytes.Equal(plaintext, message) {
		t.Fatalf("decrypted %q, want %q", plaintext, message)
	}

	// A different term-llm server cannot use this endpoint.
	otherPrivate, otherPublic, _ := webpush.GenerateVAPIDKeys()
	resp, err = webpush.SendNotification(message, sub, &webpush.Options{
		Subscriber: "admin@example.com", VAPIDPublicKey: otherPublic, VAPIDPrivateKey: otherPrivate, TTL: 60, RecordSize: 2048,
	})
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusForbidden {
		t.Fatalf("foreign server key: status %d, want 403", resp.StatusCode)
	}
}
