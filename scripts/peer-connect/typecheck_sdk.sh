#!/usr/bin/env bash
# Cheap REAL iOS/WebRTC API typecheck, not a full build or runtime claim.
set -euo pipefail
: "${RUNNER_TEMP:?Set RUNNER_TEMP to disposable storage}"
export PEER_SDK_OUTPUT="$RUNNER_TEMP/peer-sdk-artifacts"
export PEER_SDK_WORK="$(mktemp -d "$RUNNER_TEMP/peer-sdk-work.XXXXXX")"
mkdir -p "$PEER_SDK_OUTPUT"
export PEER_SDK_REVISION=44f36788497f701bc8c0306de3a1c2511d56019d
export PEER_SDK_SHA256=cb9adacf2d6bbf598d1d9e3e6c16d8fb97ca987b5b697746891828f9dc068ffe
export PEER_SDK_URL=https://github.com/stasel/WebRTC/releases/download/155.0.0/WebRTC-M155.xcframework.zip
finish() {
  status=$?
  trap - EXIT
  PEER_SDK_EXIT_STATUS="$status" python3 - <<'PY'
import json, os, subprocess
from pathlib import Path
root = Path(os.environ['PEER_SDK_OUTPUT'])
manifest = dict(schema_version=1, scope='actual-app-sources-ios-sdk-typecheck-only',
    runtime_verified=False, full_app_build_verified=False,
    source_commit=subprocess.check_output(['git','rev-parse','HEAD'], text=True).strip(),
    dirty_worktree=bool(subprocess.check_output(['git','status','--porcelain'], text=True).strip()),
    sdk_package='https://github.com/stasel/WebRTC', sdk_version='155.0.0',
    sdk_revision=os.environ['PEER_SDK_REVISION'], sdk_url=os.environ['PEER_SDK_URL'],
    sdk_expected_sha256=os.environ['PEER_SDK_SHA256'],
    exit_status=int(os.environ['PEER_SDK_EXIT_STATUS']),
    github_run_id=os.environ.get('GITHUB_RUN_ID'), github_run_attempt=os.environ.get('GITHUB_RUN_ATTEMPT'))
(root/'provenance.json').write_text(json.dumps(manifest, indent=2)+'\n')
PY
  rm -rf "$PEER_SDK_WORK"
  exit "$status"
}
trap finish EXIT
xcodebuild -version | tee "$PEER_SDK_OUTPUT/xcode-version.log"
xcrun swiftc --version | tee "$PEER_SDK_OUTPUT/swift-version.log"
export PEER_IOS_SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
printf '%s\n' "$PEER_IOS_SDK" > "$PEER_SDK_OUTPUT/sdk-path.txt"

curl --fail --location --retry 3 --silent --show-error "$PEER_SDK_URL" -o "$PEER_SDK_WORK/WebRTC.zip"
printf '%s  %s\n' "$PEER_SDK_SHA256" "$PEER_SDK_WORK/WebRTC.zip" | shasum -a 256 -c - \
  | tee "$PEER_SDK_OUTPUT/checksum.log"
curl --fail --location --retry 3 --silent --show-error \
  "https://raw.githubusercontent.com/stasel/WebRTC/$PEER_SDK_REVISION/Package.swift" \
  -o "$PEER_SDK_OUTPUT/upstream-Package.swift.txt"
ditto -x -k "$PEER_SDK_WORK/WebRTC.zip" "$PEER_SDK_WORK/extracted"

# Resolve the arm64 iOS SIMULATOR slice from the xcframework's own plist;
# never accidentally typecheck against device/macOS headers or a stub module.
python3 - <<'PY'
import hashlib, json, os, plistlib, shutil
from pathlib import Path
work, output = Path(os.environ['PEER_SDK_WORK']), Path(os.environ['PEER_SDK_OUTPUT'])
infos = list((work/'extracted').glob('**/WebRTC.xcframework/Info.plist'))
assert len(infos)==1, 'Exactly one WebRTC xcframework required'
xcframework = infos[0].parent
info = plistlib.loads(infos[0].read_bytes())
libs = [lib for lib in info['AvailableLibraries'] if lib.get('SupportedPlatform')=='ios'
        and lib.get('SupportedPlatformVariant')=='simulator' and 'arm64' in lib.get('SupportedArchitectures', [])]
assert len(libs)==1, 'Exactly one arm64 iOS simulator slice required'
framework = xcframework/libs[0]['LibraryIdentifier']/libs[0]['LibraryPath']
assert framework.name=='WebRTC.framework' and (framework/'Modules/module.modulemap').is_file(), 'Real WebRTC module map missing'
(work/'framework-directory.txt').write_text(str(framework.parent))
(output/'framework-slice.json').write_text(json.dumps(dict(slice=libs[0],
    archive_sha256=hashlib.sha256((work/'WebRTC.zip').read_bytes()).hexdigest(),
    module_map_sha256=hashlib.sha256((framework/'Modules/module.modulemap').read_bytes()).hexdigest()), indent=2)+'\n')
licenses = [p for p in (work/'extracted').rglob('*') if p.is_file() and ('license' in p.name.lower() or 'notice' in p.name.lower())]
assert licenses, 'Upstream license/third-party notices must be preserved'
for path in licenses:
    target = output/'licenses'/path.relative_to(work/'extracted')
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(path, target)
sources = sorted(Path('TermLLM').glob('*.swift')) + sorted(Path('Shared').glob('*.swift'))
assert sources and Path('TermLLM/PeerWebRTCSession.swift') in sources and Path('TermLLM/HubClient.swift') in sources, 'Actual app + peer sources required'
assert Path('TermLLM/PeerHubConnector.swift') in sources and Path('TermLLM/WebRTCHubTransport.swift') in sources
assert not any('Tests' in str(p) or 'NotificationService/' in str(p) for p in sources)
(output/'sources.json').write_text(json.dumps([dict(path=str(p), sha256=hashlib.sha256(p.read_bytes()).hexdigest()) for p in sources], indent=2)+'\n')
(work/'source-list.txt').write_text('\n'.join(str(p) for p in sources)+'\n')
# No HubTransport/application stubs. This probe solely ensures canImport(WebRTC)
# cannot silently make the real SDK-dependent source disappear from this gate.
(work/'SDKImportGate.swift').write_text('import WebRTC\nprivate let peerSDKImportGate = RTCConfiguration.self\n')
PY
framework_dir="$(cat "$PEER_SDK_WORK/framework-directory.txt")"
sources=()
while IFS= read -r source; do sources+=("$source"); done < "$PEER_SDK_WORK/source-list.txt"
xcrun swiftc -typecheck -parse-as-library -swift-version 5 -DDEBUG \
  -sdk "$PEER_IOS_SDK" -target arm64-apple-ios17.0-simulator \
  -F "$framework_dir" -module-name TermLLM \
  -module-cache-path "$PEER_SDK_WORK/module-cache" \
  "${sources[@]}" "$PEER_SDK_WORK/SDKImportGate.swift" \
  2>&1 | tee "$PEER_SDK_OUTPUT/typecheck.log"
