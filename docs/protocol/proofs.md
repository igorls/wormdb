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

The proof module treats `path_bytes` as opaque. Worker C's accumulator implementation owns Merkle/MMR path codecs and inclusion math. The verifier callback receives the accumulator kind, root, leaf hash, sequence number, and path bytes.

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
