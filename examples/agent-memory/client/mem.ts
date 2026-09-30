// Typed client wrapping EXEC mem_* procedures.
//
// Thin surface — each method encodes args, calls WormClient.sendCommand,
// and decodes the JSON response. Binary embeddings are passed as
// Uint8Array args, relying on the wire layer's binary-arg support.

import { WormClient } from "../../../apps/bun/src/lib/client";

export type Metric = "cosine" | "dot" | "l2";

export type Capabilities = {
  name: string;
  version: string;
  retrieval_unit: "chunk" | "turn" | "session";
  temporal_decay: boolean;
  bulk_add?: boolean;
  vector_only?: boolean;
  verbatim: boolean;
  local: boolean;
  structured_facts: boolean;
  metrics: Metric[];
};

export type DocRecord = {
  id: string;
  text: string;
  meta: unknown;
  ts: number;
};

export type QueryHit = {
  id: string;
  score: number;
  ts: number;
  doc?: string | null;
  meta: unknown;
};

export type NamespaceStats = {
  namespace: string;
  vectors: number;
  doc_keys: number;
  dimensions: number;
  config: null | {
    embedder_id: string;
    metric: Metric;
    vector_only?: boolean;
    created_at: number;
  };
  hnsw?: {
    metric: Metric;
    nodes: number;
    live: number;
    tombstones: number;
  };
};

export type DropResult = {
  namespace: string;
  index_dropped: boolean;
  deleted: number;
  skipped_worm: number;
  errors: number;
};

export type AddOptions = {
  meta?: unknown;
  worm?: boolean;
  embedderId?: string;
};

export type InitOptions = {
  vectorOnly?: boolean;
};

export type BulkAddRow = {
  id: string;
  embedding: Uint8Array;
  meta?: unknown;
};

export type QueryOptions = {
  lambda?: number;
  minScore?: number;
  snippetChars?: number;
  filter?: string;
};

export class MemError extends Error {
  readonly procedure: string;
  constructor(procedure: string, message: string) {
    super(`${procedure}: ${message}`);
    this.name = "MemError";
    this.procedure = procedure;
  }
}

/// Pull a string payload out of a WormResponse or throw on error/null.
/// Null is treated as an error because every mem_* procedure that
/// returns data returns a VALUE frame; null means something upstream
/// bailed without setting a response.
type WormResp =
  | { type: "ok" }
  | { type: "error"; message: string }
  | { type: "null" }
  | { type: "bulk"; value: string }
  | { type: "event"; channel: string; message: string };

function unwrapValue(resp: WormResp, proc: string): string {
  if (resp.type === "error") throw new MemError(proc, resp.message);
  if (resp.type === "null") throw new MemError(proc, "unexpected NULL response");
  if (resp.type === "bulk") return resp.value;
  if (resp.type === "ok") return "";
  throw new MemError(proc, `unexpected response type: ${resp.type}`);
}

function unwrapOk(resp: WormResp, proc: string): void {
  if (resp.type === "ok") return;
  if (resp.type === "error") throw new MemError(proc, resp.message);
  // Some procedures return VALUE instead of OK — let the caller decide.
}

export class MemClient {
  constructor(private readonly wire: WormClient) {}

  async capabilities(): Promise<Capabilities> {
    const resp = await this.wire.sendCommand({
      kind: "EXEC",
      procedure: "mem_capabilities",
      args: [],
    });
    return JSON.parse(unwrapValue(resp as WormResp, "mem_capabilities"));
  }

  async init(ns: string, embedderId: string, metric: Metric = "cosine", options: InitOptions = {}): Promise<void> {
    const args = [ns, embedderId, metric];
    if (options.vectorOnly !== undefined) {
      args.push(options.vectorOnly ? "vector_only=true" : "vector_only=false");
    }
    const resp = await this.wire.sendCommand({
      kind: "EXEC",
      procedure: "mem_init",
      args,
    });
    unwrapOk(resp as WormResp, "mem_init");
  }

  async add(
    ns: string,
    docId: string,
    text: string,
    embedding: Uint8Array,
    options: AddOptions = {},
  ): Promise<void> {
    const args: (string | Uint8Array)[] = [ns, docId, text, embedding];
    if (options.meta !== undefined) {
      args.push(JSON.stringify(options.meta));
    } else if (options.worm !== undefined || options.embedderId !== undefined) {
      // Meta is positional before worm — push an empty placeholder if
      // the caller wants to set worm/embedder without meta.
      args.push("");
    }
    if (options.worm !== undefined) {
      args.push(options.worm ? "1" : "0");
    } else if (options.embedderId !== undefined) {
      args.push("1");
    }
    if (options.embedderId !== undefined) {
      args.push(options.embedderId);
    }
    const resp = await this.wire.sendCommand({
      kind: "EXEC",
      procedure: "mem_add",
      args,
    });
    unwrapOk(resp as WormResp, "mem_add");
  }

