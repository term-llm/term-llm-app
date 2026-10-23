# WebRTC SDK provenance (native peer connect)

The app links the prebuilt libwebrtc XCFramework published by **stasel/WebRTC**. Only the DataChannel/peer-connection APIs are used: no audio/video capture or tracks.

| Item | Value |
|---|---|
| Swift package | `https://github.com/stasel/WebRTC` |
| Pinned requirement | **revision** `44f36788497f701bc8c0306de3a1c2511d56019d` (tag `155.0.0`, upstream WebRTC M155). Xcode pins by commit, not by tag or branch. |
| Lockfile | `TermLLM.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` (same revision) |
| Binary target URL (from the pinned `Package.swift`) | `https://github.com/stasel/WebRTC/releases/download/155.0.0/WebRTC-M155.xcframework.zip` |
| Binary SHA-256 (in the pinned `Package.swift`; SwiftPM verifies it) | `cb9adacf2d6bbf598d1d9e3e6c16d8fb97ca987b5b697746891828f9dc068ffe` |
| Slices in the archive | ios-arm64, ios-x86_64_arm64-simulator, ios-x86_64_arm64-maccatalyst, macos-x86_64_arm64 |
| Archive `WebRTC.xcframework/LICENSE` SHA-256 | `ab00a482b6a3902e40211b43c5d0441962ea99b6cc7c25c0f243fa270b78d482` |

Verification so far:
- The archive was downloaded and hashed independently on 2026-10-23 and matched the checksum above.
- The pinned revision's `Package.swift` was read and declares that URL and checksum.
- The `peer-connect` workflow's `sdk-typecheck` job (PR #6, head `12cd565`) re-verified the checksum, typechecked every app source against the real arm64 simulator slice, and archived the upstream `Package.swift` and license files.
- That job is a typecheck only. A linked app build, installation and runtime interoperability are **not yet verified**.

## License

The archive ships a single `LICENSE` file, the WebRTC project's BSD 3-clause license, reproduced below.

**Open gap:** libwebrtc statically includes third-party components (for example BoringSSL, libsrtp, usrsctp, abseil-cpp, opus and libvpx), and this archive's LICENSE does not list their notices. Before App Store distribution, collect the third-party notices for M155 from the WebRTC source tree at the matching branch and add them to the app's acknowledgements. That has not been done here.

```text
Copyright (c) 2011, The WebRTC project authors. All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

  * Redistributions of source code must retain the above copyright
    notice, this list of conditions and the following disclaimer.

  * Redistributions in binary form must reproduce the above copyright
    notice, this list of conditions and the following disclaimer in
    the documentation and/or other materials provided with the
    distribution.

  * Neither the name of Google nor the names of its contributors may
    be used to endorse or promote products derived from this software
    without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```
