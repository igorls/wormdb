# Troubleshooting

Common failures, what they mean, and how to fix them.

## Startup Failures

### "Address already in use"

Another process is already listening on the port you specified.

```bash
# Find what's using the port
lsof -i :6389

# Either stop that process or use a different port
./zig-out/bin/wormdb --port 6390 --data ./data
```

### "Permission denied" on bind

The server can't bind to the requested port or access the data directory.

**Port issue**: ports below 1024 require root privileges on most systems. Use a port above 1024 or configure capabilities.

**Data path issue**: the user running the server doesn't have read/write access to the `--data` directory.

```bash
# Check permissions
ls -la ./data

# Fix ownership
chown -R $(whoami) ./data
```

### "FileNotFound" or "NotDir" on startup

The `--data` path doesn't exist or points to a file instead of a directory.

```bash
# Create the data directory
mkdir -p ./data

# In containers, verify the volume mount
docker run -v /host/data:/app/data wormdb --data /app/data
```

## Command Errors

### `WORM violation: key is immutable`

You tried to overwrite or delete a key that was written with the WORM flag. This is by design — WORM keys are permanently sealed. See [WORM Semantics](/architecture/worm-semantics).

### `malformed frame`

The client sent a WormWire frame that doesn't match the expected format. Common causes:

- Using a text-based tool like `nc` or `telnet` instead of the binary client
- Sending a frame with an invalid command ID
- Payload structure doesn't match the command's expected layout

### `request too large`

The payload exceeded WormDB's **16 MiB** frame limit. If you're storing large values, consider chunking them across multiple keys.

### `unknown procedure`

The procedure name passed to `EXEC` doesn't exist in the registry. Check the available built-ins in [Stored Procedures](/architecture/procedures).

### `AUTH must be sent over gateway`

`AUTH` reached the generic command executor instead of being intercepted by a gateway connection. Use the WebSocket or QUIC gateway for SCT authentication; raw TCP WormWire clients should not send `AUTH` unless their transport implements connection-level auth handling.

### `vinsert: invalid vector bytes`

The vector payload is empty or its byte length is not a multiple of four. Vector bytes are raw `f32` values, not JSON arrays or text numbers; on supported little-endian targets, pack them as little-endian `f32`.

### `vsearch: query key not found`

`vsearch` takes a key containing the query vector, not an inline vector. Insert or set the query vector first, then call `EXEC vsearch <query_key> ...`.

### `mem_add: embedder mismatch`

The memory namespace has a configured `embedder_id`, and the caller asserted a different embedder in the optional final `mem_add` argument. Re-embed with the configured model. If you intentionally rotate, note that `EXEC mem_reset_index <ns> <new_embedder_id>` aborts when default WORM vector keys would be left behind; use non-WORM vectors for planned rotation or run `mem_drop` for a hard reset that reports skipped WORM keys.

### `replication failed after local commit`

The write succeeded on the local node but could not be replicated to one or more peers. The data exists locally but other nodes may not have it. Check:

- `CLUSTER PEERS` — are peers showing `wormwire=connected`?
- Network connectivity between nodes
- Whether the target peer is still running

## Cluster Issues

### Node doesn't appear in the cluster

Verify the basics:

1. Both nodes use the same `--cluster <name>`
2. The `--seed` address is correct and reachable
3. The gossip UDP port (default `51821`) is not blocked by a firewall
4. Check the startup logs on the joining node for connection errors

### Peer shows `state=suspected` or `state=dead`

SWIM health checks are failing for that peer. Investigate:

```bash
# Check from the suspected node's perspective
bun run apps/bun/src/bin/client.ts --port <peer_port> STATUS
```

If the node is responsive to direct commands but shows as suspected, there may be a firewall blocking the gossip UDP traffic between those specific nodes.

### `wormwire=disconnected` for a peer

The TCP replication channel isn't established. The node may be alive at the gossip layer but unreachable on the WormWire port. Check that the `--port` used for WormWire is accessible from other nodes.

## Gateway Issues

### HTTP `/api/...` returns 404

The request is not on any route registered by a composed domain package, or the gateway is not enabled. Start WormDB with `--gateway-port <port>` or set `gateway.enabled=true` in config, then request the route from the gateway port, not the primary WormWire TCP port.

### `/api/status` returns 503

A domain route may intentionally map a body value to an error status (e.g. a health endpoint returning 503 while its data is out of sync). Check the domain's feed and segment freshness.

### WebSocket command returns `auth required`

The gateway has `auth.require_auth=true` and the connection has not authenticated with a valid SCT token. Configure `auth.public_keys`, mint a token from an auth provider, and send `AUTH` before protected commands.

## Diagnostic Commands

These three commands are your primary diagnostic tools:

```bash
# Server health: keys, WAL size, cluster summary
bun run apps/bun/src/bin/client.ts STATUS

# Cluster-level health breakdown
bun run apps/bun/src/bin/client.ts CLUSTER STATUS

# Per-peer detail: IP, state, gossip endpoint, WormWire connection
bun run apps/bun/src/bin/client.ts CLUSTER PEERS
```

All three return `key=value` text designed for parsing in scripts. See [Status Fields](/reference/status-fields) for the complete field reference.
