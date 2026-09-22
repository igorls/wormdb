/* WormDB embedding FFI — single-node in-process key/value store.
 *
 * Path A of meshguard#102: the engine (KV + WAL + snapshot, std.crypto, no
 * libsodium) linked directly into a native app. No socket server, no cluster.
 *
 * Link against libwormdb_ffi (.dylib/.so, or .a for iOS).
 */
#ifndef WORMDB_H
#define WORMDB_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Result codes. */
#define WORMDB_OK         0
#define WORMDB_NOT_FOUND  1
#define WORMDB_PROC_ERR   2
#define WORMDB_ERR       (-1)

#define WORMDB_HASH_LEN       32
#define WORMDB_PUBLIC_KEY_LEN 32
#define WORMDB_SECRET_KEY_LEN 64

/* Persistence modes for wormdb_open. */
#define WORMDB_PERSIST_FULL      0  /* WAL every write + snapshots (durable)   */
#define WORMDB_PERSIST_SNAPSHOT  1  /* load/save only, no per-write IO         */
#define WORMDB_PERSIST_NONE      2  /* pure in-memory, lost on close           */

/* Proof bundle kinds. */
#define WORMDB_PROOF_BUNDLE_SINGLE_EVENT 1
#define WORMDB_PROOF_BUNDLE_RANGE        2

/* Accumulator kinds. */
#define WORMDB_ACCUMULATOR_OPAQUE_ROOT     0
#define WORMDB_ACCUMULATOR_MERKLE_SHA256_1 1
#define WORMDB_ACCUMULATOR_MMR_SHA256_1    2

/* Opaque database handle. */
typedef struct wormdb_Db wormdb_Db;

/* Entry receipt metadata copied out of the store.
 *
 * timestamp_ms is WormDB's local ingest/write timestamp in milliseconds since
 * the Unix epoch. value_sha256 is SHA-256(value) for the current entry bytes.
 */
typedef struct wormdb_EntryMeta {
    uint64_t timestamp_ms;
    int is_worm;
    size_t value_len;
    unsigned char value_sha256[WORMDB_HASH_LEN];
} wormdb_EntryMeta;

typedef struct wormdb_AppendReceipt {
    uint64_t seq;
    uint64_t ingest_time_ms;
    unsigned char prev_event_hash[WORMDB_HASH_LEN];
    unsigned char payload_hash[WORMDB_HASH_LEN];
    unsigned char event_hash[WORMDB_HASH_LEN];
    unsigned char record_hash[WORMDB_HASH_LEN];
} wormdb_AppendReceipt;

typedef struct wormdb_AppendLogReport {
    size_t count;
    uint64_t last_seq;
    unsigned char head_hash[WORMDB_HASH_LEN];
} wormdb_AppendLogReport;

typedef struct wormdb_ProofBundleInfo {
    int kind;
    uint64_t from_seq;
    uint64_t to_seq;
    size_t record_count;
    size_t checkpoint_count;
    int accumulator_kind;
    unsigned char accumulator_root[WORMDB_HASH_LEN];
    unsigned char checkpoint_hash[WORMDB_HASH_LEN];
} wormdb_ProofBundleInfo;

typedef struct wormdb_ExecArg {
    const unsigned char *ptr;
    size_t len;
} wormdb_ExecArg;

/* Prefix-scan callback.
 *
 * key/value pointers and meta are borrowed and valid only until the callback
 * returns. Return 0 to continue, non-zero to stop early. Stopping early is not
 * treated as an error; wormdb_scan_prefix still returns WORMDB_OK.
 */
typedef int (*wormdb_scan_callback)(
    void *ctx,
    const unsigned char *key, size_t key_len,
    const unsigned char *value, size_t value_len,
    const wormdb_EntryMeta *meta);

/* Open/create a DB rooted at `dir` (WAL + snapshot live under it). NULL on error. */
wormdb_Db *wormdb_open(const char *dir, int persistence);

/* Open/create a DB rooted at `dir` with synchronous per-write WAL sync (no background writer).
 * Guarantees immediate fsync on all WAL-backed writes (wormdb_set, append_log).
 * An I/O error has an uncertain outcome: a failed write may replay after reopening.
 * After a direct WAL write/sync error, further WAL-backed writes are rejected
 * until close/reopen and recovery. Reconcile recovered state before retrying.
 * Does not make in-memory unsafe procedure mutations durable. NULL on error. */
wormdb_Db *wormdb_open_sync(const char *dir);

/* Flush, close, and free a handle. */
void wormdb_close(wormdb_Db *db);

/* Set key -> value (mutable). Returns WORMDB_OK / WORMDB_ERR. */
int wormdb_set(wormdb_Db *db, const unsigned char *key, size_t key_len,
               const unsigned char *val, size_t val_len);

/* Set key -> value as write-once (WORM). Overwrite fails with WORMDB_ERR. */
int wormdb_set_worm(wormdb_Db *db, const unsigned char *key, size_t key_len,
                    const unsigned char *val, size_t val_len);

/* Get key. On WORMDB_OK, out_val and out_len reference a library-owned buffer
 * the caller must release with wormdb_free. WORMDB_NOT_FOUND leaves them NULL/0. */
