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
const NamespaceRegistry = @import("../vector/index.zig").NamespaceRegistry;
const distance = @import("../vector/distance.zig");
const Metric = @import("../vector/metric.zig").Metric;
const core = @import("../core/mod.zig");

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
    const bq_size = distance.binaryQuantizedSize(vec_f32.len);
    const bq_buf = try allocator.alloc(u8, bq_size);
    defer allocator.free(bq_buf);
    distance.binaryQuantize(vec_f32, bq_buf);

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
