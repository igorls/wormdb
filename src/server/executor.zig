//! Shared command executor — used by both tcp.zig (thread pool) and uring.zig (io_uring).
//! Decouples command dispatch from the transport layer.

const std = @import("std");
const core = @import("../core/mod.zig");
const storage = @import("../storage/mod.zig");
const event = @import("../event/mod.zig");
const cluster_mod = @import("../cluster/mod.zig");
const procedures = @import("../procedures/mod.zig");

const Store = storage.Store;
const EventBus = event.EventBus;
const Command = core.types.Command;
const Response = core.types.Response;
const Cluster = cluster_mod.Cluster;
const NamespaceRegistry = @import("../vector/index.zig").NamespaceRegistry;
const vector_ops = @import("../procedures/vector_ops.zig");
const Metric = @import("../vector/metric.zig").Metric;

/// Execute context — bundles the dependencies needed for command execution.
pub const ExecContext = struct {
    allocator: std.mem.Allocator,
    store: *Store,
    event_bus: *EventBus,
    cluster: ?*Cluster,
    /// Per-namespace HNSW index registry (optional). Procedures that do
    /// vector search consult this first; null → BQ or brute-force paths.
    vector_registry: ?*NamespaceRegistry = null,
    /// Authenticated identity (from SCT subject). Null if unauthenticated.
    identity: ?[]const u8 = null,
};

