package main

import (
	"bytes"
	"crypto/ecdh"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"

	webpush "github.com/SherClockHolmes/webpush-go"
)

// These are unmodified actual-core-producer exports, shared with native XCTest.
// The clock below is the export manifest's consumer clock, NOT time.Now(). No
// payload timestamps are rewritten (the actual manual lifetime is only 60s).
func TestActualProducerFixturesThroughRelay(t *testing.T) {
	root := filepath.Join("..", "TermLLMTests", "ProducerFixtures")
	var manifest struct {
		PublicReviewSHA   string `json:"public_review_sha"`
		ImplementationSHA string `json:"production_implementation_sha"`
		Fixtures          []struct {
			File            string `json:"file"`
			SHA256          string `json:"sha256"`
			Bytes           int    `json:"bytes"`
			Kind            string `json:"kind"`
			Source          string `json:"source"`
			InjectedTestNow string `json:"injected_test_now"`
		} `json:"fixtures"`
	}
	readJSONFixture(t, filepath.Join(root, "manifest.json"), &manifest)
	if manifest.PublicReviewSHA != "600d7199e30375758fefba7a0e57a4ae72f9a923" ||
		manifest.ImplementationSHA != "7f8b8251d0370fe7f475925b50ad7f46a8a697a2" || len(manifest.Fixtures) != 3 {
		t.Fatal("unexpected fixture provenance")
	}

	sender := &fakeSender{result: APNsResult{Status: 200}}
	_, relay := startRelay(t, nil, sender)
	key := newVAPIDKey(t)
	endpoint := registerOK(t, relay.URL, key, "development")
	ua, err := ecdh.P256().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	auth := make([]byte, 16)
	if _, err := rand.Read(auth); err != nil {
		t.Fatal(err)
	}
	sub := &webpush.Subscription{Endpoint: endpoint, Keys: webpush.Keys{
		P256dh: base64.RawURLEncoding.EncodeToString(ua.PublicKey().Bytes()), Auth: base64.RawURLEncoding.EncodeToString(auth),
	}}
	identities := map[string]string{}
	completionPayloads := map[string]map[string]any{}
	for _, entry := range manifest.Fixtures {
		t.Run(entry.File, func(t *testing.T) {
			var payload struct {
				Kind      string    `json:"kind"`
				EventID   string    `json:"event_id"`
				Source    string    `json:"source"`
				CreatedAt time.Time `json:"created_at"`
				ExpiresAt time.Time `json:"expires_at"`
			}
			raw := readJSONFixture(t, filepath.Join(root, entry.File), &payload)
			hash := sha256.Sum256(raw)
			if len(raw) != entry.Bytes || hex.EncodeToString(hash[:]) != entry.SHA256 || payload.Kind != entry.Kind || payload.Source != entry.Source {
				t.Fatal("fixture bytes/metadata differ from exported manifest")
			}
			now, err := time.Parse(time.RFC3339Nano, entry.InjectedTestNow)
			if err != nil || !now.After(payload.CreatedAt) || !now.Before(payload.ExpiresAt) {
				t.Fatal("manifest clock must be between actual producer creation and expiry")
			}
			lifetime := 24 * time.Hour
			if entry.Kind == "manual" {
				lifetime = time.Minute
			}
			if payload.ExpiresAt.Sub(payload.CreatedAt) != lifetime {
				t.Fatalf("actual producer lifetime changed: %s", payload.ExpiresAt.Sub(payload.CreatedAt))
			}
			topicHash := sha256.Sum256([]byte(payload.EventID))
			response, err := webpush.SendNotification(raw, sub, &webpush.Options{
				VAPIDPublicKey: key.encoded(), VAPIDPrivateKey: base64.RawURLEncoding.EncodeToString(key.priv.D.FillBytes(make([]byte, 32))),
				Subscriber: "fixture@example.com", TTL: int(payload.ExpiresAt.Sub(now) / time.Second),
				Topic: base64.RawURLEncoding.EncodeToString(topicHash[:])[:32], RecordSize: 2048,
			})
			if err != nil {
				t.Fatal(err)
			}
			response.Body.Close()
			if response.StatusCode != 201 {
				t.Fatalf("fake APNs relay response: %d", response.StatusCode)
			}
			sent := sender.sent()
			request := sent[len(sent)-1]
			var envelope struct {
				WebPush struct{ Body string } `json:"webpush"`
			}
			if err := json.Unmarshal(request.Payload, &envelope); err != nil {
				t.Fatal(err)
			}
			ciphertext, err := base64.StdEncoding.DecodeString(envelope.WebPush.Body)
			if err != nil {
				t.Fatal(err)
			}
			plaintext, err := decryptWebPush(ciphertext, ua, auth)
			if err != nil || !bytes.Equal(plaintext, raw) {
				t.Fatal("actual producer export changed across encryption/relay/fake APNs")
			}
			if previous := identities[payload.EventID]; previous != "" && previous != request.ID {
				t.Fatal("compact producer retry changed APNs diagnostic event identity")
			}
			identities[payload.EventID] = request.ID
			if payload.Kind == "completion" {
				var object map[string]any
				if err := json.Unmarshal(plaintext, &object); err != nil {
					t.Fatal(err)
				}
				delete(object, "title")
				completionPayloads[entry.File] = object
			}
		})
	}
	if len(identities) != 2 || len(completionPayloads) != 2 ||
		!reflect.DeepEqual(completionPayloads["completion.json"], completionPayloads["completion-compact.json"]) {
		t.Fatal("expected two independent events, primary/compact completion identical except display title")
	}
}

func readJSONFixture(t *testing.T, path string, destination any) []byte {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(raw, destination); err != nil {
		t.Fatal(err)
	}
	return raw
}
