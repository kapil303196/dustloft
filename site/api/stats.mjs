// Reads back the two figures the reports add up to: how many copies of Dustloft
// exist, and how much space they have reclaimed between them.
//
// Aggregates only. There is no endpoint, here or anywhere, that returns a
// single install's row — the per-install values exist purely so a repeated
// report cannot be counted twice.
import { configured, pipeline, KEYS, today } from './_store.mjs';

/** How many days of history the chart gets. */
const WINDOW = 30;

function days(count, now = new Date()) {
  const out = [];
  for (let i = count - 1; i >= 0; i--) {
    const d = new Date(now);
    d.setUTCDate(d.getUTCDate() - i);
    out.push(today(d));
  }
  return out;
}

const int = (v) => {
  const n = Number(v);
  return Number.isFinite(n) ? n : 0;
};

/** Binary units, to match what macOS and the app itself show. */
export function human(bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
  let n = Math.abs(bytes);
  let u = 0;
  while (n >= 1000 && u < units.length - 1) {
    n /= 1000;
    u++;
  }
  return `${u === 0 ? n : n.toFixed(n < 10 ? 2 : 1)} ${units[u]}`;
}

export default async function handler(req, res) {
  if (req.method !== 'GET' && req.method !== 'HEAD') {
    res.setHeader('Allow', 'GET');
    return res.status(405).json({ error: 'method not allowed' });
  }

  // Public by default — a running "X reclaimed" total is worth showing. Setting
  // DUSTLOFT_STATS_TOKEN closes it without any code change.
  const gate = process.env.DUSTLOFT_STATS_TOKEN;
  if (gate) {
    const auth = req.headers.authorization || '';
    const presented = auth.startsWith('Bearer ') ? auth.slice(7) : '';
    if (presented !== gate) return res.status(401).json({ error: 'unauthorized' });
  }

  res.setHeader('Access-Control-Allow-Origin', '*');

  if (!configured) {
    res.setHeader('Cache-Control', 'no-store');
    return res.status(200).json({
      configured: false,
      hint: 'Attach a Redis store in Vercel and redeploy. Nothing is being recorded until then.',
      installs: 0,
      cleaned: { bytes: 0, gb: 0, human: '0 B' },
      versions: {},
      daily: [],
    });
  }

  const window = days(WINDOW);

  try {
    const [installs, bytes, versions, newDaily, bytesDaily] = await pipeline([
      ['GET', KEYS.installCount],
      ['GET', KEYS.bytesTotal],
      ['HGETALL', KEYS.versionCounts],
      ['MGET', ...window.map(KEYS.newOn)],
      ['MGET', ...window.map(KEYS.bytesOn)],
    ]);

    // HGETALL comes back over REST as a flat field/value array.
    const versionCounts = {};
    if (Array.isArray(versions)) {
      for (let i = 0; i + 1 < versions.length; i += 2) {
        versionCounts[versions[i]] = int(versions[i + 1]);
      }
    } else if (versions && typeof versions === 'object') {
      for (const [k, v] of Object.entries(versions)) versionCounts[k] = int(v);
    }

    const totalBytes = int(bytes);
    res.setHeader('Cache-Control', 'public, s-maxage=300, stale-while-revalidate=600');
    return res.status(200).json({
      configured: true,
      installs: int(installs),
      cleaned: {
        bytes: totalBytes,
        gb: Math.round(totalBytes / 1e9),
        human: human(totalBytes),
      },
      versions: versionCounts,
      daily: window.map((date, i) => ({
        date,
        installs: int(Array.isArray(newDaily) ? newDaily[i] : 0),
        cleanedBytes: int(Array.isArray(bytesDaily) ? bytesDaily[i] : 0),
      })),
      generatedAt: new Date().toISOString(),
    });
  } catch (err) {
    console.error('stats failed:', err.message);
    res.setHeader('Cache-Control', 'no-store');
    return res.status(503).json({ error: 'temporarily unavailable' });
  }
}
