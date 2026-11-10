# Encrypted relay deployment: push.term-llm.com

The module-root command is the encrypted Web Push relay. It replaced the earlier operator-only bearer-token relay at `push.term-llm.com`. That relay's source, unit and vhost templates were removed from this repository and remain in git history (last present at commit 87269e7). **Its configuration and API are not interchangeable with this relay's.**

## Deployment contract

- Build `CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -o term-llm-push .` inside `push-relay/`.
- Install `encrypted-term-llm-push.service` as `/etc/systemd/system/term-llm-push.service` and `encrypted-nginx.conf` as `/etc/nginx/sites-available/push.term-llm.com.conf`. Replace the existing files; never enable a second vhost for this server name.
- The service runs as the dedicated unprivileged `term-llm-push` account on the loopback `127.0.0.1:8768` listener. The certificate, ACME webroot, renewal hook and firewall rules (see [Host layout](#host-layout)) do not change between releases.
- Public routes are `GET /healthz`, `POST /v1/register`, and `POST /v1/push/<sealed-token>`. The old exact `/v1/push` operator route is deliberately closed.
- Set `RELAY_PUBLIC_URL=https://push.term-llm.com`; generated endpoints and VAPID audience use that origin.
- Persist the sealing keys in `/etc/term-llm-push/endpoint-token-keys` as `id:base64-32-byte-key[,id:old-key]`. Source directory `0700`, source file `0600`, root-owned. Keep a private backup; losing this file invalidates existing endpoints. Never regenerate on service restart.
- Supply `RELAY_TOKEN_KEYS_FILE`, not raw sealing-key values in the unit. APNs signing key stays in `/etc/term-llm-push/apns-key.p8`, read through `APNS_PRIVATE_KEY_FILE`.
- systemd `LoadCredential` source files are staged as owner-readable `0400` files in a private `0700` `/run/term-llm-push/`. This accommodates this host's `0440` credential mounts without weakening validation.
- The old `/etc/term-llm-push/relay-token` operator secret is unused by the encrypted service. Retain it privately while the operator release preserved on the host remains a rollback target; never distribute it.

## Host layout

- Host: the wasnotwas DigitalOcean droplet (`root@143.198.76.107`). Use the IP for SSH; the public hostname is Cloudflare-proxied.
- Service: `term-llm-push.service`, enabled at boot. It opens no public firewall port.
- Releases: `/opt/term-llm-push/current -> releases/<release-id>/`. Each release contains the binary, a private source archive and `SHA256SUMS`.
- nginx: `/etc/nginx/sites-available/push.term-llm.com.conf`, linked from `sites-enabled`. `nginx-bootstrap.conf` serves only ACME HTTP-01 challenges, so a new host can obtain its first certificate before the TLS vhost exists. It and `encrypted-nginx.conf` occupy the same vhost file; never enable both.
- TLS: `/etc/letsencrypt/live/push.term-llm.com/`, ACME webroot `/var/www/term-llm-push/acme`. `reload-push-certificate` is installed as the certbot deploy hook `/etc/letsencrypt/renewal-hooks/deploy/reload-term-llm-push`; it tests and reloads nginx when the certificate renews.

Status, recent logs and public health:

```sh
ssh root@143.198.76.107 'systemctl status term-llm-push.service --no-pager'
ssh root@143.198.76.107 'journalctl -u term-llm-push.service -n 30 --no-pager'
curl --fail https://push.term-llm.com/healthz
```

To stop sending immediately, run `systemctl stop term-llm-push.service`. Neither the APNs key nor the sealing keys are hot-reloaded: replace the root-only source file and restart (see the [README](../README.md) for sealing-key rotation). Do not rotate or revoke the Apple key merely to clear an invalid device-token error.

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
5. On failure, restore the previous unit, vhost and release symlink together, reload units, restart the relay and reload nginx. Restoring only the binary is insufficient when configuration or API changed, as they did between the operator relay and this one. Rollback uses only what step 1 preserved on the host, not this repository.

Keep access logging disabled: sealed subscription URLs are capabilities. Do not print endpoints, signing keys, raw HTTP errors containing device tokens, or test request credentials into deployment logs. Retain the existing TLS renewal hook. Cloudflare's existing Browser Integrity Check may reject Python's default user agent; identified clients and Go passed the earlier checks. If universal client compatibility is needed, disable it only for this hostname, not the whole zone. Cloudflare may also replace origin 502 JSON with HTML, so clients must handle non-JSON errors without blind duplicate sends.

## Companion core change

The native app requires a term-llm frontend that consumes `window.__termLLMNativePush` and reconciles on `termllm-native-push-change`. Both completion and explicit notification senders must use Web Push `RecordSize: 2048`; the default padded 4096-byte record cannot fit in APNs after base64 wrapping. The browser path must retain its normal service-worker flow.

The relay cannot verify iOS signing, shared-keychain entitlements, Notification Service Extension execution or physical lock-screen delivery. Those require the Apple build/device pipeline.
