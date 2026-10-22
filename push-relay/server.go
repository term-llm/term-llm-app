package main

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"math"
	"net"
	"net/http"
	"strconv"
	"strings"
	"time"
)

const (
	// RFC 8030 push services must accept at least 4096 bytes of payload.
	maxPushBodySize     = 4096
	maxRegisterBodySize = 8 << 10
	// aes128gcm (RFC 8188) header: salt(16) rs(4) idlen(1) keyid(idlen).
	// Web Push (RFC 8291) uses the 65-byte sender public key as keyid.
	aes128gcmHeaderSize = 16 + 4 + 1 + 65
	gcmTagSize          = 16
	maxTTL              = 28 * 24 * 60 * 60 // seconds; APNs stores roughly this long at most
)

// Server implements the relay's HTTP API.
type Server struct {
	audience              string // public origin, also the expected VAPID aud claim
	sealer                *TokenSealer
	apns                  apnsSender
	pushLimit             *rateLimiter
	regLimit              *rateLimiter
	globalLimit           *rateLimiter
	slots                 chan struct{}
	environments          map[Environment]bool
	supportedEnvironments string
	alertTitle            string
	alertBody             string
	ipHeader              string
	log                   *slog.Logger
	now                   func() time.Time
}

func NewServer(cfg Config, sealer *TokenSealer, apns apnsSender, logger *slog.Logger) *Server {
	now := time.Now

	// NewServer is also used directly by tests. Apply the documented defaults
	// when a zero Config would otherwise make every push impossible.
	if cfg.GlobalPushBurst < 1 {
		cfg.GlobalPushBurst = defaultGlobalPushBurst
	}
	if !(cfg.GlobalPushPerMinute > 0) {
		cfg.GlobalPushPerMinute = defaultGlobalPushPerMinute
	}
	if cfg.MaxConcurrency < 1 {
		cfg.MaxConcurrency = defaultMaxConcurrency
	}
	envs := cfg.APNsEnvironments
	if len(envs) == 0 {
		envs = []Environment{EnvProduction}
	}
	environmentSet := make(map[Environment]bool, len(envs))
	environmentNames := make([]string, 0, len(envs))
	for _, env := range envs {
		if environmentSet[env] {
			continue
		}
		environmentSet[env] = true
		environmentNames = append(environmentNames, env.String())
	}

	return &Server{
		audience:              cfg.PublicURL,
		sealer:                sealer,
		apns:                  apns,
		pushLimit:             newRateLimiter(cfg.PushBurst, cfg.PushPerMinute, now),
		regLimit:              newRateLimiter(cfg.RegisterBurst, cfg.RegisterPerMinute, now),
		globalLimit:           newRateLimiter(cfg.GlobalPushBurst, cfg.GlobalPushPerMinute, now),
		slots:                 make(chan struct{}, cfg.MaxConcurrency),
		environments:          environmentSet,
		supportedEnvironments: strings.Join(environmentNames, ", "),
		alertTitle:            cfg.AlertTitle,
		alertBody:             cfg.AlertBody,
		ipHeader:              cfg.ClientIPHeader,
		log:                   logger,
		now:                   now,
	}
}

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = w.Write([]byte("ok\n"))
	})
	mux.HandleFunc("POST /v1/register", s.handleRegister)
	mux.HandleFunc("POST /v1/push/{token}", s.handlePush)
	return mux
}

type registerRequest struct {
	DeviceToken          string `json:"device_token"`
	Environment          string `json:"environment"`
	ApplicationServerKey string `json:"application_server_key"`
}

func (s *Server) handleRegister(w http.ResponseWriter, r *http.Request) {
	if ok, wait := s.regLimit.allow("ip:" + s.clientIP(r)); !ok {
		writeRetryAfter(w, wait)
		writeError(w, http.StatusTooManyRequests, "too many registrations, retry later")
		return
	}
	var req registerRequest
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxRegisterBodySize))
	if err := dec.Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "request body must be JSON")
		return
	}
	deviceToken, err := hex.DecodeString(strings.TrimSpace(req.DeviceToken))
	if err != nil || len(deviceToken) < minDeviceTokenSize || len(deviceToken) > maxDeviceTokenSize {
		writeError(w, http.StatusBadRequest, "device_token must be the hex-encoded APNs device token")
		return
	}
	env, err := parseEnvironment(strings.TrimSpace(req.Environment))
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	if !s.environments[env] {
		writeJSON(w, http.StatusUnprocessableEntity, map[string]string{
			"code": "unsupported_environment",
			"error": fmt.Sprintf("environment %q is not enabled on this relay (supported: %s)",
				env.String(), s.supportedEnvironments),
		})
		return
	}
	rawKey, _, err := parseApplicationServerKey(strings.TrimSpace(req.ApplicationServerKey))
	if err != nil {
		writeError(w, http.StatusBadRequest, "application_server_key: "+err.Error())
		return
	}
	token, err := s.sealer.Seal(Subscription{Env: env, DeviceToken: deviceToken, VAPIDKeyHash: sha256.Sum256(rawKey)})
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	s.log.Info("register", "device", deviceLogID(deviceToken), "env", env.String())
	writeJSON(w, http.StatusOK, map[string]string{
		"endpoint":    s.audience + "/v1/push/" + token,
		"environment": env.String(),
	})
}

