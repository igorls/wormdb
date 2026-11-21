//! Built-in VREINDEX procedure — bulk-build a namespace's HNSW index.
//!
//! EXEC vreindex [<namespace>] [<metric>]
//!
//! - namespace: prefix to rebuild (default: "vec:")
//! - metric:    override the index metric ("cosine" | "dot" | "l2").
//!              Optional. When omitted, reuses the existing namespace's
//!              metric if an index already exists; otherwise defaults to
//!              cosine. An existing index's metric can't be changed via
//!              vreindex — drop it first with `EXEC vnsdrop <namespace>`.
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
const Metric = @import("../vector/metric.zig").Metric;

const DEFAULT_NAMESPACE: []const u8 = "vec:";

const EntryMeta = struct {
    key_off: usize,
    key_len: usize,
    vec_off: usize,
    timestamp: u64,
};

/// Phase 1 scan state: copies valid vector entries out of Store shards with NO
/// `NamespaceIndex` lock held (prevents AB-BA deadlock vs `writeSnapshot` and
/// eliminates 40–200ms per-shard stalls during HNSW construction).
const CollectCtx = struct {
    allocator: std.mem.Allocator,
    keys_blob: std.ArrayListUnmanaged(u8) = .empty,
    vecs_blob: std.ArrayListUnmanaged(f32) = .empty,
    entries: std.ArrayListUnmanaged(EntryMeta) = .empty,
    expected_dim: usize = 0,
    skipped: usize = 0,
    oom: bool = false,

    fn deinit(self: *CollectCtx) void {
        self.keys_blob.deinit(self.allocator);
        self.vecs_blob.deinit(self.allocator);
        self.entries.deinit(self.allocator);
    }
};

fn onVectorMatch(
    raw_ctx: *anyopaque,
    key: []const u8,
    value: []const u8,
    timestamp: u64,
    is_worm: bool,
) Store.ScanAction {
    _ = is_worm;
    const cc: *CollectCtx = @ptrCast(@alignCast(raw_ctx));

    const vec = distance.bytesToF32(value) orelse {
        cc.skipped += 1;
        return .cont;
    };

    // Lock dimension on first valid vector; reject mismatches to keep the
    // graph consistent.
    if (cc.expected_dim == 0) {
        cc.expected_dim = vec.len;
    } else if (vec.len != cc.expected_dim) {
        cc.skipped += 1;
        return .cont;
    }

    const key_off = cc.keys_blob.items.len;
    cc.keys_blob.appendSlice(cc.allocator, key) catch {
        cc.oom = true;
        return .stop;
    };
    const vec_off = cc.vecs_blob.items.len;
    const dst = cc.vecs_blob.addManyAsSlice(cc.allocator, vec.len) catch {
        cc.oom = true;
        return .stop;
    };
    @memcpy(std.mem.sliceAsBytes(dst), value);

    cc.entries.append(cc.allocator, .{
        .key_off = key_off,
        .key_len = key.len,
        .vec_off = vec_off,
        .timestamp = timestamp,
    }) catch {
        cc.oom = true;
        return .stop;
    };
    return .cont;
}

