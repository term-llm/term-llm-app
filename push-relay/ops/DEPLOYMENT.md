# push.term-llm.com operator deployment (historical)

For the encrypted native push relay rollout, use [ENCRYPTED-DEPLOYMENT.md](ENCRYPTED-DEPLOYMENT.md), `encrypted-nginx.conf`, and `encrypted-term-llm-push.service`. The original operator command and configuration below are retained for reference/rollback, not the target for new native clients.

Initial rollout: 2026-10-21. This is an **operator-only relay**, not completed iOS notification integration. Do not distribute its shared bearer token with the app or to other server operators.

Build this service from the module directory with `go build -o term-llm-push ./cmd/term-llm-push`. The module-root command is now the separate encrypted Web Push relay and is not a drop-in replacement for this deployment. See [operator configuration and API](OPERATOR-RELAY.md).

## Host and layout

- Host: existing wasnotwas DigitalOcean droplet (`root@143.198.76.107`). Use the IP for SSH; the public hostname is Cloudflare-proxied.
- Service: `term-llm-push.service`, enabled at boot, running as the dedicated `term-llm-push` account.
- Listener: `127.0.0.1:8768`; no new public firewall port.
- Release layout: `/opt/term-llm-push/current -> releases/<release-id>/`. Each release contains the binary, a private source archive, and `SHA256SUMS`.
- Root-only source credentials: `/etc/term-llm-push/apns-key.p8` and `/etc/term-llm-push/relay-token`. No values belong in Git.
- The systemd unit loads these with `LoadCredential`, stages `0400` owner-readable runtime copies in a `0700` `/run/term-llm-push/`, and mounts the rest of the filesystem read-only. Runtime copies disappear on stop.
- Nginx: `/etc/nginx/sites-available/push.term-llm.com.conf`, linked from `sites-enabled`. `nginx-bootstrap.conf` and `nginx.conf` replace the **same** vhost file; do not enable both.
- TLS: `/etc/letsencrypt/live/push.term-llm.com/`, initially expiring 2027-01-19. ACME webroot `/var/www/term-llm-push/acme`; deploy hook `/etc/letsencrypt/renewal-hooks/deploy/reload-term-llm-push` tests/reloads nginx on certificate renewal.

## Apple environment

The supplied key is not usable against sandbox: the live sandbox negative probe returned Apple `403 BadEnvironmentKeyInToken`. Use `"environment":"production"` with this deployment's key. A production negative probe reached Apple and returned `400 BadDeviceToken` for a deliberately invalid token. This is not proof of delivery or complete app/topic/device authorization.

A development/sandbox app build will need a sandbox-capable Apple key. Never blindly switch an actual device token between environments; select the environment matching the signed app's `aps-environment` entitlement.

## Verification performed

- `gofmt`, `go vet`, all 38 tests with `go test -race`, and a static Linux/amd64 build passed.
- Public and direct-origin HTTPS `/healthz`: `200 {"status":"ok"}`.
- Missing/wrong bearer: `401`; valid bearer with invalid request: `400`; unknown path: `404`.
- Production invalid-token request through the public hostname: structured Apple `BadDeviceToken` rejection.
- Dedicated non-root process active/enabled, loopback listener only, no automatic restarts after the credential-staging correction.
- Neighboring wasnotwas, term-llm docs, and demo homepages remained HTTP 200.
- No real device token was used; no notification delivery or automatic completion alerts verified.

## Edge behavior

Cloudflare's existing Browser Integrity Check blocks the default Python urllib user agent with `403` / code `1010`; a descriptive `term-llm-push-smoke/1.0` user agent and Go's default user agent both passed. API clients should identify themselves. If universal client compatibility is required, disable Browser Integrity Check **only for this API hostname**, not the entire zone. No Cloudflare account settings were changed in this rollout.

Cloudflare can replace an origin `502` JSON response with HTML. Clients must treat non-JSON upstream errors as ambiguous failures, not delivery receipts, and must not blindly retry. A `502` was observed at the edge for the sandbox key rejection; the relay's loopback response retained Apple's actual reason.

## Operations

```sh
ssh root@143.198.76.107 'systemctl status term-llm-push.service --no-pager'
ssh root@143.198.76.107 'journalctl -u term-llm-push.service -n 30 --no-pager'
curl --fail https://push.term-llm.com/healthz
```

Build replacements outside the server, test first, upload a new release, verify checksums, atomically switch `current`, then `systemctl restart term-llm-push.service` and repeat the public health/auth smoke. Keep source archives root-readable only. On failure, switch back to a previously **verified working** release and restart; the first failed credential-layout attempt is not a known-good rollback target.

To disable sending immediately: `systemctl stop term-llm-push.service`. To rotate the bearer or Apple key, replace the root-only source file and restart. Neither key is hot-reloaded. Do not rotate/revoke the Apple key merely to clear an invalid device-token error.

The nginx template's 80-second upstream read timeout exceeds the maximum permitted 60-second APNs timeout plus server margin. The unit permits 256 tasks for the configurable concurrency range; deployed concurrency remains the default 16.
