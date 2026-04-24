#!/usr/bin/env bun
// Query an already-ingested agent-memory namespace.
//
// Usage:
//   bun run examples/agent-memory/client/query.ts "kyoto cherry blossoms" [--ns demo] [-k 5] [--lambda 0.3]

import { connect } from "./mem";
import { embed } from "../fixtures/embedder";

function parseArgs(argv: string[]): {
  text: string;
  ns: string;
  k: number;
  lambda: number;
  host: string;
  port: number;
} {
  let ns = "demo";
  let k = 5;
  let lambda = 0;
  let host = "127.0.0.1";
  let port = 6389;
  const positional: string[] = [];
  for (let i = 0; i < argv.length; i += 1) {
    const t = argv[i];
    const next = () => argv[++i] ?? "";
    if (t === "--ns") ns = next();
    else if (t === "-k" || t === "--k") k = Number(next());
    else if (t === "--lambda") lambda = Number(next());
    else if (t === "--host") host = next();
    else if (t === "--port") port = Number(next());
    else positional.push(t);
  }
  return { text: positional.join(" "), ns, k, lambda, host, port };
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.text.length === 0) {
    console.error("usage: query.ts \"<query text>\" [--ns ns] [-k 5] [--lambda 0..1]");
    process.exit(2);
  }

  const { wire, mem } = connect({ host: args.host, port: args.port });
  try {
    const qvec = embed(args.text);
    const hits = await mem.query(args.ns, qvec, args.k, {
      lambda: args.lambda,
      snippetChars: 140,
    });
    for (const h of hits) {
      const sessionTag = (h.meta as { session_id?: string } | null)?.session_id ?? "?";
      const role = (h.meta as { role?: string } | null)?.role ?? "?";
      console.log(
        `${h.score.toFixed(4)}  [${sessionTag}/${role}]  ${h.doc ?? ""}`,
      );
    }
  } finally {
    await wire.close();
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
