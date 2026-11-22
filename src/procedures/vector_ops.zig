//! Shared "apply" helpers for vector writes.
//!
//! Three entry points funnel through the helpers here:
//!   1. EXEC vinsert / vdelete procedures (client-originated, replicate=true)
//!   2. Client-originated wire VINSERT / VDELETE frames via the executor
//!      (also replicate=true)
//!   3. Peer-received VINSERT / VDELETE frames via the replication connection
//!      (replicate=false — anti-echo boundary; the frame itself is the
//!      already-replicated instance, we just apply it locally)
//!
//! Each helper owns the full local-work sequence: store write → BQ hash
//! write → HNSW insert/tombstone → event emission → optional cluster
//! replication. Failures are logged and swallowed where appropriate so
//! replication is best-effort (matches the existing SET/DEL path).

const std = @import("std");
const Store = @import("../storage/store.zig").Store;
/// See context.zig: an optional pointer only, stubbed on a narrow-atomics target.
const Cluster = if (@import("../core/compat.zig").wasm_target) @import("../core/compat.zig").ClusterStub else @import("../cluster/mod.zig").Cluster;
const EventBus = @import("../event/mod.zig").EventBus;
const index_mod = @import("../vector/index.zig");
const NamespaceRegistry = index_mod.NamespaceRegistry;
const NamespaceIndex = index_mod.NamespaceIndex;
const distance = @import("../vector/distance.zig");
const rabitq = @import("../vector/rabitq.zig");
const Metric = @import("../vector/metric.zig").Metric;
const core = @import("../core/mod.zig");
const VEC_NS_META_PREFIX: []const u8 = "__meta:vecns:";

/// Format `"<prefix><suffix>"` into `stack_buf` when it fits, otherwise allocate.
fn concatInto(
    allocator: std.mem.Allocator,
    prefix: []const u8,
    suffix: []const u8,
    stack_buf: []u8,
    heap_out: *?[]u8,
) ![]const u8 {
    heap_out.* = null;
    const total = prefix.len + suffix.len;
    const dst: []u8 = if (total <= stack_buf.len)
        stack_buf[0..total]
    else blk: {
        const b = try allocator.alloc(u8, total);
        heap_out.* = b;
        break :blk b;
    };
    @memcpy(dst[0..prefix.len], prefix);
    @memcpy(dst[prefix.len..total], suffix);
    return dst;
}

/// Encode a vector's BQ companion using optional retained RaBitQ params (outside
/// any `NamespaceIndex` lock) into reusable caller scratch buffers.
fn encodeBqWithHandle(
    allocator: std.mem.Allocator,
    vec_f32: []align(1) const f32,
    metric: Metric,
    params_opt: ?*const rabitq.RabitqParams,
    bq_stack: []u8,
    bq_heap: *?[]u8,
    res_buf: *std.ArrayListUnmanaged(f32),
    rot_buf: *std.ArrayListUnmanaged(f32),
    norm_buf: *std.ArrayListUnmanaged(f32),
) ![]const u8 {
    bq_heap.* = null;
    const dim = vec_f32.len;
    if (params_opt) |p| {
        if (p.dim == dim) {
            const needed = rabitq.encodedSize(dim);
            const out: []u8 = if (needed <= bq_stack.len)
                bq_stack[0..needed]
            else blk: {
                const b = try allocator.alloc(u8, needed);
                bq_heap.* = b;
                break :blk b;
            };
            errdefer if (bq_heap.*) |b| {
                allocator.free(b);
                bq_heap.* = null;
            };

            var res_stack: [1536]f32 = undefined;
            var rot_stack: [1536]f32 = undefined;
            var norm_stack: [1536]f32 = undefined;

            const residual: []f32 = if (dim <= res_stack.len)
                res_stack[0..dim]
            else blk: {
                try res_buf.resize(allocator, dim);
                break :blk res_buf.items;
            };
            const rotated: []f32 = if (dim <= rot_stack.len)
                rot_stack[0..dim]
            else blk: {
                try rot_buf.resize(allocator, dim);
                break :blk rot_buf.items;
            };
            const encode_input: []align(1) const f32 = if (metric == .cosine) blk: {
                const nb: []f32 = if (dim <= norm_stack.len)
                    norm_stack[0..dim]
                else blk2: {
                    try norm_buf.resize(allocator, dim);
                    break :blk2 norm_buf.items;
                };
                _ = rabitq.normalizeInto(vec_f32, nb);
                break :blk @ptrCast(nb);
            } else vec_f32;

            const enc = rabitq.encode(
                encode_input,
                p,
                residual,
                rotated,
                out[0..rabitq.codeBytes(dim)],
            );
            rabitq.serialize(enc, out);
            return out;
        }
    }
    const needed = distance.binaryQuantizedSize(dim);
    const out: []u8 = if (needed <= bq_stack.len)
        bq_stack[0..needed]
    else blk: {
        const b = try allocator.alloc(u8, needed);
        bq_heap.* = b;
        break :blk b;
    };
    distance.binaryQuantize(vec_f32, out);
    return out;
}

