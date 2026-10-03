# Verifiable Proof Bundles

Status: draft implementation slice for signed checkpoints and verifier-friendly bundles.

WormDB proof bundles are small packets that let another device verify immutable log material without trusting the sender or connecting to the original database. The database layer provides record hashes, accumulator roots, checkpoint signatures, and opaque extension bytes. Applications decide how to present domain claims such as device time, GPS fixes, supervisor notes, or incident metadata.

## Checkpoint Record

A checkpoint commits to a contiguous append-log range:

| Field | Meaning |
| --- | --- |
| `version` | Proof format version. Current value: `1`. |
| `log_id` | Application or namespace log identifier. |
| `from_seq`, `to_seq` | Inclusive sequence range covered by the checkpoint. |
| `accumulator_kind` | Root type: opaque root, Merkle SHA-256 v1, or MMR SHA-256 v1. |
| `accumulator_root` | 32-byte root produced by the accumulator layer. |
| `previous_checkpoint_hash` | Optional hash of the previous checkpoint record. |
| `creator_identity` | Signature identity bytes. For Ed25519 v1 this is the 32-byte public key. |
| `signature_scheme` | Current value: Ed25519. |
| `signature` | Signature over the canonical signing payload. |
| `created_at_ms` | Creator-supplied creation time in Unix epoch milliseconds. |
| `ingested_at_ms` | Database/node-supplied ingestion or receipt time in Unix epoch milliseconds. |
| `extension_bytes` | Signed opaque claim bytes for app-specific metadata. |

All integers in canonical proof material are big-endian. Variable-length byte fields use a 4-byte big-endian length followed by raw bytes. Hashes are SHA-256 unless the accumulator kind explicitly says otherwise.

The checkpoint signature input is domain-separated as `wormdb.checkpoint.sign.v1` and includes every checkpoint field except `signature`. The checkpoint hash is domain-separated as `wormdb.checkpoint.record.v1` and includes the signing payload plus the signature bytes.

`EXEC append_log_checkpoint` stores the canonical checkpoint bytes as a WORM record keyed by the checkpoint hash. `EXEC append_log_proof_bundle` includes those exact bytes as `checkpoint.canonical_record_hex` so external verifier tooling can decode and hash the same material.

## Witness Record

A witness record is a countersignature over an existing checkpoint. It does not claim authorship of the append-log records; it proves that a second identity observed the same checkpoint root and hash.

| Field | Meaning |
| --- | --- |
| `version` | Witness format version. Current value: `1`. |
| `log_id` | Application or namespace log identifier. |
| `from_seq`, `to_seq` | Inclusive sequence range copied from the checkpoint. |
| `accumulator_kind` | Root type copied from the checkpoint. |
| `accumulator_root` | 32-byte checkpoint accumulator root. |
| `checkpoint_hash` | Hash of the canonical checkpoint record being witnessed. |
| `witness_identity` | Signature identity bytes. For Ed25519 v1 this is the 32-byte public key. |
| `signature_scheme` | Current value: Ed25519. |
| `signature` | Signature over the canonical witness signing payload. |
| `observed_at_ms` | Witness-supplied observation time in Unix epoch milliseconds. |
| `extension_bytes` | Signed opaque claim bytes for app-specific metadata. |

The witness signature input is domain-separated as `wormdb.witness.sign.v1` and includes every witness field except `signature`. The witness record hash is domain-separated as `wormdb.witness.record.v1` and includes the signing payload plus the signature bytes.

`EXEC append_log_witness` creates a witness from a stored checkpoint. In clustered mode, omitting explicit witness/signature arguments signs with the local meshguard/WormDB Ed25519 identity. `EXEC append_log_witness_request` asks live cluster peers to run that restricted witness procedure over the replication transport; peer-side replication sockets still reject all other `EXEC` procedures. `EXEC append_log_witness_import` verifies and stores canonical witness bytes received from a peer, relay, or offline transfer. `EXEC append_log_witness_verify` checks the stored witness against the checkpoint and public key.

