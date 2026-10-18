// Spike 1+2: start a real live call in headless Chromium against a local
// term-llm server, verify the injected nav bridge captures live_id + auth
// (spike 2), then push navigation updates through /text and record how the
// voice model reacts (spike 1).
//
// Usage: BASE=http://127.0.0.1:8099/ui TOKEN=... node spike.mjs
import { createRequire } from 'node:module';
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const require = createRequire(process.env.PLAYWRIGHT_FROM || join(here, '../../../term-llm/frontend/package.json'));
const { chromium } = require('playwright');

const BASE = process.env.BASE || 'http://127.0.0.1:8099/ui';
const TOKEN = process.env.TOKEN || 'navspike-token';
const t0 = Date.now();
const ts = () => ((Date.now() - t0) / 1000).toFixed(1).padStart(6);
const log = (...a) => console.log(`[${ts()}]`, ...a);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// 60 s of 16 kHz mono silence so the fake mic never sounds like speech.
const wav = join('/tmp', 'navspike-silence.wav');
{
  const samples = 16000 * 60, data = samples * 2, b = Buffer.alloc(44 + data);
  b.write('RIFF', 0); b.writeUInt32LE(36 + data, 4); b.write('WAVE', 8); b.write('fmt ', 12);
  b.writeUInt32LE(16, 16); b.writeUInt16LE(1, 20); b.writeUInt16LE(1, 22); b.writeUInt32LE(16000, 24);
  b.writeUInt32LE(32000, 28); b.writeUInt16LE(2, 32); b.writeUInt16LE(16, 34); b.write('data', 36); b.writeUInt32LE(data, 40);
  writeFileSync(wav, b);
}

const browser = await chromium.launch({
  headless: true,
  ...(process.env.CHROME ? { executablePath: process.env.CHROME } : {}),
  args: ['--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream', `--use-file-for-fake-audio-capture=${wav}`, '--autoplay-policy=no-user-gesture-required'],
});
const context = await browser.newContext({ permissions: ['microphone'] });
await context.addInitScript((token) => { try { localStorage.setItem('term_llm_token', token); } catch (_) {} }, TOKEN);
await context.addInitScript({ content: readFileSync(join(here, 'nav-bridge.js'), 'utf8') });
const page = await context.newPage();
page.on('pageerror', (e) => log('pageerror', e.message));

// ---- SSE observer (Node side, bearer auth) ----
const events = [];
let sseAbort;
async function watch(liveId) {
  sseAbort = new AbortController();
  const res = await fetch(`${BASE}/v1/live/sessions/${encodeURIComponent(liveId)}/events`, {
    headers: { Authorization: `Bearer ${TOKEN}`, Accept: 'text/event-stream' }, signal: sseAbort.signal,
  });
  log('events stream', res.status);
  const decoder = new TextDecoder();
  let buf = '';
  try {
    for await (const chunk of res.body) {
      buf += decoder.decode(chunk, { stream: true });
      let i;
      while ((i = buf.indexOf('\n\n')) >= 0) {
        const block = buf.slice(0, i); buf = buf.slice(i + 2);
        let type = 'message', data = '';
        for (const line of block.split('\n')) {
          if (line.startsWith('event:')) type = line.slice(6).trim();
          else if (line.startsWith('data:')) data += line.slice(5).trim();
        }
        if (!data) continue;
        let payload; try { payload = JSON.parse(data); } catch { payload = data; }
        const p = payload && payload.data && typeof payload.data === 'object' ? payload.data : payload;
        const kind = (payload && payload.type) || type;
        events.push({ at: Date.now(), kind, p });
        if (kind === 'live.transcript') {
          if (p.final) log(`  ${p.role} said: ${JSON.stringify(p.text).slice(0, 300)}`);
        } else {
          log(`  ${kind}: ${JSON.stringify(p).slice(0, 260)}`);
        }
      }
    }
  } catch (e) { if (e.name !== 'AbortError') log('sse error', e.message); }
}

