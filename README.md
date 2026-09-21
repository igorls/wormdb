# WormDB

**Write-once records, compiled logic, and vector search in one engine.**

WormDB is an MIT-licensed key-value store and embeddable engine written in Zig.
Keep selected records immutable, run native procedures next to your data, and
search embeddings in the same store. Run it as a standalone server over the
WormWire binary protocol, or compose the engine into your own Zig application.

[Website](https://wormdb.dev/) · [Quick start](#quick-start) ·
[Documentation](#documentation) · [Contributing](CONTRIBUTING.md) ·
[Meshrooms](https://meshrooms.wormdb.dev/)

WormDB is under active development. Start on localhost and review the
[current boundaries](#current-boundaries) before deploying with important data.

## What you can build

- **Audit histories:** write-once records, with append-log procedures for Merkle
  proofs, signed checkpoints, and witness receipts.
- **Searchable context:** vector indexes and memory procedures alongside the keys
  and metadata your application already stores.
- **Application services:** compiled handlers for operations on keys, with
  pub/sub events and optional peer replication on Linux.

| Capability | How it works |
| --- | --- |
| Write-once storage | The WORM flag makes normal `SET` and `DEL` reject later changes to a key. Mutable keys are also supported. |
| Persistence | An in-memory, 256-shard store backed by a write-ahead log and snapshots. |
| Stored procedures | `EXEC` calls native Zig handlers with access to the store, events, and cluster. Each handler chooses its locking and durability behavior. |
| Vector search | Per-namespace HNSW, binary quantization, RaBitQ, and exact search, with cosine, dot product, and L2 metrics. |
| Pub/sub | Prefix-matched channels deliver events over existing client connections. |
| Linux clustering | MeshGuard peer discovery, best-effort replication, and synchronization for joining peers. |
| Clients | Bun/TypeScript over TCP; a browser client over WebSocket or optional WebTransport. |

## Quick start

You need **Git**, **Zig 0.16.0**, and **Bun** for the client examples. Linux and
Windows builds are checked in [CI](https://github.com/igorls/wormdb/actions/workflows/ci.yml).
Windows supports single-node operation; clustering is Linux-only.

### 1. Build and start the server

```sh
git clone https://github.com/igorls/wormdb.git
cd wormdb
git submodule update --init deps/meshguard
zig build -Doptimize=ReleaseSmall -Dcrypto-backend=std
./zig-out/bin/wormdb --config examples/local.json
```

This builds the normal server with Zig's `std.crypto` backend, without an external
libsodium dependency. It fetches only MeshGuard; optional QUIC dependencies are
not needed. See [Windows setup](docs/WINDOWS.md) for platform-specific details.

The [local configuration](examples/local.json) listens on **127.0.0.1:6389** and
stores data in `./data`. Authentication and the browser gateway are disabled in
this example. Keep it on your own machine.

### 2. Write and read an immutable record

In another terminal, from the repository root:

```sh
bun run apps/bun/src/bin/client.ts SET audit:001 ready --worm
bun run apps/bun/src/bin/client.ts GET audit:001
```

The commands return `OK` and `ready`. Try changing or deleting the record:

```sh
bun run apps/bun/src/bin/client.ts SET audit:001 changed
bun run apps/bun/src/bin/client.ts DEL audit:001
```

Both commands return `ERR: WORM violation: key is immutable` and exit with a
nonzero status. Use a fresh key if you repeat this example. For a mutable key,
omit `--worm` when first creating it.

```sh
bun run apps/bun/src/bin/client.ts STATUS
```

WormWire is a binary protocol. Redis clients, `telnet`, and text `PING` requests
are not compatible. Use the supplied client or implement the
[WormWire protocol](docs/protocol/index.md).

### 3. Use the Bun client in code

Save this as `example.ts` in the repository root and run `bun run example.ts`:

```ts
import { WormDB } from "./apps/bun/src/lib/wormdb";

const db = new WormDB({ host: "127.0.0.1", port: 6389 });
try {
  await db.set("example:greeting", "hello");
  console.log(await db.get("example:greeting"));
} finally {
  await db.close();
}
```

The client also exposes byte values, subscriptions, stored procedures, and vector
operations. See the [Bun client](apps/bun) and [client guide](docs/getting-started/clients.md).
The [browser client](apps/browser) uses a separately configured gateway.

## Stored procedures

One `EXEC` request invokes a compiled Zig function. Built-in families cover key
operations, counters, append logs, audit proofs, vector search, agent memory,
coordination, and trust. See the [procedure registry](src/procedures/registry.zig)
for the current list.

Handlers use an explicit context for locking, store access, and responses. Some
helpers update memory without appending to the WAL; durable helpers release and
reacquire held locks around writes. `EXEC` does not provide a general multi-key
transaction or rollback guarantee. See the [procedure guide](docs/architecture/procedures.md)
before adding a handler.

## Vector search

Vectors are stored as ordinary `vec:<namespace>:<id>` keys. A per-namespace HNSW
graph and quantized companions are derived serving structures. Queries select an
available index or exact search; native vector inserts and the Bun vector wrapper
default to WORM.

`vsearch` queries the local node. `vsearch_cluster` is a separate fan-out procedure.
Snapshot v2 persists index state, but WAL replay after the snapshot does not replay
every index mutation. Run `EXEC vreindex <namespace>` after raw ingestion or
recovery beyond the last snapshot.

See [vector search](docs/VECTOR_SEARCH.md) and the
[agent memory example](docs/AGENT_MEMORY_DEMO.md) for the APIs and index lifecycle.

## Clustering

On Linux, [MeshGuard](https://github.com/igorls/meshguard) provides SWIM discovery,
failure detection, identity, and WireGuard integration. WormDB replicates writes
after committing locally: peer failures do not turn a successful local write into an error.
Joining peers receive a full-state synchronization.

Configure `org_trust.grants` and `org_trust.node_cert_path` for replication
authorization. A cluster without trust enforcement requires an explicit
`--cluster-open`, intended for isolated tests. Replication uses TCP, and connections
to real peer addresses are not inherently encrypted. Verify the actual route and
provide transport protection. See [replication trust](docs/architecture/replication-proofs.md).

## Current boundaries

- **Network access:** raw WormWire TCP has no TLS. Authentication requires
  `auth.require_auth` and valid verification keys; an empty key list leaves
  listeners unauthenticated. Configure and test both authorization and transport.
- **Immutability:** WORM is an engine property. It does not prevent an administrator
  from replacing data files or code; procedure authors must use helpers that
  enforce the guarantees they need.
- **Durability:** WAL and snapshot behavior depends on persistence settings and the
  write path. Procedure writes and derived indexes have the recovery behavior
  described above.
- **Replication:** local commits are authoritative. There are no quorum
  acknowledgements or cross-node transaction guarantees.
- **Distribution:** the quick start builds from source. Binary size and dynamic
  dependencies vary with platform and build options. Docker and optional QUIC
  builds need their own validation.

See [SECURITY.md](SECURITY.md) for deployment boundaries and private vulnerability
reporting, and [persistence](docs/operations/persistence.md) for storage operations.

## Documentation

| Start here | Reference |
| --- | --- |
| Build and connect | [Quick-start guide](docs/getting-started/quick-start.md), [Windows](docs/WINDOWS.md), [clients](docs/getting-started/clients.md) |
| Protocol | [WormWire framing](docs/protocol/index.md), [commands](docs/protocol/commands.md), [status fields](docs/reference/status-fields.md) |
| Storage and proofs | [WORM semantics](docs/architecture/worm-semantics.md), [append logs](docs/protocol/append-log.md), [proofs](docs/protocol/proofs.md) |
| Extend the engine | [Procedures](docs/architecture/procedures.md), [composition root](src/main.zig), [library root](src/lib.zig), [FFI](ffi) |
| Search and memory | [Vector search](docs/VECTOR_SEARCH.md), [agent memory example](docs/AGENT_MEMORY_DEMO.md) |
| Operate | [Persistence](docs/operations/persistence.md), [authentication](docs/AUTH_SCOPED.md), [replication trust](docs/architecture/replication-proofs.md) |

## Development

From the repository root:

```sh
zig build test -Dcrypto-backend=std
bun install --frozen-lockfile
bun run docs:build
```

For the Bun client tests:

```sh
cd apps/bun
bun install --frozen-lockfile
bun test
```

The default Linux build uses libsodium; `-Dcrypto-backend=std` selects Zig's built-in
backend. The server is Zig; the Bun code is clients and tooling.

To measure vector operations on your hardware, run the
[microbenchmark](src/vector/bench.zig):

```sh
zig run src/vector/bench.zig -O ReleaseFast -lc
```

Record the commit, build flags, hardware, dataset, and query settings alongside
results. A microbenchmark does not establish end-to-end server throughput.

## Contributing

Bug reports, focused proposals, documentation improvements, and patches are
welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md), then use
[GitHub issues](https://github.com/igorls/wormdb/issues) or open a pull request.
Report vulnerabilities through [GitHub private reporting](https://github.com/igorls/wormdb/security/advisories/new).

## License

[MIT](LICENSE) for the first-party engine, clients, and tooling.
See [third-party notices](THIRD_PARTY_NOTICES.md) for dependency licenses.
