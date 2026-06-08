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
#define WORMDB_ERR       (-1)

/* Persistence modes for wormdb_open. */
#define WORMDB_PERSIST_FULL      0  /* WAL every write + snapshots (durable)   */
#define WORMDB_PERSIST_SNAPSHOT  1  /* load/save only, no per-write IO         */
#define WORMDB_PERSIST_NONE      2  /* pure in-memory, lost on close           */

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
    unsigned char value_sha256[32];
} wormdb_EntryMeta;

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

/* Delete key (missing keys succeed; WORM keys return WORMDB_ERR). */
int wormdb_delete(wormdb_Db *db, const unsigned char *key, size_t key_len);

/* Release a buffer returned by wormdb_get. */
void wormdb_free(unsigned char *ptr, size_t len);

/* Static version string (do not free). */
const char *wormdb_version(void);

#ifdef __cplusplus
}
#endif

#endif /* WORMDB_H */
