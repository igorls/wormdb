# Verifiable Append Log

WormDB append logs are generic WORM-backed provenance chains. Applications provide opaque payload bytes and optional attachment hashes; WormDB preserves those bytes, assigns a monotonic sequence in a named log, and links events with SHA-256 hashes. App-specific claims such as device time, GPS fixes, operators, or supervisor signatures belong inside the payload bytes.

## Storage Keys

Each event is stored as a WORM key:

```text
proof:append-log:v1:<sha256(log_id) hex>:event:<8B seq BE>
```

The binary big-endian sequence suffix keeps prefix scans sorted by sequence. Sequence reuse is prevented by the WORM key write: two appenders racing for the same next sequence cannot both commit.

## Procedure Surface

Append a canonical event envelope to a named log:

```bash
bun run apps/bun/src/bin/client.ts EXEC append_log_append <log_id> <payload> [ts=<ms>] [attachment_hash_hex...]
```

`ts=<ms>` is optional; when omitted WormDB records the current local receipt timestamp. Each attachment hash is a 64-character hex SHA-256 digest. The response is JSON:

```json
{"seq":1,"ingest_time_ms":1700000000000,"key_hex":"...","prev_event_hash":"...","payload_hash":"...","event_hash":"..."}
```

Verify the stored chain for a log:

```bash
bun run apps/bun/src/bin/client.ts EXEC append_log_verify <log_id>
```

The response is JSON:

```json
{"count":3,"last_seq":3,"head_hash":"..."}
```

## Envelope Format

All integer fields are unsigned big-endian. The `event_hash` is the linear chain hash: `SHA-256` over every byte before the final `event_hash` field.

```text
[8B magic = "WDBALOG1"]
[2B version = 1]
[4B log_id_len][log_id bytes]
[8B seq]
[32B prev_event_hash]
[8B ingest_time_ms]
[32B payload_hash]
[4B attachment_count]
  repeated attachment_count times:
  [32B attachment_hash]
[4B payload_len][payload bytes]
[32B event_hash]
```

`payload_hash` is `SHA-256(payload bytes)`. For the first event in a log, `prev_event_hash` is 32 zero bytes. For every later event, it must equal the previous event's `event_hash`.

Proof bundles use a separate `record_hash = SHA-256(full canonical envelope bytes)`. That hash includes the trailing `event_hash` and is the leaf material used by the MMR proof path.

`ingest_time_ms` is a generic local database receipt timestamp in Unix epoch milliseconds. It is not a claim that the real-world event happened at that time; applications that need device time, GPS time, or signed time claims should include those claims in the payload and sign them at the application layer.

## Verification

Verification scans the event prefix and checks:

- each event key is WORM-protected
- the sequence in the key matches the sequence in the envelope
- sequences are contiguous and monotonic
- `prev_event_hash` matches the previous event
- `payload_hash` matches the stored payload bytes
- `event_hash` matches the canonical envelope preimage
- the envelope `log_id` matches the requested log

This detects replacement, reordering, and interior deletion in a linear chain. Detecting deletion of the latest tail event requires an external checkpoint, witness, or Merkle/MMR accumulator.
