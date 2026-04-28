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
const Cluster = @import("../cluster/mod.zig").Cluster;
const EventBus = @import("../event/mod.zig").EventBus;
const index_mod = @import("../vector/index.zig");
const NamespaceRegistry = index_mod.NamespaceRegistry;
const NamespaceIndex = index_mod.NamespaceIndex;
const distance = @import("../vector/distance.zig");
const rabitq = @import("../vector/rabitq.zig");
const Metric = @import("../vector/metric.zig").Metric;
const core = @import("../core/mod.zig");

/// Encode a vector's BQ companion into a newly-allocated, caller-owned
/// buffer. Chooses the RaBitQ path (24-byte format on 128-dim) when the
/// namespace has installed params, falling back to naive 1-bit sign
/// quantization (16-byte on 128-dim) otherwise.
///
/// Must be called with `ns_idx` either null (unindexed namespace) or
/// pointing at the registry entry whose params we'll consult. Takes the
/// shared lock internally.
fn encodeBqOwned(
    allocator: std.mem.Allocator,
    vec_f32: []align(1) const f32,
    ns_idx: ?*NamespaceIndex,
) ![]u8 {
    if (ns_idx) |idx| {
        idx.lock.lockShared();
        defer idx.lock.unlockShared();
        if (idx.rabitq_params) |p| {
            if (p.dim == vec_f32.len) {
                // Full RaBitQ encode: code + l2 + corr.
                const out = try allocator.alloc(u8, rabitq.encodedSize(vec_f32.len));
                errdefer allocator.free(out);

                const residual = try allocator.alloc(f32, vec_f32.len);
                defer allocator.free(residual);
                const rotated = try allocator.alloc(f32, vec_f32.len);
                defer allocator.free(rotated);

                // Cosine namespaces pre-normalize so the bit pattern
                // matches the unit-sphere representation that vrabitq
                // captured for the centroid + the query path uses.
                const encode_input: []align(1) const f32 = if (idx.metric == .cosine) blk: {
                    const norm_buf = allocator.alloc(f32, vec_f32.len) catch break :blk vec_f32;
                    if (!rabitq.normalizeInto(vec_f32, norm_buf)) {
                        allocator.free(norm_buf);
                        // Zero vector — fall back to encoding raw (will
                        // produce the all-zero degenerate code).
                        break :blk vec_f32;
                    }
                    break :blk @ptrCast(norm_buf);
                } else vec_f32;
                defer if (encode_input.ptr != vec_f32.ptr) allocator.free(@constCast(encode_input));

                const code_slice = out[0..rabitq.codeBytes(vec_f32.len)];
                const enc = rabitq.encode(encode_input, p, residual, rotated, code_slice);
                rabitq.serialize(enc, out);
                return out;
            }
        }
    }
    // No params (or dim mismatch) — naive sign BQ.
    const out = try allocator.alloc(u8, distance.binaryQuantizedSize(vec_f32.len));
    errdefer allocator.free(out);
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

    // ── Pre-check dim against the frozen namespace dimension ─────
    // Fails fast BEFORE any store write. Critical for WORM inserts:
    // a mismatched vector under WORM would be permanent and invisible
    // to HNSW stage-2 refine (vec.len != query.len filter).
    if (registry) |reg| {
        if (reg.get(args.namespace)) |ns_idx| {
            if (ns_idx.expectedDim()) |d| {
                const incoming_dim = args.vector.len / 4;
                if (incoming_dim != d) return error.DimensionMismatch;
            }
        }
    }

    // ── Store the vec entry ──────────────────────────────────────
    store.set(args.key, args.vector, args.worm) catch |e| {
        return switch (e) {
            error.WormViolation => error.WormViolation,
            error.OutOfMemory => error.OutOfMemory,
            else => error.IoError,
        };
    };

    // ── Compute + store BQ companion ─────────────────────────────
    // bq:<full_key> — always alloc the bq key; small and transient.
    const bq_key = try std.fmt.allocPrint(allocator, "bq:{s}", .{args.key});
    defer allocator.free(bq_key);

    const vec_f32 = distance.bytesToF32(args.vector).?; // already validated
    const ns_idx_for_bq: ?*NamespaceIndex = if (registry) |reg| reg.get(args.namespace) else null;
    const bq_buf = try encodeBqOwned(allocator, vec_f32, ns_idx_for_bq);
    defer allocator.free(bq_buf);

    store.set(bq_key, bq_buf, args.worm) catch |e| {
        std.log.warn("applyVinsert: BQ store failed for '{s}': {s}", .{ bq_key, @errorName(e) });
    };

    // ── HNSW update (best-effort; log+skip on failures) ──────────
    if (registry) |reg| {
        const ns_idx = reg.getOrCreate(args.namespace, args.metric) catch |e| blk: {
            std.log.warn("applyVinsert: getOrCreate '{s}' (metric={s}): {s}", .{
                args.namespace, args.metric.name(), @errorName(e),
            });
            break :blk null;
        };
        if (ns_idx) |idx| {
            // First VINSERT that requests async flips the namespace into
            // async mode. Once set, subsequent requests follow the namespace's
            // mode regardless of their own flag (avoids mixing semantics).
            if (args.is_async and !idx.async_mode) {
                idx.enableAsyncMode() catch |e| {
                    std.log.warn("applyVinsert: enableAsyncMode '{s}': {s}", .{ args.namespace, @errorName(e) });
                };
            }

            if (idx.async_mode) {
                // Hand off to background worker. Copy key + vector bytes so
                // the request arena can deallocate without affecting the
                // queued job.
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
                _ = idx.insertLocked(args.key, vec_f32, args.timestamp) catch |e| {
                    std.log.warn("applyVinsert: HNSW insert '{s}': {s}", .{ args.key, @errorName(e) });
                };
            }
        }
    }

    // ── Local event emission ─────────────────────────────────────
    // Each node emits on its own bus; origin + peers all notify their
    // local subscribers. Channel: "<namespace>inserted".
    if (event_bus) |bus| {
        const channel = std.fmt.allocPrint(allocator, "{s}inserted", .{args.namespace}) catch null;
        if (channel) |ch| {
            defer allocator.free(ch);
            bus.publish(ch, args.key) catch |e| {
                std.log.warn("applyVinsert: publish '{s}': {s}", .{ ch, @errorName(e) });
            };
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

    // ── Phase 1: store.set(vec) + store.set(bq) for each item ────
    // These use per-key shard locks; parallel shards don't block each
    // other. No namespace lock held here.
    const ns_idx_for_bq: ?*NamespaceIndex = if (registry) |reg| reg.get(namespace) else null;
    var dim_check: ?usize = null;
    for (items) |item| {
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

        store.set(item.key, item.vector, worm) catch |e| {
            std.log.warn("applyVbulkinsert: store vec '{s}' failed: {s}", .{ item.key, @errorName(e) });
            continue;
        };

        const bq_key = std.fmt.allocPrint(allocator, "bq:{s}", .{item.key}) catch continue;
        defer allocator.free(bq_key);
        const vec_f32 = distance.bytesToF32(item.vector).?;
        const bq_buf = encodeBqOwned(allocator, vec_f32, ns_idx_for_bq) catch continue;
        defer allocator.free(bq_buf);
        store.set(bq_key, bq_buf, worm) catch |e| {
            std.log.warn("applyVbulkinsert: store bq '{s}' failed: {s}", .{ bq_key, @errorName(e) });
        };
    }

    // ── Phase 2: HNSW update ─────────────────────────────────────
    if (registry) |reg| {
        const ns_idx = reg.getOrCreate(namespace, metric) catch |e| blk: {
            std.log.warn("applyVbulkinsert: getOrCreate '{s}': {s}", .{ namespace, @errorName(e) });
            break :blk null;
        };
        if (ns_idx) |idx| {
            if (is_async and !idx.async_mode) {
                idx.enableAsyncMode() catch |e| {
                    std.log.warn("applyVbulkinsert: enableAsyncMode: {s}", .{@errorName(e)});
                };
            }

            if (idx.async_mode) {
                // Batch-enqueue under a single queue mutex acquisition.
                idx.enqueueAsyncBatch(items) catch |e| {
                    std.log.warn("applyVbulkinsert: enqueueAsyncBatch: {s}", .{@errorName(e)});
                };
            } else {
                // Single write-lock cycle for the whole batch.
                idx.lock.lock();
                defer idx.lock.unlock();
                for (items) |item| {
                    const vec_f32 = distance.bytesToF32(item.vector) orelse continue;
                    _ = idx.insertLocked(item.key, vec_f32, item.timestamp) catch |e| {
                        std.log.warn("applyVbulkinsert: HNSW insert '{s}': {s}", .{ item.key, @errorName(e) });
                    };
                }
            }
        }
    }

    // ── Phase 3: events + replication (per-item, same as single VINSERT) ──
    if (event_bus) |bus| {
        const channel = std.fmt.allocPrint(allocator, "{s}inserted", .{namespace}) catch null;
        if (channel) |ch| {
            defer allocator.free(ch);
            for (items) |item| {
                bus.publish(ch, item.key) catch {};
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
    errdefer ns_idx.allocator.free(centroid);
    @memcpy(std.mem.sliceAsBytes(centroid), args.centroid_bytes);

    const rotation = try ns_idx.allocator.alloc(f32, dim_usize * dim_usize);
    errdefer ns_idx.allocator.free(rotation);
    @memcpy(std.mem.sliceAsBytes(rotation), args.rotation_bytes);

    const params_ptr = try ns_idx.allocator.create(rabitq.RabitqParams);
    errdefer ns_idx.allocator.destroy(params_ptr);
    params_ptr.* = .{
        .allocator = ns_idx.allocator,
        .centroid = centroid,
        .rotation = rotation,
        .dim = args.dim,
        .seed = args.seed,
    };

    ns_idx.lock.lock();
    defer ns_idx.lock.unlock();
    ns_idx.setRabitqParams(params_ptr);
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
    // ── Delete vec entry (WAL + WORM check) ──────────────────────
    try store.delete(key);

    // ── Delete BQ companion (best-effort) ────────────────────────
    const bq_key = try std.fmt.allocPrint(allocator, "bq:{s}", .{key});
    defer allocator.free(bq_key);
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
        const channel = std.fmt.allocPrint(allocator, "{s}deleted", .{namespace}) catch null;
        if (channel) |ch| {
            defer allocator.free(ch);
            bus.publish(ch, key) catch |e| {
                std.log.warn("applyVdelete: publish '{s}': {s}", .{ ch, @errorName(e) });
            };
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

// Keep the Command union visible for callers that need to construct frames.
pub const Command = core.types.Command;
