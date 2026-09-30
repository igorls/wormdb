#!/usr/bin/env bun
// Ingest the synthetic session fixtures into a WormDB mem namespace.
//
// Usage:
//   bun run examples/agent-memory/client/ingest.ts [--ns demo] [--reset]

import { connect } from "./mem";
import { embed, embedderId } from "../fixtures/embedder";
import { SESSIONS, flatten } from "../fixtures/sessions";

function parseArgs(argv: string[]): { ns: string; reset: boolean; host: string; port: number } {
  let ns = "demo";
  let reset = false;
  let host = "127.0.0.1";
  let port = 6389;
  for (let i = 0; i < argv.length; i += 1) {
    const t = argv[i];
    const next = () => argv[++i] ?? "";
    if (t === "--ns") ns = next();
    else if (t === "--reset") reset = true;
    else if (t === "--host") host = next();
    else if (t === "--port") port = Number(next());
  }
  return { ns, reset, host, port };
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const { wire, mem } = connect({ host: args.host, port: args.port });

  try {
    if (args.reset) {
      console.error(`Dropping namespace '${args.ns}' first...`);
      const drop = await mem.drop(args.ns);
      console.error(`  deleted=${drop.deleted} skipped_worm=${drop.skipped_worm} errors=${drop.errors}`);
    }

    const eid = embedderId();
    await mem.init(args.ns, eid, "cosine");
    console.error(`Initialized ns='${args.ns}' embedder='${eid}' metric=cosine`);

    const chunks = flatten(SESSIONS);
    const t0 = performance.now();
    for (const c of chunks) {
      const vec = embed(c.text);
      await mem.add(args.ns, c.doc_id, c.text, vec, { meta: c.meta, worm: true });
    }
    const elapsed = performance.now() - t0;
    console.error(`Ingested ${chunks.length} chunks in ${elapsed.toFixed(1)}ms (${(chunks.length / (elapsed / 1000)).toFixed(0)}/s)`);

    const stats = await mem.stats(args.ns);
    console.log(JSON.stringify(stats, null, 2));
  } finally {
    await wire.close();
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
