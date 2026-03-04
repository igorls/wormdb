#!/usr/bin/env bun
import { WormClient } from "../lib/client";
import {
  WIRE_MAGIC,
  concatBytes,
  decodeResponse,
  encodeCommandFrame,
  isEventCode,
  toBytes,
  tryConsumeFrame,
  type Bytes,
} from "../lib/wire";
import path from "node:path";
import type { ServerWebSocket } from "bun";

const INITIAL_HOST = process.env.WORMDB_HOST ?? "127.0.0.1";
const INITIAL_PORT = Number(process.env.WORMDB_PORT ?? "6389");
const PORT = Number(process.env.UI_PORT ?? "8080");
const REPO_ROOT = path.resolve(import.meta.dir, "../../../..");
const UI_DIR = path.resolve(import.meta.dir, "../ui");
const ADMIN_TOKEN = process.env.WORMDB_ADMIN_TOKEN;

// ── Auto-Discovery Endpoint Pool ──

interface WormEndpoint {
  host: string;
  port: number;
  meshIp?: string;  // peer mesh IP this endpoint was derived from
}

// Start with a single seed — others are auto-discovered from CLUSTER PEERS
let activeEndpoint: WormEndpoint = { host: INITIAL_HOST, port: INITIAL_PORT };
let knownEndpoints: WormEndpoint[] = [{ ...activeEndpoint }];
let consecutiveFailures = 0;
let lastPeers: any[] = [];

function getActiveTarget() {
  return { host: activeEndpoint.host, port: activeEndpoint.port };
}

/** Auto-discover peer endpoints from CLUSTER PEERS response.
 *  Uses each alive peer's gossip endpoint IP + the cluster's WormDB port (self_port). */
function discoverEndpoints(peers: any[], wormPort: number) {
  for (const peer of peers) {
    if (peer.state !== "alive" || !peer.gossipEndpoint) continue;

    // Extract IP from gossip endpoint (format: "192.168.0.4:51821")
    const colonIdx = peer.gossipEndpoint.lastIndexOf(":");
    const peerIp = colonIdx > 0 ? peer.gossipEndpoint.slice(0, colonIdx) : peer.gossipEndpoint;
    if (!peerIp || peerIp === "0.0.0.0") continue;

    // Check if we already know this endpoint
    const exists = knownEndpoints.some(ep => ep.host === peerIp && ep.port === wormPort);
    if (!exists) {
      const newEp: WormEndpoint = { host: peerIp, port: wormPort, meshIp: peer.meshIp };
      knownEndpoints.push(newEp);
      console.log(`WS: discovered peer endpoint ${peerIp}:${wormPort} (mesh ${peer.meshIp})`);
    }
  }
}

function failoverToNext() {
  const currentKey = `${activeEndpoint.host}:${activeEndpoint.port}`;
  // Try the next known endpoint that isn't the current one
  const candidates = knownEndpoints.filter(ep => `${ep.host}:${ep.port}` !== currentKey);
  if (candidates.length === 0) {
    console.error("WS: no alternative endpoints available for failover");
    return false;
  }
  const next = candidates[0];
  console.log(`WS: FAILOVER ${currentKey} → ${next.host}:${next.port}`);
  activeEndpoint = { ...next };
  consecutiveFailures = 0;

  // Reconnect event subscription to the new target
  if (eventSocket) {
    eventSocket.end();
    eventSocket = null;
  }
  setupEventSubscription();
  return true;
}

/** Parse CLUSTER PEERS response into structured data.
 *  Filters ghost entries: when a container restarts, SWIM keeps the old dead
 *  mesh IP alongside the new alive one at the same gossip endpoint. We deduplicate
 *  by gossip IP, preferring alive over dead entries. */