## Extension Claims

WormDB intentionally does not acquire GPS, read device clocks, or interpret supervisor workflow notes. Those claims belong in `extension_bytes`, encoded by the app in a stable format such as CBOR, protobuf, or canonical JSON.

For a field-signoff app, `extension_bytes` might contain:

```json
{
  "device_time_ms": 1777777000,
  "monotonic_ms": 913384,
  "gps": {
    "lat": 37.422,
    "lon": -122.084,
    "accuracy_m": 6.5,
    "fix_time_ms": 1777776990,
    "provider": "gnss"
  },
  "role": "supervisor",
  "note": "Reviewed trail and countersigned offline"
}
```

The signature proves that the checkpoint creator signed those bytes. It does not prove that the phone's wall clock or GPS stack was truthful. Trust improves when a second device countersigns the same root, when a relay witnesses the checkpoint, or when a later online timestamp anchor is added.

## Proof Bundle

A proof bundle has one of two shapes:

| Kind | Intended use |
| --- | --- |
| `single_event` | Prove one immutable event and the checkpoint that covers it. |
| `range` | Prove a contiguous record range and the checkpoint(s) that cover it. |

Bundle contents:

| Field | Meaning |
| --- | --- |
| `version` | Proof bundle version. Current value: `1`. |
| `kind` | `single_event` or `range`. |
| `log_id` | Log namespace the bundle belongs to. |
| `records` | Carried records with exact canonical bytes and record hashes. |
| `inclusion_proofs` | Opaque accumulator path bytes per record. |
| `checkpoints` | Signed checkpoint records needed to validate the roots. |
| `extension_bytes` | Unsigned bundle-level metadata for transport/presentation. |

Each record carries:

- `seq`
- `canonical_record_bytes`
- `record_hash = SHA-256(canonical_record_bytes)`
- optional `value_bytes`
- optional `value_hash = SHA-256(value_bytes)`
- optional record-level `extension_bytes`

The proof module does not allocate append-log sequences and does not define the append-log hash chain. It verifies that exact bytes match carried hashes. Worker B's append-log layer owns canonical record construction and sequence allocation.

Each inclusion proof carries:

- `seq`
- `leaf_hash`
- `checkpoint_hash`
- `path_bytes`
- optional `extension_bytes`

For `mmr_sha256_v1`, `leaf_hash` is the proof-bundle `record_hash`, where `record_hash = SHA-256(full canonical append-log envelope bytes)`. The append-log `event_hash` remains the linear chain hash over the envelope preimage before the trailing `event_hash` field.

## Proof Bundle Bytes

Encoded proof bundles use canonical bytes for FFI and packet transfer:

```text
[8B magic = "WDBPBND1"]
[2B codec_version = 1]
[1B proof_bundle_version = 1]
[1B kind]
[4B log_id_len][log_id bytes]
[4B bundle_extension_len][bundle_extension bytes]
[4B record_count]
  repeated record_count times:
  [8B seq]
  [32B record_hash]
  [4B canonical_record_len][canonical_record bytes]
  [1B has_value]
    if has_value:
    [32B value_hash]
    [4B value_len][value bytes]
  [4B record_extension_len][record_extension bytes]
[4B inclusion_proof_count]
  repeated inclusion_proof_count times:
  [8B seq]
  [32B leaf_hash]
  [32B checkpoint_hash]
  [4B path_len][path bytes]
  [4B proof_extension_len][proof_extension bytes]
[4B checkpoint_count]
  repeated checkpoint_count times:
  [1B version]
  [4B log_id_len][log_id bytes]
  [8B from_seq]
  [8B to_seq]
  [1B accumulator_kind]
  [32B accumulator_root]
  [1B has_previous_checkpoint_hash]
    if has_previous_checkpoint_hash:
    [32B previous_checkpoint_hash]
  [4B creator_identity_len][creator_identity bytes]
  [1B signature_scheme]
  [64B signature]
  [8B created_at_ms]
  [8B ingested_at_ms]
  [4B checkpoint_extension_len][checkpoint_extension bytes]
```