// ---- Spike 2: start a call through the real UI ----
await page.goto(`${BASE}/`, { waitUntil: 'domcontentloaded' });
const send = page.locator('#sendBtn');
await page.waitForFunction(() => document.querySelector('#sendBtn')?.getAttribute('aria-label') === 'Start live voice', null, { timeout: 30000 })
  .catch(async () => { log('send label =', await send.getAttribute('aria-label')); throw new Error('Live button never appeared'); });
log('clicking Start live voice');
await send.click();
await page.waitForFunction(() => window.__termLLMNav?.state().liveId, null, { timeout: 30000 });
const bridge = await page.evaluate(() => ({ state: window.__termLLMNav.state(), log: window.__termLLMNav.log() }));
log('SPIKE2 bridge state', JSON.stringify(bridge));
const liveId = bridge.state.liveId;
watch(liveId);

// ---- Spike 1: push navigation updates ----
const frame = (s) => `Navigation update from my phone (not a request, no task needed — just tell me in one short sentence): ${s}`;
const marks = [];
async function say(label, text) {
  const at = Date.now();
  const result = await page.evaluate((t) => window.__termLLMNav.say(t), text);
  marks.push({ label, at, result });
  log(`>>> ${label}: ${JSON.stringify(result)}  ${JSON.stringify(text).slice(0, 120)}`);
}

await sleep(10000); // let any greeting finish
await say('A idle upcoming turn', frame('In about 60 metres, turn left onto Oak Street.'));
await sleep(18000);
await say('B request long story', 'Tell me a story about a lighthouse keeper. Make it about a minute long.');
// Wait until the assistant is speaking the story, then interrupt with a turn.
const storyStart = Date.now();
while (Date.now() - storyStart < 15000 && !events.some((e) => e.at > marks.at(-1).at && e.kind === 'live.transcript' && e.p.role === 'assistant')) await sleep(250);
await sleep(3000);
await say('C turn now during speech', frame('Turn right now onto Pine Street.'));
await sleep(25000);
await say('D off route', frame("You've walked past Pine Street. Turn around and go back about 40 metres, then turn right."));
await sleep(15000);
await say('E arrived', frame('You have arrived at Blue Bottle Coffee, on your left.'));
await sleep(12000);

// ---- Spike 2 (end): stop via UI, bridge should clear ----
log('clicking Stop live voice');
await send.click().catch((e) => log('stop click failed', e.message));
await sleep(3000);
const after = await page.evaluate(() => ({ state: window.__termLLMNav.state(), log: window.__termLLMNav.log(), sayAfter: null }));
after.sayAfter = await page.evaluate(() => window.__termLLMNav.say('test after end'));
log('SPIKE2 after stop', JSON.stringify(after));

sseAbort?.abort();
// ---- summary ----
const summary = marks.map((m, i) => {
  const end = marks[i + 1]?.at ?? Date.now();
  const window_ = events.filter((e) => e.at >= m.at && e.at < end);
  const firstAssistant = window_.find((e) => e.kind === 'live.transcript' && e.p.role === 'assistant');
  return {
    label: m.label,
    ok: m.result.ok,
    firstAssistantMs: firstAssistant ? firstAssistant.at - m.at : null,
    delegations: window_.filter((e) => e.kind.startsWith('live.delegation')).map((e) => e.p.state || e.kind),
    interrupted: window_.some((e) => e.kind === 'live.interrupted'),
    assistant: window_.filter((e) => e.kind === 'live.transcript' && e.p.role === 'assistant' && e.p.final).map((e) => e.p.text).join(' | ').slice(0, 600),
  };
});
writeFileSync('/tmp/navspike-events.json', JSON.stringify({ bridge, after, marks, events }, null, 2));
console.log('\nSUMMARY\n' + JSON.stringify(summary, null, 2));
await browser.close();
