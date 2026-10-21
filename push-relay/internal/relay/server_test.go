package relay

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/SamSaffron/term-llm-app/push-relay/internal/apns"
)

const testToken = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"

type pusherCall struct {
	environment apns.Environment
	deviceToken string
	payload     []byte
}

type fakePusher struct {
	mu     sync.Mutex
	calls  []pusherCall
	result apns.Result
	err    error
}

func (f *fakePusher) Send(_ context.Context, environment apns.Environment, deviceToken string, payload []byte) (apns.Result, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls = append(f.calls, pusherCall{
		environment: environment,
		deviceToken: deviceToken,
		payload:     append([]byte(nil), payload...),
	})
	return f.result, f.err
}

func (f *fakePusher) callCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.calls)
}

func (f *fakePusher) lastCall(t *testing.T) pusherCall {
	t.Helper()
	f.mu.Lock()
	defer f.mu.Unlock()
	if len(f.calls) == 0 {
		t.Fatal("pusher was not called")
	}
	return f.calls[len(f.calls)-1]
}

type blockingPusher struct {
	started chan struct{}
	release chan struct{}
	once    sync.Once
	calls   atomic.Int32
}

func newBlockingPusher() *blockingPusher {
	return &blockingPusher{started: make(chan struct{}), release: make(chan struct{})}
}

func (p *blockingPusher) Send(ctx context.Context, _ apns.Environment, _ string, _ []byte) (apns.Result, error) {
	p.calls.Add(1)
	p.once.Do(func() { close(p.started) })
	select {
	case <-p.release:
		return apns.Result{Status: http.StatusOK}, nil
	case <-ctx.Done():
		return apns.Result{}, ctx.Err()
	}
}

func TestHealthAndRoutes(t *testing.T) {
	pusher := &fakePusher{}
	server := newTestServer(t, pusher, Options{})

	status, headers, body := request(t, http.MethodGet, server.URL+"/healthz", "", "", nil)
	if status != http.StatusOK {
		t.Fatalf("health status = %d, body = %s", status, body)
	}
	if got := headers.Get("Cache-Control"); got != "no-store" {
		t.Fatalf("Cache-Control = %q", got)
	}
	if got := headers.Get("Content-Type"); got != "application/json" {
		t.Fatalf("Content-Type = %q", got)
	}
	if string(body) != "{\"status\":\"ok\"}\n" {
		t.Fatalf("health body = %q", body)
	}

	for _, testCase := range []struct {
		name   string
		method string
		path   string
		status int
		allow  string
	}{
		{"health method", http.MethodPost, "/healthz", http.StatusMethodNotAllowed, http.MethodGet},
		{"push method", http.MethodGet, "/v1/push", http.StatusMethodNotAllowed, http.MethodPost},
		{"root", http.MethodGet, "/", http.StatusNotFound, ""},
		{"unknown", http.MethodPost, "/v1/other", http.StatusNotFound, ""},
		{"trailing slash", http.MethodPost, "/v1/push/", http.StatusNotFound, ""},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			status, headers, _ := request(t, testCase.method, server.URL+testCase.path, "", "", nil)
			if status != testCase.status {
				t.Fatalf("status = %d, want %d", status, testCase.status)
			}
			if testCase.allow != "" && headers.Get("Allow") != testCase.allow {
				t.Fatalf("Allow = %q, want %q", headers.Get("Allow"), testCase.allow)
			}
		})
	}

	if pusher.callCount() != 0 {
		t.Fatalf("pusher calls = %d, want 0", pusher.callCount())
	}
}

