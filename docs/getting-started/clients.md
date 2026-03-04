# Clients & Commands

WormDB speaks WormWire v1, a binary framed protocol. You can't use `nc` or `telnet` — every command must be properly framed with a command ID, a 4-byte big-endian length, and the payload. The easiest way to interact with WormDB is through the **Bun reference client** included in this repository.

## Using the Bun Client

The client connects, sends one command, prints the response, and exits:

```bash
bun run apps/bun/src/bin/client.ts [--host HOST] [--port PORT] COMMAND [args...]
```

Default host is `127.0.0.1`, default port is `6389`.

## Core Commands

### GET — Read a Key

```bash
bun run apps/bun/src/bin/client.ts GET mykey
# → hello world        (if the key exists)
# → (null)             (if the key doesn't exist)
```

### SET — Write a Key

```bash
bun run apps/bun/src/bin/client.ts SET mykey "hello world"
# → OK
```

Add the `WORM` flag to make the key permanently immutable:

```bash
bun run apps/bun/src/bin/client.ts SET audit "record-001" WORM
# → OK
```

### DEL — Delete a Key

```bash
bun run apps/bun/src/bin/client.ts DEL mykey
# → OK
```

::: warning
Deleting a WORM key returns `ERR: WORM violation: key is immutable`. WORM keys cannot be deleted.
:::

## Pub/Sub Commands

WormDB includes a lightweight publish/subscribe system for real-time event distribution.

### SUB — Subscribe to a Channel

```bash
bun run apps/bun/src/bin/client.ts SUB events
```

The client stays connected and prints messages as they arrive on the `events` channel.

### PUB — Publish to a Channel

```bash
bun run apps/bun/src/bin/client.ts PUB events "deployment-complete"
# → OK
```

All active subscribers on the `events` channel will receive `deployment-complete` as a WormWire event frame. See [Pub/Sub](/architecture/pubsub) for the event format and design details.

## Stored Procedures

The `EXEC` command invokes compiled Zig procedures by name. Arguments are positional.

### increment

Atomically increments a key's integer value, initializing to `0` if the key doesn't exist:

```bash
bun run apps/bun/src/bin/client.ts EXEC increment counter
# → 1

bun run apps/bun/src/bin/client.ts EXEC increment counter 10
# → 11
```

### transfer

Atomically moves an integer amount between two keys, with balance checking:

```bash
# Set up accounts
bun run apps/bun/src/bin/client.ts SET acct:alice "1000"
bun run apps/bun/src/bin/client.ts SET acct:bob "500"

# Transfer 200 from Alice to Bob
bun run apps/bun/src/bin/client.ts EXEC transfer acct:alice acct:bob 200
# → OK

# Verify balances
bun run apps/bun/src/bin/client.ts GET acct:alice
# → 800
bun run apps/bun/src/bin/client.ts GET acct:bob
# → 700
```

Transfer fails safely if the source account has insufficient funds:

```bash
bun run apps/bun/src/bin/client.ts EXEC transfer acct:alice acct:bob 999999
# → ERR: insufficient_funds
```

See [Stored Procedures](/architecture/procedures) for the full procedure model and how to write your own.

## Cluster & Status Commands

### STATUS

```bash
bun run apps/bun/src/bin/client.ts STATUS
```

Returns server health as `key=value` pairs:

```
keys=42
wal_size=8192
cluster_enabled=0
```

### CLUSTER STATUS / CLUSTER PEERS

When cluster mode is enabled, these give you detailed membership and connectivity information. See [Clustering](/operations/clustering) and [Status Fields](/reference/status-fields) for the full field reference.

### SAVE

Triggers a manual snapshot write:

```bash
bun run apps/bun/src/bin/client.ts SAVE
# → OK
```

Useful before planned maintenance or as part of a backup script.