pub const VectorOpError = error{
    InvalidVectorBytes,
    KeyMissingNamespace,
    OutOfMemory,
    IoError,
    WormViolation,
    /// The vector's length (in f32 units) differs from the dimension
    /// frozen on the namespace's first insert. Checked BEFORE the store
    /// write so a WORM-mode mismatch can't become a permanent ghost entry.
    DimensionMismatch,
};

/// Parameters for `applyVinsert`. Matches Command.VinsertParams's shape
/// but uses the typed `Metric` enum rather than the wire string.
pub const VinsertArgs = struct {
    key: []const u8,
    vector: []const u8, // raw bytes; len must be multiple of 4
    worm: bool,
    namespace: []const u8,
    metric: Metric,
    timestamp: u64,
    /// If true and cluster is non-null, emit VINSERT frame to peers after
    /// local apply succeeds. False for peer-received frames to break the
    /// replication loop.
    replicate: bool,
    /// Opt-in: if true AND the namespace is already async OR this is the
    /// first VINSERT to the namespace, hand the HNSW build to the background
    /// worker. Store + BQ writes still complete synchronously.
    is_async: bool = false,
};

/// A wire vector key must live under its declared namespace. Enforced at the procedure
/// boundary (independent of token capabilities) so a key can never be written/deleted outside
/// its namespace — including on the peer-replicated path. Empty namespace ⇒ rejected.
fn keyBelongsToNamespace(key: []const u8, namespace: []const u8) bool {
    return namespace.len > 0 and std.mem.startsWith(u8, key, namespace);
}

fn persistNamespaceConfig(
    store: *Store,
    allocator: std.mem.Allocator,
    ns_idx_opt: ?*NamespaceIndex,
    namespace: []const u8,
    metric: Metric,
    timestamp: u64,
) bool {
    if (ns_idx_opt) |idx| {
        if (idx.config_persisted.load(.acquire)) return true;
    }

    var key_stack: [256]u8 = undefined;
    var key_heap: ?[]u8 = null;
    defer if (key_heap) |b| allocator.free(b);
    const key = concatInto(allocator, VEC_NS_META_PREFIX, namespace, &key_stack, &key_heap) catch return false;

    if (store.exists(key)) {
        if (ns_idx_opt) |idx| idx.config_persisted.store(true, .release);
        return true;
    }

    var val_stack: [128]u8 = undefined;
    const value = std.fmt.bufPrint(
        &val_stack,
        "{{\"metric\":\"{s}\",\"created_at\":{d}}}",
        .{ metric.name(), timestamp },
    ) catch return false;

    store.setWithTimestampNoVectorSync(key, value, false, timestamp) catch |err| {
        std.log.warn("persistNamespaceConfig: '{s}': {s}", .{ namespace, @errorName(err) });
        return false;
    };
    if (ns_idx_opt) |idx| idx.config_persisted.store(true, .release);
    return true;
}