func TestAuthenticationRejectsBeforeParsing(t *testing.T) {
	pusher := &fakePusher{}
	server := newTestServer(t, pusher, Options{})
	validBody := validRequest(t, "sandbox", strings.Repeat("ab", 32), "title", "body", nil)

	cases := []struct {
		name   string
		header []string
	}{
		{"missing", nil},
		{"wrong token", []string{"Bearer " + strings.Repeat("z", 64)}},
		{"wrong scheme", []string{"Basic " + testToken}},
		{"empty token", []string{"Bearer "}},
		{"extra field", []string{"Bearer " + testToken + " extra"}},
		{"duplicate headers", []string{"Bearer " + testToken, "Bearer " + testToken}},
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			req, err := http.NewRequest(http.MethodPost, server.URL+"/v1/push", bytes.NewReader(validBody))
			if err != nil {
				t.Fatal(err)
			}
			for _, value := range testCase.header {
				req.Header.Add("Authorization", value)
			}
			req.Header.Set("Content-Type", "application/json")
			response, err := http.DefaultClient.Do(req)
			if err != nil {
				t.Fatal(err)
			}
			defer response.Body.Close()
			body, _ := io.ReadAll(response.Body)
			if response.StatusCode != http.StatusUnauthorized {
				t.Fatalf("status = %d, body = %s", response.StatusCode, body)
			}
			if response.Header.Get("WWW-Authenticate") == "" {
				t.Fatal("missing WWW-Authenticate")
			}
		})
	}

	// Authentication must happen before JSON validation and body consumption.
	status, _, _ := request(t, http.MethodPost, server.URL+"/v1/push", "Bearer wrong", "application/json", []byte("{"))
	if status != http.StatusUnauthorized {
		t.Fatalf("malformed body with bad auth status = %d, want 401", status)
	}
	if pusher.callCount() != 0 {
		t.Fatalf("pusher calls = %d, want 0", pusher.callCount())
	}
}

func TestValidRequestIsForwarded(t *testing.T) {
	pusher := &fakePusher{result: apns.Result{Status: http.StatusOK}}
	server := newTestServer(t, pusher, Options{})
	deviceToken := strings.Repeat("a1", 36) // variable 72-character hex token
	body := validRequest(t, "sandbox", deviceToken, "Build finished", "Your task is ready.", map[string]any{
		"conversation_id": "abc123",
		"unread":          3,
	})

	status, headers, responseBody := request(t, http.MethodPost, server.URL+"/v1/push", "Bearer "+testToken, "application/json; charset=UTF-8", body)
	if status != http.StatusOK {
		t.Fatalf("status = %d, body = %s", status, responseBody)
	}
	if headers.Get("Cache-Control") != "no-store" {
		t.Fatalf("Cache-Control = %q", headers.Get("Cache-Control"))
	}
	var response pushResponse
	if err := json.Unmarshal(responseBody, &response); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if response.Status != "accepted" || response.APNSStatus != http.StatusOK {
		t.Fatalf("unexpected response: %+v", response)
	}
	if bytes.Contains(responseBody, []byte(deviceToken)) || bytes.Contains(responseBody, []byte(testToken)) {
		t.Fatal("response leaked a token")
	}

	if pusher.callCount() != 1 {
		t.Fatalf("pusher calls = %d, want 1", pusher.callCount())
	}
	call := pusher.lastCall(t)
	if call.environment != apns.Sandbox || call.deviceToken != deviceToken {
		t.Fatalf("unexpected call: %+v", call)
	}
	var payload map[string]json.RawMessage
	if err := json.Unmarshal(call.payload, &payload); err != nil {
		t.Fatalf("payload is not JSON: %v", err)
	}
	var aps struct {
		Alert struct {
			Title string `json:"title"`
			Body  string `json:"body"`
		} `json:"alert"`
		Sound string `json:"sound"`
	}
	if err := json.Unmarshal(payload["aps"], &aps); err != nil {
		t.Fatalf("decode aps: %v", err)
	}
	if aps.Alert.Title != "Build finished" || aps.Alert.Body != "Your task is ready." || aps.Sound != "default" {
		t.Fatalf("unexpected aps: %+v", aps)
	}
	if string(payload["conversation_id"]) != `"abc123"` {
		t.Fatalf("custom data missing: %s", call.payload)
	}
}

func TestProductionEnvironmentIsForwarded(t *testing.T) {
	pusher := &fakePusher{result: apns.Result{Status: http.StatusOK}}
	server := newTestServer(t, pusher, Options{})
	body := validRequest(t, "production", strings.Repeat("ab", 32), "title", "body", nil)

	status, _, responseBody := request(t, http.MethodPost, server.URL+"/v1/push", "Bearer "+testToken, "application/json", body)
	if status != http.StatusOK {
		t.Fatalf("status = %d, body = %s", status, responseBody)
	}
	if call := pusher.lastCall(t); call.environment != apns.Production {
		t.Fatalf("environment = %q, want production", call.environment)
	}
}

