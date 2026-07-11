# Quick Start

This walkthrough gets a local WormDB instance running and verified in under five minutes.

## 1. Build the Binary

Fetch the in-tree dependencies first. `deps/meshguard` is required for the normal build.

```bash
git submodule update --init --recursive
```

```bash
zig build -Doptimize=ReleaseSmall
```

This produces a statically linked binary at `./zig-out/bin/wormdb`.

## 2. Start the Server

```bash
./zig-out/bin/wormdb --port 6389 --data ./data
```

You should see startup output confirming the server is listening:

```
[wormdb] listening on 0.0.0.0:6389 (threadpool)
[wormdb] persistence: full
[wormdb] data path: ./data
```

::: tip
The default backend is `threadpool` and the default persistence mode is `full` (WAL-backed). Both are safe defaults for getting started. See [Server Backends](/architecture/server-backends) and [Persistence](/operations/persistence) when you're ready to tune.
:::

## 3. Write and Read a Key

Open a second terminal and use the Bun reference client:

```bash
bun run apps/bun/src/bin/client.ts SET hello "world"
# → OK

bun run apps/bun/src/bin/client.ts GET hello
# → world
```

## 4. Try WORM Immutability

WORM (Write Once, Read Many) is the defining capability. Set a key with the WORM flag:

```bash
bun run apps/bun/src/bin/client.ts SET audit "entry-001" --worm
# → OK
```

Now try to overwrite it:

```bash
bun run apps/bun/src/bin/client.ts SET audit "tampered-value"
# → ERR: WORM violation: key is immutable
```

The key is permanently sealed. Deleting it also fails:

```bash
bun run apps/bun/src/bin/client.ts DEL audit
# → ERR: WORM violation: key is immutable
```

::: warning
WORM is irreversible. Once a key is written with the WORM flag, there is no administrative override — the immutability guarantee is enforced at the storage layer. Choose WORM keys deliberately.
:::

## 5. Check Server Status

```bash
bun run apps/bun/src/bin/client.ts STATUS
```

```
keys=2
wal_size=128
cluster_enabled=0
```

The output is `key=value` text, one field per line, designed for easy parsing in scripts and monitoring tools.

## 6. Run a Stored Procedure

WormDB ships with built-in procedures. Try the atomic increment:

```bash
bun run apps/bun/src/bin/client.ts EXEC increment counter
# → 1

bun run apps/bun/src/bin/client.ts EXEC increment counter 5
# → 6
```

See [Stored Procedures](/architecture/procedures) for the full procedure model.

## 7. Check Recent Procedure Families

WormDB also ships procedure surfaces for vector search and agent memory:

```bash
bun run apps/bun/src/bin/client.ts EXEC vstats vec:
bun run apps/bun/src/bin/client.ts EXEC mem_capabilities
```

See [Vector Search](/architecture/vector-search) and [Agent Memory](/architecture/agent-memory) for the current command surface.

## 8. Start the Admin UI (Optional)

```bash
UI_PORT=8099 WORMDB_PORT=6389 bun run apps/bun/src/bin/ui.ts
```

Open [http://localhost:8099](http://localhost:8099) for a visual dashboard showing key counts, WAL size, and cluster state.

## Next Steps

- **Use the client in detail** → [Clients & Commands](/getting-started/clients)
- **Understand the internals** → [Architecture](/architecture/)
- **Deploy with persistence and clustering** → [Operations](/operations/)
- **Expose browser and HTTP routes** → [Gateways](/operations/gateways)
