# Listen playback CPU investigation

## Evidence and limits (2 November 2026)

A physical-device health report showed sustained native app CPU during podcast playback: approximately 55% of one core in the foreground and 37–39% in the background. The later background intervals had no managed Listen download bytes, no active device-tool calls, and a hidden page reporting no WebRTC or page media. The user reports that pausing reduces CPU but does not restore idle CPU. Restarting initially restores low CPU; resuming can reproduce the problem.

These counters identify a real native-process workload, not its functions. The user confirms that pressing Play repeatedly triggers the CPU rise; playback is the established trigger. The health report alone did not attribute the expensive work; the later physical-device trace below narrows it to retained Chat/bridge activity. Page heartbeat and resource counts do not exclude WebKit internals. A zero download-byte window does not exclude local resource-loader reads, native decoding, or framework callbacks.

An isolated iOS 26.5 simulator test using the real AVPlayer and AVAudioSession, synthetic silent MP3 data, and the managed transfer path measured roughly 1.3–1.4% of a core playing, 1% paused, and 0.8–0.9% stopped across three lifetimes. A separate 90-second playback-only comparison also stayed near 1.2–1.3%. These are test-host measurements, not iPhone power/thermal results. They do not reproduce the reported device CPU problem or exercise a real WebRTC call.

A further simulator fixture includes the production `ListenPlayer`/store, real audio session and AVPlayer, `SystemNowPlaying`, shared MusicKit observation, and the native tab accessory. Five-second windows measured about 1.3% playing at 1×, 1.7% at 1.5×, 0.5% paused, and 1.5% playing with the fallback shelf; hiding the window did not reveal a sustained plateau. This narrows the reproduction gap but still uses synthetic MP3 data, iOS 26.5, and no actual live voice call; it does not disprove the iOS 27 physical-device observation.

## Physical-device trace and retained-Chat comparison

A 25-second physical-device Time Profiler capture collected 9.486 seconds of sampled thread time. Inclusive categories overlap: 6.211 seconds (65.5%) included WebKit frames, 3.727 seconds (39.3%) included WebKit process-throttling frames, and only 0.004 seconds included AVFoundation/AVFAudio frames. The main thread accounted for 6.117 seconds. Repeated JavaScript evaluation, script-message replies, and process suspend/resume bookkeeping were hot. Release app frames were not fully symbolicated, so the trace alone does not name every Swift caller.

The user then paused only the retained Chat page while leaving the podcast playing and reported that CPU went way down. That identifies the retained page/native bridge as the large excess workload in this reproduction, rather than the decoder alone. A second profiler attachment failed to resolve the process, so the drop is a user-observed comparison, not a measured post-fix trace.

Source investigation found an unbounded retry path in the Chat frontend's `NotificationOwner.publish()` (`frontend/src/platform/notification-owner.ts` in the core repository). A failed `bind()` returns before updating the cached `active` state. Its completion handler immediately republishes whenever current attendance differs from that cached state. For example, a successfully active document becomes hidden and detached from its native window; native capabilities fail closed without an owner scene, but cached `active` remains true. Each failure then immediately triggers another capability request and native live-document JavaScript check. Audio playback can keep this workload scheduled in the background.

The root fix belongs in the server-served Chat frontend: immediate follow-up publication must be based on an attendance transition during the current attempt, not a mismatch left by an earlier successful attempt. Regression tests fail against the old implementation (including repeated hidden-document capability calls) and pass after the fix. The full frontend suite (2,102 tests), formatting/lint/type checks, frontend build, embedded-asset tests and complexity check passed. Native nonce validation and fail-closed capability checks were not weakened. Updating the iOS app alone with the unrelated handover/observer fixes is not a claim that this frontend loop is corrected; the server must serve the corrected frontend and Chat must load it. The user requested keeping changes only, so no running server was replaced/restarted and physical-device revalidation with the fixed frontend remains pending.

## Additional native correctness fixes

