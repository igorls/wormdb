/** Live, isolated security regressions. Usage: bun run scripts/test-security.ts <wormdb binary> */
import { strict as assert } from "node:assert";
import { spawn } from "node:child_process";
import { generateKeyPairSync, sign } from "node:crypto";
import { mkdtemp, writeFile, rm } from "node:fs/promises";
import { createConnection, createServer, type Socket } from "node:net";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const binary = resolve(process.argv[2] ?? "zig-out/bin/wormdb.exe");
const delay = (ms: number) => new Promise(r => setTimeout(r, ms));
const kp = generateKeyPairSync("ed25519");
const publicKey = kp.publicKey.export({ type: "spki", format: "der" }).subarray(-32).toString("base64");
function u32(n: number) { const b = Buffer.alloc(4); b.writeUInt32BE(n); return b; }
function field(s: string | Buffer) { const b = Buffer.from(s); return Buffer.concat([u32(b.length), b]); }
function frame(id: number, payload = Buffer.alloc(0)) { return Buffer.concat([Buffer.from([id]), u32(payload.length), payload]); }
function token(caps: Array<[number, number, string]>, ttl = 300n) {
  const times = Buffer.alloc(16), now = BigInt(Math.floor(Date.now() / 1000));
  times.writeBigUInt64BE(now); times.writeBigUInt64BE(now + ttl, 8);
  const payload = Buffer.concat([times, field("regression"), u32(1), Buffer.from([caps.length]), ...caps.map(([op, kind, target]) => Buffer.concat([Buffer.from([op, kind]), field(target)]))]);
  return Buffer.concat([payload, sign(null, payload, kp.privateKey)]);
}
const admin = token([[255, 255, ""]]);
const scoped = token([[2, 2, "tenant:"], [1, 2, "tenant:"]]);
const set = (key = "tenant:k", value = "value") => frame(2, Buffer.concat([Buffer.from([0]), field(key), field(value)]));