int wormdb_get(wormdb_Db *db, const unsigned char *key, size_t key_len,
               unsigned char **out_val, size_t *out_len);

/* Get entry receipt metadata without copying the value. On WORMDB_OK, out_meta
 * receives timestamp_ms, is_worm, value_len, and SHA-256(value).
 * WORMDB_NOT_FOUND leaves out_meta unchanged. */
int wormdb_get_meta(wormdb_Db *db, const unsigned char *key, size_t key_len,
                    wormdb_EntryMeta *out_meta);

/* Scan keys matching prefix in lexicographic key order.
 *
 * limit == 0 means no limit. A positive limit returns the lexicographic tail,
 * matching the existing Store.scanPrefix behavior used by EXEC scan.
 *
 * The callback receives borrowed key/value/meta pointers; copy anything that
 * must outlive the callback. Returning non-zero stops iteration early.
 */
int wormdb_scan_prefix(wormdb_Db *db,
                       const unsigned char *prefix, size_t prefix_len,
                       size_t limit,
                       void *ctx,
                       wormdb_scan_callback callback);

/* Append a payload to a named WORM append log. attachment_hashes is optional
 * contiguous SHA-256 hashes: attachment_hash_count * WORMDB_HASH_LEN bytes.
 * ingest_time_ms == 0 lets WormDB assign the local receipt time.
 * out_receipt may be NULL when the caller does not need receipt metadata.
 */
int wormdb_append_log(wormdb_Db *db,
                      const unsigned char *log_id, size_t log_id_len,
                      const unsigned char *payload, size_t payload_len,
                      const unsigned char *attachment_hashes,
                      size_t attachment_hash_count,
                      uint64_t ingest_time_ms,
                      wormdb_AppendReceipt *out_receipt);

/* Verify the stored WORM append-log chain for a log id.
 * out_report may be NULL when the caller only needs success/failure.
 */
int wormdb_append_log_verify(wormdb_Db *db,
                             const unsigned char *log_id, size_t log_id_len,
                             wormdb_AppendLogReport *out_report);

/* Build a self-contained encoded MMR proof bundle for append-log records.
 *
 * public_key is 32 raw Ed25519 public-key bytes; secret_key is the 64-byte
 * Ed25519 secret key representation expected by WormDB. created_at_ms or
 * ingested_at_ms set to 0 are filled from WormDB's local clock.
 *
 * On WORMDB_OK, out_bundle/out_bundle_len receives a library-owned byte buffer
 * that must be released with wormdb_free.
 * out_info may be NULL when the caller does not need bundle metadata.
 */
int wormdb_proof_build_mmr_bundle(
    wormdb_Db *db,
    const unsigned char *log_id, size_t log_id_len,
    uint64_t from_seq, uint64_t to_seq,
    const unsigned char public_key[WORMDB_PUBLIC_KEY_LEN],
    const unsigned char secret_key[WORMDB_SECRET_KEY_LEN],
    uint64_t created_at_ms,
    uint64_t ingested_at_ms,
    const unsigned char *checkpoint_extension, size_t checkpoint_extension_len,
    const unsigned char *bundle_extension, size_t bundle_extension_len,
    unsigned char **out_bundle, size_t *out_bundle_len,
    wormdb_ProofBundleInfo *out_info);

/* Verify an encoded append-log MMR proof bundle without a database.
 * out_info may be NULL when the caller only needs success/failure.
 */
int wormdb_proof_verify_bundle(const unsigned char *bundle, size_t bundle_len,
                               wormdb_ProofBundleInfo *out_info);

/* Verify canonical MMR proof path bytes against a leaf hash and expected root.
 * seq is the append-log sequence, so the proof leaf index must equal seq - 1.
 */
int wormdb_mmr_proof_verify(const unsigned char *proof_bytes, size_t proof_len,
                            uint64_t seq,
                            const unsigned char leaf_hash[WORMDB_HASH_LEN],
                            const unsigned char expected_root[WORMDB_HASH_LEN]);

/* Execute a stored procedure in-process, without starting a socket server.
 *
 * args is an array of argc borrowed byte slices. On WORMDB_OK with a value,
 * out_val/out_len receives a library-owned byte buffer that must be released
 * with wormdb_free. WORMDB_OK with no value leaves out_val NULL and out_len 0.
 *
 * On WORMDB_PROC_ERR, out_val/out_len contains the procedure error string and
 * must also be released with wormdb_free. WORMDB_ERR means FFI misuse or an
 * internal failure before a procedure response was produced.
 */
int wormdb_exec(wormdb_Db *db,
                const unsigned char *name, size_t name_len,
                const wormdb_ExecArg *args, size_t argc,
                unsigned char **out_val, size_t *out_len);

/* Delete key (missing keys succeed; WORM keys return WORMDB_ERR). */
int wormdb_delete(wormdb_Db *db, const unsigned char *key, size_t key_len);

/* Release a buffer returned by wormdb_get, wormdb_exec, or proof builders. */
void wormdb_free(unsigned char *ptr, size_t len);

/* Static version string (do not free). */
const char *wormdb_version(void);

#ifdef __cplusplus
}
#endif

#endif /* WORMDB_H */