/// Apply a VINSERT locally: write vec + BQ to the store, update HNSW,
/// emit event, optionally replicate. Metric mismatches on the registry
/// are logged and skipped (store + BQ still succeed — peers remain
/// consistent on data; only the HNSW graph stays as-is).
pub fn applyVinsert(
    store: *Store,
    cluster: ?*Cluster,
    event_bus: ?*EventBus,
    registry: ?*NamespaceRegistry,
    allocator: std.mem.Allocator,
    args: VinsertArgs,
) !void {
    // ── Validate ─────────────────────────────────────────────────
    if (args.vector.len == 0 or args.vector.len % 4 != 0)
        return error.InvalidVectorBytes;
    if (!keyBelongsToNamespace(args.key, args.namespace))
        return error.KeyMissingNamespace;

    const vec_f32 = distance.bytesToF32(args.vector).?; // already validated
    const incoming_dim = vec_f32.len;

    // ── Single registry lookup + single shared lock for dim pre-check & BQ encode ──
    const existing_idx: ?*NamespaceIndex = if (registry) |reg| reg.get(args.namespace) else null;
    const had_preexisting = existing_idx == null and registry != null and store.countPrefix(args.namespace) > 0;

    var bq_stack: [256]u8 = undefined;
    var bq_heap: ?[]u8 = null;
    defer if (bq_heap) |b| allocator.free(b);
    var bq_slice: []const u8 = undefined;

    if (existing_idx) |ns_idx| {
        ns_idx.lock.lockShared();
        defer ns_idx.lock.unlockShared();
        if (ns_idx.dim) |d| {
            if (incoming_dim != d) return error.DimensionMismatch;
        }
        bq_slice = try ns_idx.encodeBqIntoLocked(allocator, vec_f32, &bq_stack, &bq_heap);
    } else {
        const needed = distance.binaryQuantizedSize(incoming_dim);
        const dst: []u8 = if (needed <= bq_stack.len)
            bq_stack[0..needed]
        else blk: {
            const b = try allocator.alloc(u8, needed);
            bq_heap = b;
            break :blk b;
        };
        distance.binaryQuantize(vec_f32, dst);
        bq_slice = dst;
    }

    // ── Store the vec entry ──────────────────────────────────────
    store.setWithTimestampNoVectorSync(args.key, args.vector, args.worm, args.timestamp) catch |e| {
        return switch (e) {
            error.WormViolation => error.WormViolation,
            error.OutOfMemory => error.OutOfMemory,
            else => error.IoError,
        };
    };
    const config_ok = persistNamespaceConfig(store, allocator, existing_idx, args.namespace, args.metric, args.timestamp);
    store.appendVectorInsertWal(args.key, args.namespace, args.metric.name(), args.worm, args.is_async, args.timestamp) catch |e| {
        std.log.warn("applyVinsert: vector WAL metadata '{s}': {s}", .{ args.key, @errorName(e) });
    };

    // ── Store BQ companion (stack key buf, pre-encoded value) ────
    var bq_key_stack: [512]u8 = undefined;
    var bq_key_heap: ?[]u8 = null;
    defer if (bq_key_heap) |b| allocator.free(b);
    const bq_key = try concatInto(allocator, "bq:", args.key, &bq_key_stack, &bq_key_heap);

    store.setWithTimestampNoVectorSync(bq_key, bq_slice, args.worm, args.timestamp) catch |e| {
        std.log.warn("applyVinsert: BQ store failed for '{s}': {s}", .{ bq_key, @errorName(e) });
    };

    // ── HNSW + contiguous slab update (best-effort; log+skip on failures) ──
    if (registry) |reg| {
        const ns_idx: ?*NamespaceIndex = if (existing_idx) |ex| blk: {
            if (ex.metric != args.metric) {
                std.log.warn("applyVinsert: getOrCreate '{s}' (metric={s}): MetricMismatch", .{
                    args.namespace, args.metric.name(),
                });
                break :blk null;
            }
            break :blk ex;
        } else reg.getOrCreate(args.namespace, args.metric) catch |e| blk: {
            std.log.warn("applyVinsert: getOrCreate '{s}' (metric={s}): {s}", .{
                args.namespace, args.metric.name(), @errorName(e),
            });
            break :blk null;
        };

        if (ns_idx) |idx| {
            if (existing_idx == null and config_ok) {
                idx.config_persisted.store(true, .release);
            }
            if (args.is_async and !idx.async_mode) {
                idx.enableAsyncMode() catch |e| {
                    std.log.warn("applyVinsert: enableAsyncMode '{s}': {s}", .{ args.namespace, @errorName(e) });
                };
            }

            if (idx.async_mode) {
                const key_copy = idx.allocator.dupe(u8, args.key) catch |e| blk2: {
                    std.log.warn("applyVinsert: async key dup failed: {s}", .{@errorName(e)});
                    break :blk2 null;
                };
                if (key_copy) |kc| {
                    const vec_copy = idx.allocator.dupe(u8, args.vector) catch |e| blk2: {
                        idx.allocator.free(kc);
                        std.log.warn("applyVinsert: async vec dup failed: {s}", .{@errorName(e)});
                        break :blk2 null;
                    };
                    if (vec_copy) |vc| {
                        idx.enqueueAsync(kc, vc, args.timestamp) catch |e| {
                            idx.allocator.free(kc);
                            idx.allocator.free(vc);
                            std.log.warn("applyVinsert: enqueueAsync '{s}': {s}", .{ args.key, @errorName(e) });
                        };
                    }
                }
            } else {
                idx.lock.lock();
                defer idx.lock.unlock();
                if (had_preexisting) idx.markIncompleteLocked();
                _ = idx.insertLockedWithBq(args.key, vec_f32, args.timestamp, bq_slice) catch |e| {
                    idx.markIncompleteLocked();
                    std.log.warn("applyVinsert: HNSW insert '{s}': {s}", .{ args.key, @errorName(e) });
                };
            }
        }
    }

    // ── Local event emission ─────────────────────────────────────
    if (event_bus) |bus| {
        if (bus.subscriberCount() > 0) {
            var ch_stack: [256]u8 = undefined;
            var ch_heap: ?[]u8 = null;
            defer if (ch_heap) |b| allocator.free(b);
            if (concatInto(allocator, args.namespace, "inserted", &ch_stack, &ch_heap) catch null) |ch| {
                bus.publish(ch, args.key) catch |e| {
                    std.log.warn("applyVinsert: publish '{s}': {s}", .{ ch, @errorName(e) });
                };
            }
        }
    }

    // ── Replicate to peers ───────────────────────────────────────
    if (args.replicate) {
        if (cluster) |c| {
            c.replicateVinsert(.{
                .key = args.key,
                .vector = args.vector,
                .worm = args.worm,
                .namespace = args.namespace,
                .metric = args.metric.name(),
                .timestamp = args.timestamp,
                .is_async = args.is_async,
            }) catch |e| {
                std.log.warn("applyVinsert: cluster replication: {s}", .{@errorName(e)});
            };
        }
    }
}

