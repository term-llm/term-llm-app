#!/bin/bash
# Cross-builds the darwin term-llm CLI payload that the macOS app bundles.
#
# The payload is intentionally not committed: it is a large Go binary tied to a
# core revision. The app target copies build/cli into Contents/Resources when it
# exists and otherwise builds without it (the Setup screen then offers to adopt
# an existing installation instead).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
app_repo="$(cd "$here/../.." && pwd)"
core_dir="${TERM_LLM_CORE_DIR:-$app_repo/../term-llm}"
out_dir="${1:-$app_repo/build/cli}"
goarch="${GOARCH:-$(uname -m)}"

case "$goarch" in
  x86_64|amd64) goarch=amd64 ;;
  arm64|aarch64) goarch=arm64 ;;
  *) echo "unsupported GOARCH: $goarch" >&2; exit 2 ;;
esac

if [[ ! -f "$core_dir/go.mod" ]]; then
  echo "term-llm core checkout not found at $core_dir" >&2
  echo "Set TERM_LLM_CORE_DIR to the core worktree (it must have frontend/static assets built)." >&2
  exit 2
fi

mkdir -p "$out_dir"
echo "Building term-llm for darwin/$goarch from $core_dir"
(
  cd "$core_dir"
  # The embedded web UI must exist before compiling; `make frontend` is the
  # repository's documented step.
  if [[ ! -f internal/serveui/static/dist/manifest.json && ! -d internal/serveui/static/dist ]]; then
    echo "Frontend assets are missing; run 'make frontend' in $core_dir first." >&2
    exit 2
  fi
  GOOS=darwin GOARCH="$goarch" CGO_ENABLED=0 go build -trimpath -o "$out_dir/term-llm" .
  version="$(git describe --tags --always --dirty 2>/dev/null || git rev-parse --short HEAD)"
  printf '%s\n' "$version" > "$out_dir/VERSION"
  shasum -a 256 "$out_dir/term-llm" | awk '{print $1}' > "$out_dir/sha256"
)

echo "Payload: $out_dir/term-llm ($(cat "$out_dir/VERSION"))"
echo "SHA-256: $(cat "$out_dir/sha256")"