func (s *Server) handlePush(w http.ResponseWriter, r *http.Request) {
	start := s.now()
	sub, err := s.sealer.Open(r.PathValue("token"))
	if err != nil {
		writeError(w, http.StatusNotFound, "unknown subscription")
		return
	}
	device := deviceLogID(sub.DeviceToken)

	keyHash, err := verifyVAPID(r.Header.Get("Authorization"), s.audience, s.now())
	if err != nil {
		w.Header().Set("WWW-Authenticate", "vapid")
		writeError(w, http.StatusUnauthorized, err.Error())
		return
	}
	if subtle.ConstantTimeCompare(keyHash[:], sub.VAPIDKeyHash[:]) != 1 {
		writeError(w, http.StatusForbidden, "VAPID key does not match this subscription")
		return
	}
	if !s.environments[sub.Env] {
		// The endpoint was minted while its environment was enabled. Refuse
		// before touching APNs and tell the sender to drop the subscription.
		writeError(w, http.StatusGone, "subscription uses an APNs environment this relay does not support")
		return
	}

	if ce := strings.ToLower(strings.TrimSpace(r.Header.Get("Content-Encoding"))); ce != "aes128gcm" {
		writeError(w, http.StatusUnsupportedMediaType, "Content-Encoding must be aes128gcm")
		return
	}
	ttl, err := strconv.Atoi(strings.TrimSpace(r.Header.Get("TTL")))
	if err != nil || ttl < 0 {
		writeError(w, http.StatusBadRequest, "TTL header must be a non-negative integer")
		return
	}
	ttl = min(ttl, maxTTL)
	priority, err := apnsPriority(r.Header.Get("Urgency"))
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	collapseID := strings.TrimSpace(r.Header.Get("Topic"))
	if !validTopic(collapseID) {
		writeError(w, http.StatusBadRequest, "Topic must be at most 32 base64url characters")
		return
	}

	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxPushBodySize))
	if err != nil {
		var tooLarge *http.MaxBytesError
		if errors.As(err, &tooLarge) {
			writeError(w, http.StatusRequestEntityTooLarge, "payload exceeds 4096 bytes")
			return
		}
		writeError(w, http.StatusBadRequest, "could not read payload")
		return
	}
	if err := validateAES128GCM(body); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	payload, err := s.apnsPayload(body, sub.VAPIDKeyHash)
	if err != nil {
		s.log.Warn("push rejected", "device", device, "reason", "apns_payload_too_large", "body_bytes", len(body))
		writeError(w, http.StatusRequestEntityTooLarge, err.Error())
		return
	}

	if ok, wait := s.pushLimit.allow("device:" + sub.Env.String() + ":" + hex.EncodeToString(sub.DeviceToken)); !ok {
		writeRetryAfter(w, wait)
		writeError(w, http.StatusTooManyRequests, "too many notifications for this device, retry later")
		return
	}
	// Bound outbound work before APNs: take a send slot without waiting, then
	// the process-wide token bucket. A request that cannot get a slot must not
	// consume the global budget. The deferred release also covers send errors
	// and cancelled requests.
	if !s.acquireSendSlot() {
		writeRetryAfter(w, time.Second)
		writeError(w, http.StatusServiceUnavailable, "relay is at its send concurrency limit, retry later")
		return
	}
	defer s.releaseSendSlot()
	if ok, wait := s.globalLimit.allow("global"); !ok {
		writeRetryAfter(w, wait)
		writeError(w, http.StatusTooManyRequests, "relay-wide notification budget is exhausted, retry later")
		return
	}

	req := APNsRequest{
		Env: sub.Env, DeviceToken: sub.DeviceToken, Payload: payload,
		Priority: priority, CollapseID: collapseID, ID: eventAPNsID(sub, collapseID),
	}
	if ttl > 0 {
		req.Expiration = s.now().Add(time.Duration(ttl) * time.Second)
	}
	ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
	defer cancel()
	result, sendErr := s.apns.Send(ctx, req)
	status, retryAfter, message := mapAPNsResult(result, sendErr)
	attrs := []any{"device", device, "env", sub.Env.String(), "status", status, "apns_status", result.Status,
		"request_apns_id", req.ID, "apns_id", result.APNsID,
		"body_bytes", len(body), "ttl", ttl, "priority", priority, "duration_ms", s.now().Sub(start).Milliseconds()}
	if result.Reason != "" {
		attrs = append(attrs, "apns_reason", result.Reason)
	}
	if sendErr != nil {
		attrs = append(attrs, "error", sanitizeTransportError(sendErr).Error())
	}
	if status >= 500 {
		s.log.Error("push", attrs...)
	} else {
		s.log.Info("push", attrs...)
	}

	if status != http.StatusCreated {
		if retryAfter > 0 {
			writeRetryAfter(w, retryAfter)
		}
		writeError(w, status, message)
		return
	}
	id := result.APNsID
	if id == "" {
		id = req.ID
	}
	w.Header().Set("Location", s.audience+"/v1/messages/"+id)
	w.Header().Set("TTL", strconv.Itoa(ttl))
	w.WriteHeader(http.StatusCreated)
}

