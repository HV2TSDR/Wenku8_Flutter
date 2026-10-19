import { test } from 'node:test';
import assert from 'node:assert/strict';
import worker, { handle, imageURL, PublicBudget, PUBLIC_DAILY_LIMIT } from './worker.mjs';

const origin = 'https://app.3952039.xyz';
const image = 'https://img.wenku8.com/image/1/1305/1305s.jpg';
function fixture({ quota = true, body = new Uint8Array([255, 216, 255, 217]) } = {}) {
  const calls = [], cache = new Map(), pending = []; let grants = 0;
  const deps = {
    async admit() { grants++; return new Response(null, { status: quota ? 204 : 429, headers: { 'Retry-After': '3600' } }); },
    async fetcher(url, options) { calls.push({ url: String(url), options }); return new Response(body); },
    cache: { async match(key) { return cache.get(key.url)?.clone(); }, async put(key, response) { cache.set(key.url, response.clone()); } },
    waitUntil(p) { pending.push(p); },
  };
  return { calls, pending, cache, get grants() { return grants; },
    request: (path, init) => handle(new Request(origin + path, init), deps),
    image: url => handle(new Request(origin + '/image/' + Buffer.from(url).toString('base64url')), deps),
  };
}
test('catalogue and account API requests are not served or forwarded', async () => {
  const f = fixture();
  assert.equal((await f.request('/api', { method: 'POST', body: 'action=login' })).status, 405);
  assert.equal((await f.request('/api')).status, 404);
  assert.equal(f.calls.length, 0); assert.equal(f.grants, 0);
});
test('same image caches without forwarding visitor credentials', async () => {
  const f = fixture();
  assert.equal((await f.image(image)).status, 200);
  await Promise.all(f.pending);
  assert.equal((await f.image(image)).headers.get('x-wenku-cache'), 'HIT');
  assert.equal(f.calls.length, 1); assert.equal(f.grants, 2);
  assert.equal(f.calls[0].url, image);
  assert.equal(f.calls[0].options.headers.Cookie, undefined);
  assert.equal((await f.request('/health', { headers: { Cookie: 'fixture' } })).status, 403);
  assert.equal(f.calls.length, 1);
});
test('exhausted public allowance avoids origin/cache access and supplies a bypass duration', async () => {
  const f = fixture({ quota: false });
  const r = await f.image(image);
  assert.equal(r.status, 429); assert.equal(r.headers.get('retry-after'), '3600');
  assert.equal(f.calls.length, 0);
});
test('only image-only known-host paths are supported; bad bytes are never cached', async () => {
  const good = 'https://img.wenku8.com/image/1/1305/1305s.jpg';
  assert.equal(imageURL(good).href, good);
  for (const bad of ['https://evil.test/1/a.jpg', 'https://www.wenku8.com/login.php', 'https://img.wenku8.com/image/1/a.jpg?token=x', 'https://u:p@img.wenku8.com/image/1/a.jpg', 'http://img.wenku8.com/image/1/a.jpg']) assert.throws(() => imageURL(bad));
  const f = fixture({ body: new Uint8Array([255, 216, 255, 217]) });
  const r = await f.image(good);
  assert.equal(r.status, 200); assert.equal(r.headers.get('content-type'), 'image/jpeg');
  const invalid = fixture({ body: '<html>error</html>' }); assert.equal((await invalid.image(good)).status, 502); assert.equal(invalid.cache.size, 0);
});
test('global public daily counter persists across isolates, caps at 5000, resets on UTC day', async () => {
  const originalNow = Date.now; let now = 1792270000000;
  Date.now = () => now;
  try {
    const stored = new Map();
    const storage = { async transaction(f) { return f({ get: async k => stored.get(k), put: async (k, v) => stored.set(k, v) }); } };
    let counter = new PublicBudget({ storage });
    for (let i = 0; i < PUBLIC_DAILY_LIMIT; i++) assert.equal((await counter.fetch()).status, 204);
    counter = new PublicBudget({ storage });
    const exhausted = await counter.fetch();
    assert.equal(exhausted.status, 429); assert.ok(Number(exhausted.headers.get('retry-after')) <= 86400);
    assert.equal(stored.get('daily').used, PUBLIC_DAILY_LIMIT);
    now += 86400000;
    assert.equal((await counter.fetch()).status, 204);
    assert.equal(stored.size, 1); assert.equal(stored.get('daily').used, 1);
  } finally { Date.now = originalNow; }
});
test('missing quota/rate bindings fail closed without fetching upstream', async () => {
  assert.equal((await worker.fetch(new Request(origin + '/api'), {}, {})).status, 503);
});
