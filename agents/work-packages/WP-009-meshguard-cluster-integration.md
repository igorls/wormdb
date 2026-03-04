# WP-009: MeshGuard Cluster Integration

- ID: A-009
- Priority: P0
- Status: Implemented
- Owner: Execution Agent
- Vision: A distributed KV store that is a **dream to operate** — zero-config scaling, encrypted by default, no coordination servers
- Reviewer: PM
- Depends: WP-008 (binary protocol — implemented)

## Architecture: Two-Layer Separation

**Control plane** (meshguard daemon, UDP): SWIM gossip, peer discovery, WireGuard tunnel setup, org trust

**Data plane** (WormDB, TCP over WG tunnel): Replication using WormWire protocol — the same binary framing from WP-008

### Data Flow

```
Node A (client SET key=val)
  ├── 1. Local store.set()
  ├── 2. cluster.replicateWrite()
  │     └── 3. For each alive peer (from meshguard):
  │           TCP connect to peer's mesh IP:6389
  │           Send: 0x57 0x52 (WR magic) + WormWire SET frame
  │                 └── Encrypted at WireGuard tunnel level
  │
Node B (receives WormWire replication)
  ├── 4. handleReplicationConnection()
  │     └── 5. wire.readFrameAlloc() → SET command
  │           └── 6. store.set(key, val, worm)
  │                 └── NO re-replication (anti-echo)
```

### Why WireGuard Tunnels, Not App Messages

| Aspect          | App Messages (0x50) | WG Tunnel + WormWire                        |
| --------------- | ------------------- | ------------------------------------------- |
| Max payload     | 1024 bytes          | 16 MiB                                      |
| Transport       | UDP (unreliable)    | TCP (reliable, ordered)                     |
| Crypto overhead | Per-message         | Per-tunnel (amortized)                      |
| Code reuse      | Custom codec        | `wire.writeCommand()` — already implemented |

## Changes Made

### meshguard (new feature)

| File                       | Description                                                         |
| -------------------------- | ------------------------------------------------------------------- |
| `src/services/control.zig` | **New.** Unix domain socket server: `PEERS` → JSON, `STATUS` → JSON |
| `src/lib.zig`              | Export `services.Control`                                           |
| `src/main.zig`             | Wire control socket into daemon lifecycle + event loop              |

### WormDB

| File                    | Description                                                               |
| ----------------------- | ------------------------------------------------------------------------- |
| `src/cluster/node.zig`  | **Rewritten.** Discovery thread, WormWire TCP replication, peer lifecycle |
| `src/cluster/mod.zig`   | Updated exports                                                           |
| `src/protocol/wire.zig` | Added `REPL_MAGIC = 0x57 0x52`                                            |
| `src/server/tcp.zig`    | Added `handleReplicationConnection()` (anti-echo)                         |
| `src/main.zig`          | `--control-socket` flag, `ClusterConfig`, start/stop lifecycle            |

## Peer Discovery

WormDB's cluster module discovers peers by connecting to meshguard's Unix control socket:

```
WormDB ──[Unix socket]──> meshguard daemon
         "PEERS\n"
         <── [{"pubkey":"...","mesh_ip":"10.99.1.2","state":"alive"}, ...]
```

### Anti-Echo

Replication connections use magic `0x57 0x52` ("WR") instead of `0x57 0x57` ("WW"). The server's `handleReplicationConnection()` applies SET/DEL directly to the store without calling `cluster.replicateWrite/Delete`, preventing infinite replication loops.

## Scaling (Org Trust)

meshguard's org trust is already fully implemented in the daemon CLI:

```bash
meshguard org-keygen                          # Create org keypair
meshguard org-sign <node.pub> --name node-4   # Sign node certificate
meshguard trust <org.pub> --org               # Trust the org on seeds
# New node starts with cert → auto-joins mesh → WormDB discovers via socket → replicates
```

## Verification

- `zig build` — success (both projects)
- `zig build test` — all tests pass (both projects)
- New tests: IPv4 parsing, JSON peer discovery/removal, cluster status reporting
