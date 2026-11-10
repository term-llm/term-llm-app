# Self-hosted MacBook CI

## Financial boundary

Every job in `.github/workflows/` uses exactly:

```yaml
runs-on: [self-hosted, macOS, ARM64, term-llm-local]
```

The only exception is a job that calls this repository's own reusable workflow (`uses: ./.github/workflows/…`); the called workflow's job declares that runner.

There is no hosted fallback, setup-go Actions cache, or artifact upload. The notarized Mac build's only upload is its GitHub release asset, which is not Actions artifact storage. Offline runners leave jobs queued. This prevents these workflows from consuming GitHub-hosted runner minutes; it does not clear existing billable storage or change account billing settings. Set a GitHub Actions budget with usage blocked at the limit as an independent safety net where supported by your account.

Repository changes must be pushed to take effect. Check other branches and GitHub's Actions workflow list too: older workflows can remain runnable on refs that still contain hosted-runner configurations. Do not rerun historical hosted jobs to test the migration. Retired native-Hub, phone-Hub, and peer-connect capture workflows should stay unused/disabled; do not restore user journeys.

## One-time registration

Use a dedicated directory outside your development checkout. The official macOS ARM64 runner package was downloaded and SHA-256 verified in `~/actions-runner-term-llm`, but **registration and service startup were not completed by the agent**.

Run these commands yourself in Terminal (requires repository administration permission through `gh`):

```sh
cd "$HOME/actions-runner-term-llm"
# Short-lived token: do not paste it into files, logs, or chat.
token="$(gh api --method POST repos/SamSaffron/term-llm-app/actions/runners/registration-token --jq .token)"
./config.sh --unattended \
  --url https://github.com/SamSaffron/term-llm-app \
  --token "$token" \
  --name term-llm-macbook \
  --labels term-llm-local \
  --work _work
unset token
./svc.sh install
./svc.sh start
./svc.sh status
```

Install only once. Service installation creates a per-user LaunchAgent; stay logged in. Alternatively use `./run.sh` in a foreground Terminal instead of installing a service. The runner checks out jobs into its own `_work` directory, not your development checkout. One registered agent runs one job at a time.

Verify **Settings → Actions → Runners** shows `term-llm-macbook` online with the custom label. Self-hosted code runs with the runner user's permissions. A private repository is not a sandbox: only trusted collaborators/branches should execute here. The automatic job rejects fork PRs, uses read-only contents permission, and does not persist checkout credentials. Manual runs must also target trusted refs. Prefer a dedicated macOS account without personal secrets for stronger isolation.

## Installed tools

- Selected Xcode (`xcode-select -p`), an iOS SDK compatible with the app, and an available iPhone simulator.
- Python >=3.11, Go matching `push-relay/go.mod`, and Node.
- `scripts/ci/bootstrap-macos.sh` supplies Homebrew/mise PATH entries for noninteractive runner shells and selects modern Python instead of Apple's Python 3.9. Tools are installed locally, not downloaded or cached by Actions.

Native checks use unsigned simulator builds and unique temporary build/result directories, then clean them up. Failures remain visible in streamed job logs; no xcresult or recording is uploaded. No CI-wide simulator shutdown or erase is performed, so developer simulators are not deliberately reset.

## Menu-bar status (SwiftBar)

SwiftBar is installed in `~/Applications/SwiftBar.app`. The `term-llm-ci.1m.py` plugin shows:

- **CI 🟢**: GitHub reports the runner online and idle.
- **CI 🟠**: online and busy running a job.
- **CI 🔴**: offline or missing from the repository runner list.
- **CI ⚠️**: GitHub status unavailable (network/authentication problem), not a claim that the runner stopped.

The menu includes local LaunchAgent status, five recent repository runs with links, runner diagnostics, and start/stop service controls. Stop requires confirmation because it may interrupt work. Recent runs are repository-wide history and can include old hosted runs; they are not all necessarily jobs executed by this Mac. Polling is read-only, once per minute, using your existing `gh` login; it never dispatches workflows or registers runners. No tokens are saved in the plugin.

Enable **Launch at Login** in SwiftBar settings to bring the menu back after login. This is separate from the runner's own LaunchAgent: quitting SwiftBar does not stop CI.

