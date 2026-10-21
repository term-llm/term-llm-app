package main

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net/http"
	"sync"
	"testing"
	"time"
)

// sendPush is push without t.Fatal so it can be used from goroutines.
func sendPush(ctx context.Context, endpoint, auth string) (*http.Response, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(fakeAES128GCMBody(512)))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", auth)
	req.Header.Set("Content-Encoding", "aes128gcm")
	req.Header.Set("TTL", "300")
	return http.DefaultClient.Do(req)
}

func waitForFreeSlot(t *testing.T, relay *Server) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for len(relay.slots) != 0 {
		if time.Now().After(deadline) {
			t.Fatalf("send slot was not released (%d still held)", len(relay.slots))
		}
		time.Sleep(time.Millisecond)
	}
}

// Anonymous registration accepts any invented device token, so per-device
// limits alone can be bypassed. The process-wide bucket must still bound APNs
// egress.
func TestGlobalPushBudgetCannotBeBypassedByInventedDevices(t *testing.T) {
	sender := &fakeSender{}
	_, ts := startRelay(t, func(c *Config) {
		c.RegisterBurst = 1000
		c.RegisterPerMinute = 1000
		c.PushBurst = 1000
		c.PushPerMinute = 1000
		c.GlobalPushBurst = 3
		c.GlobalPushPerMinute = 1
		c.MaxConcurrency = 8
	}, sender)
	key := newVAPIDKey(t)
	auth := key.header(t, validClaims(ts.URL, time.Now()))

	accepted := 0
	for i := range 12 {
		endpoint := registerTokenOK(t, ts.URL, key, "production", deviceTokenVariant(byte(i+1)))
		resp := push(t, endpoint, pushOpts{auth: auth})
		switch resp.StatusCode {
		case http.StatusCreated:
			accepted++
		case http.StatusTooManyRequests:
			if resp.Header.Get("Retry-After") == "" {
				t.Fatal("global budget denial is missing Retry-After")
			}
		default:
			t.Fatalf("push %d: %d", i, resp.StatusCode)
		}
	}
	if accepted != 3 {
		t.Fatalf("accepted %d pushes, want global burst 3", accepted)
	}
	if n := len(sender.sent()); n != 3 {
		t.Fatalf("APNs received %d sends, want 3", n)
	}
}

type gatedSender struct {
	mu      sync.Mutex
	calls   int
	started chan APNsRequest
	release chan struct{}
}

func newGatedSender() *gatedSender {
	return &gatedSender{started: make(chan APNsRequest, 32), release: make(chan struct{})}
}

func (g *gatedSender) Send(ctx context.Context, req APNsRequest) (APNsResult, error) {
	g.mu.Lock()
	g.calls++
	g.mu.Unlock()
	g.started <- req
	select {
	case <-g.release:
		return APNsResult{Status: http.StatusOK}, nil
	case <-ctx.Done():
		return APNsResult{}, ctx.Err()
	}
}

func (g *gatedSender) count() int {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.calls
}

// A request that cannot get a send slot must return 503 immediately and must
// not consume the process-wide budget. Once the in-flight send finishes, the
// budget still has the token it saved.
func TestConcurrencyCapDoesNotBurnGlobalBudget(t *testing.T) {
	sender := newGatedSender()
	relay, ts := startRelay(t, func(c *Config) {
		c.PushBurst = 100
		c.PushPerMinute = 100
		c.GlobalPushBurst = 2
		c.GlobalPushPerMinute = 1
		c.MaxConcurrency = 1
	}, sender)
	key := newVAPIDKey(t)
	auth := key.header(t, validClaims(ts.URL, time.Now()))
	endpoint := registerOK(t, ts.URL, key, "production")

	firstDone := make(chan *http.Response, 1)
	go func() {
		resp, err := sendPush(context.Background(), endpoint, auth)
		if err != nil {
			firstDone <- nil
			return
		}
		firstDone <- resp
	}()
	select {
	case <-sender.started:
	case <-time.After(3 * time.Second):
		t.Fatal("first push never reached the sender")
	}

	denied, err := sendPush(context.Background(), endpoint, auth)
	if err != nil {
		t.Fatal(err)
	}
	denied.Body.Close()
	if denied.StatusCode != http.StatusServiceUnavailable || denied.Header.Get("Retry-After") == "" {
		t.Fatalf("capacity denial: status %d, Retry-After %q", denied.StatusCode, denied.Header.Get("Retry-After"))
	}

	close(sender.release)
	first := <-firstDone
	if first == nil {
		t.Fatal("first push failed")
	}
	first.Body.Close()
	if first.StatusCode != http.StatusCreated {
		t.Fatalf("first push: %d", first.StatusCode)
	}
	waitForFreeSlot(t, relay)

	resp := push(t, endpoint, pushOpts{auth: auth})
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("saved global token not available after capacity denial: %d", resp.StatusCode)
	}
	resp = push(t, endpoint, pushOpts{auth: auth})
	if resp.StatusCode != http.StatusTooManyRequests || resp.Header.Get("Retry-After") == "" {
		t.Fatalf("expected global 429 with Retry-After, got %d %q", resp.StatusCode, resp.Header.Get("Retry-After"))
	}
	if n := sender.count(); n != 2 {
		t.Fatalf("sender saw %d pushes, want 2", n)
	}
}

type mutableSender struct {
	mu    sync.Mutex
	err   error
	calls int
}

