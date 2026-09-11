// Exercises the two site endpoints end to end against a real Redis.
//
// The counting rules live in a Lua script that Redis runs, not in JavaScript,
// so a mocked store would test nothing that ships. This talks to an actual
// redis-server through a shim that speaks the same REST dialect the deployed
// functions use.
//
//   ./tools/api-tests/run.sh
//
import assert from 'node:assert/strict';
import { restShim } from './shim.mjs';

const shim = await restShim(Number(process.env.REDIS_PORT || 6399));
process.env.KV_REST_API_URL = shim.url;
process.env.KV_REST_API_TOKEN = 'test-token';
process.env.DUSTLOFT_IP_SALT = 'fixed-salt-for-tests';

// Safe only because run.sh guarantees this server was started by run.sh, on a
// port nothing else was listening on, and is shut down again afterwards.
await shim.client.cmd(['FLUSHALL']);

const { default: ping, clientIP } = await import('../../site/api/ping.mjs');
const { default: stats } = await import('../../site/api/stats.mjs');

function mock(method, body, { ip = '203.0.113.7', headers = {} } = {}) {
  // Spread last so a test can replace the forwarding headers outright; an
  // explicit undefined ip drops the platform header so the fallback is used.
  const base = ip === undefined ? {} : { 'x-real-ip': ip };
  const req = { method, body, headers: { ...base, ...headers } };
  const res = {
    code: 0, payload: undefined, headers: {},
    setHeader(k, v) { this.headers[k.toLowerCase()] = v; return this; },
    status(c) { this.code = c; return this; },
    json(o) { this.payload = o; return this; },
    end() { return this; },
  };
  return { req, res };
}

async function post(body, opts) {
  const { req, res } = mock('POST', body, opts);
  await ping(req, res);
  return res;
}
async function get(opts) {
  const { req, res } = mock('GET', undefined, opts);
  await stats(req, res);
  return res;
}

const A = '11111111-2222-4333-8444-555555555555';
const B = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';
let n = 0;
const t = async (name, fn) => { await fn(); console.log(`  ok  ${++n}. ${name}`); };

await t('rejects a non-POST', async () => {
  const { req, res } = mock('GET');
  await ping(req, res);
  assert.equal(res.code, 405);
});

await t('rejects a malformed id', async () => {
  assert.equal((await post({ id: 'nope', cleaned: 1 })).code, 400);
  assert.equal((await post({ cleaned: 1 })).code, 400);
});

await t('rejects a non-numeric or negative total', async () => {
  assert.equal((await post({ id: A, cleaned: '5' })).code, 400);
  assert.equal((await post({ id: A, cleaned: -1 })).code, 400);
  assert.equal((await post({ id: A, cleaned: NaN })).code, 400);
});

await t('first report counts one install and its bytes', async () => {
  assert.equal((await post({ id: A, cleaned: 1000, version: '1.0.26' })).code, 204);
  const s = (await get()).payload;
  assert.equal(s.installs, 1);
  assert.equal(s.cleaned.bytes, 1000);
  assert.deepEqual(s.versions, { '1.0.26': 1 });
});

await t('an identical repeat adds nothing', async () => {
  await post({ id: A, cleaned: 1000, version: '1.0.26' });
  await post({ id: A, cleaned: 1000, version: '1.0.26' });
  const s = (await get()).payload;
  assert.equal(s.installs, 1);
  assert.equal(s.cleaned.bytes, 1000);
});

await t('only the increase is added', async () => {
  await post({ id: A, cleaned: 2500, version: '1.0.26' });
  const s = (await get()).payload;
  assert.equal(s.installs, 1);
  assert.equal(s.cleaned.bytes, 2500);
});

await t('a late, lower report is ignored', async () => {
  await post({ id: A, cleaned: 40, version: '1.0.26' });
  assert.equal((await get()).payload.cleaned.bytes, 2500);
});

await t('a second machine is a second install', async () => {
  await post({ id: B, cleaned: 500, version: '1.0.26' }, { ip: '198.51.100.4' });
  const s = (await get()).payload;
  assert.equal(s.installs, 2);
  assert.equal(s.cleaned.bytes, 3000);
  assert.deepEqual(s.versions, { '1.0.26': 2 });
});

await t('updating moves the version tally, never double-counts', async () => {
  await post({ id: B, cleaned: 500, version: '1.0.27' }, { ip: '198.51.100.4' });
  const s = (await get()).payload;
  assert.deepEqual(s.versions, { '1.0.26': 1, '1.0.27': 1 });
  assert.equal(s.installs, 2);
});

