#!/bin/bash
# Install/update the plugin without replacing an existing SwiftBar plugin folder.
set -euo pipefail
source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
plugin_dir="$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || true)"
if [[ -z "$plugin_dir" ]]; then
  plugin_dir="$HOME/Library/Application Support/SwiftBar/Plugins"
  defaults write com.ameba.SwiftBar PluginDirectory -string "$plugin_dir"
fi
plugin_dir="${plugin_dir/#\~/$HOME}"
mkdir -p "$plugin_dir"
install -m 755 "$source_dir/term-llm-ci.1m.py" "$plugin_dir/term-llm-ci.1m.py"
printf 'Installed plugin: %s/term-llm-ci.1m.py\n' "$plugin_dir"
if [[ -d "$HOME/Applications/SwiftBar.app" ]]; then
  open "$HOME/Applications/SwiftBar.app"
elif [[ -d /Applications/SwiftBar.app ]]; then
  open /Applications/SwiftBar.app
else
  echo 'Install SwiftBar from https://github.com/swiftbar/SwiftBar/releases, then launch it.'
fi
