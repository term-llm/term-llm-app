#!/bin/zsh
# Local end-to-end check of native push (see TermLLMTests/PushLiveE2ETests.swift):
# real term-llm web UI enrolls through the app's bridge, `term-llm notify web`
# sends through the push relay to a capturing fake APNs, and the test decrypts
# the captured payload with the Notification Service Extension's code.
#
# Usage: scripts/push-e2e/run.sh <simulator-udid> [path-to-term-llm-checkout]
# Needs a term-llm build with native push support (`make build` in term-llm).
set -u
UDID=$1
TERM_LLM=${2:-$(cd "$(dirname $0)/../../../term-llm" && pwd)}
APP=$(cd "$(dirname $0)/../.." && pwd)
SCRIPTS=$(cd "$(dirname $0)" && pwd)
D=$(mktemp -d /tmp/termllm-push-e2e.XXXXXX)
BODY="E2E hello $(date +%s)"
mkdir -p $D/xdg-config $D/xdg-data
(cd $APP/push-relay && go build -o $D/push-relay .) || exit 1
openssl ecparam -name prime256v1 -genkey -noout | openssl pkcs8 -topk8 -nocrypt > $D/key.p8
KEYS=$($D/push-relay genkey | cut -d= -f2-)

python3 -I $SCRIPTS/fake_apns.py 18444 $D/apns.jsonl > $D/fake_apns.log 2>&1 & PIDS=($!)
env RELAY_PUBLIC_URL=http://localhost:18080 PORT=18080 RELAY_TOKEN_KEYS="$KEYS" APNS_KEY_ID=KEYID12345 \
  APNS_TEAM_ID=B6BAJ46A72 APNS_PRIVATE_KEY_FILE=$D/key.p8 APNS_DEVELOPMENT_URL=http://127.0.0.1:18444 \
  APNS_PRODUCTION_URL=http://127.0.0.1:18444 $D/push-relay > $D/relay.log 2>&1 & PIDS+=($!)
(cd $TERM_LLM && exec env XDG_CONFIG_HOME=$D/xdg-config XDG_DATA_HOME=$D/xdg-data \
  ./term-llm serve web --no-auth --port 18090) > $D/serve.log 2>&1 & PIDS+=($!)
trap 'kill $PIDS 2>/dev/null' EXIT
sleep 4

xcrun simctl boot $UDID 2>/dev/null; xcrun simctl bootstatus $UDID -b > /dev/null
cd $APP
TEST_RUNNER_TERMLLM_PUSH_E2E_URL=http://127.0.0.1:18090/ui/ \
TEST_RUNNER_TERMLLM_PUSH_E2E_RELAY=http://localhost:18080 \
TEST_RUNNER_TERMLLM_PUSH_E2E_APNS=http://127.0.0.1:18444 \
TEST_RUNNER_TERMLLM_PUSH_E2E_BODY="$BODY" \
xcodebuild test -project TermLLM.xcodeproj -scheme TermLLM -destination "id=$UDID" -derivedDataPath DerivedData \
  -only-testing:TermLLMTests/PushLiveE2ETests > $D/xctest.log 2>&1 & TEST_PID=$!

until grep -q PUSH_E2E_ENROLLED $D/xctest.log 2>/dev/null; do
  kill -0 $TEST_PID 2>/dev/null || { echo "test exited before enrollment; see $D/xctest.log"; exit 1; }
  sleep 1
done
(cd $TERM_LLM && env XDG_CONFIG_HOME=$D/xdg-config XDG_DATA_HOME=$D/xdg-data ./term-llm notify web "$BODY")
wait $TEST_PID; STATUS=$?
grep -E "PUSH_E2E|error:|\*\* TEST" $D/xctest.log
echo "logs: $D"
exit $STATUS
