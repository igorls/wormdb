//! WormDB embedding FFI — a small C ABI over the engine for native apps
//! (iOS/Swift, Android/JNI, or any C caller). Single-node, in-process: no socket
//! server, no clustering. This is Path A from meshguard#102 — the basic engine
//! (KV + WAL + snapshot) embedded directly, with std.crypto (no libsodium).
//!
//! Build: `zig build` produces zig-out/lib/libwormdb_ffi.{dylib,so,a}.
//! Header: ffi/wormdb.h.
//!
//! Memory: values returned by wormdb_get are owned by the library and must be
//! released with wormdb_free. All other buffers are caller-owned.
//!
//! Threading: the store is internally sharded with per-shard locks, so calls
//! from multiple threads are safe. A single Db handle may be shared freely.

const std = @import("std");
const wormdb = @import("wormdb");

const Store = wormdb.storage.Store;
const PersistenceMode = wormdb.core.config.PersistenceMode;

// libc malloc/free — so values handed across the boundary can be released by
// the caller (wormdb_free, or plain free()) without allocator bookkeeping.
const gpa = std.heap.c_allocator;

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// Opaque handle. Owns the store and the path strings the store's config borrows.
pub const Db = struct {
    store: Store,
    wal_path: []u8,
    snapshot_path: []u8,
};

// ─── Result / persistence codes (mirror ffi/wormdb.h) ───
const OK: c_int = 0;
const NOT_FOUND: c_int = 1;
const ERR: c_int = -1;

const PERSIST_FULL: c_int = 0; // WAL on every write + snapshots (durable)
const PERSIST_SNAPSHOT: c_int = 1; // load/save only, no per-write IO
const PERSIST_NONE: c_int = 2; // pure in-memory

/// Open (or create) a database rooted at `dir`. WAL + snapshot live under it.
/// `persistence` is one of WORMDB_PERSIST_*. Returns null on failure.
export fn wormdb_open(dir_ptr: [*:0]const u8, persistence: c_int) ?*Db {
    const dir = std.mem.span(dir_ptr);

    // Ensure the data directory exists (app sandbox dir on mobile).
    std.Io.Dir.cwd().createDirPath(io(), dir) catch {};

    const wal_path = std.fmt.allocPrint(gpa, "{s}/wormdb.wal", .{dir}) catch return null;
    errdefer gpa.free(wal_path);
    const snapshot_path = std.fmt.allocPrint(gpa, "{s}/wormdb.snapshot", .{dir}) catch return null;
    errdefer gpa.free(snapshot_path);

    const mode: PersistenceMode = switch (persistence) {
        PERSIST_FULL => .full,
        PERSIST_SNAPSHOT => .snapshot,
        else => .none,
    };

    const db = gpa.create(Db) catch return null;
    db.* = .{
        .store = Store.init(gpa, .{
            .wal_path = wal_path,
            .snapshot_path = snapshot_path,
            .sync_writes = true,
            .persistence = mode,
        }) catch {
            gpa.destroy(db);
            gpa.free(wal_path);
            gpa.free(snapshot_path);
            return null;
        },
        .wal_path = wal_path,
        .snapshot_path = snapshot_path,
    };

    // Background WAL writer must start only after the store is at its final
    // (heap, non-moving) address — db is heap-allocated, so this is safe.
    if (mode == .full) db.store.startBackgroundTasks() catch {};

    return db;
}

/// Flush, close, and free a database handle. The handle is invalid afterwards.
export fn wormdb_close(db: *Db) void {
    db.store.deinit();
    gpa.free(db.wal_path);
    gpa.free(db.snapshot_path);
    gpa.destroy(db);
}

/// Set key → value (mutable; not WORM). Returns WORMDB_OK or WORMDB_ERR.
export fn wormdb_set(db: *Db, key: [*]const u8, key_len: usize, val: [*]const u8, val_len: usize) c_int {
    db.store.set(key[0..key_len], val[0..val_len], false) catch return ERR;
    return OK;
}

/// Set key → value as a WORM (write-once) entry. Overwriting a WORM key fails.
export fn wormdb_set_worm(db: *Db, key: [*]const u8, key_len: usize, val: [*]const u8, val_len: usize) c_int {
    db.store.set(key[0..key_len], val[0..val_len], true) catch return ERR;
    return OK;
}

/// Get key. On WORMDB_OK, *out_val/*out_len point to a library-owned buffer the
/// caller must release with wormdb_free. WORMDB_NOT_FOUND leaves them null/0.
export fn wormdb_get(db: *Db, key: [*]const u8, key_len: usize, out_val: *?[*]u8, out_len: *usize) c_int {
    const maybe = db.store.getValueDupe(key[0..key_len], gpa) catch return ERR;
    if (maybe) |v| {
        // Caller owns this buffer and releases it via wormdb_free, so handing
        // back a mutable pointer to the freshly-duped bytes is correct.
        out_val.* = @constCast(v.ptr);
        out_len.* = v.len;
        return OK;
    }
    out_val.* = null;
    out_len.* = 0;
    return NOT_FOUND;
}

/// Delete key. Missing keys succeed; deleting a WORM key returns WORMDB_ERR.
export fn wormdb_delete(db: *Db, key: [*]const u8, key_len: usize) c_int {
    db.store.delete(key[0..key_len]) catch return ERR;
    return OK;
}

/// Release a buffer returned by wormdb_get.
export fn wormdb_free(ptr: ?[*]u8, len: usize) void {
    if (ptr) |p| gpa.free(p[0..len]);
}

/// Library version string (static, do not free).
export fn wormdb_version() [*:0]const u8 {
    return "wormdb-ffi 0.1";
}
