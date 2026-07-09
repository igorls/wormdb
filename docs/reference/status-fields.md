# Status Fields

The `STATUS`, `CLUSTER STATUS`, and `CLUSTER PEERS` commands return newline-delimited `key=value` text. This format is designed for easy parsing in shell scripts, monitoring agents, and automation pipelines.

## `STATUS`

Returns server-level health information. The fields differ depending on whether clustering is enabled.

### Standalone Mode

```
keys=42
wal_size=8192
cluster_enabled=0
server_started_ms=1783570000000
status_generated_ms=1783570060000
tcp_connections_active=12
tcp_commands_in_flight=1
tcp_commands_completed=320
tcp_commands_succeeded=318
tcp_last_successful_command_completed_ms=1783570059123
tcp_connection_queue_depth=0
gateway_connections_active=38
gateway_websocket_connections_active=37
gateway_threads_active=38
gateway_commands_in_flight=2
gateway_commands_completed=884
gateway_commands_succeeded=870
gateway_last_successful_command_completed_ms=1783570059988
event_bus_channels=4
event_bus_subscribers=41
event_bus_publishes=516
event_bus_drops=3
```

| Field                                         | Type    | Description                                         |
| --------------------------------------------- | ------- | --------------------------------------------------- |
| `keys`                                        | integer | Total number of keys in the store                   |
| `wal_size`                                    | integer | WAL file size in bytes (0 if persistence is `none`) |
| `cluster_enabled`                             | `0`     | Cluster is not active                               |
| `server_started_ms`                           | integer | Process start time in Unix epoch milliseconds (`0` when metrics were not wired by the embedding binary) |
| `status_generated_ms`                         | integer | Timestamp when this `STATUS` payload was generated  |
| `tcp_connections_active`                      | integer | Active TCP connections currently owned by worker threads |
| `tcp_commands_in_flight`                      | integer | TCP commands currently executing or writing a response |
| `tcp_commands_completed`                      | integer | TCP commands that reached a response write completion path |
| `tcp_commands_succeeded`                      | integer | Completed TCP commands whose response was not `ERR` |
| `tcp_last_successful_command_completed_ms`    | integer | Last successful TCP command completion timestamp; `0` until one succeeds |
| `tcp_connection_queue_depth`                  | integer | Accepted TCP connections waiting for a worker       |
| `gateway_connections_active`                  | integer | Active WebSocket gateway threads/connections, including HTTP keep-alive requests on the gateway listener |
| `gateway_websocket_connections_active`        | integer | Active upgraded WebSocket sessions                  |
| `gateway_threads_active`                      | integer | Gateway handler threads currently running           |
| `gateway_commands_in_flight`                  | integer | Gateway commands currently executing or writing a response |
| `gateway_commands_completed`                  | integer | Gateway commands that reached a response write completion path |
| `gateway_commands_succeeded`                  | integer | Completed gateway commands whose response was not `ERR` |
| `gateway_last_successful_command_completed_ms` | integer | Last successful gateway command completion timestamp; `0` until one succeeds |
| `event_bus_channels`                          | integer | Pub/sub channels currently allocated                |
| `event_bus_subscribers`                       | integer | Active pub/sub subscriptions                        |
| `event_bus_publishes`                         | integer | Publish calls accepted by the EventBus              |
| `event_bus_drops`                             | integer | Event deliveries dropped because a subscriber write path was busy |

### Cluster Mode

```
keys=42
wal_size=8192
cluster_nodes=3
cluster_alive=3
cluster_suspected=0
cluster_dead=0
replication_factor=0
proof_checkpoint_records=4
proof_witness_records=9
proof_last_verified_ms=1780957400000
anti_entropy_mode=root
server_started_ms=1783570000000
status_generated_ms=1783570060000
tcp_connections_active=12
tcp_commands_in_flight=1
tcp_commands_completed=320
tcp_commands_succeeded=318
tcp_last_successful_command_completed_ms=1783570059123
tcp_connection_queue_depth=0
gateway_connections_active=38
gateway_websocket_connections_active=37
gateway_threads_active=38
gateway_commands_in_flight=2
gateway_commands_completed=884
gateway_commands_succeeded=870
gateway_last_successful_command_completed_ms=1783570059988
event_bus_channels=4
event_bus_subscribers=41
event_bus_publishes=516
event_bus_drops=3
```

| Field                      | Type    | Description                                                  |
| -------------------------- | ------- | ------------------------------------------------------------ |
| `keys`                     | integer | Total number of keys in the store                            |
| `wal_size`                 | integer | WAL file size in bytes                                       |
| `cluster_nodes`            | integer | Total known nodes in the cluster                             |
| `cluster_alive`            | integer | Nodes responding to health checks                            |
| `cluster_suspected`        | integer | Nodes under suspicion (missed health checks)                 |
| `cluster_dead`             | integer | Nodes confirmed unreachable                                  |
| `replication_factor`       | integer | Configured replication factor (`0` = all peers)              |
| `proof_checkpoint_records` | integer | Stored append-log checkpoint records                         |
| `proof_witness_records`    | integer | Stored append-log witness records                            |
| `proof_last_verified_ms`   | integer | Last successful per-peer root verification timestamp; `0` until a root probe succeeds |
| `anti_entropy_mode`        | string  | Current anti-entropy mode; `root` probes compact roots before falling back to full sync |

Cluster-mode `STATUS` also includes every liveness, transport, and EventBus field listed for standalone mode.

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
proof_checkpoint_records=4
proof_witness_records=9
proof_last_verified_ms=1780957400000
anti_entropy_mode=root
```

### Disabled

```
cluster_enabled=0
cluster_nodes=0
cluster_alive=0
cluster_suspected=0
cluster_dead=0
proof_checkpoint_records=0
proof_witness_records=0
proof_last_verified_ms=0
anti_entropy_mode=disabled
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
root_sync=healthy
root_sync_last_ms=1780957400000
root_sync_missing_ranges=0
---
mesh_ip=10.0.0.3
state=alive
gossip_endpoint=10.0.0.3:51821
wormwire=connected
root_sync=unknown
root_sync_last_ms=0
root_sync_missing_ranges=0
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
| `root_sync`       | Root anti-entropy status: `healthy`, `behind`, `ahead`, `diverged`, or `unknown` |
| `root_sync_last_ms` | Last per-peer root verification timestamp; `0` when unknown |
| `root_sync_missing_ranges` | Missing sorted-prefix tail ranges repaired or detected by root sync |

## Parsing Tips

::: tip
Treat unknown keys as forward-compatible additions. New fields may be added in future versions — your automation should ignore keys it doesn't recognize rather than failing on unexpected input.
:::

A simple shell-based parser:

```bash
bun run apps/bun/src/bin/client.ts STATUS | grep '^keys=' | cut -d= -f2
```
