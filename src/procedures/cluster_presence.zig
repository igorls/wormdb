//! EXEC cluster_presence [agents_log=<log_id>]
//!
//! SWIM-derived presence + last-seen surface (#65). Returns one JSON object:
//!
//!   {"self":{"node":"<hex64>","mesh_ip":"a.b.c.d"},"enabled":true,
//!    "peers":[{"node":"<hex64>","name":"...","state":"alive|suspected|dead|left",
//!              "mesh_ip":"a.b.c.d","age_ms":N,"rtt_us":N|null,"incarnation":N,
//!              "org":"<hex64>"|null}, ...],
//!    "agents":[{"id":"<identity>","last_seen_ms":N}, ...]}   // only with agents_log=
//!
//! Peers come from the SWIM membership table (iterated under its shared
//! lock). `age_ms` is the monotonic delta since the peer's last successful
//! ping — absolute monotonic timestamps are meaningless to clients.
//!
//! The optional agents section folds a coordination append-log (#64): every
//! event payload is JSON-parsed and the maximum envelope ingest_time_ms per
//! "by" identity is reported as that agent's last activity (wall-clock ms).
//!
//! Without a cluster attached: {"self":null,"peers":[],"enabled":false}.
//!
//! Public-safe, same as the cluster_peers wire command — no auth op needed.

const std = @import("std");
const Ctx = @import("context.zig").Ctx;
const compat = @import("../core/compat.zig");
const presence = @import("../cluster/presence.zig");
const append_log = @import("../proof/append_log.zig");
const Store = @import("../storage/store.zig").Store;

const EMPTY_SHAPE = "{\"self\":null,\"peers\":[],\"enabled\":false}";

pub fn execute(ctx: *Ctx) anyerror!Ctx.Result {
    const usage = "cluster_presence: usage: cluster_presence [agents_log=<log_id>]";

    var agents_log: ?[]const u8 = null;
    var i: usize = 0;
    while (i < ctx.argCount()) : (i += 1) {
        const arg = ctx.arg(i).?;
        if (std.mem.startsWith(u8, arg, "agents_log=")) {
            const log_id = arg["agents_log=".len..];
            if (log_id.len == 0) return ctx.err("cluster_presence: empty agents_log");
            agents_log = log_id;
        } else {
            return ctx.err(usage);
        }
    }

    const cluster = ctx.cluster orelse return ctx.value(EMPTY_SHAPE);

    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var json: std.ArrayListUnmanaged(u8) = .empty;

    // ── self ──
    var self_hex: [64]u8 = undefined;
    presence.hexEncode(cluster.identityPublicKey(), &self_hex);
    try json.print(arena, "{{\"self\":{{\"node\":\"{s}\",\"mesh_ip\":\"{d}.{d}.{d}.{d}\"}},\"enabled\":true,\"peers\":[", .{
        self_hex[0..],
        cluster.mesh_ip[0],
        cluster.mesh_ip[1],
        cluster.mesh_ip[2],
        cluster.mesh_ip[3],
    });

    // ── peers (membership snapshot under the table's shared lock) ──
    {
        const zio = compat.io();
        cluster.membership.lock.lockSharedUncancelable(zio);
        defer cluster.membership.lock.unlockShared(zio);

        const now_ns = compat.nowNs();
        var first = true;
        var iter = cluster.membership.peers.iterator();
        while (iter.next()) |entry| {
            const peer = entry.value_ptr;
            if (!first) try json.appendSlice(arena, ",");
            first = false;

            const age_delta = now_ns - peer.last_seen_ns;
            const age_ms: u64 = if (age_delta > 0) @intCast(@divTrunc(age_delta, std.time.ns_per_ms)) else 0;

            try presence.appendPeerJson(&json, arena, .{
                .pubkey = entry.key_ptr.*,
                .name = peer.name,
                .state = peer.state,
                .mesh_ip = peer.mesh_ip,
                .age_ms = age_ms,
                .rtt_us = if (peer.last_rtt_ns) |rtt| rtt / std.time.ns_per_us else null,
                .incarnation = peer.incarnation,
                .org_pubkey = peer.org_pubkey,
            });
        }
    }
    try json.appendSlice(arena, "]");

    // ── agents (optional coordination-log fold) ──
    if (agents_log) |log_id| {
        try json.appendSlice(arena, ",\"agents\":[");
        try appendAgentsJson(&json, arena, ctx.store, log_id);
        try json.appendSlice(arena, "]");
    }

    try json.appendSlice(arena, "}");
    return ctx.value(json.items);
}