class Peer {
  data = Buffer.alloc(0); closed = false; wake?: () => void;
  constructor(readonly socket: Socket) {
    socket.on("data", d => { this.data = Buffer.concat([this.data, d]); this.wake?.(); });
    socket.on("error", () => { this.closed = true; this.wake?.(); });
    socket.on("close", () => { this.closed = true; this.wake?.(); });
  }
  async read(n: number, timeout = 2200) {
    const end = Date.now() + timeout;
    while (this.data.length < n) {
      if (this.closed) throw new Error(`closed with ${this.data.length}/${n} bytes`);
      const remaining = end - Date.now();
      if (remaining <= 0) throw new Error("read timed out");
      await new Promise<void>((r, reject) => {
        const timer = setTimeout(() => { this.wake = undefined; reject(new Error("read timed out")); }, remaining);
        this.wake = () => { clearTimeout(timer); this.wake = undefined; r(); };
      });
    }
    const out = this.data.subarray(0, n); this.data = this.data.subarray(n); return out;
  }
  async response() { const h = await this.read(5); return { code: h[0], body: await this.read(h.readUInt32BE(1)) }; }
  async request(data: Buffer) { this.socket.write(data); return this.response(); }
  async ws(data: Buffer, opcode = 2) {
    this.socket.write(wsFrame(data, opcode));
    const h = await this.read(2);
    let size = h[1] & 127;
    if (size === 126) size = (await this.read(2)).readUInt16BE();
    if (size === 127) size = Number((await this.read(8)).readBigUInt64BE());
    const payload = await this.read(size);
    return { code: payload[0], body: payload.subarray(5) };
  }
  close() { this.socket.destroy(); }
}
function wsFrame(data: Buffer, opcode = 2) {
  const h = Buffer.alloc(data.length < 126 ? 6 : 8);
  h[0] = 0x80 | opcode; h[1] = 0x80 | (data.length < 126 ? data.length : 126);
  if (data.length >= 126) h.writeUInt16BE(data.length, 2);
  return Buffer.concat([h, data]); // four zero mask bytes
}
async function connect(port: number) {
  const s = createConnection({ host: "127.0.0.1", port });
  const p = new Peer(s);
  await new Promise<void>((r, reject) => { s.once("connect", r); s.once("error", reject); });
  return p;
}
async function wsConnect(port: number) {
  const p = await connect(port);
  p.socket.write("GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n");
  let header = "";
  while (!header.endsWith("\r\n\r\n")) header += (await p.read(1)).toString();
  assert.match(header, /101 Switching/);
  return p;
}
async function port() {
  const server = createServer();
  await new Promise<void>(r => server.listen(0, "127.0.0.1", r));
  const value = (server.address() as { port: number }).port;
  await new Promise<void>(r => server.close(() => r()));
  return value;
}
async function withServer(config: object, action: (tcp: number, ws: number) => Promise<void>, persistence = "none", extraArgs: string[] = []) {
  const dir = await mkdtemp(join(tmpdir(), "wormdb-security-"));
  const tcp = await port(), ws = await port();
  await writeFile(join(dir, "config.json"), JSON.stringify(config));
  const child = spawn(binary, ["--config", join(dir, "config.json"), "--data", join(dir, "data"), "--port", String(tcp), "--gateway-port", String(ws), "--persistence", persistence, ...extraArgs], { cwd: dir, stdio: ["ignore", "ignore", "pipe"] });
  let logs = ""; child.stderr!.on("data", b => { logs += b; });
  let spawnError: Error | undefined;
  const exited = new Promise<void>(r => { child.once("exit", () => r()); child.once("error", e => { spawnError = e; r(); }); });
  try {
    const end = Date.now() + 6000;
    while (!logs.includes("WormDB listening") || !logs.includes("Gateway listening")) {
      if (spawnError || child.exitCode !== null || Date.now() > end) throw new Error(`startup failed: ${spawnError ?? logs}`);
      await delay(15);
    }
    try { await action(tcp, ws); } catch (e) { throw new Error(`${e}\nServer: ${logs}`); }
  } finally {
    child.kill(); await exited;
    await rm(dir, { recursive: true, force: true }); // only our mkdtemp fixture
  }
}
const settings = (auth: object, server = {}, gateway = {}) => ({
  auth, server: { bind_address: "127.0.0.1", timeout_ms: 350, max_connections: 128, ...server },
  gateway: { timeout_ms: 350, max_connections: 8, ...gateway },
});
const tests: Array<[string, () => Promise<void>]> = [];
function test(name: string, fn: () => Promise<void>) { tests.push([name, fn]); }

test("invalid keys and zero resource limits reject startup", async () => {
  const cases = [
    settings({ require_auth: true, public_keys: ["invalid-key"] }),
    settings({ require_auth: true }, { max_connections: 0 }),
    settings({ require_auth: true }, { timeout_ms: 0 }),
    settings({ require_auth: true }, {}, { max_connections: 0 }),
    settings({ require_auth: true }, {}, { timeout_ms: 0 }),
  ];
  for (const config of cases) {
    const dir = await mkdtemp(join(tmpdir(), "wormdb-security-invalid-"));
    await writeFile(join(dir, "config.json"), JSON.stringify(config));
    const child = spawn(binary, ["--config", join(dir, "config.json"), "--data", join(dir, "data"), "--port", String(await port()), "--gateway-port", String(await port()), "--persistence", "none"], { cwd: dir, stdio: ["ignore", "ignore", "pipe"] });
    let logs = ""; child.stderr!.on("data", b => { logs += b; });
    const exited = new Promise<number | null>(r => child.once("exit", r));
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      const code = await Promise.race([exited, new Promise<never>((_, reject) => { timer = setTimeout(() => reject(new Error("invalid configuration stayed running")), 2200); })]);
      assert.notEqual(code, 0); assert.ok(!logs.includes("listening on"));
    } finally {
      clearTimeout(timer); child.kill(); await exited; await rm(dir, { recursive: true, force: true });
    }
  }
});