/// Execute a command, returning the response.
/// Pure dispatch — no transport, no connection state.
pub fn execute(ctx: ExecContext, cmd: Command) !Response {
    return switch (cmd) {
        .get => |key| blk: {
            const value = ctx.store.getValueDupe(key, ctx.allocator) catch {
                break :blk Response{ .err = "out of memory" };
            };
            break :blk .{ .value = value };
        },
        .set => |params| blk: {
            ctx.store.set(params.key, params.value, params.worm) catch |err| {
                break :blk switch (err) {
                    error.WormViolation => Response{ .err = try ctx.allocator.dupe(u8, "WORM violation: key is immutable") },
                    else => err,
                };
            };

            if (ctx.cluster) |cluster| {
                cluster.replicateWrite(params.key, params.value, params.worm) catch |err| {
                    std.log.warn("replication failed after local commit: {s}", .{@errorName(err)});
                };
            }

            break :blk .ok;
        },
        .delete => |key| blk: {
            ctx.store.delete(key) catch |err| {
                break :blk switch (err) {
                    error.WormViolation => Response{ .err = try ctx.allocator.dupe(u8, "WORM violation: key is immutable") },
                    else => err,
                };
            };

            if (ctx.cluster) |cluster| {
                cluster.replicateDelete(key) catch |err| {
                    std.log.warn("replication failed after local commit: {s}", .{@errorName(err)});
                };
            }

            break :blk .ok;
        },
        .status => blk: {
            const key_count = ctx.store.count();
            const wal_size = ctx.store.walSize() catch 0;

            if (ctx.cluster) |cluster| {
                const s = cluster.status();
                const payload = try std.fmt.allocPrint(
                    ctx.allocator,
                    "keys={d}\nwal_size={d}\ncluster_nodes={d}\ncluster_alive={d}\ncluster_suspected={d}\ncluster_dead={d}\nreplication_factor={d}\n",
                    .{
                        key_count,
                        wal_size,
                        s.total_nodes,
                        s.alive_nodes,
                        s.suspected_nodes,
                        s.dead_nodes,
                        s.replication_factor,
                    },
                );
                break :blk Response{ .value = payload };
            }

            const payload = try std.fmt.allocPrint(
                ctx.allocator,
                "keys={d}\nwal_size={d}\ncluster_enabled=0\n",
                .{ key_count, wal_size },
            );
            break :blk Response{ .value = payload };
        },
        .cluster_status => blk: {
            if (ctx.cluster) |cluster| {
                const s = cluster.status();
                const payload = try std.fmt.allocPrint(
                    ctx.allocator,
                    "cluster_enabled=1\ncluster_nodes={d}\ncluster_alive={d}\ncluster_suspected={d}\ncluster_dead={d}\nreplication_factor={d}\n",
                    .{
                        s.total_nodes,
                        s.alive_nodes,
                        s.suspected_nodes,
                        s.dead_nodes,
                        s.replication_factor,
                    },
                );
                break :blk Response{ .value = payload };
            }

            const payload = try ctx.allocator.dupe(
                u8,
                "cluster_enabled=0\ncluster_nodes=0\ncluster_alive=0\ncluster_suspected=0\ncluster_dead=0\n",
            );
            break :blk Response{ .value = payload };
        },
        .cluster_peers => blk: {
            if (ctx.cluster) |cluster| {
                const payload = try cluster.peerList(ctx.allocator);
                break :blk Response{ .value = payload };
            }
            const payload = try ctx.allocator.dupe(u8, "self_mesh_ip=0.0.0.0\nself_port=0\n---\n");
            break :blk Response{ .value = payload };
        },
        .subscribe => |channel| blk: {
            _ = channel;
            break :blk .ok;
        },
        .unsubscribe => |channel| blk: {
            _ = channel;
            break :blk .ok;
        },
        .publish => |params| blk: {
            try ctx.event_bus.publish(params.channel, params.message);
            break :blk .ok;
        },
        .exec => |params| blk: {
            const proc_fn = procedures.registry.lookup(params.procedure) orelse {
                break :blk Response{ .err = try ctx.allocator.dupe(u8, "unknown procedure") };
            };
            var proc_ctx = procedures.context.Ctx.init(
                ctx.store,
                params.args,
                ctx.allocator,
                ctx.identity,
                ctx.cluster,
                ctx.event_bus,
                ctx.vector_registry,
            );
            defer proc_ctx.deinit(); // auto-unlock all shard locks
            const result = proc_fn(&proc_ctx) catch |e| {
                break :blk Response{ .err = try ctx.allocator.dupe(u8, @errorName(e)) };
            };
            break :blk result;
        },
        .save => blk: {
            ctx.store.save() catch |err| {
                break :blk Response{ .err = try ctx.allocator.dupe(u8, @errorName(err)) };
            };
            break :blk .ok;
        },
        .auth => {
            // AUTH is handled at the connection/gateway layer, not the executor.
            // If it reaches here, the transport didn't intercept it.
            return Response{ .err = "AUTH must be sent over gateway" };
        },
        .vinsert => |params| blk: {
            const metric_enum = Metric.fromStr(params.metric) orelse {
                break :blk Response{ .err = try ctx.allocator.dupe(u8, "vinsert: unknown metric (use cosine|dot|l2)") };
            };
            vector_ops.applyVinsert(
                ctx.store,
                ctx.cluster,
                ctx.event_bus,
                ctx.vector_registry,
                ctx.allocator,
                .{
                    .key = params.key,
                    .vector = params.vector,
                    .worm = params.worm,
                    .namespace = params.namespace,
                    .metric = metric_enum,
                    .timestamp = params.timestamp,
                    .replicate = true, // client-originated → propagate
                },
            ) catch |err| {
                break :blk switch (err) {
                    error.InvalidVectorBytes => Response{ .err = try ctx.allocator.dupe(u8, "vinsert: invalid vector bytes (must be non-empty, len % 4 == 0)") },
                    error.WormViolation => Response{ .err = try ctx.allocator.dupe(u8, "WORM violation: vector key is immutable") },
                    else => Response{ .err = try ctx.allocator.dupe(u8, @errorName(err)) },
                };
            };
            break :blk .ok;
        },
        .vdelete => |params| blk: {
            vector_ops.applyVdelete(
                ctx.store,
                ctx.cluster,
                ctx.event_bus,
                ctx.vector_registry,
                ctx.allocator,
                params.key,
                params.namespace,
                true, // client-originated → propagate
            ) catch |err| {
                break :blk switch (err) {
                    error.WormViolation => Response{ .err = try ctx.allocator.dupe(u8, "WORM violation: vector key is immutable") },
                    else => Response{ .err = try ctx.allocator.dupe(u8, @errorName(err)) },
                };
            };
            break :blk .ok;
        },
    };
}