To reinstall/update the plugin from this checkout:

```sh
bash scripts/swiftbar/install-plugin.sh
```

The installer preserves any existing SwiftBar plugin-folder preference and copies only this plugin. With no configured folder, it uses `~/Library/Application Support/SwiftBar/Plugins`. The plugin uses Python 3.9+ and the installed GitHub CLI, with no third-party Python packages. It does not change GitHub billing settings.

Offline tests: `python3 -m unittest discover -s scripts/ci -p 'test_*.py' -v`.

## Daily workflow

1. Keep the Mac awake, online, and logged in with the runner active. For a foreground session, `caffeinate -i ./run.sh` can prevent idle system sleep while the agent runs (it does not make closed-lid operation reliable).
2. Push a trusted branch/open or update a PR. Relevant changes trigger `Lightweight checks / checks` here.
3. Inspect the PR's check logs. Fix failures and push again normally.
4. For app/extension build and simulator unit coverage, use **Actions → Native notification checks (manual local Mac)** (focused) or **Native unit tests (manual local Mac)** (every `TermLLMTests` suite) **→ Run workflow** after the workflow is registered on the default branch. No UI journeys run. See [Test plans and manual workflows](#test-plans-and-manual-workflows).
5. Stop/start the service with `./svc.sh stop` / `./svc.sh start` from the runner directory as needed. Offline means queued, not paid fallback.

Before calling migration complete, push the new workflows, verify no active workflow still targets `ubuntu-*`, `macos-*`, or `windows-*` hosted labels, and get a fresh PR run showing `term-llm-macbook` as its runner. If old required checks block merging, adjust branch rules to the intended current checks. Path-filtered checks need special handling if required on docs-only PRs.

## Test plans and manual workflows

`Lightweight checks / checks` runs the portable Python checks, the notification contract, the push relay, and `swift test` for `TermLLMMacKit` (temporary homes, fake command runners and stubbed HTTP; about 12 seconds from a cold build). It never builds the iOS app or boots a simulator, and keeps its 10-minute limit. Everything else is manual (**Actions → workflow → Run workflow**, from a trusted ref):

| Workflow | Runs |
| --- | --- |
| **Native notification checks (manual local Mac)** | test plan `TermLLM-Notifications` on a job-owned simulator |
| **Linked devices native validation** | test plan `TermLLM-LinkedDevices` on a job-owned simulator |
| **Native unit tests (manual local Mac)** | test plan `TermLLM-UnitTests` (every `TermLLMTests` suite, no UI tests) on a job-owned simulator |
| **ComputerUseKit tests (manual local Mac)** | `swift build` and `swift test` in `ComputerUseKit` |
| **Mac app tests (manual local Mac)** | `TermLLMMacTests` through the `TermLLMMac` scheme; the unsigned app opens its windows on the runner's desktop |

The three native workflows only name a test plan and call `native-simulator-tests.yml`, which creates, boots and deletes one job-owned simulator with `scripts/ci/owned-ios-simulator.py` and runs `xcodebuild test -testPlan <plan>` once. ComputerUseKit stays out of the automatic job: its tests exercise the accessibility, input-event, screen-capture, pasteboard and permission code through injected fakes whose defaults are the live system calls.

Suite selections live in `TestPlans/*.xctestplan`, referenced from the shared `TermLLM` scheme, not in workflow YAML:

- `TermLLM` (default): `TermLLMTests` and `TermLLMUITests`, as before. `xcodebuild test -scheme TermLLM` and `-only-testing:TermLLMTests/<Suite>` work unchanged.
- `TermLLM-Notifications` and `TermLLM-LinkedDevices`: the suites these workflows used to list with `-only-testing`.
- `TermLLM-UnitTests`: all of `TermLLMTests`, including the live suites. `PushLiveE2ETests` and `WebMCPLiveServerTests` skip themselves unless their `TERMLLM_*` variables reach the test runner (pass them to xcodebuild as `TEST_RUNNER_TERMLLM_*`; CI sets none). `WebKitHealthLiveTests`, `LiveHangUpTests` and `LinkedDevicesLiveWebKitTests` use only local HTML strings and loopback servers and always run.

Run a plan locally with, for example:

```sh
xcodebuild test -project TermLLM.xcodeproj -scheme TermLLM -testPlan TermLLM-Notifications \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO
```

Edit selections in Xcode's test plan editor or in the JSON. `scripts/ci/test_workflows.py` checks the plans against the scheme, the project's targets and the suites in `TermLLMTests/`, and keeps the simulator and Mac test workflows manual.

## Notarized Mac builds

**Notarized Mac build** (`.github/workflows/notarized-mac-build.yml`) runs here for every push to `main` that changes the app, and on manual dispatch from `main`. It archives the `TermLLMMac` scheme in Release with Developer ID signing, exports and verifies it, notarizes and staples it, checks that Gatekeeper accepts it, then creates a release `mac-v<version>` with `term-llm-macos-<version>.zip`, marked Latest. CI automatically increments the patch version within the project's `MARKETING_VERSION` major/minor: `1.0.1`, `1.0.2`, and so on. To start a new minor series, manually change `MARKETING_VERSION` to `1.1` in both project configurations in `TermLLM.xcodeproj/project.pbxproj`; the next release is `1.1.1`. CI reads published GitHub Mac releases and, after authenticating it, the website appcast to choose the next patch, ignores drafts, prereleases and the legacy `mac-v1.0-2` naming, and applies the version to both app and extension through its temporary xcconfig. It does not commit version bumps back to Git or change iOS versions. Failed/cancelled builds do not consume a patch; manual reruns after a successful publication get the next patch. The internal build number remains the workflow run number. Releases of this private repository are visible to its collaborators only. The same stapled ZIP is EdDSA-signed for Sparkle and published with a signed appcast to `https://term-llm.com/mac/` before the private GitHub release; see [Sparkle updates](#sparkle-updates). **The website downloads are public.**

One-time setup:

1. **Signing secrets in 1Password.** The Developer ID certificate and notary key stay in 1Password; the job reads them with `op read`. A service account cannot read a Private vault, so they live in a `term-llm CI` vault, under titles that 1Password secret references can name (letters, digits, spaces, `.`, `_`, `-`). A read-only service account for that vault is the only GitHub secret; `--raw` sends its token straight to GitHub without displaying it:

   ```sh
   acct=my.1password.com
   op vault create "term-llm CI" --account $acct
   op item move "term-llm CI: Developer ID Application (sam saffron, B6BAJ46A72)" \
     --current-vault Private --destination-vault "term-llm CI" --account $acct
   op item move "term-llm CI: App Store Connect notary key (94WH5NUQB4)" \
     --current-vault Private --destination-vault "term-llm CI" --account $acct
   op item edit "term-llm CI: Developer ID Application (sam saffron, B6BAJ46A72)" \
     --vault "term-llm CI" --title "Developer ID Application" --account $acct
   op item edit "term-llm CI: App Store Connect notary key (94WH5NUQB4)" \
     --vault "term-llm CI" --title "App Store Connect notary key" --account $acct
   op service-account create "term-llm-app CI" --vault "term-llm CI:read_items" --raw --account $acct \
     | gh secret set OP_SERVICE_ACCOUNT_TOKEN -R SamSaffron/term-llm-app
   ```

   The workflow's `MACOS_*_REF` values name the fields: `developer-id.p12` and `password` on **Developer ID Application**; `AuthKey_94WH5NUQB4.p8`, `key id` and `issuer id` on **App Store Connect notary key**. Update them if you rename an item or rotate the notary key. The runner needs the 1Password CLI (`op`) installed; it does not use your own 1Password sign-in. Revoking the service account in 1Password cuts off CI.

2. **Developer ID provisioning profiles.** The app's push, app-group and shared-keychain entitlements need them (a bare CLI binary does not, which is why term-llm has none). In Certificates, Identifiers & Profiles choose **Profiles → + → Developer ID** (macOS), select the certificate in that `developer-id.p12`, and create one profile for `com.termllm.app` and one for `com.termllm.app.NotificationService`. Commit them as `TermLLMMac/DeveloperID/term-llm.provisionprofile` and `TermLLMMac/DeveloperID/TermLLMNotificationService.provisionprofile`. Profiles hold no private key. Xcode-managed profiles cannot be used for this manual signing.

Secrets never touch the disk:

- The job only runs for `main`, never for pull requests. The service account token enters only explicitly enumerated short staging steps, and only as a step environment value: the runner writes `run` scripts to disk, so it is never interpolated into one (`scripts/ci/test_workflows.py` enforces both). The presence check receives a boolean. The helper removes the token from the environment its other tools inherit; only `op` gets it.
- `op read` returns each secret straight into the helper's memory, never into an environment variable or file. `op` runs with caching off and its configuration directory on the RAM disk, so it leaves nothing in your own 1Password CLI setup.
- Each run mounts an 8 MiB RAM disk at `$RUNNER_TEMP/term-llm-mac-release.*/secrets`: memory only (anything macOS pages out goes to its encrypted swap), hidden from Finder, ownership enforced, root `0700`. If it isn't mounted that way, the job stops before using a secret.
- The `.p12` is piped from memory into `security import` and the key is imported **non-extractable** into a keychain on the RAM disk, protected by a random password that is never stored. The keychain is put first on your keychain search list while the job runs.
- The notary API key is read onto the RAM disk in its own step, so the minutes-long notarization step has no secret or token in its environment. It is deleted when notarization finishes.
- Cleanup (`if: always()`) deletes the keychain and its search-list entry, ejects the RAM disk (destroying its contents), removes the profiles it installed into Xcode's profile folder and deletes the build directory. The next run removes the RAM disk and search-list entry of a killed job; a reboot also clears the RAM disk.
- Profiles are checked before any secret is used: macOS Developer ID profiles for team `B6BAJ46A72` and the right bundle, unexpired, with production push for the app, and generated for the imported certificate. A rejected notarization prints the notary log's issues; nothing is published.

What this does not protect against: the runner runs as you, so for the few seconds a staging step runs, other processes running as you could read the service account token from its environment, and `ps` briefly shows the `.p12` password in `security import`'s arguments. While the job runs, your processes can use (not export) the signing key. Anyone who can push a workflow change to `main` can make the runner read the vault, as with any CI secret. For isolation from your own apps, run the runner as a separate macOS user.

`scripts/ci/test_notarized_mac_build.py` covers the helper against fake Apple and 1Password tools, and `scripts/ci/test_workflows.py` guards the trigger and secret boundaries. Only a run with the real service account shows that 1Password and Apple accept it.

## Sparkle updates

**One-time setup, code only until Sam explicitly applies it.** This PR does not
provision secrets, change the server, or publish a build. Review the public
distribution decision before enabling this: **anyone can download the notarized
Mac app from term-llm.com**, not just private-repository collaborators. The
Sparkle feed URL is stable: `https://term-llm.com/mac/appcast.xml`.
The stable latest Mac app download is **https://term-llm.com/mac/download**:
a direct ZIP response (not a redirect), revalidated on every request, with
attachment filename `term-llm-macos.zip`. Existing installs and feeds are
unaffected; Sparkle continues to use the signed appcast and immutable archive URLs.

### 1. Generate and retain the real update-signing key

Use Sparkle **2.10.1** tools from the pinned upstream release. The helper pins
its tools archive SHA-256; Xcode's exact package requirement and committed
`Package.resolved` pin the framework revision, whose `Package.swift` pins the
binary checksum. Review those pins together when upgrading Sparkle.

On Sam's trusted Mac, not in CI:

```sh
# Sparkle-2.10.1.tar.xz from the upstream GitHub release; verify before extracting.
# SHA256: 1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
./bin/generate_keys --account term-llm-app
./bin/generate_keys --account term-llm-app -p
# Export into a private temporary location (prefer a protected RAM disk).
umask 077
./bin/generate_keys --account term-llm-app -x /PRIVATE-TEMP/sparkle-private-key
```

Create item **Mac Sparkle** in the **term-llm CI** vault, with exact fields:

| Field | Contents | Used by |
| --- | --- | --- |
| `private key` | Entire exported base64 private key (concealed field) | `sign_update --ed-key-file`, on the job RAM disk only |
| `public key` | Public base64 key from `generate_keys -p` (32 bytes decoded) | CI `SPARKLE_PUBLIC_ED_KEY` xcconfig → app `SUPublicEDKey` |

Keep an offline backup. Losing the key can strand installed clients; never
replace it casually. Preserve the Keychain account as well. Securely remove
the temporary export after importing it into 1Password. Do not paste key values
into GitHub Actions variables, a workflow, command arguments, or this repo.
The existing read-only vault service account needs access to the new items;
**OP_SERVICE_ACCOUNT_TOKEN remains the only GitHub secret**.

### 2. Create the restricted upload credential and server directory

Generate a separate Ed25519 SSH key on a trusted machine, with a meaningful
comment (for example `term-llm-app-mac-downloads-ci`), dedicated solely to this
upload account. The unattended key has no passphrase; protect its 1Password
item and the runner accordingly. Never reuse a personal admin key.

Create item **Mac downloads SSH** in **term-llm CI**:

| Field | Contents |
| --- | --- |
| `private key` | Complete unencrypted OpenSSH Ed25519 private key (concealed field) |
| `known hosts` | Pinned host-key line for `143.198.76.107`, verified through a trusted console/admin channel, not an unverified runtime `ssh-keyscan` |

The uploader is fixed to `term-llm-updates@143.198.76.107`, port 22, with relative
destination `./`. The SSH server confines that path to
`/var/www/term-llm-downloads/mac/`. It cannot write the Hugo tree, nginx config,
SSH authorization, or execute arbitrary commands. CI enforces strict host-key
checking, disables agent/password forwarding and interactive prompts, and
keeps key/known-hosts files only on the existing owner-only RAM disk. Review
`rrsync` restrictions as part of server setup, not merely client-side flags.

Server preparation is bundled here because the matching public repo must not
receive a public PR for this private-app work:

- [`deployment/setup-mac-downloads.sh`](deployment/setup-mac-downloads.sh):
  reviewed one-time account/directory/forced-command setup; accepts **only the
  public SSH key**. Run manually as root, after installing `rsync`/`rrsync`.
- [`deployment/mac.conf`](deployment/mac.conf): candidate public-repo
  `ops/nginx/mac.conf`, to install as
  `/etc/nginx/term-llm-locations.d/mac.conf` after review. The existing HTTPS
  vhost already includes that directory. No public branch/PR is needed now.

The setup script deliberately refuses an existing account rather than silently
changing one. Review `sshd -T -C user=term-llm-updates,host=localhost,addr=127.0.0.1`,
then reload SSH explicitly. Prove that SSH shell/TTY/forwarding, downloads from
the account (`rrsync -wo`), deletions, and `../` uploads are rejected, while two
ordinary rsync uploads into `./` succeed. Use a harmless fixture file and
remove it administratively after the test. The root-owned home/authorized_keys
must remain outside the writeable upload root. Keep the account out of sudo.

**After merging the stable-download change**, Sam must reinstall the reviewed
nginx snippet, validate, and reload. From a checkout of the merged code on the
downloads server (commands for Sam to run, not CI):

```sh
sudo install -o root -g root -m 0644 docs/deployment/mac.conf /etc/nginx/term-llm-locations.d/mac.conf
sudo nginx -t && sudo systemctl reload nginx
```

Apply the snippet before the next main release reaches publication: the final
HTTPS verification requires `/mac/download` to be served directly. The link
returns 404 until the first successful latest-ZIP upload; there is no backfill
of existing releases or change to the existing feed.

**Pruning old builds.** The upload account is write-only (`rrsync -wo -no-del`),
so CI can never delete anything and every published zip (~23 MB) would otherwise
stay on the server forever. A daily root-installed timer on the server removes
superseded ones instead:

- [`deployment/term-llm-mac-prune`](deployment/term-llm-mac-prune) keeps every
  zip referenced by the **two newest** appcast items, plus any zip uploaded in
  the last **48 hours** (so a download that started from a just-replaced feed
  still finishes). Older entries further down the appcast may then 404; Sparkle
  only offers the newest compatible item, and every item requires macOS 14.
- It deletes nothing and exits 1 if `appcast.xml` is missing, malformed,
  contains a DTD, lists an unexpected URL, or its newest zip is not on disk.
  Only top-level regular files matching CI's content-addressed name are
  candidates; `appcast.xml`, `term-llm-macos-latest.zip` and rsync temporary files
  are never touched.
- [`deployment/term-llm-mac-prune.service`](deployment/term-llm-mac-prune.service)
  runs it as `term-llm-updates` with no network and only the downloads directory
  writable; [`deployment/term-llm-mac-prune.timer`](deployment/term-llm-mac-prune.timer)
  runs it daily at 04:20 UTC.
- Install or update with `sudo sh docs/deployment/install-mac-download-prune.sh`
  (dry run first, then enables the timer). Check with
  `journalctl -u term-llm-mac-prune.service`. Steady state is about 2 zips plus
  whatever shipped in the last 48 hours, plus **one extra ~23 MB file** for
  `term-llm-macos-latest.zip` (replaced each release, never pruned).

`scripts/ci/test_mac_download_prune.py` feeds CI-generated appcasts and archive
names through the prune script, so a change to either side's naming or feed
format fails the lightweight checks.
Check HTTPS certificates and a fixture's Content-Type/cache headers. Only
`appcast.xml`, `/mac/download` and content-addressed ZIP names are served;
`/mac/term-llm-macos-latest.zip` itself, directory listings, temporary files and
dotfiles return 404. The downloads tree must **not** be under
`/var/www/term-llm`: the public docs deploy uses `rsync -a --delete` there.
Keep appcast and `/mac/download` uncached/revalidated, content-addressed ZIP URLs
immutable, and old archives retained while any published feed references them. Server-side retention is an explicit
admin task; CI has no delete permission.

### 3. Release and failure policy

The main-only workflow first validates the new 1Password configuration and
injects the public key. The token is stripped before launching other tools.
After Developer ID signing, notarization and stapling, CI creates one final ZIP,
signs its exact bytes with `sign_update`, produces a feed with a bounded history
of 20 releases, and signs that XML too. Appcast build numbers are the monotonic
workflow run numbers (`sparkle:version`), with the marketing version separately
in `sparkle:shortVersionString`; minimum macOS is **14.0**. Short embedded notes
work without private GitHub access.

Publication is serialized. Public ZIP names include the marketing version, monotonic build number and full
SHA-256 (`term-llm-macos-VERSION-BUILD-SHA256.zip`); the private GitHub asset
retains `term-llm-macos-VERSION.zip`. A retry cannot reuse a URL for different
bytes. The uploader uses `--ignore-existing` and verifies the public HTTPS
object's byte count and SHA-256 before exposing it in the feed.
The content-addressed ZIP uploads first using rsync's
normal temporary-file/rename behavior, then `appcast.xml` uploads in a separate
command, again with atomic rename. **Last**, CI uploads the same verified archive
bytes again as `term-llm-macos-latest.zip`, with overwrite allowed (no
`--ignore-existing`), then verifies the exact byte count and SHA-256 over HTTPS
at `/mac/download`. The feed is the source of truth: the convenience link may
lag a release by seconds, but never points to a release not yet in the signed
feed. All uploads retain the same macOS openrsync-compatible flags and atomic
rename behavior. No `--inplace`, server shell, delete, or public artifact storage.
Readers see the old feed until the new asset exists.
The private GitHub release uses the **same ZIP**, and only runs after successful
website publication. Missing new secrets, an inaccessible/malformed old feed,
signature mismatch, nonmonotonic build, or failed transfer fails closed.
Credential/signing/upload errors name this setup section. A first-feed HTTPS 404 is permitted;
other failures must not silently reset history. A failed ZIP upload never
publishes the feed. A failed feed upload can leave an unreferenced ZIP, but not
a broken client update. Failure to upload or verify the latest download also
fails the job with an explicit `::error::` saying **the release is already
published to Sparkle**. It withholds the private GitHub release; the signed feed
is not rolled back, and existing installs can still update. The next release
advances past that published feed as usual.

**Why withhold the GitHub release on failure?** A successful release must mean
the configured update channel is available, not silently ship another
manual-download-only app. Conversely, a GitHub outage after website publication
may leave the website ahead. The next main run authenticates website history
and advances the marketing patch beyond both publication channels; it never
overwrites the earlier archive or regresses its build. An orphaned upload from
a failed feed commit has a distinct content-addressed URL and can be retained
or removed administratively. No
real website/key/Developer ID end-to-end claim can be made until Sam configures
the server/items and observes the first main run.