func TestMalformedRequestsNeverReachAPNs(t *testing.T) {
	pusher := &fakePusher{result: apns.Result{Status: http.StatusOK}}
	server := newTestServer(t, pusher, Options{})
	token := strings.Repeat("ab", 32)
	valid := string(validRequest(t, "sandbox", token, "title", "body", nil))

	cases := []struct {
		name        string
		contentType string
		body        []byte
		wantStatus  int
		wantCode    string
	}{
		{"wrong content type", "text/plain", validRequest(t, "sandbox", token, "title", "body", nil), http.StatusUnsupportedMediaType, "unsupported_media_type"},
		{"missing content type", "", validRequest(t, "sandbox", token, "title", "body", nil), http.StatusUnsupportedMediaType, "unsupported_media_type"},
		{"malformed json", "application/json", []byte("{"), http.StatusBadRequest, "invalid_json"},
		{"empty body", "application/json", nil, http.StatusBadRequest, "invalid_json"},
		{"unknown field", "application/json", []byte(strings.TrimSuffix(valid, "}") + `,"unknown":true}`), http.StatusBadRequest, "invalid_json"},
		{"trailing json", "application/json", []byte(valid + `{}`), http.StatusBadRequest, "invalid_json"},
		{"missing environment", "application/json", []byte(fmt.Sprintf(`{"device_token":%q,"title":"t","body":"b"}`, token)), http.StatusBadRequest, "invalid_environment"},
		{"invalid environment", "application/json", []byte(fmt.Sprintf(`{"environment":"staging","device_token":%q,"title":"t","body":"b"}`, token)), http.StatusBadRequest, "invalid_environment"},
		{"missing device token", "application/json", []byte(`{"environment":"sandbox","title":"t","body":"b"}`), http.StatusBadRequest, "invalid_device_token"},
		{"odd device token", "application/json", []byte(fmt.Sprintf(`{"environment":"sandbox","device_token":%q,"title":"t","body":"b"}`, strings.Repeat("a", 63))), http.StatusBadRequest, "invalid_device_token"},
		{"nonhex device token", "application/json", []byte(fmt.Sprintf(`{"environment":"sandbox","device_token":%q,"title":"t","body":"b"}`, strings.Repeat("zz", 32))), http.StatusBadRequest, "invalid_device_token"},
		{"path traversal token", "application/json", []byte(`{"environment":"sandbox","device_token":"../../etc/passwd","title":"t","body":"b"}`), http.StatusBadRequest, "invalid_device_token"},
		{"empty title", "application/json", []byte(fmt.Sprintf(`{"environment":"sandbox","device_token":%q,"title":"","body":"b"}`, token)), http.StatusBadRequest, "invalid_request"},
		{"empty body text", "application/json", []byte(fmt.Sprintf(`{"environment":"sandbox","device_token":%q,"title":"t","body":"   "}`, token)), http.StatusBadRequest, "invalid_request"},
		{"data array", "application/json", []byte(fmt.Sprintf(`{"environment":"sandbox","device_token":%q,"title":"t","body":"b","data":[]}`, token)), http.StatusBadRequest, "invalid_data"},
		{"data null", "application/json", []byte(fmt.Sprintf(`{"environment":"sandbox","device_token":%q,"title":"t","body":"b","data":null}`, token)), http.StatusBadRequest, "invalid_data"},
		{"data aps override", "application/json", []byte(fmt.Sprintf(`{"environment":"sandbox","device_token":%q,"title":"t","body":"b","data":{"aps":{"sound":"none"}}}`, token)), http.StatusBadRequest, "reserved_data_key"},
		{"request too large", "application/json", []byte(fmt.Sprintf(`{"environment":"sandbox","device_token":%q,"title":%q,"body":"b"}`, token, strings.Repeat("a", 20<<10))), http.StatusRequestEntityTooLarge, "request_too_large"},
		{"payload too large", "application/json", []byte(fmt.Sprintf(`{"environment":"sandbox","device_token":%q,"title":"t","body":"b","data":{"blob":%q}}`, token, strings.Repeat("a", 5000))), http.StatusUnprocessableEntity, "payload_too_large"},
	}

	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			status, _, body := request(t, http.MethodPost, server.URL+"/v1/push", "Bearer "+testToken, testCase.contentType, testCase.body)
			if status != testCase.wantStatus {
				t.Fatalf("status = %d, want %d, body = %s", status, testCase.wantStatus, body)
			}
			var response errorResponse
			if err := json.Unmarshal(body, &response); err != nil {
				t.Fatalf("decode error response: %v (%s)", err, body)
			}
			if response.Error.Code != testCase.wantCode {
				t.Fatalf("code = %q, want %q", response.Error.Code, testCase.wantCode)
			}
			if bytes.Contains(body, []byte(testToken)) || bytes.Contains(body, []byte(token)) {
				t.Fatal("error response leaked a token")
			}
		})
	}
	if pusher.callCount() != 0 {
		t.Fatalf("pusher calls = %d, want 0", pusher.callCount())
	}
}