/// Apply a VBULKINSERT locally: write vec + BQ for each item, then do ONE
/// namespace lock acquisition for the HNSW update (sync) or ONE queue
/// lock acquisition (async). Amortizes per-frame wire parse + per-item
/// lock/signal overhead.
///
/// Error semantics differ slightly from single-VINSERT: best-effort on
/// individual items. WORM violations and invalid-bytes errors are logged
/// per-item and do not abort the batch. Caller gets a single OK even if
/// some items failed; operators see the warnings in logs.
pub fn applyVbulkinsert(
    store: *Store,
    cluster: ?*Cluster,
    event_bus: ?*EventBus,
    registry: ?*NamespaceRegistry,
    allocator: std.mem.Allocator,
    namespace: []const u8,
    metric: Metric,
    worm: bool,
    is_async: bool,
    items: []const Command.VbulkinsertParams.BulkItem,
    replicate: bool,
) !void {
    if (items.len == 0) return;
    // Validate ALL item keys before ANY write, so a namespace mismatch produces no partial batch.
    for (items) |item| {
        if (!keyBelongsToNamespace(item.key, namespace))
            return error.KeyMissingNamespace;
    }

    // ── Phase 1: store.set(vec) + store.set(bq) for each item ────
    // Retain RaBitQ params handle once outside the loop so we do ZERO
    // per-item NamespaceIndex lock acquisitions during KV writes.
    const existing_idx: ?*NamespaceIndex = if (registry) |reg| reg.get(namespace) else null;
    const had_preexisting = existing_idx == null and registry != null and store.countPrefix(namespace) > 0;
    const config_ok = persistNamespaceConfig(store, allocator, existing_idx, namespace, metric, items[0].timestamp);

    var rq_handle: ?*index_mod.RabitqParamsHandle = null;
    defer if (rq_handle) |h| h.release();
    var idx_metric: Metric = metric;
    if (existing_idx) |idx| {
        idx.lock.lockShared();
        rq_handle = idx.acquireRabitqHandleLocked();
        idx_metric = idx.metric;
        idx.lock.unlockShared();
    }
    const params_opt: ?*const rabitq.RabitqParams = if (rq_handle) |h| h.params else null;

    // Stage pre-encoded BQ slices in a flat blob for sync Phase 2 so
    // `insertLockedWithBq` reuses them without re-encoding.
    const StagedBq = struct {
        off: u32 = 0,
        len: u32 = 0,
        stored: bool = false,
    };
    const stage_sync = registry != null and !is_async and (existing_idx == null or !existing_idx.?.async_mode);
    var staged: ?[]StagedBq = null;
    defer if (staged) |s| allocator.free(s);
    var bq_blob: std.ArrayListUnmanaged(u8) = .empty;
    defer bq_blob.deinit(allocator);
    if (stage_sync) {
        if (allocator.alloc(StagedBq, items.len)) |s| {
            @memset(s, .{});
            staged = s;
        } else |_| {}
    }

    var bq_key_stack: [512]u8 = undefined;
    var bq_val_stack: [256]u8 = undefined;
    var res_buf: std.ArrayListUnmanaged(f32) = .empty;
    defer res_buf.deinit(allocator);
    var rot_buf: std.ArrayListUnmanaged(f32) = .empty;
    defer rot_buf.deinit(allocator);
    var norm_buf: std.ArrayListUnmanaged(f32) = .empty;
    defer norm_buf.deinit(allocator);

    var dim_check: ?usize = null;
    var valid_count: usize = 0;
    for (items, 0..) |item, item_idx| {
        if (item.vector.len == 0 or item.vector.len % 4 != 0) {
            std.log.warn("applyVbulkinsert: invalid vector bytes for '{s}' (skipping)", .{item.key});
            continue;
        }
        if (dim_check) |d| {
            if (item.vector.len != d) {
                std.log.warn("applyVbulkinsert: vector-length mismatch for '{s}' (skipping)", .{item.key});
                continue;
            }
        } else dim_check = item.vector.len;

        store.setWithTimestampNoVectorSync(item.key, item.vector, worm, item.timestamp) catch |e| {
            std.log.warn("applyVbulkinsert: store vec '{s}' failed: {s}", .{ item.key, @errorName(e) });
            continue;
        };
        valid_count += 1;
        if (staged) |s| s[item_idx].stored = true;
        store.appendVectorInsertWal(item.key, namespace, metric.name(), worm, is_async, item.timestamp) catch |e| {
            std.log.warn("applyVbulkinsert: vector WAL metadata '{s}': {s}", .{ item.key, @errorName(e) });
        };

        var bq_key_heap: ?[]u8 = null;
        defer if (bq_key_heap) |b| allocator.free(b);
        const bq_key = concatInto(allocator, "bq:", item.key, &bq_key_stack, &bq_key_heap) catch continue;

        const vec_f32 = distance.bytesToF32(item.vector).?;
        var bq_val_heap: ?[]u8 = null;
        defer if (bq_val_heap) |b| allocator.free(b);
        const bq_slice = encodeBqWithHandle(
            allocator,
            vec_f32,
            idx_metric,
            params_opt,
            &bq_val_stack,
            &bq_val_heap,
            &res_buf,
            &rot_buf,
            &norm_buf,
        ) catch continue;

        store.setWithTimestampNoVectorSync(bq_key, bq_slice, worm, item.timestamp) catch |e| {
            std.log.warn("applyVbulkinsert: store bq '{s}' failed: {s}", .{ bq_key, @errorName(e) });
        };

        if (staged) |s| {
            const off = bq_blob.items.len;
            if (bq_blob.appendSlice(allocator, bq_slice)) |_| {
                s[item_idx] = .{
                    .off = @intCast(off),
                    .len = @intCast(bq_slice.len),
                    .stored = true,
                };
            } else |_| {
                s[item_idx].stored = true;
            }
        }
    }

    // ── Phase 2: HNSW + slab update ──────────────────────────────
    if (registry) |reg| {
        const ns_idx: ?*NamespaceIndex = if (existing_idx) |ex| blk: {
            if (ex.metric != metric) {
                std.log.warn("applyVbulkinsert: getOrCreate '{s}': MetricMismatch", .{namespace});
                break :blk null;
            }
            break :blk ex;
        } else reg.getOrCreate(namespace, metric) catch |e| blk: {
            std.log.warn("applyVbulkinsert: getOrCreate '{s}': {s}", .{ namespace, @errorName(e) });
            break :blk null;
        };
        if (ns_idx) |idx| {
            if (existing_idx == null and config_ok) {
                idx.config_persisted.store(true, .release);
            }
            if (is_async and !idx.async_mode) {
                idx.enableAsyncMode() catch |e| {
                    std.log.warn("applyVbulkinsert: enableAsyncMode: {s}", .{@errorName(e)});
                };
            }

            if (idx.async_mode) {
                if (had_preexisting) {
                    idx.lock.lock();
                    idx.markIncompleteLocked();
                    idx.lock.unlock();
                }
                idx.enqueueAsyncBatch(items) catch |e| {
                    std.log.warn("applyVbulkinsert: enqueueAsyncBatch: {s}", .{@errorName(e)});
                };
            } else {
                // Single write-lock cycle for the whole batch + upfront pre-reserve +
                // parallel multi-threaded HNSW linking for batches >= 32 vectors.
                idx.lock.lock();
                defer idx.lock.unlock();
                if (had_preexisting) idx.markIncompleteLocked();
                if (valid_count > 0) {
                    idx.reserveAdditionalLocked(valid_count) catch {};
                }
                var batch_stack: [1024]NamespaceIndex.BatchInsertItem = undefined;
                var batch_heap: ?[]NamespaceIndex.BatchInsertItem = null;
                defer if (batch_heap) |bh| allocator.free(bh);
                const batch_buf: ?[]NamespaceIndex.BatchInsertItem = if (valid_count >= 32) blk: {
                    if (valid_count <= batch_stack.len) break :blk batch_stack[0..valid_count];
                    const b = allocator.alloc(NamespaceIndex.BatchInsertItem, valid_count) catch break :blk null;
                    batch_heap = b;
                    break :blk b;
                } else null;

                if (batch_buf) |buf| {
                    var b_len: usize = 0;
                    for (items, 0..) |item, item_idx| {
                        if (staged) |s| {
                            if (!s[item_idx].stored) continue;
                        }
                        const vec_f32 = distance.bytesToF32(item.vector) orelse continue;
                        const pre_bq: ?[]const u8 = if (staged) |s| blk: {
                            const meta = s[item_idx];
                            if (meta.len > 0) break :blk bq_blob.items[meta.off..][0..meta.len];
                            break :blk null;
                        } else null;
                        if (b_len < buf.len) {
                            buf[b_len] = .{
                                .key = item.key,
                                .vector = vec_f32,
                                .timestamp = item.timestamp,
                                .pre_encoded_bq = pre_bq,
                            };
                            b_len += 1;
                        }
                    }
                    _ = idx.insertBatchLocked(buf[0..b_len]) catch |e| {
                        idx.markIncompleteLocked();
                        std.log.warn("applyVbulkinsert: parallel batch insert failed: {s}", .{@errorName(e)});
                    };
                } else {
                    for (items, 0..) |item, item_idx| {
                        if (staged) |s| {
                            if (!s[item_idx].stored) continue;
                        }
                        const vec_f32 = distance.bytesToF32(item.vector) orelse continue;
                        const pre_bq: ?[]const u8 = if (staged) |s| blk: {
                            const meta = s[item_idx];
                            if (meta.len > 0) break :blk bq_blob.items[meta.off..][0..meta.len];
                            break :blk null;
                        } else null;
                        _ = idx.insertLockedWithBq(item.key, vec_f32, item.timestamp, pre_bq) catch |e| {
                            idx.markIncompleteLocked();
                            std.log.warn("applyVbulkinsert: HNSW insert '{s}': {s}", .{ item.key, @errorName(e) });
                        };
                    }
                }
            }
        }
    }

    // ── Phase 3: events + replication (per-item, same as single VINSERT) ──
    if (event_bus) |bus| {
        if (bus.subscriberCount() > 0) {
            var ch_stack: [256]u8 = undefined;
            var ch_heap: ?[]u8 = null;
            defer if (ch_heap) |b| allocator.free(b);
            if (concatInto(allocator, namespace, "inserted", &ch_stack, &ch_heap) catch null) |ch| {
                for (items) |item| {
                    bus.publish(ch, item.key) catch {};
                }
            }
        }
    }

    if (replicate) {
        if (cluster) |c| {
            c.replicateVbulkinsert(.{
                .namespace = namespace,
                .metric = metric.name(),
                .worm = worm,
                .is_async = is_async,
                .items = items,
            }) catch |e| {
                std.log.warn("applyVbulkinsert: cluster replication: {s}", .{@errorName(e)});
            };
        }
    }
}

