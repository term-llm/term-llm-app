package main

import (
	"bytes"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"testing"
	"time"
)

func register(t *testing.T, baseURL string, body any) (*http.Response, map[string]string) {
	t.Helper()
	data, _ := json.Marshal(body)
	resp, err := http.Post(baseURL+"/v1/register", "application/json", bytes.NewReader(data))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var out map[string]string
	_ = json.NewDecoder(resp.Body).Decode(&out)
	return resp, out
}

func registerOK(t *testing.T, baseURL string, key vapidKey, env string) string {
	t.Helper()
	resp, out := register(t, baseURL, map[string]string{
		"device_token": hex.EncodeToString(testDeviceToken()), "environment": env, "application_server_key": key.encoded(),
	})
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("register: %d %v", resp.StatusCode, out)
	}
	return out["endpoint"]
}

type pushOpts struct {
	auth     string
	encoding string
	ttl      string
	urgency  string
	topic    string
	body     []byte
}

func push(t *testing.T, endpoint string, o pushOpts) *http.Response {
	t.Helper()
	if o.encoding == "" {
		o.encoding = "aes128gcm"
	}
	if o.ttl == "" {
		o.ttl = "300"
	}
	if o.body == nil {
		o.body = fakeAES128GCMBody(512)
	}
	req, _ := http.NewRequest(http.MethodPost, endpoint, bytes.NewReader(o.body))
	req.Header.Set("Authorization", o.auth)
	req.Header.Set("Content-Encoding", o.encoding)
	req.Header.Set("TTL", o.ttl)
	if o.urgency != "" {
		req.Header.Set("Urgency", o.urgency)
	}
	if o.topic != "" {
		req.Header.Set("Topic", o.topic)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	return resp
}

func TestRegister(t *testing.T) {
	_, ts := startRelay(t, nil, &fakeSender{})
	key := newVAPIDKey(t)

	endpoint := registerOK(t, ts.URL, key, "development")
	if !strings.HasPrefix(endpoint, ts.URL+"/v1/push/") {
		t.Fatalf("endpoint %q not under public URL", endpoint)
	}
	if again := registerOK(t, ts.URL, key, "development"); again != endpoint {
		t.Fatal("re-registration must return the same endpoint")
	}
	if prod := registerOK(t, ts.URL, key, "production"); prod == endpoint {
		t.Fatal("environments must not share endpoints")
	}

	good := map[string]string{"device_token": hex.EncodeToString(testDeviceToken()), "environment": "production", "application_server_key": key.encoded()}
	for name, mutate := range map[string]func(map[string]string){
		"non-hex token": func(m map[string]string) { m["device_token"] = "zz" },
		"short token":   func(m map[string]string) { m["device_token"] = "abcd" },
		"bad env":       func(m map[string]string) { m["environment"] = "staging" },
		"bad key":       func(m map[string]string) { m["application_server_key"] = "AAAA" },
		"missing key":   func(m map[string]string) { delete(m, "application_server_key") },
	} {
		body := map[string]string{}
		for k, v := range good {
			body[k] = v
		}
		mutate(body)
		if resp, _ := register(t, ts.URL, body); resp.StatusCode != http.StatusBadRequest {
			t.Errorf("%s: status %d", name, resp.StatusCode)
		}
	}
	resp, err := http.Post(ts.URL+"/v1/register", "application/json", strings.NewReader("{"))
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Errorf("malformed JSON: %d", resp.StatusCode)
	}
}

