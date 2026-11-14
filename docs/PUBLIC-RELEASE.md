# Public release and repository transfer

The app is MIT licensed; third-party notices remain applicable. See the root
[license](../LICENSE) and [third-party notices](../THIRD-PARTY-NOTICES.md).

## Security boundary

- The persistent Mac runner also handles signing. Never run untrusted PR code
  on it, even after approving a first-time contributor's workflow.
- Checked-in workflows run only on `main`: automatic checks on pushes, other
  tests on manual dispatch. All jobs reject other refs. Review before merging.
- Keep `main` protected against force pushes and deletion, including admins.
  Post-merge, path-filtered checks are not pre-merge required checks.
- Keep the default Actions token read-only, disallow Actions approving PRs,
  and require full-SHA action pinning. Release writes remain job-scoped.
- Retired native-Hub, phone-Hub and peer-connect workflows must remain disabled
  in GitHub, including old branch versions.
- GitHub's managed **Dependabot graph jobs** are separate from this repository's
  self-hosted CI. They can display a hosted runner but incur no Actions-minute
  charges ([GitHub documentation](https://docs.github.com/en/code-security/concepts/supply-chain-security/dependency-graph-data#dependabot-graph-jobs)).
  Do not enable billable automatic dependency submission as a replacement.

## Before changing visibility

From the repository checkout:

```sh
git fetch origin --tags --prune
bash scripts/ci/check-secrets.sh
repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
gh api "repos/$repo/actions/permissions"
gh api "repos/$repo/actions/permissions/workflow"
gh api "repos/$repo/branches/main/protection"
gh api "repos/$repo/actions/workflows" --jq '.workflows[] | [.name, .state]'
gh api "repos/$repo/actions/artifacts" --jq .total_count
gh api "repos/$repo/dependabot/alerts" --paginate --jq '.[] | [.number, .state, .security_advisory.severity]'
```

The checksum-pinned Gitleaks scan includes all fetched history and tags.
`.gitleaksignore` lists only individually reviewed historical false-positive
fingerprints, not excluded paths or rules. New findings require investigation;
rotate actual exposed credentials before considering history cleanup.

Review Actions logs, release assets, screenshots and other tracked material as
well as Git history: `.gitignore` does not remove previously published data.
Scanner results are not proof that no sensitive information exists.

The 2026-11-14 preflight covered all 217 fetched reachable commits (Gitleaks
processed 189 commits with changes). Its 18 matches were reviewed
as synthetic test data, documentation examples or code identifiers/assertions;
no live credentials were identified. All 157 then-available completed Actions
run logs were also scanned without credential findings. There were no Actions
artifacts or webhooks; release assets were Mac app ZIPs. Raw audit output stays
in ignored `output/public-release-audit/`, not in Git.

GitHub secret scanning and push protection were unavailable for the private
repository at preflight. Enable them when the repository becomes public, then
check alerts. Dependabot alerts are enabled. Initial graph generation surfaced 17 relay
alerts; the targeted updates to `jwt/v5` 5.2.2 and `x/crypto` 0.52.0 meet their
reported patched-version requirements. Verify that alerts resolve after pushing.
Do not treat an empty alert list as an exhaustive vulnerability audit, especially
for binary Swift dependencies.

## Transfer to the term-llm organization

The core CLI already lives at `term-llm/term-llm`. The app installer uses that
canonical repository, validates final release URLs against an explicit
canonical/legacy allowlist, and preserves Developer ID signature verification.
The app repository's visibility/owner are a separate administrative change.

After transferring the app repository:

1. Set the checkout's `origin` to the destination URL; verify with `gh repo view`.
2. Verify runner registration/availability, `OP_SERVICE_ACCOUNT_TOKEN` access,
   branch protections, Actions permissions, disabled retired workflows, and
   security settings in the destination organization. Organization policies
   may change access even when repository settings and secrets transfer.
3. Set SwiftBar's `TERM_LLM_CI_REPO` environment variable to the destination
   `owner/repository`, then reinstall the plugin if needed. Its current default
   intentionally remains the existing app repository until the transfer.
4. Follow the owner-independent runner/secret commands in
   [self-hosted CI](SELF-HOSTED-CI.md) if re-registration is needed.
5. Run trusted checks on `main` and verify the next notarized release. GitHub
   publishing follows `GITHUB_REPOSITORY`; the Sparkle feed stays at
   `https://term-llm.com/mac/appcast.xml` and requires no ownership rename.

Changing visibility publishes source history and repository release assets.
Do not assume adding MIT or pushing these changes performs the transfer or
changes visibility.
