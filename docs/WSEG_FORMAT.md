# `.wseg` — frozen segment format

The authoritative on-disk spec for the read-only, memory-mapped columnar store WormDB serves from.
All integers are **little-endian**. The file is built offline by the Rust writer
(hyperion-tools `crates/wseg-build`) and decoded by the Zig reader (`src/storage/segment.zig` plus the
per-domain record codecs). This document is the contract between those two repos: a change on either
side that is not reflected here — and pinned by the golden tests below — is a bug.

## Why a frozen segment exists

The generic `Store` pays ~130–160 B of fixed overhead per key (an `Entry`, a duplicated key, a value
allocation, a hashmap slot) across three heap allocations. At WAX scale (tens of millions of accounts)
that overhead alone is many GB. A frozen segment sidesteps it: `u64` keys in one contiguous **sorted
index** (binary search, zero per-entry allocation), values back-to-back in a **blob arena**, and the
whole file `mmap`'d read-only so resident memory is just the working set the OS pages in. There is no
write path in the engine: open, look up, close.

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
Serving layers own disjoint id ranges in one shared segment:

| Range | Owner | Defined in |
|------:|-------|-----------|
| `0..=10`  | Light-API | `wormdb-domain-lightapi/src/tables.zig` |
| `11..=21` | AtomicAssets | `wormdb-domain-atomicassets/src/binfmt.zig` (`TableId`) |

`MAX_TABLES = 32` is the highest addressable id + 1 (ample headroom). A directory entry with
`table_id >= MAX_TABLES` is **rejected** with `SegmentTableIdOutOfRange` — the reader fails CLOSED
rather than silently dropping the table. This guards against the `MAX_TABLES = 16` regression, which
silently served empty data for AtomicAssets ids `11..=21`. Growing the namespace is a deliberate
`version` bump (which the reader rejects until updated), never an out-of-range id at version 1.

## AtomicAssets records (table ids 11..=21)

Writer: `aa_binfmt.rs`. Reader: `wormdb-domain-atomicassets/src/binfmt.zig`. Every record begins with
a 1-byte `ASSET_VERSION = 1`. The reader checks it and returns `null` (fail-closed) on any other value,
so a writer-side layout change at the old version cannot be misdecoded at the old offsets.

### Asset forward record (`encode_asset` / `decodeAsset`)

```
version        u8   = 1
owner          u64  (Antelope name)
collection     u64  (Antelope name)
schema         u64  (Antelope name)
template_id    i32  (-1 = no template)
block_num      u32
template_mint  u32  (materialized mint ordinal within the template)
immutable      attrs  (non-empty only for assets without a template)
mutable        attrs
```

Core fields are fixed-width; the first 37 bytes (`1 + 8+8+8 + 4+4+4`) are the `AssetCore` the reader
decodes. `attrs` = `u16 count` then `count × { u8 field_idx, u16 len, len bytes UTF-8 }`.

### Template forward record (`encode_template` / `decode_template`)

```
version        u8   = 1
template_id    i32
schema         u64
immutable      attrs
```

### Hybrid posting list (`encode_posting_hybrid` / `postingHead`)

A posting is RAW when small (≤ `RAW_MAX = 512` ids), else ROARING with a small raw "head" so page-1
(newest-first) reads need no roaring decoder:

```
format     u8
full_count u32
  format 0 RAW     : u64 × full_count          (sorted ascending; the TAIL holds the largest)
  format 1 ROARING : u32 head_n, u64 × head_n   (top-K, DESCENDING)
                     then roaring bytes for the full set
```

`postingHead` emits the newest ids descending: it walks the RAW tail backwards, or reads the ROARING
head directly. `postingLen` returns `full_count`.

## Cross-repo contract — what keeps the two sides in lockstep

1. **Version bytes.** The container `version` (u32, segment header) and per-record `ASSET_VERSION` (u8)
   are the only sanctioned way to evolve a layout. Bump on any field reorder/resize; the reader
   rejects the new value until it is taught the new layout.
2. **Fail closed, never silently.** Out-of-range table id → `SegmentTableIdOutOfRange`; unknown record
   version → `null`. Neither path decodes stale offsets.
3. **Golden tests pin the bytes.** The exact bytes of
   `encode_asset(owner=1, collection=2, schema=3, template_id=7, block_num=100, template_mint=42, &[], &[])`
   are asserted on BOTH sides of the seam:
   - writer: `golden_asset_record` in `aa_binfmt.rs`
   - reader: `"golden asset record decodes byte-for-byte (cross-repo contract vs aa_binfmt.rs)"` in
     `wormdb-domain-atomicassets/src/binfmt.zig`

   A silent offset drift on either side (without a version bump) fails one of the two tests. Keep the
   two golden arrays identical; if you change the record layout, update both and bump `ASSET_VERSION`.
