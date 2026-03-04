# Status Fields

The `STATUS`, `CLUSTER STATUS`, and `CLUSTER PEERS` commands return newline-delimited `key=value` text. This format is designed for easy parsing in shell scripts, monitoring agents, and automation pipelines.

## `STATUS`

Returns server-level health information. The fields differ depending on whether clustering is enabled.

### Standalone Mode

```
keys=42
wal_size=8192
cluster_enabled=0
```

| Field             | Type    | Description                                         |
| ----------------- | ------- | --------------------------------------------------- |
| `keys`            | integer | Total number of keys in the store                   |
| `wal_size`        | integer | WAL file size in bytes (0 if persistence is `none`) |
| `cluster_enabled` | `0`     | Cluster is not active                               |

### Cluster Mode

```
keys=42
wal_size=8192
cluster_nodes=3
cluster_alive=3
cluster_suspected=0
cluster_dead=0
replication_factor=0
```

| Field                | Type    | Description                                     |
| -------------------- | ------- | ----------------------------------------------- |
| `keys`               | integer | Total number of keys in the store               |
| `wal_size`           | integer | WAL file size in bytes                          |
| `cluster_nodes`      | integer | Total known nodes in the cluster                |
| `cluster_alive`      | integer | Nodes responding to health checks               |
| `cluster_suspected`  | integer | Nodes under suspicion (missed health checks)    |
| `cluster_dead`       | integer | Nodes confirmed unreachable                     |
| `replication_factor` | integer | Configured replication factor (`0` = all peers) |

## `CLUSTER STATUS`

Returns cluster-specific health. When cluster mode is disabled, all fields are zero.

### Enabled

```
cluster_enabled=1
cluster_nodes=3
cluster_alive=3
cluster_suspected=0
cluster_dead=0
replication_factor=0
```

### Disabled

```
cluster_enabled=0
cluster_nodes=0
cluster_alive=0
cluster_suspected=0
cluster_dead=0
```

## `CLUSTER PEERS`

Returns detailed per-peer information, separated by `---` lines.

### Example Output

```
self_mesh_ip=10.0.0.1
self_port=6389
---
mesh_ip=10.0.0.2
state=alive
gossip_endpoint=10.0.0.2:51821
wormwire=connected
---
mesh_ip=10.0.0.3
state=alive
gossip_endpoint=10.0.0.3:51821
wormwire=connected
```

### Header Fields

| Field          | Description                 |
| -------------- | --------------------------- |
| `self_mesh_ip` | This node's mesh IP address |
| `self_port`    | This node's WormWire port   |

### Peer Fields (per `---` section)

| Field             | Description                                               |
| ----------------- | --------------------------------------------------------- |
| `mesh_ip`         | Peer's mesh IP address                                    |
| `state`           | SWIM state: `alive`, `suspected`, `dead`, or `left`       |
| `gossip_endpoint` | Peer's gossip address (host:port)                         |
| `wormwire`        | Replication channel status: `connected` or `disconnected` |

## Parsing Tips

::: tip
Treat unknown keys as forward-compatible additions. New fields may be added in future versions — your automation should ignore keys it doesn't recognize rather than failing on unexpected input.
:::

A simple shell-based parser:

```bash
bun run apps/bun/src/bin/client.ts STATUS | grep '^keys=' | cut -d= -f2
```