func TestPushForwardsToAPNs(t *testing.T) {
	sender := &fakeSender{result: APNsResult{Status: 200, APNsID: "11111111-2222-4333-8444-555555555555"}}
	_, ts := startRelay(t, nil, sender)
	key := newVAPIDKey(t)
	endpoint := registerOK(t, ts.URL, key, "development")
	body := fakeAES128GCMBody(2048)

	before := time.Now()
	resp := push(t, endpoint, pushOpts{auth: key.header(t, validClaims(ts.URL, time.Now())), body: body, urgency: "low", topic: "session-42"})
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("status %d", resp.StatusCode)
	}
	if loc := resp.Header.Get("Location"); loc != ts.URL+"/v1/messages/11111111-2222-4333-8444-555555555555" {
		t.Fatalf("Location %q", loc)
	}
	if resp.Header.Get("TTL") != "300" {
		t.Fatalf("TTL %q", resp.Header.Get("TTL"))
	}

	sent := sender.sent()
	if len(sent) != 1 {
		t.Fatalf("sent %d", len(sent))
	}
	req := sent[0]
	if req.Env != EnvDevelopment || !bytes.Equal(req.DeviceToken, testDeviceToken()) {
		t.Fatalf("wrong destination: %+v", req)
	}
	if req.Priority != 5 || req.CollapseID != "session-42" || req.ID == "" {
		t.Fatalf("wrong headers: %+v", req)
	}
	if exp := req.Expiration.Sub(before); exp < 299*time.Second || exp > 301*time.Second+time.Since(before) {
		t.Fatalf("expiration %v not ~TTL", exp)
	}
	var payload struct {
		APS struct {
			Alert          map[string]string `json:"alert"`
			MutableContent int               `json:"mutable-content"`
		} `json:"aps"`
		WebPush struct {
			V    int    `json:"v"`
			CE   string `json:"ce"`
			Body string `json:"body"`
		} `json:"webpush"`
	}
	if err := json.Unmarshal(req.Payload, &payload); err != nil {
		t.Fatal(err)
	}
	if payload.APS.MutableContent != 1 || payload.APS.Alert["title"] != "term-llm" || payload.WebPush.V != 1 || payload.WebPush.CE != "aes128gcm" {
		t.Fatalf("payload: %s", req.Payload)
	}
	if decoded, _ := base64.StdEncoding.DecodeString(payload.WebPush.Body); !bytes.Equal(decoded, body) {
		t.Fatal("ciphertext was not forwarded byte-for-byte")
	}
	if len(req.Payload) > apnsMaxPayloadSize {
		t.Fatalf("payload %d bytes exceeds APNs limit", len(req.Payload))
	}
}

func TestPushTTLZeroAndUrgencyDefaults(t *testing.T) {
	sender := &fakeSender{}
	_, ts := startRelay(t, nil, sender)
	key := newVAPIDKey(t)
	endpoint := registerOK(t, ts.URL, key, "production")
	if resp := push(t, endpoint, pushOpts{auth: key.header(t, validClaims(ts.URL, time.Now())), ttl: "0"}); resp.StatusCode != http.StatusCreated {
		t.Fatalf("status %d", resp.StatusCode)
	}
	req := sender.sent()[0]
	if !req.Expiration.IsZero() || req.Priority != 10 || req.Env != EnvProduction {
		t.Fatalf("unexpected request %+v", req)
	}
}

func TestPushRejections(t *testing.T) {
	sender := &fakeSender{}
	_, ts := startRelay(t, nil, sender)
	key := newVAPIDKey(t)
	other := newVAPIDKey(t)
	endpoint := registerOK(t, ts.URL, key, "production")
	auth := key.header(t, validClaims(ts.URL, time.Now()))

	cases := []struct {
		name     string
		endpoint string
		opts     pushOpts
		want     int
	}{
		{"unknown token", ts.URL + "/v1/push/nope", pushOpts{auth: auth}, http.StatusNotFound},
		{"no auth", endpoint, pushOpts{}, http.StatusUnauthorized},
		{"wrong audience", endpoint, pushOpts{auth: key.header(t, validClaims("https://fcm.googleapis.com", time.Now()))}, http.StatusUnauthorized},
		{"different server key", endpoint, pushOpts{auth: other.header(t, validClaims(ts.URL, time.Now()))}, http.StatusForbidden},
		{"legacy encoding", endpoint, pushOpts{auth: auth, encoding: "aesgcm"}, http.StatusUnsupportedMediaType},
		{"bad TTL", endpoint, pushOpts{auth: auth, ttl: "-1"}, http.StatusBadRequest},
		{"bad urgency", endpoint, pushOpts{auth: auth, urgency: "urgent"}, http.StatusBadRequest},
		{"bad topic", endpoint, pushOpts{auth: auth, topic: "has spaces"}, http.StatusBadRequest},
		{"not aes128gcm", endpoint, pushOpts{auth: auth, body: []byte("hello")}, http.StatusBadRequest},
		{"body over 4096", endpoint, pushOpts{auth: auth, body: fakeAES128GCMBody(4097)}, http.StatusRequestEntityTooLarge},
		// webpush-go's default record size pads every message to 4096 bytes,
		// which no longer fits in an APNs payload once base64-encoded.
		{"too large for APNs", endpoint, pushOpts{auth: auth, body: fakeAES128GCMBody(4096)}, http.StatusRequestEntityTooLarge},
	}
	for _, tc := range cases {
		if resp := push(t, tc.endpoint, tc.opts); resp.StatusCode != tc.want {
			t.Errorf("%s: status %d, want %d", tc.name, resp.StatusCode, tc.want)
		}
	}
	if n := len(sender.sent()); n != 0 {
		t.Fatalf("rejected pushes reached APNs: %d", n)
	}
}

