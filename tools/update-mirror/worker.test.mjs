import { test } from 'node:test';
import assert from 'node:assert/strict';
import worker, { handle, REPOSITORY, ReleaseRegistry } from './worker.mjs';

const host = 'https://git.3952039.xyz';
const name = 'wenku8-0.3.4-arm64-v8a.apk';
const path = `/${REPOSITORY}/releases/download/v0.3.4/${name}`;
const data = {
  tag_name: 'v0.3.4', draft: false, prerelease: false, body: '说明', assets: [{
    id: 12, name, size: 4, digest: `sha256:${'a'.repeat(64)}`,
    browser_download_url: `https://github.com${path}`,
  }],
};
function fixture(manifest = data, assetFetch = () => new Response(new Uint8Array([1, 2, 3, 4]), { headers: { 'Content-Length': '4' } })) {
  const stored = new Map(), calls = [], pending = [];
  const dependencies = {
    cache: {
      async match(request) { return stored.get(request.url)?.clone(); },
      async put(request, response) { stored.set(request.url, response.clone()); },
    },
    async fetcher(url, options) {
      calls.push({ url: String(url), options });
      if (String(url).startsWith('https://api.github.com/')) return Response.json(manifest);
      return assetFetch(url, options);
    },
    waitUntil(task) { pending.push(task); },
  };
  return { calls, pending, stored, request: (suffix, init) => handle(new Request(host + suffix, init), dependencies) };
}