await t('an absurd total is clamped, not rejected', async () => {
  const C = '99999999-8888-4777-8666-555544443333';
  assert.equal((await post({ id: C, cleaned: 9e18 }, { ip: '198.51.100.9' })).code, 204);
  assert.equal((await get()).payload.cleaned.bytes, 3000 + 1e15);
});

await t('today shows up in the daily series', async () => {
  const s = (await get()).payload;
  const last = s.daily[s.daily.length - 1];
  assert.equal(s.daily.length, 30);
  assert.equal(last.installs, 3);
  assert.ok(last.cleanedBytes > 0);
});

await t('rate limits a flood from one source', async () => {
  const ip = '198.51.100.200';
  let limited = 0;
  for (let i = 0; i < 40; i++) {
    const r = await post({ id: A, cleaned: 2500 }, { ip });
    if (r.code === 429) limited++;
  }
  assert.ok(limited >= 5, `expected throttling, got ${limited}`);
});

await t('every rate-limit bucket carries a TTL', async () => {
  // Set as a separate call, a failed EXPIRE leaves the bucket immortal and that
  // address refused forever. It has to be part of the same atomic step.
  const keys = await shim.client.cmd(['KEYS', 'dustloft:rl:*']);
  assert.ok(keys.length > 0, 'expected some buckets to exist by now');
  for (const key of keys) {
    const ttl = Number(await shim.client.cmd(['TTL', key]));
    assert.ok(ttl > 0 && ttl <= 60, `${key} has TTL ${ttl}`);
  }
});

await t('the address comes from the platform, or the last hop — never the first', () => {
  // The leftmost x-forwarded-for entry is whatever the caller wrote, so these
  // assertions are the whole defence: flip the fallback to hops[0] and the
  // last one here fails.
  assert.equal(clientIP({ headers: { 'x-vercel-forwarded-for': '203.0.113.9',
                                     'x-real-ip': '198.51.100.1',
                                     'x-forwarded-for': '10.0.0.1, 198.51.100.1' } }), '203.0.113.9');
  assert.equal(clientIP({ headers: { 'x-real-ip': '198.51.100.1',
                                     'x-forwarded-for': '10.0.0.1, 198.51.100.1' } }), '198.51.100.1');
  assert.equal(clientIP({ headers: { 'x-forwarded-for': '10.0.0.1, 198.51.100.1' } }), '198.51.100.1');
  assert.equal(clientIP({ headers: { 'x-forwarded-for': ' 198.51.100.1 ' } }), '198.51.100.1');
  assert.equal(clientIP({ headers: {} }), '');
});

await t('a forged x-forwarded-for does not dodge the limiter', async () => {
  await shim.client.cmd(['FLUSHALL']);
  let limited = 0;
  for (let i = 0; i < 40; i++) {
    // No platform header at all, so the fallback is what has to hold: one host
    // randomising the part it controls must still land in the same bucket.
    const r = await post(
      { id: A, cleaned: 10 },
      { headers: { 'x-forwarded-for': `10.0.0.${i}, 198.51.100.77` }, ip: undefined }
    );
    if (r.code === 429) limited++;
  }
  assert.ok(limited >= 5, `expected throttling, got ${limited}`);
});

await t('a raw Buffer body is decoded, not rejected', async () => {
  await shim.client.cmd(['FLUSHALL']);
  const { req, res } = mock('POST', Buffer.from(JSON.stringify({ id: A, cleaned: 77 })));
  await ping(req, res);
  assert.equal(res.code, 204);
  assert.equal((await get()).payload.cleaned.bytes, 77);
});

await t('a token-gated reply is never publicly cacheable', async () => {
  process.env.DUSTLOFT_STATS_TOKEN = 'sekrit';
  const res = await get({ headers: { authorization: 'Bearer sekrit' } });
  assert.equal(res.code, 200);
  // A shared CDN would otherwise serve the gated payload to the next anonymous
  // caller for five minutes, which makes the token do nothing at all.
  assert.match(res.headers['cache-control'], /no-store/);
  assert.equal(res.headers.vary, 'Authorization');
  delete process.env.DUSTLOFT_STATS_TOKEN;

  const open = await get();
  assert.match(open.headers['cache-control'], /s-maxage/);
});

await t('stats honours a token when one is set', async () => {
  process.env.DUSTLOFT_STATS_TOKEN = 'sekrit';
  assert.equal((await get()).code, 401);
  assert.equal((await get({ headers: { authorization: 'Bearer sekrit' } })).code, 200);
  delete process.env.DUSTLOFT_STATS_TOKEN;
});

console.log(`\n${n} checks passed against a real Redis.`);
shim.close();
process.exit(0);
