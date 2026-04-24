# In-Database Procedures for Vector Search — Where WormDB Fits

> Short answer to "does anyone else do this": **yes, several.** The interesting question
> isn't *whether* you can run procedures next to vectors — it's *how much overhead sits
> between your procedure code and the vector bytes* when you do.

This document catalogs what the field actually offers today, then makes the specific
case for WormDB's compiled-Zig approach. It's meant to be honest, not promotional —
the competitive landscape is real, and the differentiation worth claiming is narrower
and sharper than "nobody else does this."

---

## 1. The landscape — who offers in-db procedures alongside vector search

| System                   | Vector search      | Server-side procedures            | Procedure language(s)                    | Deployment shape                |
| ------------------------ | ------------------ | --------------------------------- | ---------------------------------------- | ------------------------------- |
| **WormDB**               | HNSW + BQ + exact  | Native, compiled in               | Zig                                      | Single 45 KB static binary      |
| **PostgreSQL + pgvector**| HNSW, IVFFlat      | Full stored procedures            | PL/pgSQL, PL/Python, PL/Rust, PL/v8      | Server + extension              |
| **Redis + RediSearch**   | HNSW, flat         | Lua scripts, Redis Functions      | Lua                                      | Server + modules                |
| **Oracle 23ai**          | HNSW, IVF          | Full stored procedures            | PL/SQL, Java                             | Server                          |
| **SingleStore**          | HNSW, IVF_PQ       | Stored procedures                 | SQL, PSQL, JS-via-WASM                   | Distributed server              |
| **SurrealDB**            | HNSW, MTree        | Functions                         | SurrealQL, JS (QuickJS)                  | Server                          |
| **Elasticsearch / OpenSearch** | HNSW         | Inline / stored scripts           | Painless (JVM)                           | Server cluster                  |
| **ClickHouse**           | Approximate NN     | SQL UDFs, executable UDFs         | SQL, Python/shell (out-of-proc)          | Distributed server              |
| **MongoDB Atlas**        | `$vectorSearch`    | Aggregation pipelines + triggers  | MongoQL, JS (Atlas Functions, external)  | Managed / server                |
| **TiDB / CockroachDB**   | pgvector-compat    | SQL UDFs                          | SQL                                      | Distributed server              |
| **Qdrant, Weaviate, Milvus, Chroma, LanceDB, Pinecone** | HNSW / disk-ANN | *None* — API only | — | Server / SaaS / embedded |

So the short list of systems where you can genuinely write "a procedure that
queries vectors and decides what to do next, inside the database process":

> **pgvector, Redis, Oracle 23ai, SingleStore, SurrealDB, Elasticsearch, ClickHouse, WormDB.**

If you've been told vector databases are scripting-free, that's half true: it
describes the purpose-built ones (Qdrant, Pinecone, Milvus, Chroma, Weaviate,
LanceDB), not the general-purpose databases that have bolted vector search on.
The most credible alternative to WormDB's approach is **pgvector** — and it is
a very credible alternative.

---

## 2. The real axis of differentiation — compiled vs. interpreted

Every system in column 3 above executes procedure code as either:

- **Interpreted script** — PL/pgSQL, PL/Python, Lua, Painless, SurrealQL, JS.
  Every call pays interpreter or dispatcher overhead. Values cross a boundary
  (SPI in Postgres, the script environment in Redis, the script context in
  Elasticsearch) to reach the storage layer.

- **JIT-compiled managed code** — Painless JIT, V8/QuickJS, PL/v8.
  Lower per-call cost than pure interpretation, but still a managed runtime
  with GC pauses and JIT warm-up.

- **Compiled extension** — PL/Rust in Postgres, a custom Redis module, a
  Postgres C extension. These match native performance but are the *exception*,
  not the path used by 95 % of stored-procedure authors on that platform.

- **Native, compiled-in** — WormDB. Procedures are Zig functions linked into
  the server binary. They call `distance.cosine()` and HNSW traversal as
  ordinary function calls in the same call frame. No boundary to cross.

### What the boundary actually costs

Concretely, a `vsearch` call inside WormDB:

```
vsearch.execute(ctx)
  └─ distance.cosine(query_bytes, candidate_bytes)   ← direct Zig call
      └─ @Vector(8, f32) SIMD reductions             ← inlined, no call overhead
```

The same pattern in pgvector calling from PL/pgSQL:

```
CREATE FUNCTION my_search(q vector) ... AS $$
  SELECT id FROM items ORDER BY embedding <-> q LIMIT 10;
$$;
```

