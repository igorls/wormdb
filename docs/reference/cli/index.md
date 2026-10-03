# CLI Flags

Command-line options for the `wormdb` binary.

```bash
./zig-out/bin/wormdb [options]
```

## Options

| Flag | Type | Default | Description |
| ---- | ---- | ------- | ----------- |
| `--config <path>` | path | `./wormdb.json` if present | JSON config file |
| `--port <n>` | integer | `6389` | TCP listen port for client and peer connections |
| `--bind <address>` | IP address | `0.0.0.0` | TCP listen address |
| `--data <path>` | path | `./data` | Directory for WAL, snapshots, node identity, and vector snapshots |
| `--persistence <mode>` | enum | `full` | Durability mode: `full`, `snapshot`, or `none` |
| `--backend <type>` | enum | `threadpool` | The standalone server supports `threadpool`; other values are rejected before startup |
| `--no-sync` | flag | off | Disable synchronous WAL writes (faster, less durable) |
| `--cluster <name>` | string | disabled | Enable cluster mode with the given cluster name |
| `--seed <host:port>` | address | none | Gossip endpoint of an existing node to join |
| `--replicas <n>` | integer | `0` | Replication factor hint (`0` = replicate to all peers) |
| `--gossip-port <n>` | integer | `51821` | UDP port for SWIM gossip |
| `--wg-port <n>` | integer | `51830` | WireGuard listen port used by meshguard |
| `--gateway-port <n>` | integer | disabled | Enable the HTTP/WebSocket gateway on this port |
| `--require-auth` / `--no-auth` | flag | required | Enable or explicitly disable global authentication |
| `--tcp-auth` / `--no-tcp-auth` | flag | enabled | Enable or explicitly disable TCP authentication; global auth must also be enabled |
| `--cluster-open` | flag | off | Acknowledge unauthenticated replication when org trust is not configured |
| `--help`, `-h` | flag | — | Show help text |

## Examples

### Standalone (defaults)

```bash
./zig-out/bin/wormdb --port 6389 --data ./data
```

Starts with `threadpool` backend, `full` persistence, listening on port 6389.

### High-Throughput Snapshot Mode

```bash
./zig-out/bin/wormdb --persistence snapshot --port 6389 --data ./data
```

No per-write WAL overhead. Data persists only through manual `SAVE` or clean shutdown.

### Cluster Node

```bash
./zig-out/bin/wormdb --cluster myapp --seed 10.99.42.1:51821 --port 6389 --data ./data
```

Joins an existing cluster named `myapp` via the seed node's gossip endpoint.

### Backend support

The standalone binary uses `threadpool`, which supports signed TCP authentication.
The Linux `epoll` and `uring` implementations remain engine APIs and do not handle
TCP AUTH frames. Selecting them through `server.backend` or `--backend` fails
with `UnsupportedBackend`; there is no silent fallback. See [Server Backends](/architecture/server-backends).

### Gateway

```bash
./zig-out/bin/wormdb --port 6389 --gateway-port 6390
```

Enables the HTTP/WebSocket gateway. See [Gateways](/operations/gateways).

## JSON Config

CLI flags override the JSON config. Fields not present in the file use defaults, and unknown fields are ignored for forward compatibility.

Relative `store.wal_path` and `store.snapshot_path` values are resolved under
`data` (after any `--data` override); absolute paths are used unchanged. Defaults
are `data/wormdb.wal` and `data/wormdb.snapshot`. Parent directories are created
when their persistence mode needs them. Other store settings, including
`max_wal_size`, `compaction_threshold` and `sync_writes`, are preserved.

Older standalone binaries used `wormdb.snapshot` in the working directory.
If that legacy file exists and the configured snapshot path points elsewhere, startup stops
with `LegacySnapshotPath`. Move the snapshot to the configured data directory,
or set `store.snapshot_path` to its absolute existing path before restarting.
This prevents silently reopening without the old snapshot.

The same check applies to the old WAL location (`--data` or `./data`, followed
by `wormdb.wal`). If honoring configured paths or `data` would skip that file,
startup reports `LegacyWalPath`. Migrate the old WAL or set `store.wal_path` to
its absolute existing path before restarting.

Older binaries also ignored `store.persistence`. If honoring it would change
the prior CLI/default `full` mode to `snapshot` or `none` while a legacy WAL
exists, startup reports `LegacyWalMode`. Recover the data in full mode first,
save any snapshot needed, and migrate or archive the old WAL before changing
the configured mode. An explicit `--persistence` override keeps its existing
meaning.

Authentication stays enabled by default even with no verification keys. Supply
`auth.public_keys` and a signed token for protected commands. Authentication
opt-outs are intended only for explicitly trusted deployments; `--no-auth`
also disables authentication on enabled gateways.

```json
{
  "data": "./data",
  "server": { "port": 6389, "backend": "threadpool" },
  "gateway": {
    "enabled": true,
    "port": 6390,
    "quic_enabled": false
  },
  "auth": {
    "public_keys": [],
    "require_auth": true,
    "token_max_age_s": 3600
  },
  "segments": [
    { "name": "mydomain", "path": "./mydomain.wseg" }
  ]
}
```
