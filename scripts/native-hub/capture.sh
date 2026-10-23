#!/usr/bin/env bash
# Actual simulator capture. Run from repository root on macOS with Xcode 26.2.
set -euo pipefail
: "${SIMULATOR_UDID:?Select an available simulator with scripts/select-ios-simulator.py}"
: "${RUNNER_TEMP:?Set RUNNER_TEMP to a disposable output directory}"
export ARTIFACT_DIR="$RUNNER_TEMP/native-hub-artifacts"
# Never reuse old media/results or silently overwrite evidence from a prior run.
if [[ -e "$ARTIFACT_DIR" ]]; then
  printf 'Artifact directory already exists; use a fresh RUNNER_TEMP: %s\n' "$ARTIFACT_DIR" >&2
  exit 1
fi
mkdir -p "$ARTIFACT_DIR"
export CAPTURE_STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
fixture_pid=''
record_pid=''
stop_recording() {
  if [[ -n "$record_pid" ]]; then
    kill -INT "$record_pid" 2>/dev/null || true
    # simctl must finalize MP4 before artifact upload; don't leave it running.
    for ((i=0; i<30; i++)); do
      kill -0 "$record_pid" 2>/dev/null || break
      sleep 1
    done
    kill -TERM "$record_pid" 2>/dev/null || true
    wait "$record_pid" 2>/dev/null || true
    record_pid=''
  fi
}
finish() {
  status=$?
  trap - EXIT INT TERM
  stop_recording
  for suite in NativeHub NativeHubUnits; do
    if [[ "$suite" == NativeHub ]]; then prefix=test; else prefix=unit-test; fi
    if [[ -d "$ARTIFACT_DIR/$suite.xcresult" && ! -s "$ARTIFACT_DIR/$prefix-summary.json" ]]; then
      xcrun xcresulttool get test-results summary --path "$ARTIFACT_DIR/$suite.xcresult" \
        > "$ARTIFACT_DIR/$prefix-summary.json" 2> "$ARTIFACT_DIR/$prefix-summary-export.log" || true
    fi
  done
  if [[ -d "$ARTIFACT_DIR/NativeHub.xcresult" && ! -d "$ARTIFACT_DIR/screenshots" ]]; then
    xcrun xcresulttool export attachments --path "$ARTIFACT_DIR/NativeHub.xcresult" \
      --output-path "$ARTIFACT_DIR/screenshots" > "$ARTIFACT_DIR/export-attachments.log" 2>&1 || true
  fi
  if [[ -n "$fixture_pid" ]]; then
    kill "$fixture_pid" 2>/dev/null || true
    wait "$fixture_pid" 2>/dev/null || true
  fi
  CAPTURE_EXIT_STATUS="$status" python3 scripts/native-hub/manifest.py || status=1
  exit "$status"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

python3 -u scripts/native-hub/fixture_server.py --port 8766 \
  --request-log "$ARTIFACT_DIR/fixture-requests.jsonl" > "$ARTIFACT_DIR/fixture-server.log" 2>&1 &
fixture_pid=$!
for ((i=0; i<50; i++)); do
  curl --fail --silent http://localhost:8766/__health > /dev/null && break
  kill -0 "$fixture_pid"
  sleep 0.2
done
curl --fail --silent http://localhost:8766/__health > /dev/null

xcrun simctl boot "$SIMULATOR_UDID" 2>/dev/null || true
xcrun simctl bootstatus "$SIMULATOR_UDID" -b
xcrun simctl status_bar "$SIMULATOR_UDID" override --time '9:41' --dataNetwork wifi \
  --wifiMode active --wifiBars 3 --batteryState charged --batteryLevel 100
xcrun simctl list devices available --json > "$ARTIFACT_DIR/simulators.json"
xcodebuild -version > "$ARTIFACT_DIR/xcode-version.txt"

build_args=(
  -project TermLLM.xcodeproj -scheme TermLLM -configuration Debug
  -sdk iphonesimulator -destination "platform=iOS Simulator,id=$SIMULATOR_UDID"
  -derivedDataPath "$RUNNER_TEMP/NativeHubDerivedData"
  -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= DEVELOPMENT_TEAM=
)
xcodebuild build-for-testing "${build_args[@]}" 2>&1 | tee "$ARTIFACT_DIR/build.log"

# Focused unit regressions run first: keep compilation/units out of the video.
xcodebuild test-without-building "${build_args[@]}" \
  -resultBundlePath "$ARTIFACT_DIR/NativeHubUnits.xcresult" \
  -only-testing:TermLLMTests/HubClientTests \
  -only-testing:TermLLMTests/HubClientModelTests \
  -only-testing:TermLLMTests/HubClientHTMLParsingTests \
  -only-testing:TermLLMTests/HubClientCookieFilterTests \
  -only-testing:TermLLMTests/HubClientAuthCookieTests \
  -only-testing:TermLLMTests/HubClientMountedPathTests \
  -only-testing:TermLLMTests/HubNavigationTests \
  -only-testing:TermLLMTests/HubStoreTests \
  -only-testing:TermLLMTests/HubPasskeyTests \
  2>&1 | tee "$ARTIFACT_DIR/unit-test.log"
xcrun xcresulttool get test-results summary --path "$ARTIFACT_DIR/NativeHubUnits.xcresult" > "$ARTIFACT_DIR/unit-test-summary.json"
xcrun xcresulttool get test-results tests --path "$ARTIFACT_DIR/NativeHubUnits.xcresult" > "$ARTIFACT_DIR/unit-test-tree.json"
python3 scripts/native-hub/verify_units.py "$ARTIFACT_DIR"

# Record the SAME device used by XCUITest. No simulator clones/parallel workers.
xcrun simctl io "$SIMULATOR_UDID" recordVideo --codec=h264 "$ARTIFACT_DIR/native-hub-demo-fixture.mp4" \
  > "$ARTIFACT_DIR/record-video.log" 2>&1 &
record_pid=$!
sleep 2
kill -0 "$record_pid"
xcodebuild test-without-building "${build_args[@]}" \
  -resultBundlePath "$ARTIFACT_DIR/NativeHub.xcresult" \
  -only-testing:TermLLMUITests/NativeHubUITests \
  2>&1 | tee "$ARTIFACT_DIR/test.log"
kill -0 "$record_pid" # Recording must remain alive for the entire UI journey.
stop_recording

xcrun xcresulttool get test-results summary --path "$ARTIFACT_DIR/NativeHub.xcresult" > "$ARTIFACT_DIR/test-summary.json"
xcrun xcresulttool export attachments --path "$ARTIFACT_DIR/NativeHub.xcresult" \
  --output-path "$ARTIFACT_DIR/screenshots" > "$ARTIFACT_DIR/export-attachments.log" 2>&1
python3 scripts/native-hub/verify_capture.py "$ARTIFACT_DIR"
