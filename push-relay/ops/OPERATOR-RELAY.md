# term-llm native APNs push relay

A small, independent Go service that accepts authenticated notification requests and delivers them directly to Apple Push Notification service (APNs). It is intentionally narrower than a general push platform: one operator-managed APNs key, one fixed topic, one shared bearer credential, and two fixed Apple endpoints.

This command lives at `cmd/term-llm-push` within the `push-relay` Go module and uses only the standard library. It does **not** modify or integrate with the iOS app. The module-root encrypted Web Push relay is a separate command; see [its documentation](../README.md).

## Deployment boundary

This first version is **operator-only infrastructure**.

- The bearer credential in `RELAY_TOKEN_FILE` is a single global secret. Any holder can ask the relay to send to any device token for the fixed topic, in either sandbox or production.
- Never embed that credential in the iOS app, TestFlight configuration, a public repository, or a distributed self-hosted build. Do not give it to arbitrary users of other term-llm instances.
- Future app integration must use per-user/per-device provisioning, scoped credentials, revocation, and registration storage. That work is intentionally out of scope here.
- An APNs `.p8` key can be scoped by Apple to sandbox, production, or both, and that scope is not encoded in the file. The caller must explicitly choose the matching environment.
- APNs accepting a request is not proof that a phone received or displayed it. A physical-device test is still required for the intended release; simulator APNs support varies by host/Xcode combination and does not replace device verification.

The supplied `ops/` templates are the expected host layout: systemd runs the binary on loopback and nginx terminates TLS. They are deployment examples, not a substitute for reviewing the host's firewall, certificate, and secret permissions. See [deployment notes](DEPLOYMENT.md) for the current `push.term-llm.com` installation, production-only key, verification, and Cloudflare caveats.

## Build and test

