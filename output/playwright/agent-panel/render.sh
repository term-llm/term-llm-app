#!/bin/zsh
# Renders the concept mocks to c1.png..c3.png (2x) with playwright-cli.
# Usage: zsh output/playwright/agent-panel/render.sh
set -u
dir=output/playwright/agent-panel
port=8791
python3 -m http.server $port --bind 127.0.0.1 --directory $dir >/tmp/agent-panel-http.log 2>&1 &
server=$!
trap 'kill $server 2>/dev/null' EXIT
for i in {1..20}; do curl -sf -o /dev/null http://127.0.0.1:$port/index.html && break; sleep 0.2; done
pw() { npx --yes --package @playwright/cli playwright-cli --session agentpanel "$@"; }
pw open "http://127.0.0.1:$port/index.html" >/dev/null 2>&1 || pw goto "http://127.0.0.1:$port/index.html" >/dev/null 2>&1
pw goto "http://127.0.0.1:$port/index.html?$(date +%s)" 2>&1 | grep -E "Error|Title" | head -3
pw resize 3200 2600 >/dev/null 2>&1
pw run-code --filename $dir/render.js 2>&1 | grep -E "Error|Result|ok" | head -5