test("keyless required auth blocks TCP and WS GET/SET/SAVE", () => withServer(settings({ require_auth: true }), async (tcp, ws) => {
  const p = await connect(tcp), w = await wsConnect(ws);
  try {
    p.socket.write("WW");
    for (const command of [set(), frame(1, field("tenant:k")), frame(11)]) {
      for (const response of [await p.request(command), await w.ws(command)]) {
        assert.equal(response.code, 3); assert.equal(response.body.toString(), "auth required");
      }
    }
    assert.equal((await p.request(frame(4))).code, 1);
  } finally { p.close(); w.close(); }
}));

test("client auth cannot be bypassed using the legacy replication preface", async () => {
  for (const keys of [[], [publicKey]]) await withServer(settings({ require_auth: true, public_keys: keys }), async tcp => {
    const p = await connect(tcp);
    try {
      p.socket.write("WR");
      let result: Awaited<ReturnType<Peer["response"]>> | undefined;
      try { result = await p.request(set()); } catch (e) { if (!p.closed) throw e; }
      // Closing with unread hostile bytes may reset the TCP connection before
      // its error frame reaches the client, especially on Windows.
      if (result) { assert.equal(result.code, 3); assert.match(result.body.toString(), /legacy replication rejected/); }
    }
    finally { p.close(); }
    if (keys.length) {
      const control = await connect(tcp); control.socket.write("WW");
      try {
        assert.equal((await control.request(frame(12, field(admin)))).code, 0);
        assert.equal((await control.request(frame(1, field("tenant:k")))).code, 2);
      } finally { control.close(); }
    }
  });
});

test("explicit cluster-open acknowledgment preserves legacy replication", () => withServer(settings({ require_auth: true }), async tcp => {
  const p = await connect(tcp);
  try { p.socket.write("WR"); assert.equal((await p.request(set())).code, 0); }
  finally { p.close(); }
}, "none", ["--cluster-open"]));

for (const perTransport of [false, true]) test(`explicit ${perTransport ? "transport" : "global"} opt-out remains functional`, () => withServer(
  settings({ require_auth: perTransport }, perTransport ? { auth_enabled: false } : {}, perTransport ? { auth_enabled: false } : {}), async (tcp, ws) => {
    const p = await connect(tcp), w = await wsConnect(ws);
    try { p.socket.write("WW"); assert.equal((await p.request(set())).code, 0); assert.equal((await p.request(frame(11))).code, 0); assert.equal((await w.ws(frame(11))).code, 0); }
    finally { p.close(); w.close(); }
  }
));

test("signed scoped tokens retain data access but cannot SAVE; admin can SAVE", () => withServer(settings({ require_auth: true, public_keys: [publicKey] }), async (tcp, ws) => {
  const p = await connect(tcp), w = await wsConnect(ws);
  try {
    p.socket.write("WW");
    for (const request of [(b: Buffer) => p.request(b), (b: Buffer) => w.ws(b)]) {
      assert.equal((await request(frame(12, field(scoped)))).code, 0);
      assert.equal((await request(set())).code, 0);
      assert.equal((await request(frame(1, field("tenant:k")))).body.toString(), "value");
      assert.equal((await request(set("other:k"))).code, 3);
      assert.equal((await request(frame(11))).body.toString(), "permission denied");
      const emptyKeyOnly = token([[255, 1, ""]]);
      assert.equal((await request(frame(12, field(emptyKeyOnly)))).code, 0);
      assert.equal((await request(frame(11))).body.toString(), "permission denied");
      assert.equal((await request(frame(12, field(admin)))).code, 0);
      assert.equal((await request(frame(11))).code, 0);
    }
  } finally { p.close(); w.close(); }
}, "snapshot"));

