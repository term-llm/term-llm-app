// Offline check of nav-bridge.js: stubbed fetch, no network.
// Run: node --test Spikes/navigation/bridge.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const source = readFileSync(join(dirname(fileURLToPath(import.meta.url)), 'nav-bridge.js'), 'utf8');

function load(liveId = 'live_abc') {
  const calls = [];
  const posted = [];
  const fakeFetch = async (input, init = {}) => {
    const url = input instanceof Request ? input.url : String(input);
    const method = (init.method || 'GET').toUpperCase();
    calls.push({ url, method, init });
    if (method === 'POST' && /\/v1\/live\/sessions$/.test(url)) {
      return new Response(JSON.stringify({ live_id: liveId, session_id: 's1', transport: 'webrtc', sdp: 'x' }), { status: 200 });
    }
    if (method === 'POST' && url.endsWith('/text')) {
      return url.includes('live_gone') ? new Response('not found', { status: 404 }) : new Response('{"ok":true}', { status: 200 });
    }
    return new Response('{}', { status: 200 });
  };
  const window = {
    fetch: fakeFetch,
    webkit: { messageHandlers: { termLLMNav: { postMessage: (m) => posted.push(m) } } },
  };
  const location = { href: 'https://node.example/ui/s/1', origin: 'https://node.example' };
  new Function('window', 'location', source)(window, location);
  return { window, calls, posted };
}

test('captures live_id, base path and Authorization from the page start request', async () => {
  const { window, posted } = load();
  const headers = new Headers({ Authorization: 'Bearer secret', 'Content-Type': 'application/json' });
  await window.fetch('/ui/v1/live/sessions', { method: 'POST', headers, body: '{}' });
  assert.deepEqual(window.__termLLMNav.state(), { liveId: 'live_abc', base: 'https://node.example/ui', hasAuth: true });
  assert.deepEqual(posted[0], { type: 'call_started', liveId: 'live_abc', hasAuth: true });
});

test('say posts to /text with the captured header and a JSON body', async () => {
  const { window, calls } = load();
  await window.fetch('https://node.example/ui/v1/live/sessions', { method: 'POST', headers: { authorization: 'Bearer secret' } });
  const result = await window.__termLLMNav.say('  Turn left now  ');
  assert.deepEqual(result, { ok: true });
  const post = calls.at(-1);
  assert.equal(post.url, 'https://node.example/ui/v1/live/sessions/live_abc/text');
  assert.equal(post.init.headers.Authorization, 'Bearer secret');
  assert.deepEqual(JSON.parse(post.init.body), { text: 'Turn left now' });
});

test('no call yet means no_call, and nothing is posted', async () => {
  const { window, calls } = load();
  assert.deepEqual(await window.__termLLMNav.say('hi'), { ok: false, error: 'no_call' });
  assert.equal(calls.length, 0);
});

test('DELETE of the call clears it', async () => {
  const { window, posted } = load();
  await window.fetch('/ui/v1/live/sessions', { method: 'POST', headers: { Authorization: 'Bearer s' } });
  await window.fetch('/ui/v1/live/sessions/live_abc', { method: 'DELETE' });
  assert.equal(window.__termLLMNav.state().liveId, '');
  assert.deepEqual(posted.at(-1), { type: 'call_ended', liveId: 'live_abc', reason: 'deleted' });
});

test('other origins and unrelated routes are ignored', async () => {
  const { window } = load();
  await window.fetch('https://evil.example/ui/v1/live/sessions', { method: 'POST' });
  await window.fetch('/ui/v1/responses', { method: 'POST' });
  assert.equal(window.__termLLMNav.state().liveId, '');
});

test('404 from /text clears a stale call', async () => {
  const { window, posted } = load('live_gone');
  await window.fetch('/ui/v1/live/sessions', { method: 'POST', headers: { Authorization: 'Bearer s' } });
  const result = await window.__termLLMNav.say('Turn right');
  assert.equal(result.ok, false);
  assert.equal(result.status, 404);
  assert.equal(window.__termLLMNav.state().liveId, '');
  assert.deepEqual(posted.at(-1), { type: 'call_ended', liveId: 'live_gone', reason: 'not_found' });
});
