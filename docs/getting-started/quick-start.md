# Quick Start

This walkthrough uses a local, unauthenticated development server. Use Zig
**0.16.0**, Git, and Bun. Linux is the primary target; Windows supports standalone
use with the threadpool backend.

## 1. Build the Binary

Fetch the in-tree dependencies first. `deps/meshguard` is required for the normal build.

```bash
git clone https://github.com/igorls/wormdb.git
cd wormdb
git submodule update --init deps/meshguard
```

```bash
zig build -Doptimize=ReleaseSmall -Dcrypto-backend=std
zig build test -Dcrypto-backend=std
```

The executable is `zig-out/bin/wormdb` (`wormdb.exe` on Windows). The `std` crypto
backend avoids the external libsodium dependency. The default Linux build uses
shared libsodium; optional QUIC builds have additional dependencies.

## 2. Start the Server

```bash
./zig-out/bin/wormdb --config examples/local.json --port 6389 --data ./data
```

On Windows:

```powershell
.\zig-out\bin\wormdb.exe --config examples/local.json --port 6389 --data .\data
```

::: tip
The example binds TCP to `127.0.0.1`, disables the WebSocket gateway, and explicitly
disables authentication. Use it only on your own machine. The stock executable
takes port, data directory, and persistence mode from CLI arguments. Use `--help`
to check its supported options.
:::

::: warning Remote access
Do not expose this development configuration to an untrusted network. In the
standalone server, `auth.require_auth: true` keeps protected commands locked until
a valid SCT is supplied. Configure verification keys; an empty key list never
disables enforcement. Plain TCP has no TLS. See
[Scoped authentication](/AUTH_SCOPED) before configuring remote access.
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
WORM is enforced by the storage APIs used by these commands. It does not prevent
an operator from modifying data files or compiling custom procedures. Procedure
authors must understand the low-level helpers described in
[Stored Procedures](/architecture/procedures).
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

Procedure durability depends on the helpers used: `ctx.set()`/`setInt()` changes
are not WAL-backed even in `full` persistence mode. See
[Persistence](/operations/persistence) and [Stored Procedures](/architecture/procedures)
before relying on crash recovery.

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
