# WormDB

A fast, distributed key-value store built in Zig. Encrypted replication, zero-config scaling, single static binary.

- **WORM mode** — Write-Once-Read-Many for immutable audit trails
- **WormWire protocol** — Binary framing over TCP, zero-copy capable
- **Pub/Sub streaming** — Real-time event channels with subscription management
- **Encrypted clustering** — P2P replication via meshguard (SWIM gossip + ChaCha20-Poly1305)
- **Org trust** — Mint certificates, add nodes with one command, revoke instantly

## Quick Start

```bash
# Build (requires Zig 0.15+, libsodium)
zig build -Doptimize=ReleaseSmall

# Run tests
zig build test

# Start server
./zig-out/bin/wormdb --port 6389 --data ./data
```

### Connect with the Bun Client

```bash
# Basic operations
bun run apps/bun/src/bin/client.ts SET mykey "hello world"
bun run apps/bun/src/bin/client.ts GET mykey
bun run apps/bun/src/bin/client.ts SET audit-log entry-001 WORM
bun run apps/bun/src/bin/client.ts STATUS

# Admin UI (http://localhost:8099)
UI_PORT=8099 WORMDB_PORT=6389 bun run apps/bun/src/bin/ui.ts
```

> **Note:** WormDB uses the WormWire binary protocol. Raw `nc`/`telnet` connections are not supported. Use the Bun client or any WormWire-compatible client.

## WormWire Protocol

All client connections use the **WormWire** binary framing protocol. Connections must begin with the magic bytes `0x57 0x57` ("WW"). The server rejects connections without the magic handshake.

### Frame Structure

```
Connection:  [ 0x57 0x57 ]                                        (once, on connect)
Request:     [ 1B Command ID ] [ 4B Payload Length (BE) ] [ payload... ]
Response:    [ 1B Response Code ] [ 4B Payload Length (BE) ] [ payload... ]
```

### Commands

| ID     | Command        | Payload                                              |
| ------ | -------------- | ---------------------------------------------------- |
| `0x01` | GET            | `[4B key_len] [key]`                                 |
| `0x02` | SET            | `[1B flags] [4B key_len] [key] [4B val_len] [value]` |
| `0x03` | DEL            | `[4B key_len] [key]`                                 |
| `0x04` | STATUS         | _(empty)_                                            |
| `0x05` | CLUSTER STATUS | _(empty)_                                            |
| `0x06` | SUB            | `[4B channel_len] [channel]`                         |
| `0x07` | UNSUB          | `[4B channel_len] [channel]`                         |
| `0x08` | PUB            | `[4B channel_len] [channel] [4B msg_len] [message]`  |

### Response Codes

| Code   | Meaning | Payload                                 |
| ------ | ------- | --------------------------------------- |
| `0x00` | OK      | _(empty)_                               |
| `0x01` | VALUE   | Data (GET result or STATUS diagnostics) |
| `0x02` | NULL    | _(empty — key not found)_               |
| `0x03` | ERR     | UTF-8 error string                      |
| `0x04` | EVENT   | Unsolicited pub/sub push                |

All multi-byte integers use **big endian** (network byte order). Maximum payload: **16 MiB**.

## Clustering