The append-log MMR builder scans and verifies the stored log prefix through `to_seq`, builds the MMR with absolute leaf indexes (`seq - 1`), carries only the requested `from_seq..to_seq` records, signs one `mmr_sha256_v1` checkpoint, encodes the bundle, and verifies it before returning bytes.

The EXEC proof-bundle exporter uses canonical JSON for transport. Binary fields are lowercase hex:

- `records[].canonical_record_hex` is the exact append-log envelope bytes.
- `records[].record_hash` is `SHA-256(canonical_record_hex bytes)`.
- `inclusion_proofs[].proof_hex` is the `mmr_sha256_v1` proof-byte format below.
- `checkpoint.canonical_record_hex` is the exact checkpoint record bytes whose hash is `checkpoint.checkpoint_hash`.

## MMR Proof Bytes

`mmr_sha256_v1` inclusion proofs use canonical path bytes so bundles can be verified without a live database. The append-log MMR leaf index is `seq - 1`.

All integers are unsigned big-endian:

```text
[7B magic = "WDBMMR1"]
[2B version = 1]
[8B leaf_index]
[8B leaf_count]
[4B peak_index]
[4B path_len]
  repeated path_len times:
  [1B side: 0 = left, 1 = right]
  [32B sibling_hash]
[4B peak_count]
  repeated peak_count times:
  [1B height]
  [32B peak_hash]
```

The verifier rejects unsupported accumulator kinds, malformed proof bytes, `leaf_index != seq - 1`, and inclusion paths that do not reconstruct the signed checkpoint root.

Canonical decoders reject `path_len > 63` and `peak_count > 64` before allocation. These are the maximum structural counts for an MMR over a `u64` leaf count.

## Verification Algorithm

A verifier should:

1. Reject unsupported versions or empty bundles.
2. For `single_event`, require exactly one record. For `range`, require contiguous ascending `seq` values.
3. Recompute every `record_hash` from `canonical_record_bytes`.
4. If values are carried, recompute every `value_hash`.
5. Verify every checkpoint signature using its `creator_identity`.
6. If multiple checkpoints are included in order, verify each `previous_checkpoint_hash` points to the previous checkpoint record hash.
7. Match every record to an inclusion proof with the same `seq` and `leaf_hash`.
8. Match every inclusion proof to a bundled checkpoint by `checkpoint_hash`.
9. Confirm the checkpoint covers the record sequence.
10. Ask the accumulator verifier to validate the inclusion path against the checkpoint root.

The current code slice implements this verifier skeleton in `src/proof/proof_bundle.zig` and the checkpoint signature/hash rules in `src/proof/checkpoint.zig`.

## Golden Vector

The proof-spine test vector appends three deterministic WORM records to log `proof-spine:golden`, uses `SHA-256(full envelope bytes)` as each MMR leaf, signs one checkpoint covering `1..3`, and verifies the resulting range bundle.

| Item | Hex |
| --- | --- |
| Event 1 `event_hash` | `87832c30e5bfea3d6a6493306e5ced774c68c2d5e9d34e14b8d1ff41c9be3da1` |
| Event 2 `event_hash` | `d50efb4e4f5ab725a3eeed61540e124f186e19ac63f722921973fba48f5429b0` |
| Event 3 `event_hash` | `cafe05fb1ac07c1170d1508465c362102b584ecb794c5d609dee20b6b6acca73` |
| MMR root | `4c54ffe73285539577648522f02edd900db8446ec6fbc96db32b2437759e0992` |
| Checkpoint hash | `223a06ecece492e00ab05c342061afe7ce72b8c180028d8acccb42f5480f071c` |