runs the PL/pgSQL interpreter, which issues an SPI call into the executor,
which runs the index scan, which calls pgvector's distance kernel. Every
layer is in-process, but every layer has a cost — parameter marshaling,
memory-context switches, tuple-slot construction. For a procedure that
*only* runs a search this overhead is tiny compared to the search itself.
It starts to matter when a procedure does many small operations around the
vector call: enrich metadata, apply business rules, chain a second
similarity pass, decide what to return.

Redis Lua is similar: a `FT.SEARCH` inside `redis.call()` crosses from the
Lua VM back into the server. It's fast, but it's still an interpretive hop
per operation.

The unique WormDB claim is therefore narrower than "only we let you do
this": it is **"the procedure body, the SIMD distance kernel, and the
on-disk byte layout are all in the same compiled artifact, with zero
indirection between them."**

---

## 3. What that buys you in practice

The four advantages below assume you've already decided an in-process
procedure approach beats round-tripping to an application server. (If you
haven't — see §6.) The question here is: given you want procedures,
*why compiled-in ones?*

### 3.1 Zero marshaling for vector bytes

Vectors are the one workload where marshaling cost shows up. A 1536-dim
embedding is 6,144 bytes. If a stored procedure has to copy those bytes
across a boundary — from storage into the script engine's string type,
or convert them to an array of doubles for PL/pgSQL, or serialize them
to a Lua table — that copy runs on every invocation.

In WormDB, `ctx.get(key)` returns a `[]const u8` slice that points
directly into the store's memory. `distance.cosine` reads those same
bytes as a `[]f32` via a reinterpret cast. No copy, no conversion.

### 3.2 SIMD inlined into the procedure call frame

Because the distance kernel is a normal Zig function in the same binary,
the compiler can inline it into the procedure, schedule the SIMD loads,
and pipeline the loop without any function-call discipline getting in
the way. Interpreted languages can't express SIMD; JIT'd ones need the
JIT to prove the inline is safe; extension languages (PL/Rust,
PL/Python NumPy) can do it but require you to leave the mainstream
procedure path.

### 3.3 Atomic multi-step vector operations

`vinsert` is a single procedure that (a) writes the raw `vec:` entry,
(b) computes and writes the `bq:` hash, (c) stores the `ts:` timestamp,
and (d) bumps the `vec:ns:stats:count`. All under one shard-lock
acquisition, committed together, replicated together.

Doing the same in pgvector requires either a single INSERT with a
trigger (doable, but the trigger is interpreted) or a PL/pgSQL function
that does multiple INSERTs inside a transaction (still fine, but
interpreted). In Qdrant/Pinecone the equivalent is several HTTP calls
— atomicity is the application's problem.

### 3.4 Composition without leaving the process

A hybrid rerank procedure that wants to run vector search, fetch full
text for each candidate, run a cheap scoring function, and return a
filtered top-K is a single Zig function that calls existing primitives.
Nothing leaves the process, nothing deserializes to a managed runtime,
nothing context-switches.

```zig
// Sketch of a rerank procedure
pub fn execute(ctx: *Ctx) !Ctx.Result {
    const candidates = try vsearch_internal(ctx, top_k * 3);
    const reranked = try rerank_with_bm25(ctx, candidates);
    return ctx.value(encode_json(reranked));
}
```

Each of those helpers is native code, calling into the store with
direct byte slices.

---

## 4. The other thing WormDB actually has uniquely — WORM vectors

Separate from the procedures question, there's one vector-search
property that is genuinely not available elsewhere: **WORM-immutable
vectors as a grow-only set (G-Set CRDT).**

Vectors are written once, never mutated. This collapses the hardest
problem in distributed vector search — conflict resolution on updates
— into triviality. Replication is append-only, anti-entropy is a
Merkle tree of key hashes, and the global index is a union of local
insert logs.

pgvector, Redis, Milvus, Qdrant, Weaviate all let you `UPDATE` or
replace vectors in place. That flexibility is useful, but it means
multi-node setups need vector clocks, CAS semantics, or a leader. Most
RAG / agent-memory workloads don't actually need mutability; they need
provenance and auditability, which is exactly what WORM provides.

This is orthogonal to "compiled procedures" but strongly *compounds*
with it: a procedure that appends a new embedding never has to reason
about concurrent writers to the same key, because by construction there
aren't any.

---

## 5. Honest tradeoffs

Leaving these out would make the document read like marketing. All of
these are real and deserve weight.

| Tradeoff                                          | WormDB                                      | PostgreSQL + pgvector                     | Redis + RediSearch                        |
| ------------------------------------------------- | ------------------------------------------- | ----------------------------------------- | ----------------------------------------- |
| Add a new procedure without restarting the server | **No** — requires rebuild & restart         | Yes — `CREATE FUNCTION` at runtime        | Yes — `FUNCTION LOAD` at runtime          |
| Procedure author ecosystem                        | Very small (Zig + WormDB internals)         | Enormous (PL/pgSQL is a lingua franca)    | Large (Lua is widely known)               |
| Ad-hoc / dynamic query composition in procedures  | Limited — you compose from primitives       | Rich — full SQL is available              | Limited — `redis.call()` primitives       |
| Hot-reload scripts for iteration                  | No                                          | Yes                                       | Yes                                       |
| Sandboxing of untrusted procedures                | None — procedures are first-party code      | Partial (PL/pgSQL is sandboxed; C is not) | Lua is sandboxed                          |
| Debugging tools                                   | Standard native debuggers (LLDB, GDB)       | Mature (pg_debug, logging, EXPLAIN)       | Limited (Lua traces, MONITOR)             |
| Dependency footprint                              | Zero                                        | Postgres + extension                      | Redis + modules                           |

The headline: **WormDB's model optimizes for shipping a known set of
procedures as part of the database binary.** It is not optimized for
letting untrusted tenants upload scripts, or for rapid iteration on
procedure logic in production. If your model for procedures is
"ops writes one during an incident response at 3 a.m. and deploys it
without a build step," pgvector or Redis is a better fit.

If your model is "the set of procedures is a deliberate part of the
product, designed, tested, and shipped with the binary" — the WormDB
approach removes a stack of overhead that the others can't.

---

## 6. When you probably don't need this at all

Stored procedures of any flavor are a specific choice. You should use
them when:

- The logic runs hot enough that a round-trip to an application server
  dominates latency.
- Atomicity across multiple operations matters and you can't easily get
  it another way.
- Bandwidth matters — e.g., candidates from vector search would be
  large to ship back to an application just to re-rank and discard.

You should *not* use them when:

- Business logic changes frequently and needs to ship independently of
  the data layer.
- Debuggability and observability in the application tier matters more
  than raw latency.
- Your team doesn't already have comfort with the procedure language.

Most RAG and agent-memory workloads hit the first bullet list cleanly
— which is why procedure support is a genuine differentiator in the
vector space, even though the absolute latency wins per call are not
dramatic.

---

## 7. Per-competitor notes (condensed)

**pgvector** — Closest competitor. PL/pgSQL is interpreted; PL/Rust
approaches WormDB's performance profile but has a small community.
SQL-native ergonomics are a real advantage for anyone already on
Postgres. Distribution is a problem pgvector doesn't solve — Citus /
Neon / CockroachDB pgvector-compat all have rough edges.

**Redis + RediSearch** — Lua is fast *as interpreters go*. The module
boundary between Lua and RediSearch is real but cheap. Main weakness
vs. WormDB: in-memory only, no WORM, and no native clustering of
vector search results (RediSearch cluster queries have sharp edges
around ANN recall).

**Oracle 23ai** — Genuinely full-featured; PL/SQL is mature. The
commercial and operational weight is the tradeoff.

**SingleStore** — Strong SQL + vector story; stored procs are
procedural SQL. Distributed execution is real. Heavier operational
footprint.

**SurrealDB** — The spiritual sibling: single binary, multi-model,
has vector search, has functions. Functions are SurrealQL or JS via
QuickJS — both interpreted. WormDB's compiled-in advantage is
sharpest vs. SurrealDB specifically, because the deployment shape is
closest.

**Elasticsearch / OpenSearch** — Painless is JVM-JIT'd, so per-call
cost is low, but the JVM itself is a deployment heavyweight. kNN
scripts exist and work.

**ClickHouse** — SQL UDFs for in-process logic; executable UDFs for
out-of-process. Vector support is genuine but the approximate-NN
story is less mature than purpose-built options.

**MongoDB Atlas** — Aggregation pipelines are powerful but limited.
Atlas Functions are *not* in-process — they run in a separate
serverless runtime and call back into MongoDB.

**Qdrant, Weaviate, Milvus, Chroma, LanceDB, Pinecone** — No
server-side procedure story. Weaviate's "modules" run at ingest time
(e.g., vectorizer modules) but are not a general procedure engine. If
you need server-side logic, you wrap these with an application layer.

---

## 8. The one-paragraph version

Many general-purpose databases let you run procedures next to vector
search: pgvector, Redis, Oracle, SingleStore, SurrealDB, Elasticsearch,
ClickHouse. What WormDB uniquely does is compile the procedures, the
SIMD distance kernels, and the storage access path into a single
native binary with no marshaling, no interpreter, and no extension
boundary between them — and layer that on top of WORM-immutable
vectors that behave as a CRDT under replication. The tradeoff is that
procedures are first-party code shipped with the server, not runtime
scripts. For workloads where the set of procedures is deliberate and
the vector path is hot, that tradeoff is favorable; for workloads
where procedures are ad-hoc and need to ship independently of the
database, pgvector is the more pragmatic choice.
