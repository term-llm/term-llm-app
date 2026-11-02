import Foundation
import WebKit

/// One redacted activity report from the injected page probe. Every field is a
/// count, a duration or a short code-defined name (CSS animation/class); never
/// page text, URLs, titles or form values.
struct WebPageHealthSample: Equatable, Sendable {
    struct Animation: Equatable, Sendable, Hashable {
        /// CSS animation name, `transition:<property>`, or `script`.
        let name: String
        /// `tag.class.class` of the animated element (plus `::before`-style pseudo).
        let target: String
        let properties: [String]
        let infinite: Bool
        /// Only transform/opacity-type properties: Core Animation can run it
        /// without the page repainting every frame.
        let composited: Bool
    }

    let documentID: String
    /// Native-issued measurement window, echoed only after the probe resets.
    let windowID: String?
    let sequence: Int
    /// Wall time this report covers.
    let spanSeconds: Double
    let visibility: String
    let hiddenSeconds: Double
    let ticks: Int
    /// Heartbeat lateness beyond jitter while visible: time the page's main
    /// thread kept a 1 s timer waiting (a lower bound of busy time).
    let lateMilliseconds: Double
    let maxLateMilliseconds: Double
    /// Distinct animation frames in which page requestAnimationFrame callbacks ran.
    let frames: Int
    let frameCallbackMilliseconds: Double
    /// DOM changes seen while counting, which runs for one second per
    /// visible report only (see `mutationSeconds`).
    let mutations: Int
    let mutationSeconds: Double
    let resources: Int
    let longTasks: Int?
    let domNodes: Int?
    /// Measured only while WebKit reports the page visible.
    let runningAnimations: Int
    let animations: [Animation]
    let audioContextsRunning: Int
    let audioContexts: Int
    let liveTracks: Int
    let peerConnections: Int
    let webSockets: Int
    let eventSources: Int
    let mediaPlaying: Int
    /// Time the probe itself ran in the page during this span.
    let probeMilliseconds: Double

    var isVisible: Bool { visibility == "visible" }
    var visibleSeconds: Double { max(0, spanSeconds - hiddenSeconds) }
    var busyFraction: Double {
        let visible = visibleSeconds
        return visible >= 0.5 ? min(1, lateMilliseconds / 1000 / visible) : 0
    }
    var framesPerSecond: Double { spanSeconds > 0 ? Double(frames) / spanSeconds : 0 }
    var mutationsPerSecond: Double { mutationSeconds >= 0.2 ? Double(mutations) / mutationSeconds : 0 }
    var resourcesPerMinute: Double { spanSeconds > 0 ? Double(resources) * 60 / spanSeconds : 0 }
    /// Share of one core the probe used.
    var probeShare: Double { spanSeconds > 0 ? probeMilliseconds / 1000 / spanSeconds : 0 }
    /// Running animations the page must restyle/repaint itself every frame.
    var repaintingAnimations: [Animation] { animations.filter { !$0.composited } }
}

/// Injected at document start in the configured server's main frame (page
/// world, so it can count the page's own requestAnimationFrame/AudioContext
/// use). Built to cost next to nothing, and to say what it costs:
/// - on screen, a 1 s heartbeat measures main-thread blocking and a report
///   goes out every 5 s;
/// - hidden, WebKit draws nothing and throttles timers, so the probe only
///   reports every 15 s and skips its animation and DOM scans. A suspended
///   page runs nothing at all;
/// - a document-wide MutationObserver makes every DOM change allocate a
///   record, so DOM changes are counted for one second per visible report;
/// - animation descriptions are cached per animation object;
/// - it times its own work and includes that in every report.
enum WebKitHealthProbe {
    static let handlerName = "termllmHealth"
    static let version = 2
    static let maximumAnimations = 8

