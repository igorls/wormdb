# Verifiable Append Log

WormDB append logs are generic WORM-backed provenance chains. Applications provide opaque payload bytes and optional attachment hashes; WormDB preserves those bytes, assigns a monotonic sequence in a named log, and links events with SHA-256 hashes. App-specific claims such as device time, GPS fixes, operators, or supervisor signatures belong inside the payload bytes.

## Storage Keys

Each event is stored as a WORM key:

```text
proof:append-log:v1:<sha256(log_id) hex>:event:<8B seq BE>
```

The binary big-endian sequence suffix keeps prefix scans sorted by sequence. Sequence reuse is prevented by the WORM key write: two appenders racing for the same next sequence cannot both commit.

Each successful append also stores a WORM accumulator-state record:

```text
proof:append-log-mmr-state:v1:<sha256(log_id) hex>:state:<8B seq BE>
```

The state value contains the log id, last sequence, head event hash, `mmr_sha256_v1` root, and canonical MMR peaks for that sequence. Appends load the latest state by prefix tail scan and update the MMR root incrementally. If the state is absent or stale, WormDB falls back to a full WORM-chain verification and state rebuild before writing the next event.

## Procedure Surface

Append a canonical event envelope to a named log:

```bash
bun run apps/bun/src/bin/client.ts EXEC append_log_append <log_id> <payload> [ts=<ms>] [attachment_hash_hex...]
```

`ts=<ms>` is optional; when omitted WormDB records the current local receipt timestamp. Each attachment hash is a 64-character hex SHA-256 digest. The response is JSON:

```json
{"seq":1,"ingest_time_ms":1700000000000,"key_hex":"...","prev_event_hash":"...","payload_hash":"...","event_hash":"...","accumulator_kind":"mmr_sha256_v1","accumulator_root":"...","accumulator_leaf_count":1}
```

Verify the stored chain for a log:

```bash
bun run apps/bun/src/bin/client.ts EXEC append_log_verify <log_id>
```

The response is JSON:

```json
{"count":3,"last_seq":3,"head_hash":"..."}
```

Generate an MMR inclusion proof for a stored event:

```bash
bun run apps/bun/src/bin/client.ts EXEC append_log_mmr_proof <log_id> <seq>
```

The response carries hex-encoded proof bytes that can be verified without a live database:

```json
{"seq":2,"leaf_index":1,"leaf_count":3,"root":"...","record_hash":"...","proof_hex":"..."}
```

Verify proof bytes directly:

```bash
bun run apps/bun/src/bin/client.ts EXEC append_log_mmr_verify <record_hash_hex> <root_hex> <proof_hex>
```

The response is `{"valid":true}` or `{"valid":false}`. This procedure uses the canonical `mmr_sha256_v1` proof-byte format from [Verifiable Proof Bundles](/protocol/proofs). Appends persist the latest MMR root and peaks incrementally; proof generation still rebuilds path nodes from stored append-log envelopes when serving an inclusion proof.

Create and store a signed checkpoint record:

```bash
bun run apps/bun/src/bin/client.ts EXEC append_log_checkpoint <log_id> <from_seq> <to_seq> <creator_pubkey_hex> sk=<secret_key_hex>|sig=<signature_hex> [created_at_ms=<ms>] [ingested_at_ms=<ms>] [prev=<checkpoint_hash_hex>] [ext=<hex>]
```

`append_log_checkpoint` verifies the append-log chain, rebuilds the `mmr_sha256_v1` root up to `to_seq`, signs or validates the checkpoint, then stores the canonical checkpoint bytes as a WORM record:

```text
proof:append-log-checkpoint:v1:<sha256(log_id) hex>:<checkpoint_hash hex>
```

For test/dev signing, pass `sk=<128 hex chars>` with the Ed25519 secret key bytes. For externally signed records, pass `sig=<128 hex chars>` and make sure the supplied timestamp/options match the bytes that were signed. `ext=<hex>` carries signed opaque extension bytes. The response is canonical JSON with checkpoint metadata, `checkpoint_hash`, and `canonical_record_hex`.

Create and store a witness countersignature over an existing checkpoint:

```bash
bun run apps/bun/src/bin/client.ts EXEC append_log_witness <log_id> <checkpoint_hash_hex> [witness_pubkey_hex] [sk=<secret_key_hex>|sig=<signature_hex>] [observed_at_ms=<ms>] [ext=<hex>]
```

When clustering is enabled and no witness public key or signature material is supplied, WormDB signs with the local meshguard/WormDB identity. Otherwise, callers can pass a 32-byte Ed25519 public key plus either `sk=<128 hex chars>` for local signing or `sig=<128 hex chars>` for an externally produced signature. The signature covers the checkpoint identity, range, accumulator kind/root, checkpoint hash, witness identity, observation timestamp, and opaque extension bytes.

Witness records are stored as WORM keys and replicate through the normal durable procedure write path:

```text
proof:append-log-witness:v1:<sha256(log_id) hex>:<checkpoint_hash hex>:<sha256(witness_pubkey) hex>
```

Ask live cluster peers to countersign a stored checkpoint with their own meshguard/WormDB identities:

```bash
bun run apps/bun/src/bin/client.ts EXEC append_log_witness_request <log_id> <checkpoint_hash_hex>
```

The requester validates that the checkpoint exists locally and has a valid creator signature, then sends a restricted peer-to-peer `EXEC append_log_witness` over the replication connection. Peers reject all other `EXEC` calls on replication sockets. Each peer stores its witness through the durable WORM path, so the witness record replicates back like any other WORM proof record. The immediate response is `{"requested":<count>}` for peers that accepted the request frame; it is not a quorum acknowledgement.

Import a canonical witness received from a peer or offline packet:

```bash
bun run apps/bun/src/bin/client.ts EXEC append_log_witness_import <log_id> <checkpoint_hash_hex> <canonical_witness_hex>
```

Verify the stored witness for a checkpoint and witness identity:

```bash
bun run apps/bun/src/bin/client.ts EXEC append_log_witness_verify <log_id> <checkpoint_hash_hex> <witness_pubkey_hex>
```

The response is `{"valid":false}` or `{"valid":true,"witness":{...}}` with witness metadata, `witness_record_hash`, and `canonical_record_hex`.

Export a verifier-friendly JSON proof bundle for a single event or contiguous range:

```bash
bun run apps/bun/src/bin/client.ts EXEC append_log_proof_bundle <log_id> <from_seq> <to_seq> <checkpoint_hash_hex>
```

The checkpoint must cover the requested range. WormDB loads the checkpoint, verifies its signature, rebuilds the MMR root from stored append-log envelopes, and refuses to emit a bundle if the stored log no longer matches the checkpoint root. The response contains:

- `records[]` with `seq`, `canonical_record_hex`, `record_hash`, `payload_hash`, and `event_hash`
- `inclusion_proofs[]` with `seq`, `leaf_hash`, `checkpoint_hash`, and `proof_hex`
- `checkpoint` with the stored checkpoint metadata and canonical bytes

Verify a record hash and MMR proof against a stored checkpoint:

```bash
bun run apps/bun/src/bin/client.ts EXEC append_log_proof_verify <log_id> <seq> <record_hash_hex> <checkpoint_hash_hex> <proof_hex>
```

The response is `{"valid":true}` only when the checkpoint exists, has a valid signature, covers `seq`, and the MMR proof reconstructs the checkpoint root.

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
