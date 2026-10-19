// Public image backup only. Catalogue/account traffic retains the existing relay.
const IMAGE_HOSTS = new Set(['img.wenku8.com', 'pic.wenku8.com', 'pic.wenku8.cn', 'pic.wenku8.net', 'pic.777743.xyz']);
export const PUBLIC_DAILY_LIMIT = 5000;

function reply(message, status, retry = 60) {
  return Response.json({ error: message }, { status, headers: {
    'Cache-Control': 'no-store', 'Retry-After': String(retry),
    'X-Wenku-Direct-Until': String(Math.floor(Date.now() / 1000) + retry),
  } });
}
function resetSeconds(now) { return 86400 - Math.floor(now / 1000) % 86400; }

export function imageURL(raw) {
  const u = new URL(raw);
  if (u.protocol !== 'https:' || u.username || u.password || u.port || u.search || u.hash || !IMAGE_HOSTS.has(u.hostname) ||
      !/^\/(?:image|pictures|\d+)\/[a-zA-Z0-9_/-]+\.(?:jpe?g|png|gif|webp)$/i.test(u.pathname)) throw new Error('Unsupported image');
  return u;
}

async function bounded(response, maximum) {
  if (Number(response.headers.get('Content-Length')) > maximum) { await response.body?.cancel(); throw new Error('Response too large'); }
  const reader = response.body.getReader(), chunks = [];
  let total = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.length;
    if (total > maximum) { await reader.cancel(); throw new Error('Response too large'); }
    chunks.push(value);
  }
  const all = new Uint8Array(total); let offset = 0;
  for (const value of chunks) { all.set(value, offset); offset += value.length; }
  return all;
}

async function headersFetch(fetcher, address, options) {
  const controller = new AbortController(), timer = setTimeout(() => controller.abort(), 5000);
  try { return await fetcher(address, { ...options, redirect: 'manual', signal: controller.signal }); }
  finally { clearTimeout(timer); }
}

export async function handle(request, dependencies) {
  const url = new URL(request.url);
  if (request.headers.has('Cookie') || request.headers.has('Authorization')) return reply('Anonymous public content only', 403);
  if (!['GET', 'HEAD'].includes(request.method)) return reply('Public images use GET or HEAD', 405);
  if (url.search) return reply('Unsupported query', 400);
  if (url.pathname === '/health' && ['GET', 'HEAD'].includes(request.method)) {
    return Response.json({ status: 'ok', scope: 'public-images', priority: 'updates-first', publicDailyLimit: PUBLIC_DAILY_LIMIT, country: request.cf?.country ?? null, colo: request.cf?.colo ?? null }, { headers: { 'Cache-Control': 'no-store' } });
  }
  try {
    let target, options, key;
    if (url.pathname.startsWith('/image/')) {
      const token = url.pathname.slice(7);
      if (!/^[A-Za-z0-9_-]{1,2048}$/.test(token)) return reply('Invalid image path', 400);
      const raw = new TextDecoder('utf-8', { fatal: true }).decode(Uint8Array.from(atob(token.replaceAll('-', '+').replaceAll('_', '/')), c => c.charCodeAt(0)));
      target = imageURL(raw);
      options = { method: 'GET', headers: { Accept: 'image/*', 'User-Agent': 'Wenku8-Public-Gateway' } };
      key = new Request(`${url.origin}/_public-image/${token}`);
    } else return reply('No public route', 404);

    // A tiny daily global allowance, independent of update/download limiters.
    // Once exhausted, the app stays on the original host until the next UTC day.
    const grant = await dependencies.admit();
    if (!grant.ok) return grant;
    const cached = await dependencies.cache.match(key);
    if (cached) return output(cached, request.method, 'HIT');
    let upstream;
    for (let hop = 0; hop < 4; hop++) {
      upstream = await headersFetch(dependencies.fetcher, target, options);
      if (![301, 302, 303, 307, 308].includes(upstream.status)) break;
      const location = upstream.headers.get('Location'); await upstream.body?.cancel();
      if (!location || hop === 3) return reply('Origin redirect unavailable', 502);
      target = imageURL(new URL(location, target).href.replace(/^http:/, 'https:'));
    }
    if (upstream.status !== 200) { await upstream.body?.cancel(); return reply(`Origin temporarily unavailable (HTTP ${upstream.status})`, 503); }
    const bytes = await bounded(upstream, 8 * 1024 * 1024);
    const image = bytes[0] === 0xff && bytes[1] === 0xd8 ? 'image/jpeg' :
      bytes[0] === 0x89 && bytes[1] === 0x50 ? 'image/png' :
      bytes[0] === 0x47 && bytes[1] === 0x49 ? 'image/gif' :
      bytes[0] === 0x52 && bytes[1] === 0x49 && bytes[8] === 0x57 ? 'image/webp' : null;
    if (!image) return reply('Invalid origin image', 502);
    const response = new Response(bytes, { headers: { 'Content-Type': image, 'Content-Length': String(bytes.length), 'Cache-Control': 'public, max-age=0, s-maxage=86400', 'X-Content-Type-Options': 'nosniff' } });
    dependencies.waitUntil(dependencies.cache.put(key, response.clone()).catch(() => {}));
    return output(response, request.method, 'MISS');
  } catch { return reply('Public acceleration temporarily unavailable', 503); }
}
function output(response, method, state) {
  const headers = new Headers(response.headers); headers.set('X-Wenku-Cache', state);
  return new Response(method === 'HEAD' ? null : response.body, { status: response.status, headers });
}

export default {
  async fetch(request, env, ctx) {
    if (!env.PUBLIC_LIMITER || !env.PUBLIC_BUDGET) return reply('Public acceleration disabled', 503);
    const allowed = await env.PUBLIC_LIMITER.limit({ key: request.headers.get('CF-Connecting-IP') ?? 'unknown' });
    if (!allowed.success) return reply('Use original host temporarily', 429);
    return handle(request, { fetcher: (...args) => fetch(...args), cache: caches.default, waitUntil: task => ctx.waitUntil(task),
      admit: () => env.PUBLIC_BUDGET.get(env.PUBLIC_BUDGET.idFromName('daily')).fetch('https://budget/admit') });
  },
};

export class PublicBudget {
  constructor(ctx) { this.storage = ctx.storage; }
  async fetch() {
    const now = Date.now(), day = Math.floor(now / 86400000);
    const allowed = await this.storage.transaction(async txn => {
      const previous = await txn.get('daily');
      const used = previous?.day === day ? previous.used : 0;
      if (used >= PUBLIC_DAILY_LIMIT) return false;
      await txn.put('daily', { day, used: used + 1 }); return true;
    });
    return allowed ? new Response(null, { status: 204 }) : reply('Updates take priority; use original host today', 429, resetSeconds(now));
  }
}
