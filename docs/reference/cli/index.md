# CLI Flags

Command-line options for the `wormdb` binary.

```bash
./zig-out/bin/wormdb [options]
```

## Options

| Flag                   | Type    | Default      | Description                                            |
| ---------------------- | ------- | ------------ | ------------------------------------------------------ |
| `--port <n>`           | integer | `6389`       | TCP listen port for client and peer connections        |
| `--data <path>`        | path    | `./data`     | Directory for WAL, snapshots, and node identity        |
| `--persistence <mode>` | enum    | `full`       | Durability mode: `full`, `snapshot`, or `none`         |
| `--backend <type>`     | enum    | `threadpool` | IO backend: `threadpool`, `epoll`, or `uring`          |
| `--no-sync`            | flag    | off          | Disable synchronous WAL writes (faster, less durable)  |
| `--cluster <name>`     | string  | disabled     | Enable cluster mode with the given cluster name        |
| `--seed <host:port>`   | address | none         | Gossip endpoint of an existing node to join            |
| `--replicas <n>`       | integer | `0`          | Replication factor hint (`0` = replicate to all peers) |
| `--io-uring`           | flag    | off          | Legacy shortcut for `--backend uring`                  |
| `--help`, `-h`         | flag    | —            | Show help text                                         |

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

### Low-Latency io_uring

```bash
./zig-out/bin/wormdb --backend uring --port 6389 --data ./data
```

Requires Linux kernel 5.6+. See [Server Backends](/architecture/server-backends) for tradeoffs.
