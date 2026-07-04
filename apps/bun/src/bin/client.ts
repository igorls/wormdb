#!/usr/bin/env bun
import { WormDB } from "../lib/wormdb";

const DEFAULT_HOST = "127.0.0.1";
const DEFAULT_PORT = 6389;

type ParsedArgs = {
  host: string;
  port: number;
  commandParts: string[];
};

function parseArgs(argv: string[]): ParsedArgs {
  let host = DEFAULT_HOST;
  let port = DEFAULT_PORT;

  const commandParts: string[] = [];

  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i];
    if (token === "--host") {
      host = argv[++i] ?? host;
      continue;
    }
    if (token === "--port") {
      const next = Number(argv[++i]);
      if (!Number.isFinite(next)) throw new Error("--port must be a number");
      port = next;
      continue;
    }
    commandParts.push(token);
  }

  return { host, port, commandParts };
}

function formatConnectionDiagnostic(err: unknown, host: string, port: number): string {
  const maybeErr = err as { code?: string; message?: string };
  const code = maybeErr?.code;
  const base = `Unable to reach WormDB at ${host}:${port}.`;

  if (code === "ECONNREFUSED") {
    return `${base} Connection refused. Start WormDB (default port ${DEFAULT_PORT}) or check --host/--port.`;
  }
  if (code === "ENOTFOUND" || code === "EAI_AGAIN") {
    return `${base} Host resolution failed (${code}). Verify --host and DNS/network configuration.`;
  }
  if (code === "ETIMEDOUT") {
    return `${base} Connection timed out. Verify firewall/routing and that WormDB is listening on ${host}:${port}.`;
  }
  if (code === "EHOSTUNREACH" || code === "ENETUNREACH") {
    return `${base} Network is unreachable (${code}). Verify local networking and target host reachability.`;
  }

  const message = maybeErr?.message ?? String(err);
  return `${base} ${message}`;
}

function buildCommand(parts: string[]): string {
  if (parts.length === 0) {
    throw new Error("Missing command. Example: STATUS or GET mykey");
  }

  const verb = parts[0].toLowerCase();

  if (verb === "status") return "STATUS";
  if (verb === "cluster-status") return "CLUSTER STATUS";
  if (verb === "get" && parts[1]) return `GET ${parts[1]}`;
  if (verb === "set" && parts[1] && parts[2]) {
    const worm = parts.includes("--worm") ? " WORM" : "";
    return `SET ${parts[1]} ${parts[2]}${worm}`;
  }
  if (verb === "del" && parts[1]) return `DEL ${parts[1]}`;
  if (verb === "pub" && parts[1] && parts.length >= 3) {
    return `PUB ${parts[1]} ${parts.slice(2).join(" ")}`;
  }

  return parts.join(" ");
}

async function main() {
  const args = parseArgs(Bun.argv.slice(2));
  selectedHost = args.host;
  selectedPort = args.port;
  const command = buildCommand(args.commandParts);
  // One-shot CLI: reconnect off so a dead server fails fast instead of retrying.
  const client = new WormDB({ host: args.host, port: args.port, reconnect: { enabled: false } });
  const response = await client.send(command).finally(() => client.close());

  if (response.type === "error") {
    console.error(`ERR: ${response.message}`);
    process.exit(1);
  }

  if (response.type === "ok") {
    console.log("OK");
    return;
  }

  if (response.type === "null") {
    console.log("(null)");
    return;
  }

  if (response.type === "bulk") {
    console.log(response.value);
    return;
  }

  if (response.type === "event") {
    console.log(`[${response.channel}] ${response.message}`);
  }
}

let selectedHost = DEFAULT_HOST;
let selectedPort = DEFAULT_PORT;

main().catch((err) => {
  const maybeErr = err as Error;
  const hasCode = typeof err === "object" && err !== null && "code" in err;
  if (!hasCode && maybeErr?.message?.startsWith("--port must be a number")) {
    console.error(maybeErr.message);
  } else {
    console.error(formatConnectionDiagnostic(err, selectedHost, selectedPort));
  }
  process.exit(1);
});