test("idle and trickled magic, frame payloads, HTTP and WS input expire", () => withServer(settings({ require_auth: true, public_keys: [publicKey] }), async (tcp, ws) => {
  const peers: Peer[] = [];
  const tricklers: ReturnType<typeof setInterval>[] = [];
  try {
    for (const bytes of [Buffer.alloc(0), Buffer.from("W"), Buffer.from("WR"), Buffer.from("W2"), Buffer.concat([Buffer.from("WW"), frame(2, Buffer.alloc(100)).subarray(0, 10)])]) {
      const p = await connect(tcp); peers.push(p); if (bytes.length) p.socket.write(bytes);
    }
    const h = await connect(ws); peers.push(h); h.socket.write("GET / HTTP/1.1\r\n");
    tricklers.push(setInterval(() => { if (!h.closed) h.socket.write("x"); }, 65));
    const w = await wsConnect(ws); peers.push(w); w.socket.write(Buffer.from([0x82, 0xfe, 0, 100, 0, 0, 0, 0, 1]));
    tricklers.push(setInterval(() => { if (!w.closed) w.socket.write(Buffer.from([1])); }, 65));
    await delay(1000);
    assert.ok(peers.every(p => p.closed), "stalled clients must all close");
    const good = await connect(tcp); peers.push(good); good.socket.write("WW"); assert.equal((await good.request(frame(4))).code, 1);
  } finally { tricklers.forEach(clearInterval); peers.forEach(p => p.close()); }
}));

test("pre-auth STATUS and WS PING cannot renew the authentication deadline", () => withServer(settings({ require_auth: true }), async (tcp, ws) => {
  const p = await connect(tcp), w = await wsConnect(ws); p.socket.write("WW");
  const timer = setInterval(() => { if (!p.closed) p.socket.write(frame(4)); if (!w.closed) w.socket.write(wsFrame(Buffer.alloc(0), 9)); }, 55);
  try { await delay(1000); assert.ok(p.closed && w.closed); }
  finally { clearInterval(timer); p.close(); w.close(); }
}));

test("global TCP and gateway budgets reject excess and recover slots", () => withServer(settings({ require_auth: true }, { max_connections: 4, timeout_ms: 900 }, { max_connections: 4, timeout_ms: 900 }), async (tcp, ws) => {
  for (const endpoint of [tcp, ws]) {
    const peers: Peer[] = [];
    try {
      for (let i = 0; i < 4; i++) peers.push(await connect(endpoint));
      await delay(60);
      const excess = await connect(endpoint); peers.push(excess);
      await delay(180); assert.ok(excess.closed, "fifth client must be rejected");
      peers[0].close(); await delay(60);
      const replacement = endpoint === tcp ? await connect(tcp) : await wsConnect(ws); peers.push(replacement);
      if (endpoint === tcp) { replacement.socket.write("WW"); assert.equal((await replacement.request(frame(4))).code, 1); }
    } finally { peers.forEach(p => p.close()); }
  }
}));

test("queued idle TCP sockets expire from accept time; workers recover", () => withServer(settings({ require_auth: true }), async (tcp) => {
  const peers: Peer[] = [];
  try {
    for (let i = 0; i < 90; i++) peers.push(await connect(tcp));
    await delay(1200);
    assert.ok(peers.every(p => p.closed), "queued clients must not get a fresh deadline at worker pickup");
    const p = await connect(tcp); peers.push(p); p.socket.write("WW"); assert.equal((await p.request(frame(4))).code, 1);
  } finally { peers.forEach(p => p.close()); }
}));