function parsePeersResponse(text: string): { selfIp: string; selfPort: number; peers: any[] } {
  const sections = text.split("---\n").filter(s => s.trim());
  let selfIp = "0.0.0.0";
  let selfPort = 0;
  const rawPeers: any[] = [];

  for (let i = 0; i < sections.length; i++) {
    const kv: Record<string, string> = {};
    for (const line of sections[i].split("\n")) {
      const eq = line.indexOf("=");
      if (eq > 0) kv[line.slice(0, eq)] = line.slice(eq + 1);
    }
    if (i === 0 && kv.self_mesh_ip) {
      selfIp = kv.self_mesh_ip;
      selfPort = Number(kv.self_port || "0");
    } else if (kv.mesh_ip) {
      rawPeers.push({
        meshIp: kv.mesh_ip,
        state: kv.state || "unknown",
        gossipEndpoint: kv.gossip_endpoint || null,
        wormwire: kv.wormwire || "disconnected",
      });
    }
  }

  // Deduplicate by gossip endpoint IP — prefer alive over dead
  const byGossipIp = new Map<string, any>();
  for (const peer of rawPeers) {
    if (!peer.gossipEndpoint) continue;
    const ip = peer.gossipEndpoint.split(":")[0];
    const existing = byGossipIp.get(ip);
    if (!existing || (existing.state === "dead" && peer.state !== "dead")) {
      byGossipIp.set(ip, peer);
    }
  }
  const peers = [...byGossipIp.values()];

  return { selfIp, selfPort, peers };
}

type ConnectionDiagnostic = {
  code?: string;
  error: string;
  hint: string;
};

function isValidPort(value: number): boolean {
  return Number.isInteger(value) && value >= 1 && value <= 65535;
}

function formatConnectionDiagnostic(err: unknown, host: string, port: number): ConnectionDiagnostic {
  const maybeErr = err as { code?: string; message?: string };
  const code = maybeErr?.code;
  const target = `${host}:${port}`;

  if (code === "ECONNREFUSED") {
    return {
      code,
      error: `Connection refused by WormDB at ${target}.`,
      hint: `Start WormDB and confirm it listens on ${target} (default port is 6389).`,
    };
  }

  if (code === "ENOTFOUND" || code === "EAI_AGAIN") {
    return {
      code,
      error: `Unable to resolve WormDB host '${host}'.`,
      hint: "Verify WORMDB_HOST and DNS/network configuration.",
    };
  }

  if (code === "ETIMEDOUT") {
    return {
      code,
      error: `Timed out connecting to WormDB at ${target}.`,
      hint: "Verify firewall/routing and that WormDB is reachable from this machine.",
    };
  }

  if (code === "EHOSTUNREACH" || code === "ENETUNREACH") {
    return {
      code,
      error: `Network unreachable for WormDB target ${target}.`,
      hint: "Check host reachability and local network routes.",
    };
  }

  const message = maybeErr?.message ?? String(err);
  return {
    code,
    error: `Failed to reach WormDB at ${target}: ${message}`,
    hint: "Verify WORMDB_HOST/WORMDB_PORT and ensure WormDB is running.",
  };
}

function statusErrorPayload(err: unknown) {
  const diagnostic = formatConnectionDiagnostic(err, activeEndpoint.host, activeEndpoint.port);
  return {
    target: `${activeEndpoint.host}:${activeEndpoint.port}`,
    error: diagnostic.error,
    hint: diagnostic.hint,
    code: diagnostic.code,
  };
}

function hasAdminAccess(req: Request): boolean {
  if (!ADMIN_TOKEN || ADMIN_TOKEN.length === 0) return true;
  const headerToken = req.headers.get("x-admin-token");
  return headerToken === ADMIN_TOKEN;
}

async function runDeploymentCommand(command: string[]) {
  const proc = Bun.spawn(command, {
    cwd: REPO_ROOT,
    stdout: "pipe",
    stderr: "pipe",
  });

  const [stdout, stderr, code] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]);

  return {
    ok: code === 0,
    code,
    stdout,
    stderr,
    command: command.join(" "),
  };
}

function notFound(): Response {
  return new Response("Not found", { status: 404 });
}

if (!isValidPort(activeEndpoint.port)) {
  console.error(`Invalid WORMDB_PORT '${process.env.WORMDB_PORT ?? ""}'. Use a port between 1 and 65535 (default 6389).`);
  process.exit(1);
}

if (!isValidPort(PORT)) {
  console.error(`Invalid UI_PORT '${process.env.UI_PORT ?? ""}'. Use a port between 1 and 65535.`);
  process.exit(1);
}