/// Apply a VRABITQ_INSTALL locally: build a `RabitqParams` from the
/// wire payload (validated to match `dim`) and install it on the
/// namespace's index. Used both by peer-side replication and by tests
/// that want to seed a namespace without running the full vrabitq
/// procedure end-to-end.
///
/// On success, the namespace's RaBitQ params slot is populated and any
/// subsequent `applyVinsert` / `vsearch` will use the unbiased estimator
/// path. On failure (registry missing, OOM, dim mismatch) the function
/// returns an error and leaves the index untouched.
pub fn applyVrabitqInstall(
    registry: ?*NamespaceRegistry,
    args: struct {
        namespace: []const u8,
        dim: u32,
        seed: u64,
        centroid_bytes: []const u8,
        rotation_bytes: []const u8,
        metric: Metric,
    },
) !void {
    const reg = registry orelse return error.RegistryUnavailable;

    const dim_usize: usize = @intCast(args.dim);
    if (args.centroid_bytes.len != dim_usize * 4) return error.InvalidVectorBytes;
    if (args.rotation_bytes.len != dim_usize * dim_usize * 4) return error.InvalidVectorBytes;

    // We need the index allocator. getOrCreate so the params land on the
    // correct namespace even if the peer hasn't seen any VINSERTs yet —
    // the leader's re-encode SETs will arrive next and want this index.
    const ns_idx = try reg.getOrCreate(args.namespace, args.metric);

    const centroid = try ns_idx.allocator.alloc(f32, dim_usize);
    var ownership_transferred = false;
    errdefer if (!ownership_transferred) ns_idx.allocator.free(centroid);
    @memcpy(std.mem.sliceAsBytes(centroid), args.centroid_bytes);

    const rotation = try ns_idx.allocator.alloc(f32, dim_usize * dim_usize);
    errdefer if (!ownership_transferred) ns_idx.allocator.free(rotation);
    @memcpy(std.mem.sliceAsBytes(rotation), args.rotation_bytes);

    const params_ptr = try ns_idx.allocator.create(rabitq.RabitqParams);
    errdefer if (!ownership_transferred) ns_idx.allocator.destroy(params_ptr);
    params_ptr.* = .{
        .allocator = ns_idx.allocator,
        .centroid = centroid,
        .rotation = rotation,
        .dim = args.dim,
        .seed = args.seed,
    };

    ns_idx.lock.lock();
    defer ns_idx.lock.unlock();
    try ns_idx.setRabitqParams(params_ptr);
    ownership_transferred = true;
}