func TestContentLengthUpperBoundBeforeRead(t *testing.T) {
	pusher := &fakePusher{}
	server, err := New(pusher, []byte(testToken), Options{})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	req := httptest.NewRequest(http.MethodPost, "/v1/push", strings.NewReader(""))
	req.ContentLength = DefaultMaxBodyBytes + 1
	req.Header.Set("Authorization", "Bearer "+testToken)
	req.Header.Set("Content-Type", "application/json")
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, req)
	if recorder.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("status = %d, want 413", recorder.Code)
	}
	if pusher.callCount() != 0 {
		t.Fatalf("pusher calls = %d, want 0", pusher.callCount())
	}
}

func TestAPNsRejectionMapping(t *testing.T) {
	deviceToken := strings.Repeat("ab", 32)
	cases := []struct {
		name        string
		rejection   *apns.RejectError
		wantStatus  int
		wantInvalid bool
		wantCode    string
	}{
		{"bad device token", &apns.RejectError{Status: 400, Reason: "BadDeviceToken", DeviceInvalid: true}, http.StatusBadRequest, true, "apns_rejected"},
		{"wrong topic", &apns.RejectError{Status: 400, Reason: "DeviceTokenNotForTopic", DeviceInvalid: true}, http.StatusBadRequest, true, "apns_rejected"},
		{"unregistered", &apns.RejectError{Status: 410, Reason: "Unregistered", DeviceInvalid: true}, http.StatusGone, true, "apns_rejected"},
		{"bad provider token", &apns.RejectError{Status: 403, Reason: "InvalidProviderToken"}, http.StatusBadGateway, false, "apns_rejected"},
		{"rate limited", &apns.RejectError{Status: 429, Reason: "TooManyRequests"}, http.StatusBadGateway, false, "apns_rejected"},
		{"payload too large", &apns.RejectError{Status: 413, Reason: "PayloadTooLarge"}, http.StatusUnprocessableEntity, false, "apns_rejected"},
		{"apple internal", &apns.RejectError{Status: 500, Reason: "InternalServerError"}, http.StatusBadGateway, false, "apns_rejected"},
		{"unparseable reason", &apns.RejectError{Status: 400}, http.StatusBadGateway, false, "apns_rejected"},
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			pusher := &fakePusher{err: testCase.rejection}
			server := newTestServer(t, pusher, Options{})
			body := validRequest(t, "sandbox", deviceToken, "title", "body", nil)

			status, _, responseBody := request(t, http.MethodPost, server.URL+"/v1/push", "Bearer "+testToken, "application/json", body)
			if status != testCase.wantStatus {
				t.Fatalf("status = %d, want %d, body = %s", status, testCase.wantStatus, responseBody)
			}
			var response errorResponse
			if err := json.Unmarshal(responseBody, &response); err != nil {
				t.Fatalf("decode response: %v", err)
			}
			if response.Error.Code != testCase.wantCode {
				t.Fatalf("code = %q, want %q", response.Error.Code, testCase.wantCode)
			}
			if response.Error.APNSStatus != testCase.rejection.Status {
				t.Fatalf("apns_status = %d, want %d", response.Error.APNSStatus, testCase.rejection.Status)
			}
			if response.Error.Reason != testCase.rejection.Reason {
				t.Fatalf("reason = %q, want %q", response.Error.Reason, testCase.rejection.Reason)
			}
			if response.Error.DeviceInvalid == nil || *response.Error.DeviceInvalid != testCase.wantInvalid {
				t.Fatalf("device_invalid = %v, want %v", response.Error.DeviceInvalid, testCase.wantInvalid)
			}
			if bytes.Contains(responseBody, []byte(deviceToken)) || bytes.Contains(responseBody, []byte(testToken)) {
				t.Fatal("error response leaked a token")
			}
			if pusher.callCount() != 1 {
				t.Fatalf("pusher calls = %d, want exactly 1", pusher.callCount())
			}
		})
	}
}