    static func script(origin: String, reportMilliseconds: Int = 5_000, hiddenMilliseconds: Int = 15_000) -> String {
        func literal(_ value: String) -> String { String(decoding: JSONValue.string(value).encoded(), as: UTF8.self) }
        return """
        (() => {
          'use strict';
          const ORIGIN = \(literal(origin));
          if (location.origin !== ORIGIN || window.__termLLMHealthProbe) return;
          const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[\(literal(handlerName))];
          if (!handler) return;
          try { Object.defineProperty(window, '__termLLMHealthProbe', { value: true }); } catch { return; }
          const now = () => performance.now();
          const visible = () => document.visibilityState === 'visible';
          const TICK = 1000, REPORT = \(max(1_000, reportMilliseconds)), HIDDEN = \(max(1_000, hiddenMilliseconds));
          const JITTER = 50, MAX_ANIMATIONS = \(maximumAnimations), MUTATION_WINDOW = 1000, DOM_EVERY = 60000;
          const doc = (crypto.randomUUID ? crypto.randomUUID() : String(Math.random()).slice(2)).slice(0, 40);
          let seq = 0, windowID = null, start = now(), expected = 0, timer = 0, hiddenSince = visible() ? -1 : start;
          let observationSince = start;
          let hiddenMs = 0, ticks = 0, lateMs = 0, maxLateMs = 0, probeMs = 0;
          let frames = 0, frameMs = 0, lastFrame = -1, resources = 0, longTasks = 0;
          let mutations = 0, mutationMs = 0, observingSince = -1;
          let domNodes = -1, domAt = -Infinity;
          const sets = { audio: new Set(), peers: new Set(), sockets: new Set(), sources: new Set(), streams: new Set(), media: new Set() };
          const count = (set, test) => {
            let n = 0;
            for (const ref of set) {
              const value = ref.deref();
              if (!value) { set.delete(ref); continue; }
              try { n += test(value); } catch {}
            }
            return n;
          };
          const remember = (set, value) => {
            if (!value || typeof WeakRef !== 'function') return;
            if (set.size >= 64) count(set, () => 0);
            if (set.size < 64) set.add(new WeakRef(value));
          };
          const track = (name, set) => {
            const Original = window[name];
            if (typeof Original !== 'function') return;
            try {
              window[name] = new Proxy(Original, {
                construct(target, args, newTarget) {
                  const instance = Reflect.construct(target, args, newTarget);
                  try { remember(set, instance); } catch {}
                  return instance;
                },
              });
            } catch {}
          };
          track('AudioContext', sets.audio);
          track('webkitAudioContext', sets.audio);
          track('RTCPeerConnection', sets.peers);
          track('WebSocket', sets.sockets);
          track('EventSource', sets.sources);
          try {
            const proto = window.MediaDevices && MediaDevices.prototype;
            const original = proto && proto.getUserMedia;
            if (typeof original === 'function') {
              proto.getUserMedia = function getUserMedia(...args) {
                const result = original.apply(this, args);
                Promise.resolve(result).then((stream) => { try { remember(sets.streams, stream); } catch {} }, () => {});
                return result;
              };
            }
          } catch {}
          try {
            const proto = window.HTMLMediaElement && HTMLMediaElement.prototype;
            const original = proto && proto.play;
            if (typeof original === 'function') {
              proto.play = function play(...args) {
                try { remember(sets.media, this); } catch {}
                return original.apply(this, args);
              };
            }
          } catch {}
          try {
            const raf = window.requestAnimationFrame;
            if (typeof raf === 'function') {
              window.requestAnimationFrame = function requestAnimationFrame(callback) {
                if (typeof callback !== 'function') return raf.call(window, callback);
                return raf.call(window, function (time) {
                  if (time !== lastFrame) { lastFrame = time; frames++; }
                  const began = now();
                  try { return callback.call(this, time); } finally { frameMs += now() - began; }
                });
              };
            }
          } catch {}
          let observer = null;
          try { observer = new MutationObserver((records) => { mutations += records.length; }); } catch {}
          const observe = (t) => {
            if (!observer || observingSince >= 0) return;
            try {
              observer.observe(document, { subtree: true, childList: true, attributes: true, characterData: true });
              observingSince = t;
            } catch {}
          };
          const unobserve = (t) => {
            if (observingSince < 0) return;
            try { mutations += observer.takeRecords().length; } catch {}
            try { observer.disconnect(); } catch {}
            mutationMs += t - observingSince;
            observingSince = -1;
          };
          try { new PerformanceObserver((list) => { resources += list.getEntries().filter((entry) => entry.startTime >= observationSince).length; }).observe({ type: 'resource' }); } catch {}
          let longTaskSupport = false;
          try {
            if ((PerformanceObserver.supportedEntryTypes || []).includes('longtask')) {
              new PerformanceObserver((list) => { longTasks += list.getEntries().filter((entry) => entry.startTime >= observationSince).length; }).observe({ type: 'longtask' });
              longTaskSupport = true;
            }
          } catch {}
          const COMPOSITED = new Set(['transform', 'opacity', 'translate', 'rotate', 'scale']);
          const META = new Set(['offset', 'computedOffset', 'easing', 'composite']);
          const label = (element) => {
            if (!element || !element.tagName) return '';
            const classes = element.classList && element.classList.length ? '.' + Array.from(element.classList).slice(0, 2).join('.') : '';
            return (element.tagName.toLowerCase() + classes).slice(0, 48);
          };
          const kebab = (name) => String(name).replace(/[A-Z]/g, (c) => '-' + c.toLowerCase());
          const described = new WeakMap();
          const describe = (animation) => {
            const cached = described.get(animation);
            if (cached) return cached;
            const effect = animation.effect;
            let props = [];
            if (animation.transitionProperty) props = [kebab(animation.transitionProperty)];
            else {
              try {
                const keys = new Set();
                for (const frame of (effect && effect.getKeyframes ? effect.getKeyframes() : [])) {
                  for (const key of Object.keys(frame)) if (!META.has(key)) keys.add(kebab(key));
                }
                props = Array.from(keys).slice(0, 6);
              } catch {}
            }
            const name = animation.animationName || (animation.transitionProperty ? 'transition:' + kebab(animation.transitionProperty) : 'script');
            let infinite = false;
            try { infinite = effect.getComputedTiming().iterations === Infinity; } catch {}
            const target = effect && effect.target ? label(effect.target) + (effect.pseudoElement || '') : '';
            const entry = { name: String(name).slice(0, 48), target: target.slice(0, 64), props, infinite,
              composited: props.length > 0 && props.every((p) => COMPOSITED.has(p)) };
            try { described.set(animation, entry); } catch {}
            return entry;
          };
          const animations = () => {
            let running = 0;
            const seen = new Map();
            let list = [];
            try { list = document.getAnimations(); } catch {}
            for (const animation of list) {
              if (animation.playState !== 'running') continue;
              running++;
              if (seen.size >= MAX_ANIMATIONS) continue;
              const entry = describe(animation);
              const key = entry.name + '|' + entry.target;
              if (!seen.has(key)) seen.set(key, entry);
            }
            return { running, list: Array.from(seen.values()) };
          };
          // The caller's own timing covers this report; its cost lands in the next span.
          const report = (t) => {
            const shown = visible();
            if (hiddenSince >= 0) { hiddenMs += t - hiddenSince; hiddenSince = t; }
            if (shown && t - domAt >= DOM_EVERY) {
              domAt = t;
              try { domNodes = document.getElementsByTagName('*').length; } catch {}
            }
            unobserve(t);
            const anim = shown ? animations() : { running: 0, list: [] };
            const sample = {
              v: \(version), doc, window: windowID, seq: seq++, span: t - start, vis: document.visibilityState, hidden: hiddenMs, ticks,
              late: lateMs, maxLate: maxLateMs, frames, frameMs, mutations, mutMs: mutationMs, resources,
              longTasks: longTaskSupport ? longTasks : -1, dom: domNodes, running: anim.running, anims: anim.list,
              audio: count(sets.audio, (c) => c.state === 'running' ? 1 : 0),
              audioTotal: count(sets.audio, (c) => c.state !== 'closed' ? 1 : 0),
              tracks: count(sets.streams, (s) => s.getTracks().filter((track) => track.readyState === 'live').length),
              peers: count(sets.peers, (p) => p.connectionState !== 'closed' && p.signalingState !== 'closed' ? 1 : 0),
              sockets: count(sets.sockets, (s) => s.readyState < 2 ? 1 : 0),
              sources: count(sets.sources, (s) => s.readyState < 2 ? 1 : 0),
              media: count(sets.media, (m) => !m.paused && !m.ended ? 1 : 0),
              probe: probeMs,
            };
            start = t; hiddenMs = 0; ticks = 0; lateMs = 0; maxLateMs = 0; probeMs = 0;
            frames = 0; frameMs = 0; mutations = 0; mutationMs = 0; resources = 0; longTasks = 0;
            try { handler.postMessage(sample); } catch {}
            // Count DOM changes for the first second of the next visible span.
            if (shown) observe(now());
          };
          const schedule = (t) => {
            clearTimeout(timer);
            const delay = visible() ? TICK : HIDDEN;
            expected = t + delay;
            timer = setTimeout(tick, delay);
          };
          const tick = () => {
            const t = now();
            if (visible()) {
              const late = Math.max(0, t - expected);
              if (late > JITTER) lateMs += late - JITTER;
              if (late > maxLateMs) maxLateMs = late;
              if (observingSince >= 0 && t - observingSince >= MUTATION_WINDOW - JITTER) unobserve(t);
            }
            ticks++;
            if (t - start >= (visible() ? REPORT : HIDDEN) - JITTER) report(t);
            schedule(now());
            probeMs += now() - t;
          };
          // Suspension is not main-thread work. Discard spans crossing lifecycle
          // boundaries, including an overdue heartbeat, rather than reporting them.
          const resetWindow = () => {
            const t = now();
            unobserve(t);
            start = t; observationSince = t; hiddenSince = visible() ? -1 : t;
            hiddenMs = 0; ticks = 0; lateMs = 0; maxLateMs = 0; probeMs = 0;
            frames = 0; frameMs = 0; lastFrame = -1; mutations = 0; mutationMs = 0; resources = 0; longTasks = 0;
            if (visible()) observe(t);
            schedule(t);
          };
          // Native never waits for this call. Its token makes queued pre-reset
          // reports unusable even when message and notification delivery race.
          try {
            Object.defineProperty(window, '__termLLMHealthResetWindow', { value: (id) => {
              windowID = id;
              resetWindow();
            } });
          } catch {}
          document.addEventListener('visibilitychange', resetWindow);
          document.addEventListener('freeze', resetWindow);
          document.addEventListener('resume', resetWindow);
          window.addEventListener('pagehide', resetWindow);
          window.addEventListener('pageshow', resetWindow);
          schedule(start);
        })();
        """
    }

