#!/bin/sh
# Renders each mock HTML file to a 2x PNG with headless Chrome.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
profile=$(mktemp -d /tmp/agents-tab-mocks-chrome.XXXXXX)
for page in "$dir"/*.html; do
  name=$(basename "$page" .html)
  "$chrome" --headless=new --disable-gpu --hide-scrollbars --no-first-run --user-data-dir="$profile" \
    --window-size=1160,820 --force-device-scale-factor=2 \
    --screenshot="$dir/$name.png" "file://$page" >/dev/null 2>&1
  echo "$dir/$name.png"
done
rm -rf "$profile"
