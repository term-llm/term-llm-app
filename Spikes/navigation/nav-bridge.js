// Spike: navigation bridge user script.
//
// Injected into the term-llm web UI (as a WKUserScript in the app, via
// addInitScript in the Playwright spike). It learns the active live call's
// live_id and the Authorization header the page uses by wrapping fetch, then
// exposes window.__termLLMNav.say(text), which pushes text into the call with
// the existing POST /v1/live/sessions/{live_id}/text endpoint.
//
// No term-llm changes: this depends on the web UI starting calls with fetch
// and sending Authorization: Bearer on same-origin API requests.
(() => {
  if (window.__termLLMNav) return;

  const state = { liveId: '', base: '', auth: '', log: [] };
  const handler = () => window.webkit?.messageHandlers?.termLLMNav;
  const notify = (event) => {
    state.log.push({ at: Date.now(), ...event });
    try { handler()?.postMessage(event); } catch (_) { /* native optional */ }
  };

  const startPath = /^(.*)\/v1\/live\/sessions\/?$/;
  const callPath = /^(.*)\/v1\/live\/sessions\/([^/]+)\/?$/;

  const authFrom = (input, init) => {
    const pick = (headers) => {
      if (!headers) return '';
      if (headers instanceof Headers) return headers.get('Authorization') || '';
      if (Array.isArray(headers)) {
        const pair = headers.find(([k]) => String(k).toLowerCase() === 'authorization');
        return pair ? String(pair[1]) : '';
      }
      for (const key of Object.keys(headers)) {
        if (key.toLowerCase() === 'authorization') return String(headers[key]);
      }
      return '';
    };
    return pick(init?.headers) || (input instanceof Request ? input.headers.get('Authorization') || '' : '');
  };

  const clear = (reason) => {
    if (!state.liveId) return;
    const liveId = state.liveId;
    state.liveId = '';
    notify({ type: 'call_ended', liveId, reason });
  };

  const originalFetch = window.fetch.bind(window);
  window.fetch = async (input, init) => {
    const rawURL = input instanceof Request ? input.url : String(input);
    const method = (init?.method || (input instanceof Request ? input.method : 'GET')).toUpperCase();
    let url;
    try { url = new URL(rawURL, location.href); } catch (_) { return originalFetch(input, init); }
    const sameOrigin = url.origin === location.origin;
    const response = await originalFetch(input, init);
    if (!sameOrigin) return response;
    try {
      const start = method === 'POST' && url.pathname.match(startPath);
      if (start && response.ok) {
        const body = await response.clone().json();
        if (body && typeof body.live_id === 'string' && body.live_id) {
          state.liveId = body.live_id;
          state.base = url.origin + start[1];
          state.auth = authFrom(input, init);
          notify({ type: 'call_started', liveId: state.liveId, hasAuth: Boolean(state.auth) });
        }
      }
      const call = method === 'DELETE' && url.pathname.match(callPath);
      if (call && decodeURIComponent(call[2]) === state.liveId) clear('deleted');
    } catch (error) {
      notify({ type: 'bridge_error', message: String(error) });
    }
    return response;
  };

  async function say(text) {
    const trimmed = String(text || '').trim();
    if (!trimmed) return { ok: false, error: 'empty' };
    if (!state.liveId) return { ok: false, error: 'no_call' };
    const headers = { 'Content-Type': 'application/json' };
    if (state.auth) headers.Authorization = state.auth;
    const target = `${state.base}/v1/live/sessions/${encodeURIComponent(state.liveId)}/text`;
    const response = await originalFetch(target, { method: 'POST', headers, body: JSON.stringify({ text: trimmed }) });
    if (response.status === 404) clear('not_found');
    if (!response.ok) return { ok: false, status: response.status, error: (await response.text()).slice(0, 300) };
    notify({ type: 'said', text: trimmed });
    return { ok: true };
  }

  window.__termLLMNav = {
    say,
    state: () => ({ liveId: state.liveId, base: state.base, hasAuth: Boolean(state.auth) }),
    log: () => state.log.slice(),
  };
})();
