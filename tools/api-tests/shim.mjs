// A minimal RESP client, plus a shim that speaks the store's REST dialect in
// front of a real redis-server.
//
// Small on purpose: pulling a Redis client and an HTTP framework into a repo
// that otherwise has no JavaScript dependencies at all would cost more than the
// hundred lines it saves.
import net from 'node:net';
import http from 'node:http';

export function connect(port) {
  const sock = net.createConnection({ port, host: '127.0.0.1' });
  let buf = Buffer.alloc(0);
  const waiters = [];
  sock.on('data', (d) => { buf = Buffer.concat([buf, d]); drain(); });

  function parse(b, i) {
    const nl = b.indexOf('\r\n', i);
    if (nl < 0) return null;
    const type = String.fromCharCode(b[i]);
    const head = b.toString('utf8', i + 1, nl);
    const next = nl + 2;
    if (type === '+') return { v: head, i: next };
    if (type === '-') return { v: new Error(head), i: next };
    if (type === ':') return { v: Number(head), i: next };
    if (type === '$') {
      const len = Number(head);
      if (len === -1) return { v: null, i: next };
      if (b.length < next + len + 2) return null;
      return { v: b.toString('utf8', next, next + len), i: next + len + 2 };
    }
    if (type === '*') {
      const n = Number(head);
      if (n === -1) return { v: null, i: next };
      const out = []; let j = next;
      for (let k = 0; k < n; k++) {
        const r = parse(b, j); if (!r) return null;
        out.push(r.v); j = r.i;
      }
      return { v: out, i: j };
    }
    throw new Error('unknown RESP type ' + type);
  }

  function drain() {
    while (waiters.length && buf.length) {
      let r; try { r = parse(buf, 0); } catch (e) { waiters.shift().rej(e); return; }
      if (!r) return;
      buf = buf.subarray(r.i);
      const w = waiters.shift();
      r.v instanceof Error ? w.rej(r.v) : w.res(r.v);
    }
  }

  const ready = new Promise((res) => sock.once('connect', res));
  return {
    ready,
    end: () => sock.end(),
    cmd(args) {
      const parts = [`*${args.length}\r\n`];
      for (const a of args) {
        const s = String(a);
        parts.push(`$${Buffer.byteLength(s)}\r\n${s}\r\n`);
      }
      return new Promise((res, rej) => { waiters.push({ res, rej }); sock.write(parts.join('')); });
    },
  };
}

/** Speaks the Upstash REST dialect the handlers expect, over a real redis. */
export async function restShim(redisPort) {
  const client = connect(redisPort);
  await client.ready;
  const server = http.createServer(async (req, res) => {
    let body = '';
    for await (const c of req) body += c;
    const send = (code, obj) => {
      res.writeHead(code, { 'content-type': 'application/json' });
      res.end(JSON.stringify(obj));
    };
    try {
      const parsed = JSON.parse(body || '[]');
      if (req.url.endsWith('/pipeline')) {
        const out = [];
        for (const c of parsed) {
          try { out.push({ result: await client.cmd(c) }); }
          catch (e) { out.push({ error: e.message }); }
        }
        return send(200, out);
      }
      return send(200, { result: await client.cmd(parsed) });
    } catch (e) {
      return send(200, { error: e.message });
    }
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  return {
    url: `http://127.0.0.1:${server.address().port}`,
    close: () => { server.close(); client.end(); },
    client,
  };
}