// apnsPayload wraps the still-encrypted Web Push body for the Notification
// Service Extension. The alert is a placeholder shown if decryption fails.
// "k" identifies the sending server (see sourceTag) so the app can route taps.
func (s *Server) apnsPayload(body []byte, vapidKeyHash [32]byte) ([]byte, error) {
	payload, err := json.Marshal(map[string]any{
		"aps": map[string]any{
			"alert":           map[string]string{"title": s.alertTitle, "body": s.alertBody},
			"mutable-content": 1,
			"sound":           "default",
		},
		"webpush": map[string]any{
			"v":    1,
			"ce":   "aes128gcm",
			"k":    sourceTag(vapidKeyHash),
			"body": base64.StdEncoding.EncodeToString(body),
		},
	})
	if err != nil {
		return nil, err
	}
	if len(payload) > apnsMaxPayloadSize {
		return nil, errors.New("encrypted payload is too large for APNs; send with a Web Push record size of 2048 bytes or less")
	}
	return payload, nil
}

// sourceTag is base64url(SHA-256(VAPID public key)[:8]). The app computes the
// same value when it registers, mapping pushes back to the server that sent
// them without the relay revealing anything the server did not already sign.
func sourceTag(vapidKeyHash [32]byte) string {
	return base64.RawURLEncoding.EncodeToString(vapidKeyHash[:8])
}

// mapAPNsResult translates an APNs outcome into a Web Push (RFC 8030) status.
// 404/410 tell the sender to delete the subscription; 429/5xx are retryable.
func mapAPNsResult(result APNsResult, err error) (status int, retryAfter time.Duration, message string) {
	if err != nil {
		return http.StatusBadGateway, 30 * time.Second, "push gateway unavailable"
	}
	switch {
	case result.Status == http.StatusOK:
		return http.StatusCreated, 0, ""
	case result.Status == http.StatusGone,
		result.Reason == "BadDeviceToken",
		result.Reason == "DeviceTokenNotForTopic",
		result.Reason == "Unregistered",
		result.Reason == "ExpiredToken":
		return http.StatusGone, 0, "subscription is no longer valid"
	case result.Status == http.StatusRequestEntityTooLarge:
		return http.StatusRequestEntityTooLarge, 0, "payload too large"
	case result.Status == http.StatusTooManyRequests:
		return http.StatusTooManyRequests, time.Minute, "device is receiving too many notifications"
	case result.Status >= 500:
		return http.StatusServiceUnavailable, 30 * time.Second, "push gateway temporarily unavailable"
	default:
		// 400/403/405 not tied to the device token indicate relay
		// misconfiguration (bad topic, credentials). Ask senders to retry
		// rather than discarding valid subscriptions.
		return http.StatusBadGateway, 5 * time.Minute, "push relay is misconfigured"
	}
}

func apnsPriority(urgency string) (int, error) {
	switch strings.ToLower(strings.TrimSpace(urgency)) {
	case "", "normal", "high":
		return 10, nil
	case "low", "very-low":
		return 5, nil
	}
	return 0, errors.New("Urgency must be very-low, low, normal or high")
}

func validTopic(topic string) bool {
	if len(topic) > 32 {
		return false
	}
	for _, c := range topic {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '_') {
			return false
		}
	}
	return true
}

func validateAES128GCM(body []byte) error {
	if len(body) < aes128gcmHeaderSize+gcmTagSize+1 {
		return errors.New("payload is not a valid aes128gcm Web Push message")
	}
	rs := binary.BigEndian.Uint32(body[16:20])
	if rs < 18 || body[20] != 65 || body[21] != 0x04 {
		return errors.New("payload is not a valid aes128gcm Web Push message")
	}
	// The relay only forwards single-record messages, which is all Web Push uses.
	if uint32(len(body)-aes128gcmHeaderSize) > rs {
		return errors.New("payload must be a single aes128gcm record")
	}
	return nil
}

func (s *Server) acquireSendSlot() bool {
	select {
	case s.slots <- struct{}{}:
		return true
	default:
		return false
	}
}

func (s *Server) releaseSendSlot() {
	<-s.slots
}

func (s *Server) clientIP(r *http.Request) string {
	if s.ipHeader != "" {
		if v := strings.TrimSpace(r.Header.Get(s.ipHeader)); v != "" {
			first, _, _ := strings.Cut(v, ",")
			return strings.TrimSpace(first)
		}
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

// deviceLogID is a short, non-reversible identifier for log correlation.
func deviceLogID(token []byte) string {
	sum := sha256.Sum256(token)
	return hex.EncodeToString(sum[:6])
}

func writeRetryAfter(w http.ResponseWriter, wait time.Duration) {
	w.Header().Set("Retry-After", strconv.Itoa(int(math.Ceil(max(wait, time.Second).Seconds()))))
}

func writeError(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, map[string]string{"error": message})
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