Requires Go 1.25 or newer, as declared by the shared module (the operator APNs transport requires Go 1.24's HTTP/2-only `http.Protocols` API).

```sh
cd push-relay
gofmt -l .
go vet ./...
go test -race ./...
CGO_ENABLED=0 go build -trimpath -o term-llm-push ./cmd/term-llm-push
```

The operator command is `./cmd/term-llm-push`; the build output name above matches the systemd `ExecStart` path. `term-llm-push` loads and validates all configuration before listening; any configuration error is fatal. It logs only startup/shutdown and the listen address, never request headers, bodies, device tokens, or credentials.

## Configuration

All configuration is read from the environment at startup.

| Variable | Required | Meaning |
|---|---|---|
| `APNS_KEY_FILE` | yes | Path to the APNs provider auth key. Must be a PKCS#8 `PRIVATE KEY` PEM containing an ECDSA P-256 key. |
| `APNS_KEY_ID` | yes | Apple key identifier, 1–64 ASCII letters/digits. |
| `APNS_TEAM_ID` | yes | Apple team identifier, 1–64 ASCII letters/digits. |
| `APNS_TOPIC` | yes | Fixed APNs topic (normally the app bundle ID). Every request uses it; callers cannot override it. |
| `RELAY_TOKEN_FILE` | yes | Path to the shared bearer secret. 32–512 printable ASCII bytes, at least 8 distinct byte values. |
| `RELAY_ADDR` | no | Listen address. Default `127.0.0.1:8768`. An explicit host is required; use `0.0.0.0` only when remote exposure is intentional and protected. |
| `APNS_TIMEOUT` | no | Per-request APNs timeout, default `10s`, range `1s`–`60s`. |
| `RELAY_SHUTDOWN_TIMEOUT` | no | Graceful shutdown budget, default `10s`, range `1s`–`60s`. |
| `RELAY_MAX_CONCURRENCY` | no | Maximum simultaneous APNs calls, default `16`, range `1`–`128`. |

`APNS_KEY_FILE` and `RELAY_TOKEN_FILE` must be regular files with no group or other permission bits (`chmod 600` or `400`). The process refuses to start otherwise. Never commit either file.

The supplied systemd unit uses `LoadCredential=` to read root-only source files, then stages owner-readable `0400` copies in a private `0700` `RuntimeDirectory` under `/run/term-llm-push/`. This accommodates hosts that expose credential mounts as root-owned `0440` without weakening the relay's owner-only file validation. Runtime copies are removed when the service stops. The loader also accepts literal `%d/<single-file-name>` values resolved against `CREDENTIALS_DIRECTORY`, or already-resolved paths, for hosts where credential copies are owner-only.

Generate the shared secret with a cryptographic source:

```sh
umask 077
openssl rand -base64 48 > /etc/term-llm-push/relay-token
chmod 400 /etc/term-llm-push/relay-token
```

Put the Apple-provided `.p8` key at the path selected by `APNS_KEY_FILE` and make it owner-readable only. Rotating either the key or the relay token requires restarting the process; neither is hot-reloaded.

## HTTP API

The service exposes exactly two routes. Every other path returns `404`.

### `GET /healthz`

Returns `200` with `{"status":"ok"}` after configuration has loaded and the listener is running. It does not contact Apple, prove APNs credentials work, or prove that a notification can be delivered. It is intentionally unauthenticated; keep the listener on loopback or protect it at the proxy.

### `POST /v1/push`

```http
POST /v1/push HTTP/1.1
Authorization: Bearer <RELAY_TOKEN_FILE contents>
Content-Type: application/json

{
  "environment": "sandbox",
  "device_token": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  "title": "Build finished",
  "body": "Your task is ready.",
  "data": {
    "conversation_id": "abc123"
  }
}
```

Fields:

- `environment` — required, exactly `"sandbox"` or `"production"`. There is no implicit production fallback.
- `device_token` — required, hexadecimal, even length, between 32 and 512 characters. Apple documents device tokens as variable length and says not to assume a size, so the relay does not require 64 characters. The bound only prevents an unbounded URL path segment.
- `title`, `body` — required non-empty UTF-8 strings. They become `aps.alert.title` and `aps.alert.body`.
- `data` — optional JSON object. Its keys are merged into the top-level payload. The reserved key `aps` is rejected so callers cannot override alert/sound or other APNs controls.

The relay constructs:

```json
{
  "aps": {
    "alert": {"title": "...", "body": "..."},
    "sound": "default"
  },
  "...caller data keys..."
}
```

Request limits: 16 KiB total JSON body, 4096-byte final APNs payload, one JSON object with no unknown fields and no trailing JSON. `Content-Type` must be `application/json` (an optional `charset=utf-8` parameter is accepted).

Successful acceptance:

```http
HTTP/1.1 200 OK
Content-Type: application/json

{"status":"accepted","apns_status":200}
```

`accepted` means APNs returned a 2xx status. It is not a delivery receipt.

APNs rejections retain the upstream status and reason without exposing Apple URLs or authorization material:

```json
{
  "error": {
    "code": "apns_rejected",
    "message": "Apple Push Notification service rejected the request",
    "apns_status": 400,
    "reason": "BadDeviceToken",
    "device_invalid": true
  }
}
```

`device_invalid` is true for reasons such as `BadDeviceToken`, `DeviceTokenNotForTopic`, `Unregistered`, and `ExpiredToken`. Before removing any stored registration, verify that the request used the intended environment, topic, and APNs key: `BadDeviceToken` and `DeviceTokenNotForTopic` can indicate an environment/topic mismatch rather than a dead device token. Do not blindly retry the same request. Device-invalid rejections use `400`, except `Unregistered`, which uses `410`. Other APNs rejections use `502`, except Apple's `PayloadTooLarge`, which maps to `422`.

Other status codes:

| Status | Code | Meaning |
|---|---|---|
| `400` | `invalid_request`, `invalid_json`, `invalid_environment`, `invalid_device_token`, `invalid_data`, `reserved_data_key`, `invalid_payload` | Request validation failed; APNs was not called. |
| `401` | `unauthorized` | Missing or invalid bearer credential. |
| `404` | `not_found` | Route closed. |
| `405` | `method_not_allowed` | Wrong method; see `Allow`. |
| `413` | `request_too_large` | JSON body exceeded 16 KiB. |
| `415` | `unsupported_media_type` | Content type was not JSON. |
| `422` | `payload_too_large` | Final notification exceeded 4096 bytes. |
| `502` | `apns_rejected`, `apns_unavailable`, `upstream_failure` | APNs rejected the request or transport failed. |
| `503` | `relay_busy` | The configured concurrent APNs call limit is full. |
| `504` | `apns_timeout` | The APNs request exceeded `APNS_TIMEOUT`. |

Example:

```sh
read -r RELAY_TOKEN < /etc/term-llm-push/relay-token
curl -sS https://push.term-llm.com/v1/push \
  --header "Authorization: Bearer $RELAY_TOKEN" \
  --header "Content-Type: application/json" \
  --data '{
    "environment": "sandbox",
    "device_token": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    "title": "Build finished",
    "body": "Your task is ready."
  }'
```

## Delivery behavior and limitations

- The relay makes one application-level APNs request and does not retry after a rejection, timeout, or redirect. The Go HTTP/2 transport may transparently retry an HTTP/2 stream when it can prove the stream was not processed; this is still not an exactly-once delivery guarantee.
- `apns-expiration: 0` tells APNs to attempt immediate delivery only, without storing the notification for later. `apns-priority: 10`, `apns-push-type: alert`, and the fixed topic are always set by the relay.
- If a request times out or the connection fails after sending, delivery state is unknown. Retrying can duplicate a notification. Clients should not blindly retry ambiguous failures.
- The provider JWT is cached for 50 minutes in-process. APNs asks providers to refresh no more often than 20 minutes and no less than 60 minutes. A process restarted several times within 20 minutes may temporarily receive `TooManyProviderTokenUpdates`.
- The concurrency cap and rate behavior are per process. The nginx template also applies per-address limits; neither is a global delivery queue.
- No device registration, per-user authentication, delivery receipts, APNs collapse IDs, custom sounds, rich media, or token hot-reload are implemented.

## Verification

Tests do not call Apple. They use local TLS `httptest` servers for HTTP/2 and HTTP/1 protocol checks and a recording fake for the relay boundary. They cover:

- configuration loading, required values, private-file permissions, P-256/PKCS#8 validation, weak-token rejection, and `%d` credential paths;
- ES256 JWT header/claims/raw `r||s` signature verification, 50-minute caching, and concurrent caching;
- APNs request headers, payload, topic, device-token path, JWT verification, timeout/no-retry behavior, APNs rejection mapping, payload bounds, and HTTP/2 enforcement;
- health routing, constant-time bearer rejection before body parsing, strict JSON/content-type/token validation, unknown and trailing fields, payload and body bounds, concurrency limiting, sanitized upstream errors, and APNs error mapping.

Run `go test -race ./...` from this directory.
