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