    /// A bounded, fire-and-forget reset; no navigation, document replacement or
    /// dependency on JavaScript responsiveness in the native navigation path.
    static func resetScript(windowID: String) -> String {
        let literal = String(decoding: JSONValue.string(windowID).encoded(), as: UTF8.self)
        return "window.__termLLMHealthResetWindow?.(\(literal)); void 0;"
    }

    // MARK: Parsing (untrusted page input)

    static func parse(_ body: Any) -> WebPageHealthSample? {
        guard let object = body as? [String: Any], (object["v"] as? NSNumber)?.intValue == version,
              let documentID = token(object["doc"], limit: 40), !documentID.isEmpty,
              let span = number(object["span"], max: 86_400_000), span > 0 else { return nil }
        func int(_ key: String, max: Double = 10_000_000) -> Int { Int(number(object[key], max: max) ?? 0) }
        func optionalInt(_ key: String) -> Int? {
            guard let value = number(object[key], min: -1, max: 100_000_000), value >= 0 else { return nil }
            return Int(value)
        }
        func milliseconds(_ key: String) -> Double { min(span, number(object[key], max: 86_400_000) ?? 0) }
        var animations: [WebPageHealthSample.Animation] = []
        for item in (object["anims"] as? [Any] ?? []).prefix(maximumAnimations) {
            guard let entry = item as? [String: Any], let name = token(entry["name"], limit: 48), !name.isEmpty else { continue }
            let properties = (entry["props"] as? [Any] ?? []).prefix(6).compactMap { token($0, limit: 32) }.filter { !$0.isEmpty }
            animations.append(.init(name: name, target: token(entry["target"], limit: 64) ?? "",
                                    properties: properties, infinite: entry["infinite"] as? Bool ?? false,
                                    composited: entry["composited"] as? Bool ?? false))
        }
        let visibility = token(object["vis"], limit: 16) ?? "unknown"
        return WebPageHealthSample(
            documentID: documentID,
            windowID: token(object["window"], limit: 40),
            sequence: int("seq", max: Double(Int32.max)),
            spanSeconds: span / 1000,
            visibility: ["visible", "hidden", "prerender"].contains(visibility) ? visibility : "unknown",
            hiddenSeconds: milliseconds("hidden") / 1000,
            ticks: int("ticks"),
            lateMilliseconds: milliseconds("late"),
            maxLateMilliseconds: number(object["maxLate"], max: 86_400_000) ?? 0,
            frames: int("frames"),
            frameCallbackMilliseconds: milliseconds("frameMs"),
            mutations: int("mutations", max: 1_000_000_000),
            mutationSeconds: milliseconds("mutMs") / 1000,
            resources: int("resources"),
            longTasks: optionalInt("longTasks"),
            domNodes: optionalInt("dom"),
            runningAnimations: int("running", max: 100_000),
            animations: animations,
            audioContextsRunning: int("audio", max: 64),
            audioContexts: int("audioTotal", max: 64),
            liveTracks: int("tracks", max: 1_024),
            peerConnections: int("peers", max: 64),
            webSockets: int("sockets", max: 64),
            eventSources: int("sources", max: 64),
            mediaPlaying: int("media", max: 64),
            probeMilliseconds: milliseconds("probe"))
    }

