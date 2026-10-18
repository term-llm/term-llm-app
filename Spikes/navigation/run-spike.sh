#!/bin/sh
# Runs the navigation spike against a throwaway local term-llm server that is
# always stopped when this script exits.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
port=${PORT:-8099}
token=${TOKEN:-navspike-token}
log=/tmp/navspike-server.log

term-llm serve web --port "$port" --auth bearer --token "$token" >"$log" 2>&1 &
server=$!
trap 'kill "$server" 2>/dev/null; wait "$server" 2>/dev/null || true' EXIT INT TERM

i=0
until curl -fsS -o /dev/null -H "Authorization: Bearer $token" "http://127.0.0.1:$port/ui/v1/capabilities"; do
  i=$((i + 1)); [ "$i" -gt 40 ] && { echo "server did not start"; tail -20 "$log"; exit 1; }
  sleep 0.5
done

BASE="http://127.0.0.1:$port/ui" TOKEN="$token" node "$here/spike.mjs"
