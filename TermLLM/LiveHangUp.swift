import Foundation

extension Notification.Name {
    /// Posted on the main thread just before this app starts music or a podcast.
    static let appWillStartPlayback = Notification.Name("termllm.appWillStartPlayback")
}

/// Ends the page's live voice call when this app starts audio: an open call
/// keeps listening, so it hears the music and talks over it. Like
/// `VoiceLaunchScript`, it only presses the page's own Stop button and never
/// reaches into frontend stores.
///
/// When the agent started the audio through a device tool, the call must stay
/// up until that tool's result reaches the server, or the voice turn records
/// the tool as failed. The installed script watches (via resource timing, so
/// the page's fetch is untouched) for a live tool result upload to finish.
enum LiveHangUp {
    /// How long a deferred hang-up waits for the tool result upload.
    static let toolResultGrace: Duration = .seconds(4)

    /// Installed at document start in the main frame.
    static let userScript = """
    (() => {
      'use strict';
      if (window.__termLLMLiveHangUp) return;
      const RESULT = /\\/v1\\/live\\/sessions\\/[^/]+\\/tool_calls\\/[^/]+\\/result$/;
      let pending = false;
      const stopButton = () => {
        const buttons = [...document.querySelectorAll('button')].filter((b) => !b.disabled);
        return buttons.find((b) => b.closest('section[aria-label="Live voice"]') && b.textContent.trim() === 'Stop') ||
          buttons.find((b) => b.getAttribute('aria-label') === 'Stop live voice');
      };
      const stop = () => {
        pending = false;
        const button = stopButton();
        if (!button) return 'idle';
        button.click();
        return 'stopped';
      };
      try {
        new PerformanceObserver((list) => {
          if (!pending) return;
          for (const entry of list.getEntries()) {
            let path = '';
            try { path = new URL(entry.name).pathname; } catch { continue; }
            if (RESULT.test(path)) { stop(); return; }
          }
        }).observe({ type: 'resource' });
      } catch {}
      Object.defineProperty(window, '__termLLMLiveHangUp', {
        value: Object.freeze({
          // afterToolResult: wait for the next live tool result upload to finish.
          request(afterToolResult) {
            if (!stopButton()) { pending = false; return 'idle'; }
            if (!afterToolResult) return stop();
            pending = true;
            return 'pending';
          },
          // The grace period ran out: end a still-pending call regardless.
          flush() { return pending ? stop() : 'idle'; },
        }),
        configurable: true,
      });
    })();
    """

    static func requestScript(afterToolResult: Bool) -> String {
        "window.__termLLMLiveHangUp?.request(\(afterToolResult)); void 0;"
    }

    static let flushScript = "window.__termLLMLiveHangUp?.flush(); void 0;"
}