WormDB clusters use [meshguard](https://github.com/igorls/meshguard) for peer discovery (SWIM gossip), failure detection, and encrypted replication. No central coordinator required.

### Standalone

```bash
wormdb --port 6389 --data ./data
```

### Multi-Node Cluster

```bash
# Seed node
wormdb --port 6389 --data ./data1 --cluster myapp --gossip-port 51821

# Join nodes
wormdb --port 6390 --data ./data2 --cluster myapp --seed 10.0.0.1:51821
wormdb --port 6391 --data ./data3 --cluster myapp --seed 10.0.0.1:51821
```

### Org Trust (Zero-Config Scaling)

For production clusters, use org certificates for secure, effortless node management:

```bash
# One-time: create org keypair
wormdb keygen-org
# → cluster-org.key (secret)  +  cluster-org.pub (share with seeds)

# Start seed with org trust enforcement
wormdb --port 6389 --data ./data1 --cluster myapp \
    --gossip-port 51821 --org-trust cluster-org.pub

# Mint certificate for a new node
wormdb cert-sign --org-key cluster-org.key \
    --node-pub ./data2/identity.pub --name node-2

# Start new node — auto-joins, auto-replicates
wormdb --port 6390 --data ./data2 --cluster myapp \
    --seed 10.0.0.1:51821 --cert node-2.cert

# Revoke a node (instant cluster-wide eviction)
wormdb cert-revoke --org-key cluster-org.key --node-pub <pubkey>
```

### Docker Compose

```yaml
services:
  node1:
    image: wormdb:latest
    ports:
      - "16379:6389"
      - "51821:51821/udp"
    command: --cluster wormdb-cluster --gossip-port 51821

  node2:
    image: wormdb:latest
    ports:
      - "16380:6389"
      - "51822:51822/udp"
    command: --cluster wormdb-cluster --seed node1:51821 --gossip-port 51822
    depends_on:
      - node1
```

```bash
docker build -t wormdb:latest .
docker compose up -d
```

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                          WormDB                              │
├──────────────┬──────────────┬────────────┬───────────────────┤
│ TCP Server   │ Protocol     │ Store      │ EventBus          │
│ (thread/conn)│ (WormWire v1)│ (Map+WAL)  │ (pub/sub)         │
├──────────────┴──────────────┴────────────┴───────────────────┤
│                      Cluster Layer                           │
│  ┌───────────┐  ┌──────────────┐  ┌────────────────────┐    │
│  │ meshguard │  │ SWIM Gossip  │  │ Encrypted           │    │
│  │ (Ed25519) │  │ (discovery)  │  │ Replication (E2E)   │    │
│  └───────────┘  └──────────────┘  └────────────────────┘    │
└──────────────────────────────────────────────────────────────┘
```

### Components

| Component    | File                    | Description                               |
| ------------ | ----------------------- | ----------------------------------------- |
| **Types**    | `src/core/types.zig`    | Entry, Command, Response, CommandId       |
| **Config**   | `src/core/config.zig`   | Store, Server, and Cluster configuration  |
| **WAL**      | `src/storage/wal.zig`   | Write-Ahead Log with CRC32 integrity      |
| **Store**    | `src/storage/store.zig` | In-memory HashMap + WAL persistence       |
| **Wire**     | `src/protocol/wire.zig` | WormWire binary codec (read/write frames) |
| **EventBus** | `src/event/bus.zig`     | Pub/sub channel management                |
| **Server**   | `src/server/tcp.zig`    | TCP server (thread-per-connection)        |
| **Cluster**  | `src/cluster/node.zig`  | meshguard SWIM + encrypted replication    |

### WAL Format

```
┌──────────────────────────────────────────────────────────────┐
│ Record Header (13 bytes)                                     │
├──────────┬──────────┬────────────────────────────────────────┤
│ CRC32    │ Type     │ Length (u64)                           │
│ (4 bytes)│ (1 byte) │ (8 bytes)                              │
└──────────┴──────────┴────────────────────────────────────────┘
Payload:
  SET: [key_len:2][value_len:4][flags:1][timestamp:8][key][value]
  DEL: [key_len:2][key]
```

## Port Policy

| Port      | Purpose                       | Protocol |
| --------- | ----------------------------- | -------- |
| **6389**  | Client connections (WormWire) | TCP      |
| **51821** | Cluster gossip (SWIM)         | UDP      |

Default client port is `6389` (avoids Redis `6379` collision). Override with `--port`. Gossip port defaults to `51821` (WireGuard convention). Override with `--gossip-port`.

## Performance

- **Binary size**: 45KB (ReleaseSmall)
- **Docker image**: 37MB (Debian slim)
- **Read latency**: O(1) in-memory lookup
- **Write latency**: Disk fsync + memory update

## Development Status

### ✅ Implemented

- [x] Core KV store with HashMap
- [x] WAL persistence with CRC32
- [x] WORM mode enforcement
- [x] TCP server (thread-per-connection)
- [x] WormWire binary protocol (v1)
- [x] Pub/Sub event bus
- [x] Bun reference client + admin UI
- [x] Replication hooks in write path
- [x] Docker containerization

### 🚧 In Progress

- [ ] meshguard cluster integration (WP-009)
  - SWIM peer discovery & failure detection
  - Encrypted data replication (ChaCha20-Poly1305)
  - Org trust certificates for zero-config scaling
  - Identity persistence across restarts

### 📋 Planned

- [ ] Snapshot/compaction
- [ ] Merkle-tree consistency checks
- [ ] Pipeline + EVENT interleave integration tests
- [ ] Web dashboard
- [ ] Backup/restore

## Testing

```bash
# Unit tests (31 tests)
zig build test

# Local cluster test
./test-local.sh

# Docker cluster test
docker compose up -d
docker compose -f docker-compose.bench.yml run --rm benchmark
```

## Dependencies

- **Zig 0.15+** — Language and build system
- **libsodium** — Crypto primitives (ChaCha20-Poly1305, Ed25519)
- **meshguard** — P2P mesh networking (SWIM gossip, encrypted messaging)

## Troubleshooting

| Problem                       | Solution                                                         |
| ----------------------------- | ---------------------------------------------------------------- |
| Port already in use           | `wormdb --port <other-port>`                                     |
| Permission denied on data dir | Check `--data` directory permissions                             |
| Bun client connection refused | Verify `--host`/`--port` and that WormDB is running              |
| Node won't join cluster       | Verify seed address, gossip port reachability, and cert validity |

## License

MIT

---

Built with Zig for speed, simplicity, and reliability.
