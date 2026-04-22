//! Built-in VREINDEX procedure — bulk-build a namespace's HNSW index.
//!
//! EXEC vreindex [<namespace>]
//!
//! Walks every `<namespace>*` entry in the store, re-inserts each vector
//! into a fresh HNSW index, and atomically swaps it in for the namespace.
//! Use after:
//!   - Server restart (indexes are in-memory only)
//!   - Replicated data arriving on a peer (SET frames bypass vinsert, so
//!     the peer's index never gets the updates)
//!   - Bulk ingest via raw SET (no vinsert = no HNSW entries)
//!
//! Returns JSON: {"namespace":"vec:","inserted":N,"skipped":S}
//!   inserted — vectors successfully added to the new index
//!   skipped  — entries with invalid bytes, dim mismatch, or internal
//!              insert errors
//!
//! The operation holds the namespace's write-lock for the duration of the
//! rebuild. Concurrent inserts to this namespace block; concurrent searches
//! either see the old index (shared lock races) or wait. For a 1M-vector
//! namespace expect multi-second latency; run during low-traffic windows
//! or as part of startup warmup.

const std = @import("std");
const Ctx = @import("context.zig").Ctx;
const distance = @import("../vector/distance.zig");
const Store = @import("../storage/store.zig").Store;
const IndexModule = @import("../vector/index.zig");

const DEFAULT_NAMESPACE: []const u8 = "vec:";

/// Scan callback state — one per vreindex invocation.
const RebuildCtx = struct {
    ns_idx: *IndexModule.NamespaceIndex,
    expected_dim: usize, // 0 = not yet captured
    now_ms: u64,
    inserted: usize,
    skipped: usize,
    oom: bool,
};

fn onVectorMatch(
    raw_ctx: *anyopaque,
    key: []const u8,
    value: []const u8,
    timestamp: u64,
    is_worm: bool,
) Store.ScanAction {
    _ = is_worm;
    const sc: *RebuildCtx = @ptrCast(@alignCast(raw_ctx));

    const vec = distance.bytesToF32(value) orelse {
        sc.skipped += 1;
        return .cont;
    };

    // Lock dimension on first valid vector; reject mismatches to keep the
    // graph consistent.
    if (sc.expected_dim == 0) {
        sc.expected_dim = vec.len;
    } else if (vec.len != sc.expected_dim) {
        sc.skipped += 1;
        return .cont;
    }

    // Reuse the entry's own timestamp (WORM stability) rather than now_ms,
    // so temporal-decay queries give the same answers before/after rebuild.
    _ = sc.ns_idx.insertLocked(key, vec, timestamp) catch |e| {
        if (e == error.OutOfMemory) {
            sc.oom = true;
            return .stop;
        }
        sc.skipped += 1;
        return .cont;
    };
    sc.inserted += 1;
    return .cont;
}

pub fn execute(ctx: *Ctx) anyerror!Ctx.Result {
    const namespace = ctx.arg(0) orelse DEFAULT_NAMESPACE;

    const reg = ctx.vector_registry orelse
        return ctx.err("vreindex: vector registry not enabled on this server");

    const ns_idx = reg.getOrCreate(namespace) catch |e| {
        return ctx.err(ctx.fmt("vreindex: getOrCreate failed: {s}", .{@errorName(e)}));
    };

    // Take the write lock for the rebuild. Inserts wait; searches that
    // grab the shared lock before us see the old graph (if any).
    ns_idx.lock.lock();
    defer ns_idx.lock.unlock();

    ns_idx.clearLocked();

    var rc = RebuildCtx{
        .ns_idx = ns_idx,
        .expected_dim = 0,
        .now_ms = ctx.timestamp(),
        .inserted = 0,
        .skipped = 0,
        .oom = false,
    };

    // scanCallback locks each shard independently; it must not run while
    // the procedure holds any shard locks. vreindex holds only the
    // ns_idx lock (a different class) — safe.
    ctx.scanCallback(namespace, @ptrCast(&rc), onVectorMatch);

    if (rc.oom) return ctx.err("vreindex: out of memory during rebuild");

    var json: std.ArrayListUnmanaged(u8) = .empty;
    try json.appendSlice(ctx.allocator, "{\"namespace\":\"");
    try json.appendSlice(ctx.allocator, namespace);
    try json.appendSlice(ctx.allocator, "\",\"inserted\":");
    var buf: [32]u8 = undefined;
    var s = std.fmt.bufPrint(&buf, "{d}", .{rc.inserted}) catch "0";
    try json.appendSlice(ctx.allocator, s);
    try json.appendSlice(ctx.allocator, ",\"skipped\":");
    s = std.fmt.bufPrint(&buf, "{d}", .{rc.skipped}) catch "0";
    try json.appendSlice(ctx.allocator, s);
    try json.append(ctx.allocator, '}');

    return ctx.value(try json.toOwnedSlice(ctx.allocator));
}