pub fn execute(ctx: *Ctx) anyerror!Ctx.Result {
    const namespace = ctx.arg(0) orelse DEFAULT_NAMESPACE;

    // Rebuilding the serving index for a namespace is a write over that
    // namespace (it replaces the graph every reader sees).
    try ctx.requirePrefix(namespace, .write);

    const reg = ctx.vector_registry orelse
        return ctx.err("vreindex: vector registry not enabled on this server");

    // Determine the metric: explicit arg > existing index's metric > cosine.
    // Explicit arg is only honored when the namespace is new OR already
    // matches; metric mutation requires a prior vnsdrop.
    const explicit_metric: ?Metric = if (ctx.arg(1)) |s|
        Metric.fromStr(s) orelse return ctx.err("vreindex: unknown metric (use cosine|dot|l2)")
    else
        null;

    const existing_metric: ?Metric = if (reg.get(namespace)) |idx| idx.metric else null;

    const effective_metric: Metric = explicit_metric orelse existing_metric orelse .cosine;

    const ns_idx = reg.getOrCreate(namespace, effective_metric) catch |e| {
        return ctx.err(ctx.fmt("vreindex: getOrCreate failed: {s}", .{@errorName(e)}));
    };

    // ── Phase 1: collect valid vectors from Store with NO ns_idx lock held ──
    var cc = CollectCtx{ .allocator = ctx.allocator };
    defer cc.deinit();
    ctx.scanCallback(namespace, @ptrCast(&cc), onVectorMatch);
    if (cc.oom) return ctx.err("vreindex: out of memory during scan");

    // ── Phase 2: build fresh HNSW + slabs completely off-lock ──────────────
    ns_idx.lock.lockShared();
    const hnsw_params = ns_idx.hnsw.params;
    const rq_handle = ns_idx.acquireRabitqHandleLocked();
    ns_idx.lock.unlockShared();
    defer if (rq_handle) |h| h.release();

    const built_for_params: ?*const @import("../vector/rabitq.zig").RabitqParams =
        if (rq_handle) |h| h.params else null;

    var fresh = IndexModule.NamespaceIndex.init(ns_idx.allocator, hnsw_params, ns_idx.metric);
    defer {
        // Borrowed pointer only (owned by `rq_handle`, never by `fresh`).
        fresh.rabitq_params = null;
        fresh.deinit();
    }
    if (rq_handle) |h| {
        fresh.rabitq_params = h.params;
        fresh.bq_slab.synced = false;
        fresh.rq_slab.synced = true;
    }

    if (cc.entries.items.len > 0) {
        fresh.reserveAdditionalLocked(cc.entries.items.len) catch {
            return ctx.err("vreindex: out of memory during rebuild");
        };
    }

    var inserted: usize = 0;
    var skipped: usize = cc.skipped;
    const dim = cc.expected_dim;
    for (cc.entries.items) |entry| {
        const key = cc.keys_blob.items[entry.key_off..][0..entry.key_len];
        const vec: []align(1) const f32 = cc.vecs_blob.items[entry.vec_off..][0..dim];
        _ = fresh.insertLocked(key, vec, entry.timestamp) catch |e| {
            if (e == error.OutOfMemory) {
                return ctx.err("vreindex: out of memory during rebuild");
            }
            skipped += 1;
            continue;
        };
        inserted += 1;
    }
    fresh.complete_with_store = (skipped == 0);

    // ── Phase 3: <1µs atomic swap under exclusive lock; old graph freed off-lock ──
    {
        ns_idx.lock.lock();
        defer ns_idx.lock.unlock();
        ns_idx.swapRebuiltLocked(&fresh, built_for_params);
    }

    var json: std.ArrayListUnmanaged(u8) = .empty;
    errdefer json.deinit(ctx.allocator);
    try json.ensureTotalCapacity(ctx.allocator, namespace.len + 64);
    try json.appendSlice(ctx.allocator, "{\"namespace\":\"");
    try json.appendSlice(ctx.allocator, namespace);
    try json.appendSlice(ctx.allocator, "\",\"inserted\":");
    var buf: [32]u8 = undefined;
    var s = std.fmt.bufPrint(&buf, "{d}", .{inserted}) catch "0";
    try json.appendSlice(ctx.allocator, s);
    try json.appendSlice(ctx.allocator, ",\"skipped\":");
    s = std.fmt.bufPrint(&buf, "{d}", .{skipped}) catch "0";
    try json.appendSlice(ctx.allocator, s);
    try json.append(ctx.allocator, '}');

    return ctx.valueOwned(try json.toOwnedSlice(ctx.allocator));
}

test "vreindex: off-lock rebuild reclaims tombstones with zero leaks" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var store = try Store.init(alloc, .{ .persistence = .none });
    defer store.deinit();
    var reg = IndexModule.NamespaceRegistry.init(alloc, .{ .m = 4, .ef_construction = 32 });
    defer reg.deinit();
    store.vector_registry = &reg;

    const v1 = [_]f32{ 1, 0, 0, 0 };
    const v2 = [_]f32{ 0, 1, 0, 0 };
    const v3 = [_]f32{ 0, 0, 1, 0 };
    try store.set("vec:r:1", std.mem.sliceAsBytes(&v1), false);
    try store.set("vec:r:2", std.mem.sliceAsBytes(&v2), false);
    try store.set("vec:r:3", std.mem.sliceAsBytes(&v3), false);

    // Seed index with a tombstoned node first so swapRebuiltLocked frees non-empty old graph.
    const idx = try reg.getOrCreate("vec:r:", .cosine);
    {
        idx.lock.lock();
        defer idx.lock.unlock();
        _ = try idx.insertLocked("vec:r:stale", &v1, 1);
        _ = idx.markTombstoneLocked("vec:r:stale");
        idx.markIncompleteLocked();
    }

    const args = [_][]const u8{"vec:r:"};
    var ctx = Ctx.init(&store, &args, alloc, null, null, null, &reg);
    defer ctx.deinit();

    const res = try execute(&ctx);
    defer if (res == .value) if (res.value) |v| alloc.free(v);
    try testing.expect(res == .value);
    const json = res.value.?;
    try testing.expect(std.mem.indexOf(u8, json, "\"inserted\":3") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"skipped\":0") != null);

    idx.lock.lockShared();
    defer idx.lock.unlockShared();
    try testing.expectEqual(@as(usize, 3), idx.len());
    try testing.expectEqual(@as(usize, 0), idx.tombstone_count);
    try testing.expect(idx.complete_with_store);
    try testing.expect(idx.canUseBqSlabLocked(4));
    try testing.expect(idx.canUseExactSlabLocked(4, .cosine));
}
