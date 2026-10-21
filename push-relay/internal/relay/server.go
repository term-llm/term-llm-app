// Package relay implements the minimal authenticated HTTP boundary in front of
// Apple Push Notification service. It owns strict request validation, bearer
// authentication, concurrency limiting, and sanitized error mapping.
package relay

import (
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime"
	"net/http"
	"strings"
	"time"

	"github.com/SamSaffron/term-llm-app/push-relay/internal/apns"
)

const (
	DefaultMaxBodyBytes  int64 = 16 << 10
	DefaultAPNSTimeout         = 10 * time.Second
	DefaultMaxConcurrent       = 16
)

// Pusher is the outbound APNs boundary. *apns.Client is the production
// implementation; tests use a recording fake.
type Pusher interface {
	Send(ctx context.Context, environment apns.Environment, deviceToken string, payload []byte) (apns.Result, error)
}

// Options bounds relay work. Zero values receive conservative defaults.
type Options struct {
	MaxConcurrent int
	APNSTimeout   time.Duration
	MaxBodyBytes  int64
}

// Server is the complete HTTP handler. It exposes GET /healthz and
// POST /v1/push and closes every other route.
type Server struct {
	pusher       Pusher
	tokenHash    [32]byte
	sem          chan struct{}
	apnsTimeout  time.Duration
	maxBodyBytes int64
}

func New(pusher Pusher, token []byte, options Options) (*Server, error) {
	if pusher == nil {
		return nil, fmt.Errorf("relay requires a pusher")
	}
	if len(token) == 0 {
		return nil, fmt.Errorf("relay requires a non-empty bearer token")
	}
	if options.MaxConcurrent <= 0 {
		options.MaxConcurrent = DefaultMaxConcurrent
	}
	if options.APNSTimeout <= 0 {
		options.APNSTimeout = DefaultAPNSTimeout
	}
	if options.MaxBodyBytes <= 0 {
		options.MaxBodyBytes = DefaultMaxBodyBytes
	}

	return &Server{
		pusher:       pusher,
		tokenHash:    sha256.Sum256(token),
		sem:          make(chan struct{}, options.MaxConcurrent),
		apnsTimeout:  options.APNSTimeout,
		maxBodyBytes: options.MaxBodyBytes,
	}, nil
}

func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	switch r.URL.Path {
	case "/healthz":
		if r.Method != http.MethodGet {
			w.Header().Set("Allow", http.MethodGet)
			writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
			return
		}
		writeJSON(w, http.StatusOK, struct {
			Status string `json:"status"`
		}{Status: "ok"})
	case "/v1/push":
		if r.Method != http.MethodPost {
			w.Header().Set("Allow", http.MethodPost)
			writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
			return
		}
		s.handlePush(w, r)
	default:
		writeError(w, http.StatusNotFound, "not_found", "not found")
	}
}

type pushRequest struct {
	Environment string          `json:"environment"`
	DeviceToken string          `json:"device_token"`
	Title       string          `json:"title"`
	Body        string          `json:"body"`
	Data        json.RawMessage `json:"data"`
}

type pushResponse struct {
	Status     string `json:"status"`
	APNSStatus int    `json:"apns_status"`
}

func (s *Server) handlePush(w http.ResponseWriter, r *http.Request) {
	if !s.authorized(r) {
		w.Header().Set("WWW-Authenticate", `Bearer realm="push-relay"`)
		writeError(w, http.StatusUnauthorized, "unauthorized", "missing or invalid bearer token")
		return
	}
	if status, code, message := validateContentType(r.Header.Get("Content-Type")); status != 0 {
		writeError(w, status, code, message)
		return
	}
	if r.ContentLength > s.maxBodyBytes {
		writeError(w, http.StatusRequestEntityTooLarge, "request_too_large", "request body is too large")
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, s.maxBodyBytes)
	defer r.Body.Close()

	var request pushRequest
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&request); err != nil {
		status, code, message := bodyError(err)
		writeError(w, status, code, message)
		return
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		writeError(w, http.StatusBadRequest, "invalid_json", "request body must contain exactly one JSON object")
		return
	}

	environment, err := apns.ParseEnvironment(request.Environment)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_environment", `environment must be "sandbox" or "production"`)
		return
	}
	if err := apns.ValidateDeviceToken(request.DeviceToken); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_device_token", "device_token must be even-length hexadecimal within the documented bounds")
		return
	}
	if strings.TrimSpace(request.Title) == "" || strings.TrimSpace(request.Body) == "" {
		writeError(w, http.StatusBadRequest, "invalid_request", "title and body are required")
		return
	}

	data, err := decodeData(request.Data)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_data", "data must be a single JSON object")
		return
	}
	payload, err := apns.BuildPayload(request.Title, request.Body, data)
	switch {
	case errors.Is(err, apns.ErrPayloadTooLarge):
		writeError(w, http.StatusUnprocessableEntity, "payload_too_large", fmt.Sprintf("notification payload exceeds %d bytes", apns.MaxPayloadBytes))
		return
	case errors.Is(err, apns.ErrReservedPayloadKey):
		writeError(w, http.StatusBadRequest, "reserved_data_key", `data must not contain the reserved key "aps"`)
		return
	case err != nil:
		writeError(w, http.StatusBadRequest, "invalid_payload", "notification payload is invalid")
		return
	}

	select {
	case s.sem <- struct{}{}:
		defer func() { <-s.sem }()
	default:
		writeError(w, http.StatusServiceUnavailable, "relay_busy", "relay is at its concurrent APNs limit")
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), s.apnsTimeout)
	defer cancel()

	result, err := s.pusher.Send(ctx, environment, request.DeviceToken, payload)
	if err != nil {
		writeUpstreamError(w, err)
		return
	}

	writeJSON(w, http.StatusOK, pushResponse{
		Status:     "accepted",
		APNSStatus: result.Status,
	})
}