test('latest keeps canonical GitHub URLs and digests; shared cache is 120 seconds', async () => {
  const f = fixture();
  const first = await f.request('/api/releases/latest');
  assert.deepEqual(await first.json(), data);
  assert.equal(first.headers.get('x-wenku-cache'), 'MISS');
  assert.equal(first.headers.get('cache-control'), 'no-store');
  await Promise.all(f.pending);
  assert.match([...f.stored.values()][0].headers.get('cache-control'), /s-maxage=120/);
  assert.equal((await f.request('/api/releases/latest')).headers.get('x-wenku-cache'), 'HIT');
  assert.equal(f.calls.length, 1);
  assert.equal(f.calls[0].options.redirect, 'manual');
});
test('only fixed-repository releases can be requested; credentials never forwarded', async () => {
  const f = fixture();
  for (const url of ['/https://example.org/', '/other/repo/releases/download/v0.3.4/a.apk', '/api/releases/latest?url=https://example.org']) {
    assert.equal((await f.request(url)).status, 404);
  }
  assert.equal((await f.request(path, { method: 'POST' })).status, 405);
  assert.equal(f.calls.length, 0);
  const r = await f.request(path + '?asset=12', { headers: { Authorization: 'secret', Cookie: 'session=secret' } });
  assert.equal(r.status, 200);
  assert.deepEqual([...new Uint8Array(await r.arrayBuffer())], [1, 2, 3, 4]);
  assert.equal(f.calls[1].options.headers.has('Authorization'), false);
  assert.equal(f.calls[1].options.headers.has('Cookie'), false);
  assert.match(r.headers.get('content-type'), /package-archive/);
});
test('release replacement gets a new asset-ID cache key; old ID rejects', async () => {
  const f = fixture();
  assert.equal((await f.request(path + '?asset=11')).status, 409);
  assert.equal(f.calls.length, 1);
  await f.request(path + '?asset=12');
  await Promise.all(f.pending);
  assert.ok(f.stored.has(host + path + '?asset=12'));
  assert.equal((await f.request(path + '?asset=12')).headers.get('x-wenku-cache'), 'HIT');
});
test('HEAD stays bodyless and a partial upstream response never poisons full cache', async () => {
  const f = fixture(data, (url, options) => options.method === 'HEAD'
    ? new Response(null, { headers: { 'Content-Length': '4' } })
    : new Response(new Uint8Array([2, 3]), { status: 206, headers: { 'Content-Length': '2', 'Content-Range': 'bytes 1-2/4' } }));
  assert.equal(await (await f.request(path, { method: 'HEAD' })).text(), '');
  const partial = await f.request(path, { headers: { Range: 'bytes=1-2' } });
  assert.equal(partial.status, 206);
  assert.equal(partial.headers.get('content-range'), 'bytes 1-2/4');
  assert.equal(f.calls.at(-1).options.headers.get('Range'), 'bytes=1-2');
  await Promise.all(f.pending);
  assert.equal(f.stored.has(host + path + '?asset=12'), false);
});
test('reject unexpected redirect destinations and sizes', async () => {
  const badRedirect = fixture(data, () => new Response(null, { status: 302, headers: { Location: 'https://evil.test/a.apk' } }));
  assert.equal((await badRedirect.request(path)).status, 502);
  assert.equal(badRedirect.calls.length, 2);
  const size = fixture(data, () => new Response('wrong', { headers: { 'Content-Length': '5' } }));
  assert.equal((await size.request(path)).status, 502);
});
test('follows known GitHub CDN redirect without exposing signed upstream URL', async () => {
  const f = fixture(data, url => String(url).startsWith('https://github.com/')
    ? new Response(null, { status: 302, headers: { Location: 'https://release-assets.githubusercontent.com/path?signature=temporary' } })
    : new Response(new Uint8Array([1, 2, 3, 4]), { headers: { 'Content-Length': '4' } }));
  const r = await f.request(path);
  assert.equal(r.status, 200);
  assert.equal(r.headers.get('location'), null);
  assert.equal(f.calls.length, 3);
});
test('no draft/prerelease or fabricated asset is served', async () => {
  for (const field of ['draft', 'prerelease']) {
    assert.equal((await fixture({ ...data, [field]: true }).request(path)).status, 404);
  }
  assert.equal((await fixture({ ...data, assets: [] }).request(path)).status, 404);
  assert.equal((await fixture().request(path + '?other=x')).status, 400);
});
test('encoded build tags work with either canonical GitHub encoding', async () => {
  for (const encoded of ['v0.3.4+57', 'v0.3.4%2B57']) {
    const f = fixture({ ...data, tag_name: 'v0.3.4+57', assets: [{ ...data.assets[0], browser_download_url: `https://github.com/${REPOSITORY}/releases/download/${encoded}/${name}` }] });
    assert.equal((await f.request(`/${REPOSITORY}/releases/download/v0.3.4%2B57/${name}`)).status, 200);
  }
});
test('native rate bindings fail closed and excessive requests receive retry guidance', async () => {
  const request = new Request(host + path, { headers: { 'CF-Connecting-IP': '192.0.2.1' } });
  assert.equal((await worker.fetch(request, {}, {})).status, 503);
  let limitedKey;
  const reply = await worker.fetch(request, { DOWNLOAD_LIMITER: { async limit({ key }) { limitedKey = key; return { success: false }; } } }, {});
  assert.equal(reply.status, 429);
  assert.equal(reply.headers.get('retry-after'), '60');
  assert.equal(limitedKey, '192.0.2.1');
});