    private static func number(_ value: Any?, min lower: Double = 0, max upper: Double) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        let double = value.doubleValue
        guard double.isFinite else { return nil }
        return Swift.min(upper, Swift.max(lower, double))
    }

    /// Code-defined identifiers only: anything else becomes `?`, so free text
    /// can never travel through a diagnostics report.
    static func token(_ value: Any?, limit: Int, allowingSpaces: Bool = false) -> String? {
        guard let string = value as? String else { return nil }
        let allowed = allowingSpaces ? tokenCharacters.union(CharacterSet(charactersIn: " ")) : tokenCharacters
        var result = ""
        for scalar in string.unicodeScalars.prefix(limit) {
            result.unicodeScalars.append(allowed.contains(scalar) ? scalar : "?")
        }
        return result
    }

    private static let tokenCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.:#")
}

/// Installs the probe and receives its reports for one browser view. Only the
/// configured origin's main frame is accepted, and reports are rate limited.
final class WebKitHealthBridge: NSObject, WKScriptMessageHandler {
    let serverURL: URL
    private(set) var userScript: WKUserScript
    /// Weak: the controller retains its message handlers (this bridge).
    private weak var installedController: WKUserContentController?
    private var lastAccepted: TimeInterval = -.infinity
    var onSample: (WebPageHealthSample, WKWebView?) -> Void = { _, _ in }