func (s *mutableSender) Send(context.Context, APNsRequest) (APNsResult, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.calls++
	if s.err != nil {
		return APNsResult{}, s.err
	}
	return APNsResult{Status: http.StatusOK}, nil
}

func (s *mutableSender) setErr(err error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.err = err
}

// A failed send must not leak its concurrency slot.
func TestSendSlotReleasedAfterFailure(t *testing.T) {
	sender := &mutableSender{err: errors.New("upstream failed")}
	relay, ts := startRelay(t, func(c *Config) {
		c.PushBurst = 100
		c.PushPerMinute = 100
		c.GlobalPushBurst = 10
		c.GlobalPushPerMinute = 10
		c.MaxConcurrency = 1
	}, sender)
	key := newVAPIDKey(t)
	auth := key.header(t, validClaims(ts.URL, time.Now()))
	endpoint := registerOK(t, ts.URL, key, "production")

	if resp := push(t, endpoint, pushOpts{auth: auth}); resp.StatusCode != http.StatusBadGateway {
		t.Fatalf("failed send: %d", resp.StatusCode)
	}
	waitForFreeSlot(t, relay)
	sender.setErr(nil)
	if resp := push(t, endpoint, pushOpts{auth: auth}); resp.StatusCode != http.StatusCreated {
		t.Fatalf("slot leaked after send error: %d", resp.StatusCode)
	}
}

type cancelProbeSender struct {
	mu      sync.Mutex
	calls   int
	entered chan struct{}
	once    sync.Once
}

func (s *cancelProbeSender) Send(ctx context.Context, _ APNsRequest) (APNsResult, error) {
	s.mu.Lock()
	n := s.calls
	s.calls++
	s.mu.Unlock()
	if n == 0 {
		s.once.Do(func() { close(s.entered) })
		<-ctx.Done()
		return APNsResult{}, ctx.Err()
	}
	return APNsResult{Status: http.StatusOK}, nil
}

// A cancelled request must not leak its concurrency slot.
func TestSendSlotReleasedAfterCancellation(t *testing.T) {
	sender := &cancelProbeSender{entered: make(chan struct{})}
	relay, ts := startRelay(t, func(c *Config) {
		c.PushBurst = 100
		c.PushPerMinute = 100
		c.GlobalPushBurst = 10
		c.GlobalPushPerMinute = 10
		c.MaxConcurrency = 1
	}, sender)
	key := newVAPIDKey(t)
	auth := key.header(t, validClaims(ts.URL, time.Now()))
	endpoint := registerOK(t, ts.URL, key, "production")

	ctx, cancel := context.WithCancel(context.Background())
	requestDone := make(chan struct{})
	go func() {
		resp, err := sendPush(ctx, endpoint, auth)
		if err == nil {
			_, _ = io.Copy(io.Discard, resp.Body)
			resp.Body.Close()
		}
		close(requestDone)
	}()
	select {
	case <-sender.entered:
	case <-time.After(3 * time.Second):
		t.Fatal("push never reached the sender")
	}
	cancel()
	select {
	case <-requestDone:
	case <-time.After(3 * time.Second):
		t.Fatal("cancelled request did not finish")
	}
	waitForFreeSlot(t, relay)

	if resp := push(t, endpoint, pushOpts{auth: auth}); resp.StatusCode != http.StatusCreated {
		t.Fatalf("slot leaked after cancellation: %d", resp.StatusCode)
	}
}

// Invalid requests are rejected before the egress gate, so an attacker cannot
// exhaust the global budget with requests that never reach APNs.
func TestInvalidRequestsDoNotConsumeGlobalBudget(t *testing.T) {
	sender := &fakeSender{}
	_, ts := startRelay(t, func(c *Config) {
		c.PushBurst = 100
		c.PushPerMinute = 100
		c.GlobalPushBurst = 1
		c.GlobalPushPerMinute = 1
		c.MaxConcurrency = 8
	}, sender)
	key := newVAPIDKey(t)
	endpoint := registerOK(t, ts.URL, key, "production")
	auth := key.header(t, validClaims(ts.URL, time.Now()))

	for range 5 {
		if resp := push(t, endpoint, pushOpts{}); resp.StatusCode != http.StatusUnauthorized {
			t.Fatalf("missing auth: %d", resp.StatusCode)
		}
		if resp := push(t, endpoint, pushOpts{auth: "vapid garbage"}); resp.StatusCode != http.StatusUnauthorized {
			t.Fatalf("bad auth: %d", resp.StatusCode)
		}
		if resp := push(t, endpoint, pushOpts{auth: auth, encoding: "aesgcm"}); resp.StatusCode != http.StatusUnsupportedMediaType {
			t.Fatalf("bad encoding: %d", resp.StatusCode)
		}
		if resp := push(t, endpoint, pushOpts{auth: auth, body: []byte("not encrypted")}); resp.StatusCode != http.StatusBadRequest {
			t.Fatalf("bad payload: %d", resp.StatusCode)
		}
	}
	if n := len(sender.sent()); n != 0 {
		t.Fatalf("rejected requests reached APNs: %d", n)
	}
	if resp := push(t, endpoint, pushOpts{auth: auth}); resp.StatusCode != http.StatusCreated {
		t.Fatalf("valid push denied after invalid traffic: %d", resp.StatusCode)
	}
	if resp := push(t, endpoint, pushOpts{auth: auth}); resp.StatusCode != http.StatusTooManyRequests {
		t.Fatalf("global budget was not consumed by the valid push: %d", resp.StatusCode)
	}
}
