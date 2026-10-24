#!/bin/bash
# Sourced by Actions jobs: launchd does not inherit the interactive shell's PATH.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/share/mise/installs/node/latest/bin:$PATH"

# Apple's Python 3.9 cannot parse all producer-fixture ISO timestamps.
python=""
for candidate in python3 python3.14 python3.13 python3.12 python3.11; do
  if command -v "$candidate" >/dev/null && "$candidate" -c 'import sys; sys.exit(sys.version_info < (3, 11))'; then
    python="$(command -v "$candidate")"
    break
  fi
done
if [[ -z "$python" ]]; then
  echo 'Install Python >= 3.11 on the runner Mac.' >&2
  exit 1
fi
mkdir -p "$RUNNER_TEMP/term-llm-ci-bin"
ln -sf "$python" "$RUNNER_TEMP/term-llm-ci-bin/python3"
export PATH="$RUNNER_TEMP/term-llm-ci-bin:$PATH"
printf '%s\n' "$RUNNER_TEMP/term-llm-ci-bin" /opt/homebrew/bin /usr/local/bin "$HOME/.local/share/mise/installs/node/latest/bin" >> "$GITHUB_PATH"
python3 --version
