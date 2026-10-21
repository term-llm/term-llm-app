# term-llm push relay

This module provides two separate commands: the encrypted Web Push relay described below (`go build .`), and the existing operator-only bearer-authenticated relay (`go build -o term-llm-push ./cmd/term-llm-push`). The latter retains its original configuration and API; see [operator relay documentation](ops/OPERATOR-RELAY.md) and [existing deployment notes](ops/DEPLOYMENT.md). The `ops/` systemd and nginx templates target that operator command, not the encrypted relay. Do not replace the deployed operator binary with the module-root command without migrating its configuration and proxy routes.

A small Go service that lets self-hosted term-llm servers send native iOS notifications to the term-llm app.

Only the holder of the app's APNs key can push to it, and that key cannot be shipped to self-hosted servers. The app therefore registers a Web Push subscription whose endpoint is this relay. term-llm sends ordinary encrypted Web Push (RFC 8030/8291/8292) to that endpoint, exactly as it does for browsers. The relay forwards the still-encrypted body to APNs. The app's Notification Service Extension decrypts it on the device.

```
term-llm server ──Web Push (aes128gcm, VAPID)──▶ relay /v1/push/<token> ──APNs (HTTP/2)──▶ iPhone ─▶ NSE decrypts
```

The relay cannot read notification content and stores no per-device state. The device token, APNs environment and the server's VAPID key are sealed (AES-256-GCM) into the endpoint token. The binary uses only the Go standard library. `webpush-go` is a test-only dependency.

## API

### `POST /v1/register`

Called by the app.

```json
{
  "device_token": "<hex APNs device token>",
  "environment": "production | development",
  "application_server_key": "<term-llm VAPID public key, base64url>"
}
```

Returns `200 {"endpoint": "https://push.example.com/v1/push/<token>", "environment": "..."}`.

- **environment:** `development` is only for builds signed with a development profile (run from Xcode). TestFlight, App Store and Ad Hoc builds are `production`. Read it from the `aps-environment` entitlement.
- **application_server_key:** the same key the web UI passes to `pushManager.subscribe`. The endpoint only accepts pushes signed by that key, so one endpoint belongs to one term-llm server.
- **Deterministic endpoint:** the same inputs always return the same endpoint. term-llm upserts subscriptions by endpoint, so the app can re-register on every launch without creating duplicates.
- **Subscribing:** the app then subscribes to term-llm with the existing API. It sends this `endpoint` plus its own `p256dh` key and `auth` secret, both generated and kept on the device.

### `POST /v1/push/{token}`

Called by term-llm, using any Web Push library. The request must have:

- `Authorization: vapid t=<jwt>, k=<key>`, with `aud` equal to the relay origin, `exp` no more than 24 hours ahead, and `k` matching the registered key.
- `Content-Encoding: aes128gcm`.
- A `TTL` header.
- A single-record body of at most 4096 bytes. In practice it must be smaller to fit in an APNs payload; see [Required term-llm change](#required-term-llm-change).

Optional headers:

- **`Urgency`:** `very-low` and `low` map to `apns-priority: 5`; everything else to `10`.
- **`Topic`:** becomes `apns-collapse-id`.
- **`TTL`:** becomes `apns-expiration` (0 means deliver now or drop), capped at 28 days.

| Status | Meaning for the sender |
| --- | --- |
| 201 | Accepted by APNs. `Location` holds the message URL. |
| 400 / 415 | Malformed request (bad headers, not aes128gcm). |
| 401 / 403 | VAPID missing or invalid / signed by a key other than the registered one. |
| 404 | Unknown or undecryptable token. Delete the subscription. |
| 410 | APNs says the device token is gone (`Unregistered`, `BadDeviceToken`, `DeviceTokenNotForTopic`). Delete the subscription. |
| 413 | Payload too large for APNs. |
| 429 | Rate limited, per device or by APNs. Honour `Retry-After`. |
| 502 / 503 | APNs unreachable or relay misconfigured. Retry after `Retry-After`. |

term-llm already marks subscriptions stale on 404/410 and retries everything else with backoff.

### `GET /healthz`

Returns `ok`.

## APNs payload (contract for the Notification Service Extension)

```json
{
  "aps": {
    "alert": { "title": "term-llm", "body": "New notification" },
    "mutable-content": 1,
    "sound": "default"
  },
  "webpush": { "v": 1, "ce": "aes128gcm", "k": "<source tag>", "body": "<standard base64 of the Web Push body>" }
}
```

`k` identifies the sending server: `base64url(SHA-256(VAPID public key)[:8])`, unpadded. The app computes the same tag when it registers, so it can map a push back to the server (and hub node) that sent it.

The alert is a placeholder shown only if the extension fails or times out. To build the real notification, the extension:

1. Base64-decodes `webpush.body`. It is laid out as `salt(16) | rs(4) | idlen(1)=65 | as_public(65) | ciphertext`.
2. Computes `ecdh = ECDH(ua_private, as_public)`.
3. Derives the keys:
   - `IKM = HKDF-SHA256(salt=auth_secret, ikm=ecdh, info="WebPush: info\0" || ua_public || as_public, 32)`
   - `CEK = HKDF(salt=salt, ikm=IKM, info="Content-Encoding: aes128gcm\0", 16)`
   - `NONCE = HKDF(salt=salt, ikm=IKM, info="Content-Encoding: nonce\0", 12)`
4. Decrypts with AES-128-GCM (CEK, NONCE). It strips trailing `0x00` bytes, then the `0x02` delimiter.
5. Parses the resulting term-llm JSON. Completion pushes carry `title`, `body`, `url`, `session_id`, `outcome` and `event_id`. `term-llm notify` sends `title` and `body`. The extension sets the notification's title and body, a `threadIdentifier` (the session), and stores `url` so a tap opens that chat.

`decryptWebPush` in `helpers_test.go` is a working reference, and `TestWebPushGoEndToEnd` checks it against `webpush-go`.

## Required term-llm change

`webpush-go` pads every message to its record size, which defaults to 4096 bytes. In base64 that is 5462 characters, more than the 4096-byte APNs limit. The relay returns 413 for such messages rather than truncating them. term-llm must send with `webpush.Options{RecordSize: 2048}` (in `serve_completion_push.go` and `notify/webpush.go`). That still leaves about 1.9 KB for the JSON message and works for browser push services too.

## Configuration

| Variable | Required | Description |
| --- | --- | --- |
| `RELAY_PUBLIC_URL` | yes | Public origin, e.g. `https://push.term-llm.com`. Used in endpoints and as the VAPID `aud`. HTTPS only (HTTP is allowed for loopback). No path. |
| `RELAY_TOKEN_KEYS` | yes | `id:base64(32 bytes)[,id:base64...]`. The first key seals new endpoints; all listed keys open existing ones. Generate with `push-relay genkey`. |
| `APNS_KEY_ID` | yes | Key ID of the APNs auth key. |
| `APNS_TEAM_ID` | yes | Apple Developer Team ID (`B6BAJ46A72`). |
| `APNS_PRIVATE_KEY` / `APNS_PRIVATE_KEY_FILE` | yes | Contents of the `.p8` file (PEM, or base64 of the PEM), or a path to it. |
| `APNS_TOPIC` | no | App bundle ID. Default `com.termllm.app`. |
| `PORT` / `RELAY_LISTEN_ADDR` | no | Listen on `:$PORT`, or an explicit address. Default `:8080`. |
| `RELAY_CLIENT_IP_HEADER` | no | Trusted proxy header for the client IP (`Fly-Client-IP`, `CF-Connecting-IP`). Only set it behind such a proxy. |
| `RELAY_PUSH_BURST` / `RELAY_PUSH_PER_MINUTE` | no | Per-device token bucket. Default 30 / 20. |
| `RELAY_REGISTER_BURST` / `RELAY_REGISTER_PER_MINUTE` | no | Per-IP registration bucket. Default 20 / 10. |
| `RELAY_ALERT_TITLE` / `RELAY_ALERT_BODY` | no | Placeholder alert text. |

Missing or invalid settings are all reported at startup and the process exits.

## Deploying

1. **APNs key:** in the Apple Developer portal go to Certificates, IDs & Profiles → Keys. Create a key with *Apple Push Notifications service (APNs)* enabled and download the `.p8` (it can only be downloaded once). One key covers both sandbox and production. Also enable the Push Notifications capability on the `com.termllm.app` App ID.
2. **Token key:** run `go run . genkey` (or `docker run --rm <image> genkey`). Store `RELAY_TOKEN_KEYS` as a secret and keep a backup. Losing it invalidates every endpoint; devices recover when the app re-registers, and servers drop the old subscriptions on 404.
3. **Run the image:**

   ```sh
   docker build -t term-llm-push-relay push-relay
   docker run -p 8080:8080 \
     -e RELAY_PUBLIC_URL=https://push.term-llm.com \
     -e RELAY_TOKEN_KEYS=... -e APNS_KEY_ID=... -e APNS_TEAM_ID=B6BAJ46A72 \
     -e APNS_PRIVATE_KEY="$(cat AuthKey_XXXX.p8)" \
     term-llm-push-relay
   ```

4. **TLS:** terminate TLS in front of the relay. Use `/healthz` as the health check.

Rate limits are kept in memory per instance. Run one instance, or accept that limits are per instance. Logs are JSON on stdout. Devices appear only as a short hash, and payloads are never logged.

**Rotating the token key:** prepend a new key (`2:new,1:old`). New registrations use key 2 and old endpoints keep working. Remove key 1 once the apps have re-registered.

## Development

```sh
cd push-relay
go test -race ./...
```