    init(serverURL: URL, reportMilliseconds: Int = 5_000, hiddenMilliseconds: Int = 15_000) {
        self.serverURL = serverURL
        userScript = WKUserScript(source: WebKitHealthProbe.script(origin: NativeLogin.origin(for: serverURL),
                                                                    reportMilliseconds: reportMilliseconds,
                                                                    hiddenMilliseconds: hiddenMilliseconds),
                                  injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page)
    }

    var expectedOrigin: String { NativeLogin.origin(for: serverURL) }
    var isInstalled: Bool { installedController != nil }

    /// Idempotent. Applies to documents loaded after installation.
    func install(into controller: WKUserContentController) {
        guard installedController !== controller else { return }
        controller.removeScriptMessageHandler(forName: WebKitHealthProbe.handlerName, contentWorld: .page)
        controller.addUserScript(userScript)
        controller.add(self, contentWorld: .page, name: WebKitHealthProbe.handlerName)
        installedController = controller
    }

    func uninstall() {
        guard let controller = installedController else { return }
        controller.removeScriptMessageHandler(forName: WebKitHealthProbe.handlerName, contentWorld: .page)
        controller.removeUserScript(userScript)
        installedController = nil
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let origin = message.frameInfo.securityOrigin
        guard message.frameInfo.isMainFrame,
              WebMCPBridge.originString(scheme: origin.protocol, host: origin.host, port: origin.port) == expectedOrigin else { return }
        // A page can post at will; a genuine probe reports every 5 s at most
        // (plus once per visibility change).
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastAccepted >= 0.2, let sample = WebKitHealthProbe.parse(message.body) else { return }
        lastAccepted = now
        onSample(sample, message.webView)
    }
}
