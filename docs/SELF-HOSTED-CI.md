# Self-hosted MacBook CI

## Financial boundary

Every job in `.github/workflows/` uses exactly:

```yaml
runs-on: [self-hosted, macOS, ARM64, term-llm-local]
```

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
4. For app/extension build and focused unit coverage, use **Actions → Native notification checks (manual local Mac) → Run workflow** after the workflow is registered on the default branch. No UI journeys run.
5. Stop/start the service with `./svc.sh stop` / `./svc.sh start` from the runner directory as needed. Offline means queued, not paid fallback.

Before calling migration complete, push the new workflows, verify no active workflow still targets `ubuntu-*`, `macos-*`, or `windows-*` hosted labels, and get a fresh PR run showing `term-llm-macbook` as its runner. If old required checks block merging, adjust branch rules to the intended current checks. Path-filtered checks need special handling if required on docs-only PRs.

## Notarized Mac builds

**Notarized Mac build** (`.github/workflows/notarized-mac-build.yml`) runs here for every push to `main` that changes the app, and on manual dispatch from `main`. It archives the `TermLLMMac` scheme in Release with Developer ID signing, exports and verifies it, notarizes and staples it, checks that Gatekeeper accepts it, then creates a release `mac-v<version>-<build>` with `term-llm-macos-<version>-<build>.zip`, marked Latest. The build number is the workflow run number. Releases of this private repository are visible to its collaborators only. Installed copies do not update themselves; download the newest release.

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

- The job only runs for `main`, never for pull requests. The service account token enters only two short steps, and only as a step environment value: the runner writes `run` scripts to disk, so it is never interpolated into one (`scripts/ci/test_workflows.py` enforces both). The presence check receives a boolean. The helper removes the token from the environment its other tools inherit; only `op` gets it.
- `op read` returns each secret straight into the helper's memory, never into an environment variable or file. `op` runs with caching off and its configuration directory on the RAM disk, so it leaves nothing in your own 1Password CLI setup.
- Each run mounts an 8 MiB RAM disk at `$RUNNER_TEMP/term-llm-mac-release.*/secrets`: memory only (anything macOS pages out goes to its encrypted swap), hidden from Finder, ownership enforced, root `0700`. If it isn't mounted that way, the job stops before using a secret.
- The `.p12` is piped from memory into `security import` and the key is imported **non-extractable** into a keychain on the RAM disk, protected by a random password that is never stored. The keychain is put first on your keychain search list while the job runs.
- The notary API key is read onto the RAM disk in its own step, so the minutes-long notarization step has no secret or token in its environment. It is deleted when notarization finishes.
- Cleanup (`if: always()`) deletes the keychain and its search-list entry, ejects the RAM disk (destroying its contents), removes the profiles it installed into Xcode's profile folder and deletes the build directory. The next run removes the RAM disk and search-list entry of a killed job; a reboot also clears the RAM disk.
- Profiles are checked before any secret is used: macOS Developer ID profiles for team `B6BAJ46A72` and the right bundle, unexpired, with production push for the app, and generated for the imported certificate. A rejected notarization prints the notary log's issues; nothing is published.

What this does not protect against: the runner runs as you, so for the few seconds a staging step runs, other processes running as you could read the service account token from its environment, and `ps` briefly shows the `.p12` password in `security import`'s arguments. While the job runs, your processes can use (not export) the signing key. Anyone who can push a workflow change to `main` can make the runner read the vault, as with any CI secret. For isolation from your own apps, run the runner as a separate macOS user.

`scripts/ci/test_notarized_mac_build.py` covers the helper against fake Apple and 1Password tools, and `scripts/ci/test_workflows.py` guards the trigger and secret boundaries. Only a run with the real service account shows that 1Password and Apple accept it.