func TestUnsafeAPNSReasonIsSanitized(t *testing.T) {
	pusher := &fakePusher{err: &apns.RejectError{Status: 400, Reason: "BadDeviceToken\n{\"injected\":true}"}}
	server := newTestServer(t, pusher, Options{})
	body := validRequest(t, "sandbox", strings.Repeat("ab", 32), "title", "body", nil)

	status, _, responseBody := request(t, http.MethodPost, server.URL+"/v1/push", "Bearer "+testToken, "application/json", body)
	if status != http.StatusBadGateway {
		t.Fatalf("status = %d, want 502", status)
	}
	if bytes.Contains(responseBody, []byte("injected")) || bytes.Contains(responseBody, []byte("BadDeviceToken")) {
		t.Fatalf("unsafe reason leaked into response: %s", responseBody)
	}
	var response errorResponse
	if err := json.Unmarshal(responseBody, &response); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if response.Error.Reason != "" {
		t.Fatalf("reason = %q, want empty", response.Error.Reason)
	}
}

func TestTransportErrorMapping(t *testing.T) {
	cases := []struct {
		name       string
		err        error
		wantStatus int
		wantCode   string
	}{
		{"timeout", &apns.TransportError{Timeout: true}, http.StatusGatewayTimeout, "apns_timeout"},
		{"unavailable", &apns.TransportError{}, http.StatusBadGateway, "apns_unavailable"},
		{"deadline", context.DeadlineExceeded, http.StatusGatewayTimeout, "apns_timeout"},
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			pusher := &fakePusher{err: testCase.err}
			server := newTestServer(t, pusher, Options{})
			body := validRequest(t, "sandbox", strings.Repeat("ab", 32), "title", "body", nil)

			status, _, responseBody := request(t, http.MethodPost, server.URL+"/v1/push", "Bearer "+testToken, "application/json", body)
			if status != testCase.wantStatus {
				t.Fatalf("status = %d, want %d", status, testCase.wantStatus)
			}
			var response errorResponse
			if err := json.Unmarshal(responseBody, &response); err != nil {
				t.Fatalf("decode response: %v", err)
			}
			if response.Error.Code != testCase.wantCode {
				t.Fatalf("code = %q, want %q", response.Error.Code, testCase.wantCode)
			}
			if pusher.callCount() != 1 {
				t.Fatalf("pusher calls = %d, want exactly 1", pusher.callCount())
			}
		})
	}
}

func TestUnexpectedUpstreamErrorIsSanitized(t *testing.T) {
	deviceToken := strings.Repeat("ab", 32)
	secret := "provider-jwt-that-must-not-leak"
	pusher := &fakePusher{err: fmt.Errorf("POST https://api.sandbox.push.apple.com/3/device/%s Authorization: bearer %s", deviceToken, secret)}
	server := newTestServer(t, pusher, Options{})
	body := validRequest(t, "sandbox", deviceToken, "title", "body", nil)

	status, _, responseBody := request(t, http.MethodPost, server.URL+"/v1/push", "Bearer "+testToken, "application/json", body)
	if status != http.StatusBadGateway {
		t.Fatalf("status = %d, want 502", status)
	}
	for _, forbidden := range []string{deviceToken, secret, "https://", "apple.com"} {
		if bytes.Contains(responseBody, []byte(forbidden)) {
			t.Fatalf("response leaked %q: %s", forbidden, responseBody)
		}
	}
	var response errorResponse
	if err := json.Unmarshal(responseBody, &response); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if response.Error.Code != "upstream_failure" {
		t.Fatalf("code = %q, want upstream_failure", response.Error.Code)
	}
}

