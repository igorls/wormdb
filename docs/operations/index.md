# Operations

This section covers everything you need to run WormDB in practice — from choosing a durability mode to deploying a multi-node cluster, exposing browser/Light-API gateways, maintaining vector indexes, and diagnosing failures.

## Before You Deploy

Make sure you've completed the [Quick Start](/getting-started/quick-start) and are comfortable with basic key-value operations. This section assumes a working binary and familiarity with the `STATUS` command.

## Operator Checklist

After starting any WormDB instance, verify these in order:

**1. Confirm the startup log** — check that the selected backend, persistence mode, and port are what you expect.

**2. Run STATUS** — verify `keys`, `wal_size`, and cluster fields:

```bash
bun run apps/bun/src/bin/client.ts STATUS
```

```
keys=0
wal_size=0
cluster_enabled=0
```

**3. In clusters, check membership** after every node join or change:

```bash
bun run apps/bun/src/bin/client.ts CLUSTER STATUS
bun run apps/bun/src/bin/client.ts CLUSTER PEERS
```

**4. Trigger a snapshot** before planned maintenance:

```bash
bun run apps/bun/src/bin/client.ts SAVE
# → OK
```

**5. For vector-heavy deployments, inspect namespace health**:

```bash
bun run apps/bun/src/bin/client.ts EXEC vstats vec:
```

Run `EXEC vreindex <namespace>` after raw vector ingest, raw/custom vector recovery where metric metadata is unavailable, or suspected HNSW corruption. Memory namespaces are rebuilt from recovered `vec:mem:<ns>:` keys on startup when their config key is present.

## Admin UI

For visual inspection, launch the admin dashboard:

```bash
UI_PORT=8099 WORMDB_PORT=6389 bun run apps/bun/src/bin/ui.ts
```

Then open [http://localhost:8099](http://localhost:8099). The UI shows key counts, WAL size, and cluster state in real time.

## Topics

- [Persistence Modes](/operations/persistence) — WAL, snapshot, and in-memory tradeoffs
- [Clustering](/operations/clustering) — forming a mesh, replication, and verifying health
- [Gateways & Light-API](/operations/gateways) — WebSocket, QUIC/WebTransport, SCT auth, and plain HTTP Light-API routes
- [Troubleshooting](/operations/troubleshooting) — common failures, error messages, and diagnostics
