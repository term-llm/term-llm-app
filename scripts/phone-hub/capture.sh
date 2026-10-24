#!/usr/bin/env bash
# Reuse the working native Hub simulator pipeline; only its test fixture differs.
set -euo pipefail
export NATIVE_HUB_ARTIFACT_SUBDIR=phone-hub-artifacts
export NATIVE_HUB_FIXTURE_PORT=8767
export NATIVE_HUB_FIXTURE_SERVER=scripts/phone-hub/fixture_server.py
export NATIVE_HUB_VIDEO_NAME=phone-hub-demo-fixture.mp4
export NATIVE_HUB_UNIT_SUITES='HubConnectionStoreTests HubAggregateStoreTests DirectNodeClientTests DirectNodeClientModelTests DirectNodeClientMountTests DirectNodeClientCookieFilterTests HubConnectionSecurityTests ListenToolsTests ListenPlayerTests ListenStoreTests ListenMediaTransportTests'
export NATIVE_HUB_UI_SUITE=PhoneHubUITests
export NATIVE_HUB_CAPTURE_VERIFIER=scripts/phone-hub/verify_capture.py
exec bash scripts/native-hub/capture.sh
