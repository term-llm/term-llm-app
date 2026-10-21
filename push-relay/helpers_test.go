package main

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdh"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/hkdf"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http/httptest"
	"sync"
	"testing"
	"time"
)

func testTokenKey(id byte) TokenKey {
	secret := make([]byte, 32)
	for i := range secret {
		secret[i] = id + byte(i)
	}
	return TokenKey{ID: id, Secret: secret}
}

func testDeviceToken() []byte {
	tok := make([]byte, 32)
	for i := range tok {
		tok[i] = byte(0xa0 + i)
	}
	return tok
}

type vapidKey struct {
	priv *ecdsa.PrivateKey
	raw  []byte // uncompressed public key
}

func newVAPIDKey(t *testing.T) vapidKey {
	t.Helper()
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	raw, err := priv.PublicKey.Bytes()
	if err != nil {
		t.Fatal(err)
	}
	return vapidKey{priv: priv, raw: raw}
}

func (k vapidKey) encoded() string { return base64.RawURLEncoding.EncodeToString(k.raw) }

func (k vapidKey) header(t *testing.T, claims map[string]any) string {
	t.Helper()
	return "vapid t=" + k.jwt(t, map[string]any{"typ": "JWT", "alg": "ES256"}, claims) + ", k=" + k.encoded()
}

func (k vapidKey) jwt(t *testing.T, header, claims map[string]any) string {
	t.Helper()
	h, _ := json.Marshal(header)
	c, _ := json.Marshal(claims)
	input := base64.RawURLEncoding.EncodeToString(h) + "." + base64.RawURLEncoding.EncodeToString(c)
	sig, err := signES256(k.priv, []byte(input))
	if err != nil {
		t.Fatal(err)
	}
	return input + "." + base64.RawURLEncoding.EncodeToString(sig)
}

func validClaims(aud string, now time.Time) map[string]any {
	return map[string]any{"aud": aud, "exp": now.Add(12 * time.Hour).Unix(), "sub": "mailto:test@example.com"}
}

// fakeAES128GCMBody is structurally valid Web Push ciphertext (random bytes).
func fakeAES128GCMBody(size int) []byte {
	body := make([]byte, size)
	_, _ = rand.Read(body)
	binary.BigEndian.PutUint32(body[16:20], uint32(size))
	body[20] = 65
	body[21] = 0x04
	return body
}

type fakeSender struct {
	mu       sync.Mutex
	requests []APNsRequest
	result   APNsResult
	err      error
}

func (f *fakeSender) Send(_ context.Context, req APNsRequest) (APNsResult, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.requests = append(f.requests, req)
	if f.err != nil {
		return APNsResult{}, f.err
	}
	r := f.result
	if r.Status == 0 {
		r.Status = 200
	}
	return r, nil
}

func (f *fakeSender) sent() []APNsRequest {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]APNsRequest(nil), f.requests...)
}

func testConfig(publicURL string) Config {
	return Config{
		PublicURL:         publicURL,
		TokenKeys:         []TokenKey{testTokenKey(1)},
		AlertTitle:        "term-llm",
		AlertBody:         "New notification",
		PushBurst:         30,
		PushPerMinute:     20,
		RegisterBurst:     20,
		RegisterPerMinute: 10,
	}
}

// startRelay runs the relay on a loopback listener whose URL is also its
// public origin, matching how webpush-go derives the VAPID audience.
func startRelay(t *testing.T, mutate func(*Config), sender apnsSender) (*Server, *httptest.Server) {
	t.Helper()
	ts := httptest.NewUnstartedServer(nil)
	cfg := testConfig("http://" + ts.Listener.Addr().String())
	if mutate != nil {
		mutate(&cfg)
	}
	sealer, err := NewTokenSealer(cfg.TokenKeys)
	if err != nil {
		t.Fatal(err)
	}
	relay := NewServer(cfg, sealer, sender, slog.New(slog.NewTextHandler(io.Discard, nil)))
	ts.Config.Handler = relay.Handler()
	ts.Start()
	t.Cleanup(ts.Close)
	return relay, ts
}

// decryptWebPush implements RFC 8291 receiving (aes128gcm, single record),
// mirroring what the iOS Notification Service Extension must do.
func decryptWebPush(body []byte, uaPrivate *ecdh.PrivateKey, authSecret []byte) ([]byte, error) {
	if len(body) < aes128gcmHeaderSize {
		return nil, errors.New("short body")
	}
	salt := body[:16]
	idLen := int(body[20])
	asPublicRaw := body[21 : 21+idLen]
	ciphertext := body[21+idLen:]

	asPublic, err := ecdh.P256().NewPublicKey(asPublicRaw)
	if err != nil {
		return nil, err
	}
	shared, err := uaPrivate.ECDH(asPublic)
	if err != nil {
		return nil, err
	}
	keyInfo := "WebPush: info\x00" + string(uaPrivate.PublicKey().Bytes()) + string(asPublicRaw)
	ikm, err := hkdf.Key(sha256.New, shared, authSecret, keyInfo, 32)
	if err != nil {
		return nil, err
	}
	cek, err := hkdf.Key(sha256.New, ikm, salt, "Content-Encoding: aes128gcm\x00", 16)
	if err != nil {
		return nil, err
	}
	nonce, err := hkdf.Key(sha256.New, ikm, salt, "Content-Encoding: nonce\x00", 12)
	if err != nil {
		return nil, err
	}
	block, err := aes.NewCipher(cek)
	if err != nil {
		return nil, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	plain, err := gcm.Open(nil, nonce, ciphertext, nil)
	if err != nil {
		return nil, err
	}
	// Strip padding: trailing zeros, then the 0x02 last-record delimiter.
	i := len(plain) - 1
	for i >= 0 && plain[i] == 0 {
		i--
	}
	if i < 0 || plain[i] != 0x02 {
		return nil, errors.New("missing padding delimiter")
	}
	return plain[:i], nil
}
