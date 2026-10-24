# Self-hosted MacBook CI

## Financial boundary

Every job in `.github/workflows/` uses exactly:

```yaml
runs-on: [self-hosted, macOS, ARM64, term-llm-local]
```

There is no hosted fallback, setup-go Actions cache, or artifact upload. Offline runners leave jobs queued. This prevents these workflows from consuming GitHub-hosted runner minutes; it does not clear existing billable storage or change account billing settings. Set a GitHub Actions budget with usage blocked at the limit as an independent safety net where supported by your account.

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

## Daily workflow

1. Keep the Mac awake, online, and logged in with the runner active. For a foreground session, `caffeinate -i ./run.sh` can prevent idle system sleep while the agent runs (it does not make closed-lid operation reliable).
2. Push a trusted branch/open or update a PR. Relevant changes trigger `Lightweight checks / checks` here.
3. Inspect the PR's check logs. Fix failures and push again normally.
4. For app/extension build and focused unit coverage, use **Actions → Native notification checks (manual local Mac) → Run workflow** after the workflow is registered on the default branch. No UI journeys run.
5. Stop/start the service with `./svc.sh stop` / `./svc.sh start` from the runner directory as needed. Offline means queued, not paid fallback.

Before calling migration complete, push the new workflows, verify no active workflow still targets `ubuntu-*`, `macos-*`, or `windows-*` hosted labels, and get a fresh PR run showing `term-llm-macbook` as its runner. If old required checks block merging, adjust branch rules to the intended current checks. Path-filtered checks need special handling if required on docs-only PRs.