test("authenticated idle subscriptions survive; partial frames still expire", () => withServer(settings({ require_auth: true, public_keys: [publicKey] }), async (tcp, ws) => {
  const p = await connect(tcp), w = await wsConnect(ws); p.socket.write("WW");
  try {
    assert.equal((await p.request(frame(12, field(admin)))).code, 0);
    assert.equal((await w.ws(frame(12, field(admin)))).code, 0);
    assert.equal((await p.request(frame(6, field("events:")))).code, 0);
    assert.equal((await w.ws(frame(6, field("events:")))).code, 0);
    await delay(800); assert.ok(!p.closed && !w.closed, "idle subscriptions must remain usable");
    const publisher = await connect(tcp); publisher.socket.write("WW");
    try {
      assert.equal((await publisher.request(frame(12, field(admin)))).code, 0);
      assert.equal((await publisher.request(frame(8, Buffer.concat([field("events:"), field("hello")])))).code, 0);
      assert.equal((await p.response()).code, 4);
      const h = await w.read(2); const data = await w.read(h[1] & 127); assert.equal(data[0], 4);
    } finally { publisher.close(); }
    p.socket.write(Buffer.from([2])); w.socket.write(Buffer.from([0x82]));
    await delay(800); assert.ok(p.closed && w.closed, "partial frames must expire even on subscribed connections");
  } finally { p.close(); w.close(); }
}));

test("expiry during an idle read restores the reauthentication deadline", () => withServer(settings({ require_auth: true, public_keys: [publicKey] }), async (tcp, ws) => {
  const p = await connect(tcp), w = await wsConnect(ws); p.socket.write("WW");
  const short = token([[255, 255, ""]], 2n);
  let timer: ReturnType<typeof setInterval> | undefined;
  try {
    assert.equal((await p.request(frame(12, field(short)))).code, 0);
    assert.equal((await w.ws(frame(12, field(short)))).code, 0);
    assert.equal((await p.request(frame(6, field("events:")))).code, 0);
    await delay(2200);
    assert.equal((await p.request(set())).body.toString(), "auth required");
    assert.equal((await w.ws(set())).body.toString(), "auth required");
    timer = setInterval(() => { if (!p.closed) p.socket.write(frame(4)); if (!w.closed) w.socket.write(wsFrame(frame(4))); }, 55);
    await delay(1000); assert.ok(p.closed && w.closed, "expired credentials must not retain workers via public commands");
  } finally { clearInterval(timer); p.close(); w.close(); }
}));

test("non-reading clients cannot pin senders or retain connection slots", () => withServer(
  settings({ require_auth: false }, { max_connections: 1, timeout_ms: 5000 }, { max_connections: 1, timeout_ms: 5000 }), async (tcp, ws) => {
    const seed = await connect(tcp); seed.socket.write("WW");
    try { assert.equal((await seed.request(set("large", "x".repeat(8 * 1024 * 1024)))).code, 0); }
    finally { seed.close(); }
    await delay(60);
    for (const endpoint of [tcp, ws]) {
      const slow = endpoint === tcp ? await connect(tcp) : await wsConnect(ws);
      if (endpoint === tcp) slow.socket.write("WW");
      slow.socket.pause();
      // Multiple responses exceed OS send buffering even on Windows loopback.
      for (let i = 0; i < 16; i++) slow.socket.write(endpoint === tcp ? frame(1, field("large")) : wsFrame(frame(1, field("large"))));
      try {
        await delay(4500);
        const fresh = endpoint === tcp ? await connect(tcp) : await wsConnect(ws);
        try {
          if (endpoint === tcp) fresh.socket.write("WW");
          const response = endpoint === tcp ? await fresh.request(frame(4)) : await fresh.ws(frame(4));
          assert.equal(response.code, 1);
        } finally { fresh.close(); }
      } finally { slow.close(); }
    }
  }
));

let failures = 0;
const selected = tests.filter(([name]) => !process.argv[3] || name.includes(process.argv[3]));
assert.ok(selected.length, "test filter matched nothing");
for (const [name, fn] of selected) {
  try { await fn(); console.log(`PASS ${name}`); }
  catch (error) { failures++; console.error(`FAIL ${name}: ${error}`); }
}
console.log(`${selected.length - failures}/${selected.length} live security regressions passed (${process.platform})`);
process.exitCode = failures ? 1 : 0;