test('global release registry shares refreshes and historical guesses spend no upstream API requests', async () => {
  const oldFetch = globalThis.fetch, oldNow = Date.now;
  let calls = 0, now = 1792270000000, failing = false;
  const stored = new Map();
  const storage = { get: async k => stored.get(k), put: async (k, v) => stored.set(k, v),
    list: async ({ prefix }) => new Map([...stored].filter(([k]) => k.startsWith(prefix))),
    delete: async keys => keys.forEach(k => stored.delete(k)) };
  globalThis.fetch = async () => { calls++; return failing ? new Response(null, { status: 403 }) : Response.json(data); };
  Date.now = () => now;
  try {
    let registry = new ReleaseRegistry({ storage });
    const latest = () => registry.fetch(new Request('https://registry/latest'));
    const results = await Promise.all([latest(), latest(), latest()]);
    assert.ok(results.every(r => r.status === 200)); assert.equal(calls, 1);
    registry = new ReleaseRegistry({ storage });
    assert.equal((await latest()).status, 200); assert.equal(calls, 1);
    assert.equal((await registry.fetch(new Request('https://registry/tags/v0.3.4?download=1'))).status, 200);
    assert.equal((await registry.fetch(new Request('https://registry/tags/v9.9.9?download=1'))).status, 404);
    assert.equal(calls, 1);
    now += 121000; failing = true;
    assert.equal((await latest()).status, 503);
    const staleDownload = await registry.fetch(new Request('https://registry/latest?download=1'));
    assert.equal(staleDownload.status, 200); assert.equal(staleDownload.headers.get('x-wenku-stale'), '1');
    assert.equal(calls, 2);
    assert.equal((await latest()).status, 503); assert.equal(calls, 2);
    now += 86400000;
    assert.equal((await registry.fetch(new Request('https://registry/latest?download=1'))).status, 503);
  } finally { globalThis.fetch = oldFetch; Date.now = oldNow; }
});
test('optional API credential stays on the fixed GitHub API request, outside response data', async () => {
  const original = globalThis.fetch;
  const stored = new Map();
  const storage = { get: async k => stored.get(k), put: async (k, v) => stored.set(k, v), list: async () => new Map(), delete: async () => {} };
  const calls = [];
  globalThis.fetch = async (url, options) => { calls.push({url: String(url), options}); return Response.json(data); };
  try {
    const registry = new ReleaseRegistry({ storage }, { GITHUB_TOKEN: 'fixture-read-only-not-a-real-credential' });
    const response = await registry.fetch(new Request('https://registry/latest'));
    assert.equal(calls[0].url, `https://api.github.com/repos/${REPOSITORY}/releases/latest`);
    assert.equal(calls[0].options.headers.Authorization, 'Bearer fixture-read-only-not-a-real-credential');
    assert.equal(calls[0].options.redirect, 'manual');
    assert.doesNotMatch(await response.text(), /fixture-read-only/);
  } finally { globalThis.fetch = original; }
});

test('withdrawn 0.4.0 rejects GET, HEAD, Range and known-ID caches before reading bytes', async () => {
  const f = fixture();
  const withdrawn = `/${REPOSITORY}/releases/download/v0.4.0/wenku8-0.4.0-arm64-v8a.apk?asset=99`;
  f.stored.set(host + withdrawn, new Response('old cached APK'));
  for (const init of [{}, { method: 'HEAD' }, { headers: { Range: 'bytes=0-3' } }]) {
    assert.equal((await f.request(withdrawn, init)).status, 410);
  }
  assert.equal((await f.request(withdrawn.replace('arm64-v8a.apk?asset=99', 'source.zip'))).status, 410);
  assert.equal(f.calls.length, 0);
  assert.equal((await fixture({ ...data, tag_name: 'v0.4.0' }).request('/api/releases/latest')).status, 404);
});

test('rollback registry ignores old manifests, restores exact historical tags and rejects draft guesses', async () => {
  const oldFetch = globalThis.fetch;
  const stored = new Map([
    ['release:latest', { at: Date.now(), data: { ...data, tag_name: 'v0.4.0' } }],
  ]);
  const storage = { get: async k => stored.get(k), put: async (k, v) => stored.set(k, v),
    list: async ({ prefix }) => new Map([...stored].filter(([k]) => k.startsWith(prefix))),
    delete: async keys => keys.forEach(k => stored.delete(k)) };
  const calls = [];
  globalThis.fetch = async url => { calls.push(String(url)); return Response.json(data); };
  try {
    const registry = new ReleaseRegistry({ storage });
    const history = await registry.fetch(new Request('https://registry/tags/v0.3.4?download=1'));
    assert.equal(history.status, 200);
    assert.equal((await history.json()).tag_name, 'v0.3.4');
    assert.equal(calls[0], `https://api.github.com/repos/${REPOSITORY}/releases/tags/v0.3.4`);
    const latest = await registry.fetch(new Request('https://registry/latest'));
    assert.equal((await latest.json()).tag_name, 'v0.3.4');
    assert.equal((await registry.fetch(new Request('https://registry/tags/v0.4.0?download=1'))).status, 410);
    assert.equal((await registry.fetch(new Request('https://registry/tags/v0.3.0+29?download=1'))).status, 404);
    assert.equal((await registry.fetch(new Request('https://registry/tags/v8.8.8?download=1'))).status, 404);
    assert.equal(calls.length, 2);
  } finally { globalThis.fetch = oldFetch; }
});
