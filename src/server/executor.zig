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
const auth = @import("auth.zig");

/// Execute context — bundles the dependencies needed for command execution.
pub const ExecContext = struct {
    allocator: std.mem.Allocator,
    store: *Store,
    event_bus: *EventBus,
    cluster: ?*Cluster,
    /// Per-namespace HNSW index registry (optional). Procedures that do
    /// vector search consult this first; null → BQ or brute-force paths.
    vector_registry: ?*NamespaceRegistry = null,
    /// Authorization decision supplied by the calling transport. Defaults to `.trusted` so
    /// internal/replicated callers and existing tests bypass checks; every CLIENT-facing
    /// transport MUST set a non-trusted value (`.enforce`/`.disabled`) explicitly.
    auth: auth.AuthContext = .trusted,
};

/// Execute a command, returning the response.
/// Pure dispatch — no transport, no connection state.
pub fn execute(ctx: ExecContext, cmd: Command) !Response {
    // Unified authorization chokepoint — every transport funnels through here. `.trusted`
    // (internal/replicated) and `.disabled` (explicit per-transport opt-out) bypass checks;
    // `.enforce` runs the capability check for protected commands, while public commands
    // (STATUS/CLUSTER_*/SAVE/AUTH → no operation) always pass.
    switch (ctx.auth) {
        .trusted, .disabled => {},
        .enforce => |maybe_state| {
            if (auth.operationForCommand(cmd) != null) {
                const state = maybe_state orelse return Response{ .err = "auth required" };
                if (!auth.commandPermittedUnion(state, cmd)) return Response{ .err = "permission denied" };
            }
        },
    }

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
                ctx.auth.identity(),
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
                    .is_async = params.is_async,
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
        .vbulkinsert => |params| blk: {
            const metric_enum = Metric.fromStr(params.metric) orelse {
                break :blk Response{ .err = try ctx.allocator.dupe(u8, "vbulkinsert: unknown metric (use cosine|dot|l2)") };
            };
            vector_ops.applyVbulkinsert(
                ctx.store,
                ctx.cluster,
                ctx.event_bus,
                ctx.vector_registry,
                ctx.allocator,
                params.namespace,
                metric_enum,
                params.worm,
                params.is_async,
                params.items,
                true, // client-originated → propagate
            ) catch |err| {
                // applyVbulkinsert skips invalid/oversized items internally; the only error it
                // surfaces is the namespace-confinement check (#15).
                const msg: []const u8 = if (err == error.KeyMissingNamespace)
                    "vbulkinsert: item key outside its declared namespace"
                else
                    @errorName(err);
                break :blk Response{ .err = try ctx.allocator.dupe(u8, msg) };
            };
            break :blk .ok;
        },
        .vrabitq_install => |params| blk: {
            // Peer-side install. The leader's `EXEC vrabitq` is the only
            // path that emits this frame, and it has already validated
            // the dim / namespace lifecycle. A peer applying it picks
            // up the metric from the namespace's existing index, or
            // defaults to L2 if the namespace hasn't been touched yet
            // (the only case RaBitQ is meaningful for today).
            const inferred_metric: Metric = if (ctx.vector_registry) |reg|
                if (reg.get(params.namespace)) |idx| idx.metric else Metric.l2
            else
                Metric.l2;
            vector_ops.applyVrabitqInstall(ctx.vector_registry, .{
                .namespace = params.namespace,
                .dim = params.dim,
                .seed = params.seed,
                .centroid_bytes = params.centroid,
                .rotation_bytes = params.rotation,
                .metric = inferred_metric,
            }) catch |err| {
                break :blk Response{ .err = try ctx.allocator.dupe(u8, @errorName(err)) };
            };
            break :blk .ok;
        },
    };
}

test "executor auth gate: enforce blocks unauthenticated writes, public passes, disabled/trusted bypass" {
    const testing = std.testing;
    var store = try Store.init(testing.allocator, .{ .persistence = .none });
    defer store.deinit();
    var bus = EventBus.init(testing.allocator);
    defer bus.deinit();

    const base = ExecContext{
        .allocator = testing.allocator,
        .store = &store,
        .event_bus = &bus,
        .cluster = null,
    };
    const set_cmd = Command{ .set = .{ .key = "k", .value = "v" } };

    // .enforce(null): protected SET rejected, nothing written.
    {
        var ctx = base;
        ctx.auth = .{ .enforce = null };
        const resp = try execute(ctx, set_cmd);
        try testing.expect(resp == .err);
        try testing.expectEqualStrings("auth required", resp.err);
        try testing.expectEqual(@as(usize, 0), store.count());
    }
    // .enforce(null): public STATUS passes.
    {
        var ctx = base;
        ctx.auth = .{ .enforce = null };
        const resp = try execute(ctx, .status);
        try testing.expect(resp == .value);
        if (resp.value) |v| testing.allocator.free(v);
    }
    // .disabled bypass: SET applies.
    {
        var ctx = base;
        ctx.auth = .disabled;
        try testing.expect(try execute(ctx, set_cmd) == .ok);
        try testing.expectEqual(@as(usize, 1), store.count());
    }
    // .trusted (the default) bypass: SET applies.
    {
        try testing.expect(try execute(base, Command{ .set = .{ .key = "k2", .value = "v2" } }) == .ok);
        try testing.expectEqual(@as(usize, 2), store.count());
    }
    // .enforce(state): capability honored — outside prefix denied, inside allowed.
    {
        const state = auth.TokenState{
            .subject = "u",
            .iat = 0,
            .exp = 0,
            .jti = 0,
            .capabilities = &[_]auth.Capability{
                .{ .op = .set, .match_type = .prefix, .pattern = "ok:" },
            },
        };
        var ctx = base;
        ctx.auth = .{ .enforce = &state };
        const denied = try execute(ctx, Command{ .set = .{ .key = "no:1", .value = "v" } });
        try testing.expect(denied == .err);
        try testing.expectEqualStrings("permission denied", denied.err);
        try testing.expect(try execute(ctx, Command{ .set = .{ .key = "ok:1", .value = "v" } }) == .ok);
    }
}