func TestPushRateLimitPerDevice(t *testing.T) {
	sender := &fakeSender{}
	_, ts := startRelay(t, func(c *Config) { c.PushBurst = 2; c.PushPerMinute = 1 }, sender)
	key := newVAPIDKey(t)
	endpoint := registerOK(t, ts.URL, key, "production")
	auth := key.header(t, validClaims(ts.URL, time.Now()))

	// Unauthenticated requests must not drain the device budget.
	for range 5 {
		push(t, endpoint, pushOpts{})
	}
	for i := range 2 {
		if resp := push(t, endpoint, pushOpts{auth: auth}); resp.StatusCode != http.StatusCreated {
			t.Fatalf("push %d: %d", i, resp.StatusCode)
		}
	}
	resp := push(t, endpoint, pushOpts{auth: auth})
	if resp.StatusCode != http.StatusTooManyRequests || resp.Header.Get("Retry-After") == "" {
		t.Fatalf("expected 429 with Retry-After, got %d %q", resp.StatusCode, resp.Header.Get("Retry-After"))
	}
}

func TestRegisterRateLimitUsesTrustedHeader(t *testing.T) {
	_, ts := startRelay(t, func(c *Config) { c.RegisterBurst = 1; c.ClientIPHeader = "Fly-Client-IP" }, &fakeSender{})
	key := newVAPIDKey(t)
	body, _ := json.Marshal(map[string]string{"device_token": hex.EncodeToString(testDeviceToken()), "environment": "production", "application_server_key": key.encoded()})
	do := func(ip string) int {
		req, _ := http.NewRequest(http.MethodPost, ts.URL+"/v1/register", bytes.NewReader(body))
		req.Header.Set("Fly-Client-IP", ip)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		return resp.StatusCode
	}
	if do("203.0.113.1") != 200 || do("203.0.113.1") != 429 || do("203.0.113.2") != 200 {
		t.Fatal("register rate limit not keyed by client IP header")
	}
}

func TestPushMapsAPNsFailures(t *testing.T) {
	cases := []struct {
		result     APNsResult
		err        error
		want       int
		retryAfter bool
	}{
		{APNsResult{Status: 410, Reason: "Unregistered"}, nil, http.StatusGone, false},
		{APNsResult{Status: 400, Reason: "BadDeviceToken"}, nil, http.StatusGone, false},
		{APNsResult{Status: 400, Reason: "DeviceTokenNotForTopic"}, nil, http.StatusGone, false},
		{APNsResult{Status: 429, Reason: "TooManyRequests"}, nil, http.StatusTooManyRequests, true},
		{APNsResult{Status: 503, Reason: "ServiceUnavailable"}, nil, http.StatusServiceUnavailable, true},
		{APNsResult{Status: 403, Reason: "InvalidProviderToken"}, nil, http.StatusBadGateway, true},
		{APNsResult{Status: 400, Reason: "BadTopic"}, nil, http.StatusBadGateway, true},
		{APNsResult{Status: 413, Reason: "PayloadTooLarge"}, nil, http.StatusRequestEntityTooLarge, false},
		{APNsResult{}, errors.New("dial tcp: timeout"), http.StatusBadGateway, true},
	}
	for _, tc := range cases {
		sender := &fakeSender{result: tc.result, err: tc.err}
		_, ts := startRelay(t, nil, sender)
		key := newVAPIDKey(t)
		endpoint := registerOK(t, ts.URL, key, "production")
		resp := push(t, endpoint, pushOpts{auth: key.header(t, validClaims(ts.URL, time.Now()))})
		if resp.StatusCode != tc.want || (resp.Header.Get("Retry-After") != "") != tc.retryAfter {
			t.Errorf("%+v %v: got %d Retry-After=%q, want %d", tc.result, tc.err, resp.StatusCode, resp.Header.Get("Retry-After"), tc.want)
		}
	}
}

func TestHealthz(t *testing.T) {
	_, ts := startRelay(t, nil, &fakeSender{})
	resp, err := http.Get(ts.URL + "/healthz")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("healthz %d", resp.StatusCode)
	}
}