  async addVectorOnly(
    ns: string,
    docId: string,
    embedding: Uint8Array,
    options: AddOptions = {},
  ): Promise<void> {
    const args: (string | Uint8Array)[] = [ns, docId, embedding];
    if (options.meta !== undefined) {
      args.push(JSON.stringify(options.meta));
    } else if (options.worm !== undefined || options.embedderId !== undefined) {
      args.push("");
    }
    if (options.worm !== undefined) {
      args.push(options.worm ? "1" : "0");
    } else if (options.embedderId !== undefined) {
      args.push("1");
    }
    if (options.embedderId !== undefined) {
      args.push(options.embedderId);
    }
    const resp = await this.wire.sendCommand({
      kind: "EXEC",
      procedure: "mem_add",
      args,
    });
    unwrapOk(resp as WormResp, "mem_add");
  }

  async bulkAdd(ns: string, rows: BulkAddRow[]): Promise<void> {
    const args: (string | Uint8Array)[] = [ns, String(rows.length)];
    for (const row of rows) {
      args.push(row.id, row.embedding, row.meta === undefined ? "" : JSON.stringify(row.meta));
    }
    const resp = await this.wire.sendCommand({
      kind: "EXEC",
      procedure: "mem_bulk_add",
      args,
    });
    unwrapOk(resp as WormResp, "mem_bulk_add");
  }

  async get(ns: string, docId: string): Promise<DocRecord> {
    const resp = await this.wire.sendCommand({
      kind: "EXEC",
      procedure: "mem_get",
      args: [ns, docId],
    });
    return JSON.parse(unwrapValue(resp as WormResp, "mem_get")) as DocRecord;
  }

  async query(
    ns: string,
    embedding: Uint8Array,
    k: number,
    options: QueryOptions = {},
  ): Promise<QueryHit[]> {
    const args: (string | Uint8Array)[] = [ns, embedding, String(k)];
    // Positional: lambda, min_score, snippet_chars, filter — push placeholders
    // only as far as the trailing set requires.
    const lambdaSet = options.lambda !== undefined;
    const minSet = options.minScore !== undefined;
    const snipSet = options.snippetChars !== undefined;
    const filterSet = options.filter !== undefined && options.filter.trim().length > 0;

    if (lambdaSet || minSet || snipSet || filterSet) {
      args.push(options.lambda !== undefined ? String(options.lambda) : "0");
    }
    if (minSet || snipSet || filterSet) {
      // Empty string placeholder → server parseFloat fails → falls back
      // to -inf (no filter). Avoids arguing about JS's `-Infinity` text form.
      args.push(options.minScore !== undefined ? String(options.minScore) : "");
    }
    if (snipSet || filterSet) {
      args.push(options.snippetChars !== undefined ? String(options.snippetChars) : "");
    }
    if (filterSet) {
      const filter = options.filter!.trim();
      args.push(/^filter=/i.test(filter) ? filter : `filter=${filter}`);
    }
    const resp = await this.wire.sendCommand({
      kind: "EXEC",
      procedure: "mem_query",
      args,
    });
    return JSON.parse(unwrapValue(resp as WormResp, "mem_query")) as QueryHit[];
  }

  async stats(ns: string): Promise<NamespaceStats> {
    const resp = await this.wire.sendCommand({
      kind: "EXEC",
      procedure: "mem_stats",
      args: [ns],
    });
    return JSON.parse(unwrapValue(resp as WormResp, "mem_stats")) as NamespaceStats;
  }

  async drop(ns: string): Promise<DropResult> {
    const resp = await this.wire.sendCommand({
      kind: "EXEC",
      procedure: "mem_drop",
      args: [ns],
    });
    return JSON.parse(unwrapValue(resp as WormResp, "mem_drop")) as DropResult;
  }
}

/// Build a keep-alive client connected to a local WormDB instance and
/// wrap it with MemClient. Caller is responsible for `wire.close()`.
export function connect(options: { host?: string; port?: number; timeoutMs?: number } = {}): {
  wire: WormClient;
  mem: MemClient;
} {
  const wire = new WormClient({
    host: options.host ?? "127.0.0.1",
    port: options.port ?? 6389,
    timeoutMs: options.timeoutMs ?? 15_000,
    keepAlive: true,
  });
  return { wire, mem: new MemClient(wire) };
}