/// Apply a VDELETE locally: delete vec + BQ from the store, tombstone
/// the HNSW node, emit event, optionally replicate. Returns
/// `error.WormViolation` if the vec entry is WORM (store guard).
pub fn applyVdelete(
    store: *Store,
    cluster: ?*Cluster,
    event_bus: ?*EventBus,
    registry: ?*NamespaceRegistry,
    allocator: std.mem.Allocator,
    key: []const u8,
    namespace: []const u8,
    replicate: bool,
) !void {
    if (!keyBelongsToNamespace(key, namespace))
        return error.KeyMissingNamespace;

    // ── Delete vec entry (WAL + WORM check) ──────────────────────
    try store.delete(key);
    store.appendVectorDeleteWal(key, namespace) catch |e| {
        std.log.warn("applyVdelete: vector WAL metadata '{s}': {s}", .{ key, @errorName(e) });
    };

    // ── Delete BQ companion (best-effort) ────────────────────────
    var bq_key_stack: [512]u8 = undefined;
    var bq_key_heap: ?[]u8 = null;
    defer if (bq_key_heap) |b| allocator.free(b);
    const bq_key = try concatInto(allocator, "bq:", key, &bq_key_stack, &bq_key_heap);
    store.delete(bq_key) catch |e| switch (e) {
        error.WormViolation => return error.WormViolation,
        else => {}, // tolerated — the BQ may never have existed
    };

    // ── Tombstone in HNSW ────────────────────────────────────────
    if (registry) |reg| {
        if (reg.get(namespace)) |ns_idx| {
            ns_idx.lock.lock();
            defer ns_idx.lock.unlock();
            _ = ns_idx.markTombstoneLocked(key);
        }
    }

    // ── Local event emission ─────────────────────────────────────
    if (event_bus) |bus| {
        if (bus.subscriberCount() > 0) {
            var ch_stack: [256]u8 = undefined;
            var ch_heap: ?[]u8 = null;
            defer if (ch_heap) |b| allocator.free(b);
            if (concatInto(allocator, namespace, "deleted", &ch_stack, &ch_heap) catch null) |ch| {
                bus.publish(ch, key) catch |e| {
                    std.log.warn("applyVdelete: publish '{s}': {s}", .{ ch, @errorName(e) });
                };
            }
        }
    }

    // ── Replicate to peers ───────────────────────────────────────
    if (replicate) {
        if (cluster) |c| {
            c.replicateVdelete(key, namespace) catch |e| {
                std.log.warn("applyVdelete: cluster replication: {s}", .{@errorName(e)});
            };
        }
    }
}

