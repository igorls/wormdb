# `.wseg` — frozen segment format

The authoritative on-disk spec for the read-only, memory-mapped columnar store WormDB serves from.
All integers are **little-endian**. The file is built offline by an external builder tool and decoded
by the Zig reader (`src/storage/segment.zig`); the record payloads inside each table are opaque to the
engine and are encoded/decoded by the domain package that owns the table. This document is the
contract between the engine reader and any external builder: a change on either side that is not
reflected here — and pinned by the reader's tests — is a bug.

## Why a frozen segment exists

The generic `Store` pays ~130–160 B of fixed overhead per key (an `Entry`, a duplicated key, a value
allocation, a hashmap slot) across three heap allocations. At tens of millions of keys that overhead
alone is many GB. A frozen segment sidesteps it: `u64` keys in one contiguous **sorted index** (binary
search, zero per-entry allocation), values back-to-back in a **blob arena**, and the whole file
`mmap`'d read-only so resident memory is just the working set the OS pages in. There is no write path
in the engine: open, look up, close.

## Container layout

```
Header (40 B):
  magic        char[8]  "WSEG0001"
  version      u32      = 1
  flags        u32
  table_count  u32      ≤ MAX_TABLES (32)
  _pad         u32
  meta_off     u64
  meta_len     u64

Table directory: table_count × 48 B, in any order:
  table_id     u32      opaque id assigned by the builder (see namespace below)
  key_stride   u32
  key_count    u64
  index_off    u64      \
  index_len    u64       |  index_len MUST equal key_count × 20
  blob_off     u64       |
  blob_len     u64      /

Index region (per table): key_count × 20 B, SORTED by key ascending:
  key          u64
  off          u64      offset into THIS table's blob
  len          u32

Blob region (per table): the payloads, concatenated.
```

The reader validates magic, `version == 1`, `table_count ≤ MAX_TABLES`, every region in bounds, and
`index_len == key_count × 20`. It looks values up by binary search over the sorted index.

### Table-id namespace (fail-closed)

`table_id` is **opaque to the engine** — it attaches no meaning and simply indexes `tables[table_id]`.
Serving domains own disjoint id ranges in one shared segment; each domain package documents the range
it claims.

`MAX_TABLES = 32` is the highest addressable id + 1 (ample headroom). A directory entry with
`table_id >= MAX_TABLES` is **rejected** with `SegmentTableIdOutOfRange` — the reader fails CLOSED
rather than silently dropping the table. This guards against the historical `MAX_TABLES = 16`
regression, which silently served empty data for a domain's tables above id 15. Growing the namespace
is a deliberate `version` bump (which the reader rejects until updated), never an out-of-range id at
version 1.

## Record payloads

Everything inside a table's blob is domain-defined. The engine hands back the raw `(off, len)` slice;
the owning domain package encodes and decodes its own records. Two conventions keep those codecs safe
and are strongly recommended for every domain format:

1. **Version bytes.** The container `version` (u32, segment header) is the only sanctioned way to
   evolve the container layout; domain records should likewise begin with their own version byte so a
   writer-side layout change cannot be misdecoded at old offsets.
2. **Fail closed, never silently.** Out-of-range table id → `SegmentTableIdOutOfRange`; a domain
   decoder seeing an unknown record version should return null/error, never decode stale offsets.
3. **Golden tests pin the bytes.** Builders and readers live in different repos; each side should
   assert the exact bytes of a representative record so silent offset drift fails a test on one side
   or the other.
