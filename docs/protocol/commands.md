# Command Reference

Every WormDB command has a 1-byte integer ID and a defined payload layout. All variable-length fields are encoded as `[4B length BE][bytes]`.

## Command IDs

| ID     | Command          | Description                             |
| ------ | ---------------- | --------------------------------------- |
| `0x01` | `GET`            | Read a key's value                      |
| `0x02` | `SET`            | Write a key (optionally with WORM flag) |
| `0x03` | `DEL`            | Delete a key                            |
| `0x04` | `STATUS`         | Server health summary                   |
| `0x05` | `CLUSTER STATUS` | Cluster membership summary              |
| `0x06` | `SUB`            | Subscribe to a pub/sub channel          |
| `0x07` | `UNSUB`          | Unsubscribe from a channel              |
| `0x08` | `PUB`            | Publish a message to a channel          |
| `0x09` | `EXEC`           | Execute a stored procedure              |
| `0x0A` | `CLUSTER PEERS`  | Detailed peer information               |
| `0x0B` | `SAVE`           | Trigger manual snapshot                 |
| `0x0C` | `AUTH`           | Authenticate with a binary SCT token    |
| `0x0D` | `VINSERT`        | Native vector insert                    |
| `0x0E` | `VDELETE`        | Native vector delete/tombstone          |
| `0x0F` | `VBULKINSERT`    | Native bulk vector insert               |
| `0x10` | `VRABITQ_INSTALL` | Peer-only RaBitQ parameter replication |

## Payload Layouts

### Single-Field Commands — `GET`, `DEL`, `SUB`, `UNSUB`

```text
[4B field_len][field bytes]
```

**GET** returns `value` (0x01) with the data, or `null_value` (0x02) if the key doesn't exist.

**DEL** returns `ok` (0x00) on success, or `err` (0x03) if the key is WORM-protected.

### SET

```text
[1B flags][4B key_len][key][4B value_len][value]
```

**Flags byte**:

- Bit 0 (`0x01`): WORM flag — if set, the key becomes permanently immutable
- Bits 1–7: reserved, must be `0`

**Responses**:

- `ok` (0x00) on success
- `err` (0x03) with `"WORM violation: key is immutable"` if the key already exists with WORM

### PUB

```text
[4B channel_len][channel][4B message_len][message]
```

Returns `ok` (0x00) regardless of subscriber count.

### EXEC

```text
[4B proc_len][procedure name][4B arg_count][arg0][arg1]...
where each arg = [4B arg_len][arg bytes]
```

**Responses** depend on the procedure:

- `ok` (0x00) — success with no data (e.g., transfer)
- `value` (0x01) — success with data (e.g., increment returns the new value)
- `err` (0x03) — procedure-specific error (e.g., `"insufficient_funds"`, `"unknown procedure"`)

### AUTH

```text
[4B token_len][token bytes]
```

`AUTH` carries a binary signed client token. It is intercepted by transports that support authentication; if it reaches the generic executor, the server returns `err` (0x03) because auth must be handled at the connection or gateway layer.

### VINSERT

```text
[key][vector][1B flags][namespace][metric][8B timestamp]
```

`key`, `vector`, `namespace`, and `metric` are length-prefixed fields. `vector` is raw `f32` bytes interpreted directly by the server; on supported little-endian targets, clients should pack little-endian `f32` values. `metric` is the UTF-8 string `cosine`, `dot`, or `l2`.

**Flags byte**:

- Bit 0 (`0x01`): WORM flag — if set, the vector key is immutable
- Bit 1 (`0x02`): async HNSW build request for the namespace
- Bits 2–7: reserved, must be `0`

The timestamp is an unsigned 64-bit big-endian integer carried by the originator so replicated HNSW side tables keep stable ordering across peers.

### VDELETE

```text
[key][namespace]
```

Both fields are length-prefixed. The command deletes the stored vector key and tombstones its HNSW node when the namespace has an index. WORM-protected vectors return `err` (0x03).

### VBULKINSERT

```text
[namespace][metric][1B flags][4B count]
for each item: [key][vector][8B timestamp]
```

`namespace`, `metric`, `key`, and `vector` are length-prefixed fields. The flags byte uses the same bits as `VINSERT`, but applies to every item in the batch. The bulk command amortizes frame parsing and namespace locking across many vector inserts.

### VRABITQ_INSTALL

```text
[namespace][4B dim][8B seed][centroid][rotation]
```

This is an internal replication frame emitted by `EXEC vrabitq`. It installs the leader's RaBitQ centroid and rotation matrix on peers before the re-encoded `bq:*` writes arrive. Normal client libraries should not expose this as an application command.

### No-Payload Commands — `STATUS`, `CLUSTER STATUS`, `CLUSTER PEERS`, `SAVE`

These commands have an empty payload (payload length = 0).

**STATUS** and cluster commands return `value` (0x01) with `key=value` text. See [Status Fields](/reference/status-fields) for the complete field reference.

**SAVE** returns `ok` (0x00) on success or `err` (0x03) if the snapshot write fails.