test "vector wire helpers reject keys outside namespace" {
    const testing = std.testing;

    var store = try Store.init(testing.allocator, .{ .persistence = .none });
    defer store.deinit();

    try testing.expectError(error.KeyMissingNamespace, applyVinsert(
        &store,
        null,
        null,
        null,
        testing.allocator,
        .{
            .key = "admin/session",
            .vector = "\x00\x00\x00\x00",
            .worm = false,
            .namespace = "vec:docs:",
            .metric = .cosine,
            .timestamp = 1,
            .replicate = false,
        },
    ));

    try testing.expectError(error.KeyMissingNamespace, applyVdelete(
        &store,
        null,
        null,
        null,
        testing.allocator,
        "admin/session",
        "vec:docs:",
        false,
    ));
}

test "vector bulk insert rejects keys outside namespace before writing" {
    const testing = std.testing;

    var store = try Store.init(testing.allocator, .{ .persistence = .none });
    defer store.deinit();

    const items = &[_]Command.VbulkinsertParams.BulkItem{
        .{ .key = "vec:docs:1", .vector = "\x00\x00\x00\x00", .timestamp = 1 },
        .{ .key = "admin/session", .vector = "\x00\x00\x00\x00", .timestamp = 2 },
    };

    try testing.expectError(error.KeyMissingNamespace, applyVbulkinsert(
        &store,
        null,
        null,
        null,
        testing.allocator,
        "vec:docs:",
        .cosine,
        false,
        false,
        items,
        false,
    ));
    try testing.expect(store.get("vec:docs:1") == null);
}