func TestConcurrentAPNSCallsAreCapped(t *testing.T) {
	pusher := newBlockingPusher()
	server := newTestServer(t, pusher, Options{MaxConcurrent: 1, APNSTimeout: 5 * time.Second})
	body := validRequest(t, "sandbox", strings.Repeat("ab", 32), "title", "body", nil)
	client := &http.Client{Timeout: 5 * time.Second}

	firstDone := make(chan int, 1)
	go func() {
		status, _, _ := requestWithClient(t, client, http.MethodPost, server.URL+"/v1/push", "Bearer "+testToken, "application/json", body)
		firstDone <- status
	}()

	select {
	case <-pusher.started:
	case <-time.After(2 * time.Second):
		t.Fatal("first APNs call did not start")
	}

	status, _, responseBody := requestWithClient(t, client, http.MethodPost, server.URL+"/v1/push", "Bearer "+testToken, "application/json", body)
	if status != http.StatusServiceUnavailable {
		t.Fatalf("second status = %d, body = %s", status, responseBody)
	}
	var response errorResponse
	if err := json.Unmarshal(responseBody, &response); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if response.Error.Code != "relay_busy" {
		t.Fatalf("code = %q, want relay_busy", response.Error.Code)
	}
	if pusher.calls.Load() != 1 {
		t.Fatalf("APNs calls = %d, want 1", pusher.calls.Load())
	}

	close(pusher.release)
	select {
	case status := <-firstDone:
		if status != http.StatusOK {
			t.Fatalf("first status = %d, want 200", status)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("first request did not finish")
	}
}

func TestNewValidation(t *testing.T) {
	if _, err := New(nil, []byte(testToken), Options{}); err == nil {
		t.Fatal("New accepted nil pusher")
	}
	if _, err := New(&fakePusher{}, nil, Options{}); err == nil {
		t.Fatal("New accepted empty token")
	}
	server, err := New(&fakePusher{}, []byte(testToken), Options{})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	if server.maxBodyBytes != DefaultMaxBodyBytes || server.apnsTimeout != DefaultAPNSTimeout || cap(server.sem) != DefaultMaxConcurrent {
		t.Fatalf("unexpected defaults: %+v", server)
	}
}

func newTestServer(t *testing.T, pusher Pusher, options Options) *httptest.Server {
	t.Helper()
	handler, err := New(pusher, []byte(testToken), options)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)
	return server
}

func validRequest(t *testing.T, environment, deviceToken, title, body string, data map[string]any) []byte {
	t.Helper()
	request := map[string]any{
		"environment":  environment,
		"device_token": deviceToken,
		"title":        title,
		"body":         body,
	}
	if data != nil {
		request["data"] = data
	}
	encoded, err := json.Marshal(request)
	if err != nil {
		t.Fatalf("marshal request: %v", err)
	}
	return encoded
}

func request(t *testing.T, method, url, authorization, contentType string, body []byte) (int, http.Header, []byte) {
	t.Helper()
	return requestWithClient(t, &http.Client{Timeout: 5 * time.Second}, method, url, authorization, contentType, body)
}

func requestWithClient(t *testing.T, client *http.Client, method, url, authorization, contentType string, body []byte) (int, http.Header, []byte) {
	t.Helper()
	req, err := http.NewRequest(method, url, bytes.NewReader(body))
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	if authorization != "" {
		req.Header.Set("Authorization", authorization)
	}
	if contentType != "" {
		req.Header.Set("Content-Type", contentType)
	}
	response, err := client.Do(req)
	if err != nil {
		t.Fatalf("request: %v", err)
	}
	defer response.Body.Close()
	responseBody, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatalf("read response: %v", err)
	}
	return response.StatusCode, response.Header.Clone(), responseBody
}