const htmlText = await Bun.file(path.join(UI_DIR, "index.html")).text();
const cssText = await Bun.file(path.join(UI_DIR, "styles.css")).text();

// Bundle app.ts + mesh.ts into a single JS output (resolves imports)
const buildResult = await Bun.build({
  entrypoints: [path.join(UI_DIR, "app.ts")],
  target: "browser",
  minify: false,
});
const appJsText = buildResult.success ? await buildResult.outputs[0].text() : "console.error('Build failed');";

// ── WebSocket Real-Time Infrastructure ──

type WsData = { id: number };
const wsClients = new Set<ServerWebSocket<WsData>>();
let wsIdCounter = 0;

function broadcast(type: string, payload: unknown) {
  const msg = JSON.stringify({ type, ...payload as object });
  for (const ws of wsClients) {
    try { ws.send(msg); } catch { wsClients.delete(ws); }
  }
}

// Shared WormDB event subscription — one TCP connection for all WS clients
type SocketData = string | ArrayBuffer | SharedArrayBuffer | ArrayBufferView;
type EventSocket = {
  write(data: SocketData): number;
  end(): void;
};

let eventSocket: EventSocket | null = null;
let eventConnecting = false;
let eventInbound: Bytes = new Uint8Array(0);
let eventReconnectTimer: ReturnType<typeof setTimeout> | null = null;

function scheduleEventReconnect(delayMs = 3000) {
  if (eventReconnectTimer) return;
  eventReconnectTimer = setTimeout(() => {
    eventReconnectTimer = null;
    setupEventSubscription();
  }, delayMs);
}

function setupEventSubscription() {
  if (eventSocket || eventConnecting) return;
  eventConnecting = true;

  Bun.connect({
    hostname: activeEndpoint.host,
    port: activeEndpoint.port,
    socket: {
      open(socket) {
        eventConnecting = false;
        eventSocket = socket;
        eventInbound = new Uint8Array(0);

        socket.write(WIRE_MAGIC);
        const subFrame = encodeCommandFrame({ kind: "SUB", channel: "cluster" });
        socket.write(subFrame);
        console.log("WS: subscribed to WormDB cluster events");
      },
      data(socket, chunk) {
        if (eventSocket !== socket) return;

        eventInbound = concatBytes([eventInbound, toBytes(chunk)]);
        while (true) {
          const frame = tryConsumeFrame(eventInbound);
          if (frame == null) return;

          eventInbound = frame.remaining;
          if (!isEventCode(frame.code)) continue;

          const decoded = decodeResponse(frame.code, frame.payload);
          if (decoded.type === "event") {
            broadcast("event", { channel: decoded.channel, message: decoded.message });
          }
        }
      },
      close(socket) {
        if (eventSocket !== socket) return;
        eventSocket = null;
        eventInbound = new Uint8Array(0);
        scheduleEventReconnect(3000);
      },
      error(socket, err) {
        if (eventSocket && eventSocket !== socket) return;
        eventSocket = null;
        eventConnecting = false;
        eventInbound = new Uint8Array(0);
        console.error("WS: event subscription error", err.message);
        scheduleEventReconnect(3000);
      },
    },
  }).catch((err) => {
    eventConnecting = false;
    eventSocket = null;
    eventInbound = new Uint8Array(0);
    console.error("WS: event subscription connect failure", err instanceof Error ? err.message : String(err));
    scheduleEventReconnect(3000);
  });
}

// Push status updates to all WS clients
async function pushStatus() {
  const { host, port } = getActiveTarget();
  try {
    const client = new WormClient({ host, port, timeoutMs: 3000 });
    const [response, cluster, peersResp] = await Promise.all([
      client.send("STATUS"),
      client.send("CLUSTER STATUS"),
      client.send("CLUSTER PEERS").catch(() => null),
    ]);

    consecutiveFailures = 0;

    // Parse peer data if available
    let selfMeshIp = "";
    let peers: any[] = [];
    if (peersResp?.type === "bulk" && peersResp.value) {
      const parsed = parsePeersResponse(peersResp.value);
      selfMeshIp = parsed.selfIp;
      peers = parsed.peers;
      lastPeers = peers;

      // Auto-discover failover endpoints from peer gossip IPs
      if (parsed.selfPort > 0 && peers.length > 0) {
        discoverEndpoints(peers, parsed.selfPort);
      }
    }

    broadcast("status", {
      target: `${host}:${port}`,
      selfMeshIp,
      response,
      cluster,
      peers,
      knownEndpoints: knownEndpoints.length,
      connected: true,
    });
  } catch {
    consecutiveFailures++;
    broadcast("status", {
      target: `${host}:${port}`,
      connected: false,
      failureCount: consecutiveFailures,
    });

    // Auto-failover after 2 consecutive failures
    if (consecutiveFailures >= 2 && knownEndpoints.length > 1) {
      failoverToNext();
    }
  }
}

