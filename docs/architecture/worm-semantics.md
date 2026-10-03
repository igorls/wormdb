# WORM Semantics

WORM stands for **Write Once, Read Many**. It's the central design principle behind WormDB and the reason the project exists.

## The Problem

Most databases treat data as mutable by default. You can `UPDATE` a row, overwrite a key, or delete a record at any time. This is convenient for applications, but dangerous for data that should be permanent:

- **Audit logs** — if a bad actor can modify log entries, the audit trail is worthless
- **Financial ledgers** — transactions should be recorded, not rewritten
- **Compliance records** — regulatory frameworks (SOX, HIPAA, SEC Rule 17a-4) often require immutable record retention
- **Sensor and IoT data** — raw telemetry should be write-once to prevent post-hoc manipulation

WormDB enforces immutability at the storage layer. When a key is written with the WORM flag, the server itself refuses to overwrite or delete it. This isn't an application-level convention — it's a server-enforced invariant.

## How It Works

Setting a WORM key looks like a normal `SET` with an added flag:

```bash
bun run apps/bun/src/bin/client.ts SET audit:tx-001 "debit 500 acct:alice" --worm
# → OK
```

After this, any attempt to overwrite the key is rejected:

```bash
bun run apps/bun/src/bin/client.ts SET audit:tx-001 "TAMPERED"
# → ERR: WORM violation: key is immutable
```

Deleting a WORM key is also rejected:

```bash
bun run apps/bun/src/bin/client.ts DEL audit:tx-001
# → ERR: WORM violation: key is immutable
```

Reading works normally — WORM only restricts writes and deletes:

```bash
bun run apps/bun/src/bin/client.ts GET audit:tx-001
# → debit 500 acct:alice
```

## Implementation

In the WormWire binary protocol, WORM is encoded as **bit 0** of the 1-byte flags field in the `SET` payload:

```text
SET payload: [1B flags][4B key_len][key][4B value_len][value]
                 ↑
          bit 0 = WORM flag
```

At the storage layer, each entry has an `is_worm` boolean. When `store.set()` encounters a key that already exists with `is_worm = true`, it returns `error.WormViolation`. The executor translates this into the `ERR: WORM violation: key is immutable` response. The same check applies to `store.delete()`.

::: tip
WORM is per-key, not per-database. You can freely mix mutable and immutable keys in the same WormDB instance. A common pattern is to use key prefixes like `audit:`, `ledger:`, or `log:` for WORM data and plain prefixes for working data.
:::

::: warning
WORM is irreversible and there is no administrative override. Once a key is sealed, it stays sealed for the lifetime of the data file. Design your key naming scheme carefully before committing to WORM.
:::

## Use Cases

### Append-Only Audit Trail

```bash
# Each entry is a unique, immutable event
bun run apps/bun/src/bin/client.ts SET audit:2026-03-02:001 '{"action":"login","user":"alice"}' --worm
bun run apps/bun/src/bin/client.ts SET audit:2026-03-02:002 '{"action":"transfer","amount":500}' --worm
```

### Financial Transaction Ledger

Pair WORM records with the `transfer` procedure — the procedure atomically updates mutable balance keys, while WORM keys record the immutable transaction history:

```bash
# Record the transfer as immutable history
bun run apps/bun/src/bin/client.ts SET txn:00042 "alice→bob:200" --worm
# Execute the actual balance transfer (mutable keys)
bun run apps/bun/src/bin/client.ts EXEC transfer acct:alice acct:bob 200
```

## Vectors And Memory

WORM also applies to vector and memory records. Native vector inserts and `mem_add` default to immutable vector/doc records unless the caller opts out. This is useful for agent memory and embedding provenance: old memories can stay searchable without being silently rewritten by a later ingestion run.

## Replicated WORM Proofs

WORM prevents stored records from being rewritten, but replicated deployments also need compact ways to prove that peers saw the same immutable history. WormDB now stores checkpoint and witness records as WORM data; the remaining replication-proof work is to use Merkle/MMR roots to compare peer histories and repair missing ranges without a full dump when possible.

See [Replication Proofs](/architecture/replication-proofs) for the checkpoint witness and anti-entropy design.
