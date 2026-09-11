// Receives one anonymous report from a Dustloft install.
//
// The entire payload is { id, cleaned, version }: a random identifier the app
// generated for itself, the number of bytes that copy has reclaimed in its
// lifetime, and which build it is running. There is no account, no address, no
// path and no file name — nothing here can be traced back to a person, and the
// request's IP address is used for rate limiting and then discarded unstored.
import { createHash, randomBytes } from 'node:crypto';
import { configured, redis, KEYS, today } from './_store.mjs';
import { REPORT, RATE_LIMIT, DAILY_TTL_SECONDS } from './_lua.mjs';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const VERSION = /^[0-9]{1,4}(\.[0-9]{1,4}){0,3}$/;

/** 1 PB. Anything above this is a bug or a forgery, and is clamped rather than
 *  rejected so a genuine oddity cannot wedge one install into retrying forever. */
const MAX_CLEANED = 1e15;

/** Per source address, per minute. Generous for a client that reports once a
 *  day, and low enough that no single source can move the totals. */
const MAX_REPORTS_PER_MINUTE = 30;

// Without DUSTLOFT_IP_SALT the salt is random per container and dies with it,
// so a hashed address cannot be correlated across requests even in principle.
// Setting it makes the limit global instead of per container.
const IP_SALT = process.env.DUSTLOFT_IP_SALT || randomBytes(32).toString('hex');

/**
 * The caller's address, as far as it can be trusted.
 *
 * Never the leftmost x-forwarded-for entry: that part of the header is whatever
 * the client sent, so a single host could randomise it and never be limited at
 * all. The platform's own headers come first, and the fallback takes the
 * rightmost entry — the one nearest hop appended — rather than the first.
 *
 * Worth being clear about what this does and does not buy: it stops one host
 * flooding the endpoint. It cannot stop someone minting fresh UUIDs to inflate
 * the install count, and nothing short of an account could.
 */
function clientIP(req) {
  const first = (value) => {
    if (Array.isArray(value)) return value.length ? String(value[0]).trim() : '';
    return typeof value === 'string' ? value.trim() : '';
  };

  const platform = first(req.headers['x-vercel-forwarded-for']) || first(req.headers['x-real-ip']);
  if (platform) return platform;

  const forwarded = first(req.headers['x-forwarded-for']);
  if (!forwarded) return '';
  const hops = forwarded.split(',').map((hop) => hop.trim()).filter(Boolean);
  return hops.length ? hops[hops.length - 1] : '';
}

/** Vercel parses a JSON body for us, but not for every content type, and not
 *  when the client sends none. Both shapes are handled so a malformed request
 *  is a 400 rather than a crash. */
async function readBody(req) {
  if (req.body && typeof req.body === 'object') return req.body;
  if (typeof req.body === 'string') return JSON.parse(req.body);
  const chunks = [];
  let size = 0;
  for await (const chunk of req) {
    size += chunk.length;
    if (size > 4096) throw new Error('body too large');
    chunks.push(chunk);
  }
  if (!chunks.length) return {};
  return JSON.parse(Buffer.concat(chunks).toString('utf8'));
}

export default async function handler(req, res) {
  if (req.method !== 'POST') {
    res.setHeader('Allow', 'POST');
    return res.status(405).json({ error: 'method not allowed' });
  }

  let body;
  try {
    body = await readBody(req);
  } catch {
    return res.status(400).json({ error: 'expected a small JSON body' });
  }

  const id = typeof body.id === 'string' ? body.id : '';
  if (!UUID.test(id)) return res.status(400).json({ error: 'invalid id' });

  const version =
    typeof body.version === 'string' && VERSION.test(body.version) ? body.version : '';

  const raw = body.cleaned;
  if (typeof raw !== 'number' || !Number.isFinite(raw) || raw < 0) {
    return res.status(400).json({ error: 'invalid cleaned' });
  }
  const cleaned = Math.min(Math.floor(raw), MAX_CLEANED);

  // Nothing is attached yet, so accept and discard. A preview deployment
  // without a store must not look broken to a client that cannot tell the
  // difference between "not configured" and "down".
  if (!configured) return res.status(202).json({ ok: true, recorded: false });

  try {
    const ip = clientIP(req);
    if (ip) {
      const bucket =
        'dustloft:rl:' + createHash('sha256').update(IP_SALT + ip).digest('hex').slice(0, 24);
      const hits = Number(await redis(['EVAL', RATE_LIMIT, 1, bucket, 60]));
      if (Number.isFinite(hits) && hits > MAX_REPORTS_PER_MINUTE) {
        res.setHeader('Retry-After', '60');
        return res.status(429).json({ error: 'too many reports' });
      }
    }

    const day = today();
    await redis([
      'EVAL',
      REPORT,
      7,
      KEYS.installs,
      KEYS.installCount,
      KEYS.bytesTotal,
      KEYS.newOn(day),
      KEYS.bytesOn(day),
      KEYS.versionOf,
      KEYS.versionCounts,
      id,
      cleaned,
      version,
      DAILY_TTL_SECONDS,
    ]);
  } catch (err) {
    // Never echo the store's error text to the caller. A 503 tells the app to
    // keep its unreported total and try again on its next launch.
    console.error('ping failed:', err.message);
    return res.status(503).json({ error: 'temporarily unavailable' });
  }

  return res.status(204).end();
}
