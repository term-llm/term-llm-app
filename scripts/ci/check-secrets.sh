#!/bin/bash
# Scan all fetched history; reports are redacted and never uploaded as artifacts.
# CI must use checkout fetch-depth: 0 so old commits and tags are included.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

version=8.30.1
archive="gitleaks_${version}_darwin_arm64.tar.gz"
sha256=b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
  echo 'This pinned scanner targets the macOS ARM64 CI runner.' >&2
  exit 1
fi
work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/term-llm-secrets.XXXXXX")"
trap 'rm -rf -- "$work"' EXIT
curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
  "https://github.com/gitleaks/gitleaks/releases/download/v${version}/${archive}" \
  --output "$work/$archive"
printf '%s  %s\n' "$sha256" "$work/$archive" | shasum -a 256 --check --status
tar -xzf "$work/$archive" -C "$work" gitleaks
"$work/gitleaks" git --redact --log-opts='--all --full-history' .