/// Fold a coordination append-log into per-agent last-activity entries:
/// scan the log's events (scanPrefix locks each shard internally; no ctx
/// shard locks are held), JSON-parse each payload, and keep the maximum
/// envelope ingest_time_ms per "by" identity. Emits
/// {"id":"<identity>","last_seen_ms":N} objects joined by commas, in
/// first-appearance (seq) order. Factored out of execute() so tests can
/// exercise the fold without a cluster.
fn appendAgentsJson(
    json: *std.ArrayListUnmanaged(u8),
    arena: std.mem.Allocator,
    store: *Store,
    log_id: []const u8,
) !void {
    const AgentField = struct { by: []const u8 = "" };

    const prefix = try append_log.eventKeyPrefix(arena, log_id);
    const results = try store.scanPrefix(prefix, 0, arena);

    var last_seen: std.StringArrayHashMapUnmanaged(u64) = .empty;
    for (results) |r| {
        const view = append_log.decodeEnvelope(r.value) catch continue;
        const parsed = std.json.parseFromSliceLeaky(AgentField, arena, view.payload, .{
            .ignore_unknown_fields = true,
        }) catch continue;
        if (parsed.by.len == 0) continue;

        // parsed.by is arena-owned (slices the arena-copied envelope value,
        // or an arena allocation when the string had escapes) — safe as a key.
        const gop = try last_seen.getOrPut(arena, parsed.by);
        if (!gop.found_existing or view.ingest_time_ms > gop.value_ptr.*) {
            gop.value_ptr.* = view.ingest_time_ms;
        }
    }

    var first = true;
    var iter = last_seen.iterator();
    while (iter.next()) |entry| {
        if (!first) try json.appendSlice(arena, ",");
        first = false;
        try json.appendSlice(arena, "{\"id\":");
        try presence.appendJsonString(json, arena, entry.key_ptr.*);
        try json.print(arena, ",\"last_seen_ms\":{d}}}", .{entry.value_ptr.*});
    }
}

// ╔═══════════════════════════════════════════════╗
// ║  Tests                                         ║
// ╚═══════════════════════════════════════════════╝

const testing = std.testing;
const Config = @import("../core/config.zig").Config;

test "cluster_presence: no cluster returns the empty shape" {
    var store = try Store.init(testing.allocator, Config{ .persistence = .none });
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var ctx = Ctx.init(&store, &.{}, arena.allocator(), null, null, null, null);
    defer ctx.deinit();
    const res = try execute(&ctx);
    try testing.expectEqualStrings("{\"self\":null,\"peers\":[],\"enabled\":false}", res.value.?);
}

test "cluster_presence: unknown option and empty agents_log rejected" {
    var store = try Store.init(testing.allocator, Config{ .persistence = .none });
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var bad_ctx = Ctx.init(&store, &.{"bogus"}, arena.allocator(), null, null, null, null);
    defer bad_ctx.deinit();
    const bad = try execute(&bad_ctx);
    try testing.expectEqualStrings("cluster_presence: usage: cluster_presence [agents_log=<log_id>]", bad.err);

    var empty_ctx = Ctx.init(&store, &.{"agents_log="}, arena.allocator(), null, null, null, null);
    defer empty_ctx.deinit();
    const empty = try execute(&empty_ctx);
    try testing.expectEqualStrings("cluster_presence: empty agents_log", empty.err);
}

test "agents fold: max ingest_time_ms per by identity, non-JSON and by-less events skipped" {
    var store = try Store.init(testing.allocator, Config{ .persistence = .none });
    defer store.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const inject = struct {
        fn run(a: std.mem.Allocator, s: *Store, payload: []const u8, at_ms: u64) !void {
            var result = try append_log.append(a, s, "coord:presence", payload, &.{}, .{
                .ingest_time_ms = at_ms,
            });
            defer result.deinit(a);
        }
    }.run;

    try inject(arena, &store, "{\"t\":\"claim.request\",\"task\":\"t1\",\"by\":\"agent-a\",\"hlc\":\"0000000000000010\",\"lease_ms\":1000}", 100);
    try inject(arena, &store, "{\"t\":\"claim.request\",\"task\":\"t1\",\"by\":\"agent-b\",\"hlc\":\"0000000000000020\",\"lease_ms\":1000}", 200);
    try inject(arena, &store, "not json at all", 250);
    try inject(arena, &store, "{\"t\":\"claim.grant\",\"task\":\"t1\",\"winner\":\"agent-a\"}", 260); // no "by": skipped
    try inject(arena, &store, "{\"t\":\"claim.release\",\"task\":\"t1\",\"by\":\"agent-a\",\"outcome\":\"applied\"}", 300);

    var json: std.ArrayListUnmanaged(u8) = .empty;
    try appendAgentsJson(&json, arena, &store, "coord:presence");
    try testing.expectEqualStrings(
        "{\"id\":\"agent-a\",\"last_seen_ms\":300},{\"id\":\"agent-b\",\"last_seen_ms\":200}",
        json.items,
    );
}

test "agents fold: unknown log id yields no entries" {
    var store = try Store.init(testing.allocator, Config{ .persistence = .none });
    defer store.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var json: std.ArrayListUnmanaged(u8) = .empty;
    try appendAgentsJson(&json, arena, &store, "coord:none");
    try testing.expectEqualStrings("", json.items);
}
