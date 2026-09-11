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

await shim.client.cmd(['FLUSHALL']);

const { default: ping } = await import('../../site/api/ping.mjs');
const { default: stats } = await import('../../site/api/stats.mjs');

function mock(method, body, { ip = '203.0.113.7', headers = {} } = {}) {
  const req = { method, body, headers: { 'x-forwarded-for': ip, ...headers } };
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

await t('stats honours a token when one is set', async () => {
  process.env.DUSTLOFT_STATS_TOKEN = 'sekrit';
  assert.equal((await get()).code, 401);
  assert.equal((await get({ headers: { authorization: 'Bearer sekrit' } })).code, 200);
  delete process.env.DUSTLOFT_STATS_TOKEN;
});

console.log(`\n${n} checks passed against a real Redis.`);
shim.close();
process.exit(0);
