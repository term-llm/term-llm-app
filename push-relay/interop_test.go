package main

import (
	"bytes"
	"crypto/ecdh"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

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
	created := time.Now().UTC().Format(time.RFC3339)
	expires := time.Now().UTC().Add(time.Hour).Format(time.RFC3339)
	message, _ := json.Marshal(map[string]any{
		"version": 2, "kind": "completion", "event_id": "completion:turn-1:sub-1", "turn_id": "turn-1",
		"response_id": "resp-final", "window_id": "scene:owner", "store_instance_id": "store-1",
		"session_id": "s1", "attention_seq": 7, "run_epoch": 1, "outcome": "completed", "source": "/ui",
		"title": "Response complete", "body": "Your term-llm response is ready.", "url": "/ui/chat/s1",
		"created_at": created, "expires_at": expires,
	})
	topicHash := sha256.Sum256([]byte("completion:turn-1:sub-1"))
	topic := base64.RawURLEncoding.EncodeToString(topicHash[:])[:32]
	send := func(recordSize uint32) *http.Response {
		t.Helper()
		resp, err := webpush.SendNotification(message, sub, &webpush.Options{
			Subscriber: "admin@example.com", VAPIDPublicKey: vapidPublic, VAPIDPrivateKey: vapidPrivate,
			TTL: 300, Topic: topic, Urgency: webpush.UrgencyHigh, RecordSize: recordSize,
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
	if got.Proto != "HTTP/2.0" || got.Header.Get("apns-collapse-id") != topic || got.Header.Get("apns-priority") != "10" {
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

	// Lost acceptance ACK: retry encrypts with fresh randomness, but keeps the
	// event's diagnostic identity. Both requests reached fake APNs: this does
	// NOT assert provider/device exactly-once delivery.
	retry := send(2048)
	reqs = fake.requests()
	if retry.StatusCode != http.StatusCreated || len(reqs) != 2 ||
		reqs[0].Header.Get("apns-id") == "" || reqs[0].Header.Get("apns-id") != reqs[1].Header.Get("apns-id") ||
		retry.Header.Get("Location") != resp.Header.Get("Location") {
		t.Fatal("retry lost event-scoped diagnostic identity at real APNs HTTP boundary")
	}
	if bytes.Equal(reqs[0].Payload, reqs[1].Payload) {
		t.Fatal("test must re-encrypt the retry")
	}
	message, _ = json.Marshal(map[string]any{"version": 2, "kind": "manual", "event_id": "manual-invocation-2",
		"title": "Custom title", "body": "An explicit message", "url": "/ui/", "created_at": created, "expires_at": expires})
	topicHash = sha256.Sum256([]byte("manual-invocation-2"))
	topic = base64.RawURLEncoding.EncodeToString(topicHash[:])[:32]
	manual := send(2048)
	reqs = fake.requests()
	if manual.StatusCode != http.StatusCreated || len(reqs) != 3 || reqs[2].Header.Get("apns-id") == reqs[0].Header.Get("apns-id") {
		t.Fatal("independent manual event reused completion identity")
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