- MCP playback handover now waits for the playback-initiating invocation's native reply rather than all outstanding tools. A real WebKit/WebMCP fixture driving `media_add`, native playback notification, HTTP result upload, and a page Stop button failed against the old implementation while an unrelated tool remained running; it passes with the fix. Audio and voice UI in that fixture are test doubles, not a live voice server.
- Deferred handover is invalidated when the document or bridge is replaced, the page process terminates, or the coordinator is torn down. Superseding a handover also disarms its JavaScript resource observer.
- AVPlayer's periodic time observer and block-based notification observers are explicitly removed when the engine is released.

## Apple guidance applied to this implementation

- **Retain AVPlayer for native media playback.** Changing playback frameworks without a measured bottleneck is not a diagnosis.
- **Keep `.timeDomain` for speech rate control.** Apple describes it as suitable for voice and less computationally intensive than `.spectral`. Do not switch to a higher-cost algorithm as a speculative fix.
- **Bound observer work and end its lifetime explicitly.** Buffer KVO notifications already share one pending delivery at a 250 ms cadence. Apple requires pairing every periodic-time-observer registration with `removeTimeObserver`; dropping its token alone is undefined behavior.
- **Do less background work.** Only essential audio, transfer, and persistence work should continue. Stop UI-only work when hidden/backgrounded, while preserving audio, lock-screen controls, interruptions, and saved positions.
- **Trace the physical-device workload.** Audio-session configuration, custom resource loading, MusicKit observation, and pitch processing are hypotheses until their stacks/activity correlate with the CPU plateau. Do not change stall waiting or abandon per-source authentication/caching merely on the basis of CPU counters.

Sources:

- [Apple: AVPlayer periodic time observer, including cleanup requirements](https://developer.apple.com/documentation/avfoundation/avplayer/addperiodictimeobserver(forinterval:queue:using:))
- [Apple: timeDomain pitch algorithm](https://developer.apple.com/documentation/avfoundation/avaudiotimepitchalgorithm/timedomain)
- [Apple: Work Less in the Background](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/EnergyGuide-iOS/WorkLessInTheBackground.html)
- [Apple: Measuring your app's power use with Power Profiler](https://developer.apple.com/documentation/xcode/measuring-your-app-s-power-use-with-power-profiler)
- [Apple: AVAssetResourceLoader](https://developer.apple.com/documentation/avfoundation/avassetresourceloader)

## Reproduction and the next device check

The automated suites are `LiveHangUpTests`, `BrowserLifecycleTests`, `WebMCPBridgeTests`, `ListenEngineTransferTests`, and `ListenAudioSessionTests`. For a longer local simulator comparison, pass these environment variables to `xcodebuild test` with an explicit simulator destination and select `ListenEngineTransferTests/testRepeatedStreamPlaybackKeepsBufferCallbacksBounded`:

```sh
TEST_RUNNER_TERMLLM_LISTEN_CPU_SAMPLE_SECONDS=10 \
TEST_RUNNER_TERMLLM_LISTEN_REAL_AUDIO_SESSION=1 \
xcodebuild test ...
```

The test writes a `simulator-stream-playback-cpu-diagnostics` attachment into its xcresult. Sample windows default to two seconds and are capped at sixty. The real-audio-session option adds paused and stopped windows; normal CI uses a stub session to avoid changing system audio-session state unnecessarily. CPU values are diagnostics, not portable pass/fail thresholds.

On the affected physical phone, record Time Profiler (and optionally Power Profiler) through: live voice → MCP-started podcast → playing → paused → fully stopped. Keep the same episode and record transition times. Pausing retains the player item; fully stopping must unload it, not merely hide the shelf. If necessary, separately compare after pausing the Chat page (which closes its retained document, so protect drafts first). Inspect main-thread and framework stacks during the sustained plateau rather than only startup. This distinguishes player/resource-loader work, audio-session handover state, MusicKit callbacks, and WebKit/native IPC. Do not label this device issue resolved based on simulator fixtures.