test "applyVbulkinsert does not overwrite WORM key in HNSW or slabs when Store rejects it" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var store = try Store.init(alloc, .{ .persistence = .none });
    defer store.deinit();
    var reg = NamespaceRegistry.init(alloc, .{ .m = 8, .ef_construction = 32 });
    defer reg.deinit();
    store.vector_registry = &reg;

    const v_orig = [_]f32{ 1.0, 0.0, 0.0, 0.0 };
    const v_overwrite = [_]f32{ 0.0, 1.0, 0.0, 0.0 };
    const v_new = [_]f32{ 0.0, 0.0, 1.0, 0.0 };

    try applyVinsert(&store, null, null, &reg, alloc, .{
        .key = "vec:worm:a",
        .vector = std.mem.sliceAsBytes(&v_orig),
        .worm = true,
        .namespace = "vec:worm:",
        .metric = .l2,
        .timestamp = 10,
        .replicate = false,
    });

    const items = &[_]Command.VbulkinsertParams.BulkItem{
        .{ .key = "vec:worm:a", .vector = std.mem.sliceAsBytes(&v_overwrite), .timestamp = 20 },
        .{ .key = "vec:worm:b", .vector = std.mem.sliceAsBytes(&v_new), .timestamp = 21 },
    };
    try applyVbulkinsert(&store, null, null, &reg, alloc, "vec:worm:", .l2, true, false, items, false);

    const idx = reg.get("vec:worm:").?;
    idx.lock.lockShared();
    defer idx.lock.unlockShared();

    try testing.expectEqual(@as(usize, 2), idx.liveCount());
    try testing.expectEqual(@as(usize, 0), idx.tombstone_count);
    const id_a = idx.nodeIdFor("vec:worm:a").?;
    try testing.expectApproxEqAbs(@as(f32, 1.0), idx.hnsw.getVector(id_a)[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.0), idx.hnsw.getVector(id_a)[1], 1e-6);
    const id_b = idx.nodeIdFor("vec:worm:b").?;
    try testing.expectApproxEqAbs(@as(f32, 1.0), idx.hnsw.getVector(id_b)[2], 1e-6);
}

test "applyVbulkinsert parallel batch (>=32) indexes vectors, syncs BQ slab, and tombstones overwrites" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var store = try Store.init(alloc, .{ .persistence = .none });
    defer store.deinit();
    var reg = NamespaceRegistry.init(alloc, .{ .m = 8, .m_max0 = 16, .ef_construction = 48 });
    defer reg.deinit();
    store.vector_registry = &reg;

    const dim: usize = 16;
    const n_batch: usize = 96;
    var prng = std.Random.DefaultPrng.init(0x96_B47C);
    const rand = prng.random();

    const vecs = try alloc.alloc([dim]f32, n_batch);
    defer alloc.free(vecs);
    const keys = try alloc.alloc([]u8, n_batch);
    defer {
        for (keys) |k| alloc.free(k);
        alloc.free(keys);
    }
    const items = try alloc.alloc(Command.VbulkinsertParams.BulkItem, n_batch);
    defer alloc.free(items);

    for (0..n_batch) |i| {
        for (&vecs[i]) |*x| x.* = rand.floatNorm(f32);
        keys[i] = try std.fmt.allocPrint(alloc, "vec:par:{d:0>4}", .{i});
        items[i] = .{
            .key = keys[i],
            .vector = std.mem.sliceAsBytes(&vecs[i]),
            .timestamp = 100 + i,
        };
    }

    // Batch 1 (48 items) + Batch 2 (48 items) both exercise parallel insert path.
    try applyVbulkinsert(&store, null, null, &reg, alloc, "vec:par:", .cosine, false, false, items[0..48], false);
    try applyVbulkinsert(&store, null, null, &reg, alloc, "vec:par:", .cosine, false, false, items[48..96], false);

    // Batch 3: overwrite first 40 keys with fresh vectors + newer timestamps.
    const upd_vecs = try alloc.alloc([dim]f32, 40);
    defer alloc.free(upd_vecs);
    const upd_items = try alloc.alloc(Command.VbulkinsertParams.BulkItem, 40);
    defer alloc.free(upd_items);
    for (0..40) |i| {
        for (&upd_vecs[i]) |*x| x.* = rand.floatNorm(f32);
        upd_items[i] = .{
            .key = keys[i],
            .vector = std.mem.sliceAsBytes(&upd_vecs[i]),
            .timestamp = 500 + i,
        };
    }
    try applyVbulkinsert(&store, null, null, &reg, alloc, "vec:par:", .cosine, false, false, upd_items, false);

    const idx = reg.get("vec:par:").?;
    idx.lock.lockShared();
    defer idx.lock.unlockShared();

    try testing.expectEqual(@as(usize, n_batch), idx.liveCount());
    try testing.expectEqual(@as(usize, 40), idx.tombstone_count);
    try testing.expectEqual(@as(usize, n_batch + 40), idx.hnsw.len());
    try testing.expect(idx.bq_slab.synced);
    try testing.expectEqual(idx.hnsw.len(), idx.bq_slab.len);

    // Search for an overwritten vector must return its updated key as top-1.
    var out: [5]index_mod.IndexSearchResult = undefined;
    var scratch: [5]@import("../vector/hnsw.zig").SearchResult = undefined;
    const found = try idx.searchLocked(&upd_vecs[7], 5, 48, &out, &scratch);
    try testing.expect(found > 0);
    try testing.expectEqualStrings(keys[7], out[0].key);
}

// Keep the Command union visible for callers that need to construct frames.
pub const Command = core.types.Command;