// Push docker container state to all WS clients
async function pushDocker() {
  try {
    const proc = Bun.spawn(
      ["docker", "compose", "ps", "--format", "json", "-a"],
      { cwd: REPO_ROOT, stdout: "pipe", stderr: "pipe" }
    );
    const [stdout, , code] = await Promise.all([
      new Response(proc.stdout).text(),
      new Response(proc.stderr).text(),
      proc.exited,
    ]);
    if (code !== 0) return;
    const containers = stdout.trim().split("\n")
      .filter((l) => l.startsWith("{"))
      .map((l) => {
        const c = JSON.parse(l);
        return { name: c.Name, service: c.Service, state: c.State, status: c.Status, ports: c.Ports };
      });
    broadcast("docker", { containers });
  } catch { /* docker might not be available */ }
}

let server: ReturnType<typeof Bun.serve>;
try {
  server = Bun.serve<WsData>({
    port: PORT,
    idleTimeout: 120,
    async fetch(req, server) {
      const url = new URL(req.url);

      // WebSocket upgrade
      if (url.pathname === "/ws") {
        const upgraded = server.upgrade(req, { data: { id: ++wsIdCounter } });
        if (upgraded) return undefined as unknown as Response;
        return new Response("WebSocket upgrade failed", { status: 400 });
      }

      if (url.pathname === "/") {
        return new Response(htmlText, {
          headers: { "content-type": "text/html; charset=utf-8" },
        });
      }

      if (url.pathname === "/assets/styles.css") {
        return new Response(cssText, {
          headers: { "content-type": "text/css; charset=utf-8" },
        });
      }

      if (url.pathname === "/assets/app.js") {
        return new Response(appJsText, {
          headers: { "content-type": "application/javascript; charset=utf-8" },
        });
      }

      if (url.pathname === "/api/status" && req.method === "GET") {
        try {
          const client = new WormClient({ host: activeEndpoint.host, port: activeEndpoint.port, timeoutMs: 5000 });
          const [response, cluster] = await Promise.all([
            client.send("STATUS"),
            client.send("CLUSTER STATUS"),
          ]);
          return Response.json({
            target: `${activeEndpoint.host}:${activeEndpoint.port}`,
            response,
            cluster,
          });
        } catch (err) {
          return Response.json(statusErrorPayload(err), { status: 503 });
        }
      }

      if (url.pathname === "/api/cluster/status" && req.method === "GET") {
        try {
          const client = new WormClient({ host: activeEndpoint.host, port: activeEndpoint.port, timeoutMs: 5000 });
          const response = await client.send("CLUSTER STATUS");
          return Response.json({
            target: `${activeEndpoint.host}:${activeEndpoint.port}`,
            response,
          });
        } catch (err) {
          return Response.json(statusErrorPayload(err), { status: 503 });
        }
      }

      if (url.pathname === "/api/db/command" && req.method === "POST") {
        if (!hasAdminAccess(req)) {
          return Response.json({ error: "unauthorized" }, { status: 401 });
        }

        const body = await req.json() as { command?: string };
        if (!body.command || typeof body.command !== "string") {
          return Response.json({ error: "Missing command" }, { status: 400 });
        }

        try {
          const client = new WormClient({ host: activeEndpoint.host, port: activeEndpoint.port, timeoutMs: 5000 });
          const response = await client.send(body.command.trim());
          return Response.json({ command: body.command.trim(), response });
        } catch (err) {
          const diagnostic = formatConnectionDiagnostic(err, activeEndpoint.host, activeEndpoint.port);
          return Response.json({
            error: diagnostic.error,
            hint: diagnostic.hint,
            code: diagnostic.code,
          }, { status: 503 });
        }
      }

      if (url.pathname === "/api/events" && req.method === "GET") {
        return new Response(new ReadableStream({
          start(controller) {
            import("node:net").then((net) => {
              const socket = net.createConnection({ host: activeEndpoint.host, port: activeEndpoint.port });
              socket.on("connect", () => {
                socket.write("SUB cluster\n");
              });
              let buffer = "";
              socket.on("data", (chunk) => {
                buffer += chunk.toString("utf8");
                let newlineIdx;
                while ((newlineIdx = buffer.indexOf("\r\n")) !== -1) {
                  const line = buffer.slice(0, newlineIdx);
                  buffer = buffer.slice(newlineIdx + 2);
                  if (line.startsWith(">EVENT ")) {
                    // It expects another line with the message
                    const nextNewline = buffer.indexOf("\r\n");
                    if (nextNewline !== -1) {
                      const message = buffer.slice(0, nextNewline);
                      buffer = buffer.slice(nextNewline + 2);
                      const channel = line.slice(7).trim();
                      controller.enqueue(`data: ${JSON.stringify({ channel, message })}\n\n`);
                    } else {
                      // restore line and wait for more data
                      buffer = line + "\r\n" + buffer;
                      break;
                    }
                  } else if (line.startsWith("+OK")) {
                    // SUB success
                  }
                }
              });
              socket.on("error", (err) => {
                console.error("SSE socket error", err);
                controller.error(err);
              });
              socket.on("close", () => {
                try { controller.close(); } catch (e) { }
              });
              req.signal.addEventListener("abort", () => {
                socket.destroy();
              });
            });
          }
        }), {
          headers: {
            "Content-Type": "text/event-stream",
            "Cache-Control": "no-cache",
            "Connection": "keep-alive"
          }
        });
      }

      if (url.pathname === "/api/deploy/start" && req.method === "POST") {
        if (!hasAdminAccess(req)) {
          return Response.json({ error: "unauthorized" }, { status: 401 });
        }

        const result = await runDeploymentCommand(["docker", "compose", "up", "-d"]);
        return Response.json(result, { status: result.ok ? 200 : 500 });
      }

      if (url.pathname === "/api/deploy/stop" && req.method === "POST") {
        if (!hasAdminAccess(req)) {
          return Response.json({ error: "unauthorized" }, { status: 401 });
        }

        const result = await runDeploymentCommand(["docker", "compose", "down"]);
        return Response.json(result, { status: result.ok ? 200 : 500 });
      }

      // ── Docker Container Control Panel ──

      if (url.pathname === "/api/docker/containers" && req.method === "GET") {
        try {
          const proc = Bun.spawn(
            ["docker", "compose", "ps", "--format", "json", "-a"],
            { cwd: REPO_ROOT, stdout: "pipe", stderr: "pipe" }
          );
          const [stdout, , code] = await Promise.all([
            new Response(proc.stdout).text(),
            new Response(proc.stderr).text(),
            proc.exited,
          ]);
          if (code !== 0) {
            return Response.json({ error: "docker compose ps failed" }, { status: 500 });
          }
          // Docker outputs one JSON object per line
          const containers = stdout
            .trim()
            .split("\n")
            .filter((l) => l.startsWith("{"))
            .map((l) => {
              const c = JSON.parse(l);
              return {
                name: c.Name,
                service: c.Service,
                state: c.State,    // "running" | "exited" | ...
                status: c.Status,  // "Up 5 minutes" etc
                ports: c.Ports,
              };
            });
          return Response.json({ containers });
        } catch (err) {
          return Response.json({ error: String(err) }, { status: 500 });
        }
      }

      if (url.pathname === "/api/docker/container" && req.method === "POST") {
        if (!hasAdminAccess(req)) {
          return Response.json({ error: "unauthorized" }, { status: 401 });
        }
        const body = (await req.json()) as { container?: string; action?: string };
        const { container, action } = body;
        if (!container || !action) {
          return Response.json({ error: "Missing container or action" }, { status: 400 });
        }
        // Validate action
        if (!["stop", "kill", "start"].includes(action)) {
          return Response.json({ error: `Invalid action: ${action}` }, { status: 400 });
        }
        // Validate container name (must start with wormdb-)
        if (!container.startsWith("wormdb-")) {
          return Response.json({ error: "Invalid container name" }, { status: 400 });
        }
        const cmd =
          action === "stop"
            ? ["docker", "stop", "-t", "10", container]
            : action === "kill"
              ? ["docker", "kill", container]
              : ["docker", "start", container];

        const result = await runDeploymentCommand(cmd);
        return Response.json(result, { status: result.ok ? 200 : 500 });
      }

      return notFound();
    },

    // Bun native WebSocket handler
    websocket: {
      open(ws: ServerWebSocket<WsData>) {
        wsClients.add(ws);
        console.log(`WS: client ${ws.data.id} connected (${wsClients.size} total)`);
        // Send immediate snapshot
        pushStatus();
        pushDocker();
      },
      close(ws: ServerWebSocket<WsData>) {
        wsClients.delete(ws);
        console.log(`WS: client ${ws.data.id} disconnected (${wsClients.size} total)`);
      },
      message(ws: ServerWebSocket<WsData>, msg: string | Buffer) {
        // Handle client commands over WS
        try {
          const data = JSON.parse(typeof msg === "string" ? msg : msg.toString());
          if (data.type === "docker_action") {
            handleDockerAction(ws, data);
          } else if (data.type === "command") {
            handleWormCommand(ws, data);
          }
        } catch { /* ignore malformed */ }
      },
    },
  });

  // WS message handlers
  async function handleDockerAction(ws: ServerWebSocket<WsData>, data: { container?: string; action?: string }) {
    const { container, action } = data;
    if (!container || !action) return;
    if (!["stop", "kill", "start"].includes(action)) return;
    if (!container.startsWith("wormdb-")) return;
    const cmd = action === "stop"
      ? ["docker", "stop", "-t", "10", container]
      : action === "kill"
        ? ["docker", "kill", container]
        : ["docker", "start", container];
    const result = await runDeploymentCommand(cmd);
    ws.send(JSON.stringify({ type: "docker_result", ...result }));

    // Rapid polling burst: push docker + status every 1s for 10s
    // to quickly catch the SWIM state transition on the mesh canvas
    pushDocker();
    pushStatus();
    for (let i = 1; i <= 10; i++) {
      setTimeout(() => { pushDocker(); pushStatus(); }, i * 1000);
    }
  }

  async function handleWormCommand(ws: ServerWebSocket<WsData>, data: { command?: string }) {
    if (!data.command) return;
    try {
      const client = new WormClient({ host: activeEndpoint.host, port: activeEndpoint.port, timeoutMs: 5000 });
      const response = await client.send(data.command.trim());
      ws.send(JSON.stringify({ type: "command_result", command: data.command.trim(), response }));
    } catch (err) {
      const diagnostic = formatConnectionDiagnostic(err, activeEndpoint.host, activeEndpoint.port);
      ws.send(JSON.stringify({ type: "command_result", error: diagnostic.error }));
    }
  }
} catch (err) {
  const message = err instanceof Error ? err.message : String(err);
  console.error(`WormDB UI failed to start on port ${PORT}: ${message}`);
  console.error("Remediation: verify UI_PORT is free and valid, then retry.");
  process.exit(1);
}

console.log(`WormDB UI listening on http://localhost:${server.port}`);
console.log(`Target database: ${activeEndpoint.host}:${activeEndpoint.port}`);

// Start WebSocket push loops
setInterval(pushStatus, 2000);
setInterval(pushDocker, 3000);
setupEventSubscription();

const startupProbe = new WormClient({ host: activeEndpoint.host, port: activeEndpoint.port, timeoutMs: 2000 });
startupProbe.send("STATUS").catch((err) => {
  const diagnostic = formatConnectionDiagnostic(err, activeEndpoint.host, activeEndpoint.port);
  console.error(`Startup connectivity check: ${diagnostic.error}`);
  console.error(`Hint: ${diagnostic.hint}`);
});
