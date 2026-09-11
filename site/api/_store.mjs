// Counter storage for the anonymous install/reclaimed figures.
//
// Deliberately talks to Redis over its REST interface rather than through a
// client library: a serverless function gets a fresh, short-lived container per
// request, so a pooled TCP client spends more time connecting than working, and
// a dependency-free handler keeps the marketing site a zero-install static
// project.
//
// Both naming conventions are accepted so it works whichever integration is
// attached in Vercel — the first-party KV product and Upstash's own store
// expose the same REST API under different variable names.
const REST_URL =
  process.env.KV_REST_API_URL || process.env.UPSTASH_REDIS_REST_URL || '';
const REST_TOKEN =
  process.env.KV_REST_API_TOKEN || process.env.UPSTASH_REDIS_REST_TOKEN || '';

/** Whether a store is attached. Everything degrades to a no-op when it is not,
 *  so an unconfigured preview deployment still serves the site normally. */
export const configured = Boolean(REST_URL && REST_TOKEN);

/**
 * Runs one Redis command. Arguments are sent as a JSON array, which keeps
 * values opaque — nothing here is interpolated into a command string.
 */
export async function redis(command, { timeoutMs = 5000 } = {}) {
  if (!configured) throw new Error('store not configured');

  const abort = new AbortController();
  const timer = setTimeout(() => abort.abort(), timeoutMs);
  try {
    const res = await fetch(REST_URL, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${REST_TOKEN}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(command.map(String)),
      signal: abort.signal,
    });
    const body = await res.json().catch(() => ({}));
    if (!res.ok || body.error) {
      throw new Error(body.error || `store returned ${res.status}`);
    }
    return body.result;
  } finally {
    clearTimeout(timer);
  }
}

/**
 * Runs several commands in one round trip. The read path needs half a dozen
 * keys and a serverless function pays the full network latency for each call,
 * so batching is the difference between one hop and six.
 */
export async function pipeline(commands, { timeoutMs = 5000 } = {}) {
  if (!configured) throw new Error('store not configured');
  if (!commands.length) return [];

  const abort = new AbortController();
  const timer = setTimeout(() => abort.abort(), timeoutMs);
  try {
    const res = await fetch(`${REST_URL.replace(/\/$/, '')}/pipeline`, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${REST_TOKEN}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(commands.map((c) => c.map(String))),
      signal: abort.signal,
    });
    const body = await res.json().catch(() => null);
    if (!res.ok || !Array.isArray(body)) {
      throw new Error((body && body.error) || `store returned ${res.status}`);
    }
    // A pipeline reports per-command failures rather than failing the request,
    // so an error buried in the array still has to surface.
    const failed = body.find((entry) => entry && entry.error);
    if (failed) throw new Error(failed.error);
    return body.map((entry) => (entry ? entry.result : null));
  } finally {
    clearTimeout(timer);
  }
}

// Key names, in one place so the reader and the writer cannot drift apart.
export const KEYS = {
  /** Hash of install id -> the highest lifetime total that install has reported.
   *  Storing the running total rather than each delta makes a retried or
   *  duplicated report a no-op instead of double counting. */
  installs: 'dustloft:installs',
  installCount: 'dustloft:installs:count',
  bytesTotal: 'dustloft:bytes:total',
  newOn: (day) => `dustloft:new:${day}`,
  bytesOn: (day) => `dustloft:bytes:${day}`,
  /** Which version each install is on, and the tally derived from it. Keeping
   *  both lets the tally be corrected when an install updates, so it counts
   *  installs rather than reports. */
  versionOf: 'dustloft:installs:version',
  versionCounts: 'dustloft:versions',
};

/** UTC day stamp. Buckets have to agree across regions, so never local time. */
export function today(now = new Date()) {
  return now.toISOString().slice(0, 10);
}