func (s *Server) authorized(r *http.Request) bool {
	values := r.Header.Values("Authorization")
	if len(values) != 1 {
		return false
	}
	fields := strings.Fields(values[0])
	if len(fields) != 2 || !strings.EqualFold(fields[0], "bearer") {
		return false
	}
	candidate := sha256.Sum256([]byte(fields[1]))
	return subtle.ConstantTimeCompare(candidate[:], s.tokenHash[:]) == 1
}

func validateContentType(value string) (status int, code, message string) {
	mediaType, parameters, err := mime.ParseMediaType(value)
	if err != nil || mediaType != "application/json" {
		return http.StatusUnsupportedMediaType, "unsupported_media_type", "content type must be application/json"
	}
	for key, parameter := range parameters {
		if strings.EqualFold(key, "charset") && strings.EqualFold(parameter, "utf-8") {
			continue
		}
		return http.StatusUnsupportedMediaType, "unsupported_media_type", "content type must be application/json"
	}
	return 0, "", ""
}

func decodeData(raw json.RawMessage) (map[string]json.RawMessage, error) {
	if len(raw) == 0 {
		return nil, nil
	}
	if bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
		return nil, fmt.Errorf("data is null")
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	var data map[string]json.RawMessage
	if err := decoder.Decode(&data); err != nil || data == nil {
		return nil, fmt.Errorf("data is not an object")
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return nil, fmt.Errorf("data contains trailing JSON")
	}
	return data, nil
}

func bodyError(err error) (status int, code, message string) {
	var tooLarge *http.MaxBytesError
	if errors.As(err, &tooLarge) {
		return http.StatusRequestEntityTooLarge, "request_too_large", "request body is too large"
	}
	if errors.Is(err, io.EOF) {
		return http.StatusBadRequest, "invalid_json", "request body is required"
	}
	return http.StatusBadRequest, "invalid_json", "request body must be a single JSON object with no unknown fields"
}

type errorResponse struct {
	Error errorDetail `json:"error"`
}

type errorDetail struct {
	Code          string `json:"code"`
	Message       string `json:"message,omitempty"`
	APNSStatus    int    `json:"apns_status,omitempty"`
	Reason        string `json:"reason,omitempty"`
	DeviceInvalid *bool  `json:"device_invalid,omitempty"`
}

func writeUpstreamError(w http.ResponseWriter, err error) {
	var rejection *apns.RejectError
	if errors.As(err, &rejection) {
		reason := safeReason(rejection.Reason)
		status := http.StatusBadGateway
		if rejection.DeviceInvalid {
			status = http.StatusBadRequest
			if reason == "Unregistered" {
				status = http.StatusGone
			}
		} else if rejection.Status == http.StatusRequestEntityTooLarge || reason == "PayloadTooLarge" {
			status = http.StatusUnprocessableEntity
		}
		deviceInvalid := rejection.DeviceInvalid
		writeErrorDetail(w, status, errorDetail{
			Code:          "apns_rejected",
			Message:       "Apple Push Notification service rejected the request",
			APNSStatus:    rejection.Status,
			Reason:        reason,
			DeviceInvalid: &deviceInvalid,
		})
		return
	}

	var transport *apns.TransportError
	if errors.As(err, &transport) {
		if transport.Timeout {
			writeError(w, http.StatusGatewayTimeout, "apns_timeout", "Apple Push Notification service request timed out")
			return
		}
		writeError(w, http.StatusBadGateway, "apns_unavailable", "Apple Push Notification service request failed")
		return
	}

	switch {
	case errors.Is(err, context.DeadlineExceeded):
		writeError(w, http.StatusGatewayTimeout, "apns_timeout", "Apple Push Notification service request timed out")
	case errors.Is(err, apns.ErrInvalidDeviceToken):
		writeError(w, http.StatusBadRequest, "invalid_device_token", "device_token is invalid")
	case errors.Is(err, apns.ErrPayloadTooLarge):
		writeError(w, http.StatusUnprocessableEntity, "payload_too_large", fmt.Sprintf("notification payload exceeds %d bytes", apns.MaxPayloadBytes))
	case errors.Is(err, apns.ErrInvalidPayload):
		writeError(w, http.StatusBadRequest, "invalid_payload", "notification payload is invalid")
	case errors.Is(err, apns.ErrInvalidEnvironment):
		writeError(w, http.StatusBadRequest, "invalid_environment", "environment is invalid")
	default:
		writeError(w, http.StatusBadGateway, "upstream_failure", "notification could not be sent to Apple Push Notification service")
	}
}

func writeError(w http.ResponseWriter, status int, code, message string) {
	writeErrorDetail(w, status, errorDetail{Code: code, Message: message})
}

// safeReason mirrors the allow-list applied by the APNs client. Keeping this
// check at the HTTP boundary means a malformed or future pusher error can never
// inject arbitrary text into a response.
func safeReason(reason string) string {
	if len(reason) == 0 || len(reason) > 64 {
		return ""
	}
	for i := 0; i < len(reason); i++ {
		c := reason[i]
		if (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-' {
			continue
		}
		return ""
	}
	return reason
}

func writeErrorDetail(w http.ResponseWriter, status int, detail errorDetail) {
	writeJSON(w, status, errorResponse{Error: detail})
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	encoded, err := json.Marshal(value)
	if err != nil {
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.WriteHeader(status)
	_, _ = w.Write(append(encoded, '\n'))
}
