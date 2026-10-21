# Encrypted relay migration: push.term-llm.com

The module-root command is the encrypted Web Push relay. The original operator command remains available under `cmd/term-llm-push`; its templates are `nginx.conf` and `term-llm-push.service`. **The commands and configuration are not interchangeable.**

## New deployment contract

- Build `CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -o term-llm-push .` inside `push-relay/`.
- Install `encrypted-term-llm-push.service` as `/etc/systemd/system/term-llm-push.service` and `encrypted-nginx.conf` as `/etc/nginx/sites-available/push.term-llm.com.conf`. Replace the existing files; do not enable both vhosts.
- The service keeps the dedicated unprivileged account and loopback `127.0.0.1:8768` listener. Existing certificate, ACME webroot, renewal hook and firewall rules are unchanged.
- Public routes are `GET /healthz`, `POST /v1/register`, and `POST /v1/push/<sealed-token>`. The old exact `/v1/push` operator route is deliberately closed.
- Set `RELAY_PUBLIC_URL=https://push.term-llm.com`; generated endpoints and VAPID audience use that origin.
- Persist the sealing keys in `/etc/term-llm-push/endpoint-token-keys` as `id:base64-32-byte-key[,id:old-key]`. Source directory `0700`, source file `0600`, root-owned. Keep a private backup; losing this file invalidates existing endpoints. Never regenerate on service restart.
- Supply `RELAY_TOKEN_KEYS_FILE`, not raw sealing-key values in the unit. APNs signing key stays in `/etc/term-llm-push/apns-key.p8`, read through `APNS_PRIVATE_KEY_FILE`.
- systemd `LoadCredential` source files are staged as owner-readable `0400` files in a private `0700` `/run/term-llm-push/`. This accommodates this host's `0440` credential mounts without weakening validation.
- The old `/etc/term-llm-push/relay-token` operator secret is unused by the encrypted service; retain it privately for rollback, never distribute it.

## Environment and abuse bounds

The supplied Apple key rejects sandbox (`BadEnvironmentKeyInToken` observed during the original rollout). The deployment explicitly sets `RELAY_APNS_ENVIRONMENTS=production`; unsupported development registration must fail before an endpoint is minted. A sandbox-capable key/appropriately configured separate development relay is required for Xcode-signed development builds. Do not send a development device token to production as a workaround.

Production defaults in the service template are a **global 60 outbound attempts/minute, burst 10, maximum 8 in flight**. These are process-wide, independent of invented device tokens or IP addresses. Existing per-device and per-registration-IP limits remain additional controls. No automatic APNs retry loop is added.

Registration remains public and is **not proof of app/device ownership**. VAPID binds a registered endpoint to the declared signing key; it is not app attestation. Global limits bound Apple traffic but an attacker may still exhaust the shared budget. Attestation/admission and capacity planning are separate work, not claimed complete here.

This host already has `/etc/nginx/conf.d/cloudflare-realip.conf` with trusted Cloudflare CIDRs. nginx overwrites `X-Relay-Client-IP` with its trusted/restored `$remote_addr`; the app trusts only that overwritten header. Do not expose the application port directly or trust caller-supplied forwarding headers. On another host, install a correctly scoped trusted-proxy configuration first, or accept socket-peer limits.

## Rollout and rollback

1. Test the new command; preserve the current symlink, unit, nginx config and private sealing key backup before changing anything.
2. Upload a new immutable release with the tested binary, source archive, checksums and source revision. Keep private source archives root-readable only.
3. Stage/verify the new unit (`systemd-analyze verify`) and nginx file (`nginx -t`). Atomically switch `current`, reload units, restart this service, reload nginx. Do not restart unrelated chat/hub services.
4. Check direct-origin and public TLS health, invalid registration, explicit development rejection, production endpoint registration, invalid VAPID rejection, rate/concurrency tests, and fixed-body Web Push flow against **fake APNs**. Treat actual Apple acceptance/physical-device delivery as separate evidence.
5. On failure, restore the previous unit, vhost and release symlink together, reload units, restart the relay and reload nginx. Restoring only the binary is insufficient because configuration/API changed.

Keep access logging disabled: sealed subscription URLs are capabilities. Do not print endpoints, signing keys, raw HTTP errors containing device tokens, or test request credentials into deployment logs. Retain the existing TLS renewal hook. Cloudflare's existing Browser Integrity Check may reject Python's default user agent; identified clients and Go passed the earlier checks. Cloudflare may also replace origin 502 JSON with HTML, so clients must handle non-JSON errors without blind duplicate sends.

## Companion core change

The native app requires a term-llm frontend that consumes `window.__termLLMNativePush` and reconciles on `termllm-native-push-change`. Both completion and explicit notification senders must use Web Push `RecordSize: 2048`; the default padded 4096-byte record cannot fit in APNs after base64 wrapping. The browser path must retain its normal service-worker flow.

The relay cannot verify iOS signing, shared-keychain entitlements, Notification Service Extension execution or physical lock-screen delivery. Those require the Apple build/device pipeline.
