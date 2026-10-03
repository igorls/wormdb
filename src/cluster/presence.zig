//! Presence deltas + peer JSON views (#65).
//!
//! Pure helpers shared by the SWIM callback/poll wiring in node.zig and the
//! `EXEC cluster_presence` procedure. Everything in this file is
//! platform-neutral and unit-testable — the Linux-only cluster wiring
//! (callbacks, discovery loop) stays in node.zig and only *calls* into here.
//!
//! Channel: deltas are published to pub/sub channel "cluster:presence".
//! Event shapes (all JSON, `ts` is wall-clock ms):
//!   {"event":"join","node":"<hex64>","name":"...","mesh_ip":"a.b.c.d","state":"alive","ts":N}
//!   {"event":"suspect"|"recover"|"dead"|"left","node":"<hex64>","state":"<new state>","ts":N}
//!   {"event":"punched","node":"<hex64>","endpoint":"a.b.c.d:port","ts":N}

const std = @import("std");
const meshguard = @import("meshguard");

pub const PeerState = meshguard.discovery.Membership.PeerState;

/// Pub/sub channel presence deltas are published to.
pub const CHANNEL = "cluster:presence";

// ╔═══════════════════════════════════════════════╗
// ║  State-diff transition detector                ║
// ╚═══════════════════════════════════════════════╝

/// Presence delta kinds emitted by the state-diff poll. `join` and `punched`
/// come straight from SWIM callbacks; suspect/recover/dead/left transitions
/// are detected by diffing the membership table against a cached snapshot
/// (SWIM has no alive→suspected callback).
pub const DeltaKind = enum {
    suspect,
    recover,
    dead,
    left,

    pub fn eventName(self: DeltaKind) []const u8 {
        return switch (self) {
            .suspect => "suspect",
            .recover => "recover",
            .dead => "dead",
            .left => "left",
        };
    }

    /// The peer's NEW state implied by the delta.
    pub fn stateName(self: DeltaKind) []const u8 {
        return switch (self) {
            .suspect => "suspected",
            .recover => "alive",
            .dead => "dead",
            .left => "left",
        };
    }
};

/// One (pubkey, state) pair snapshotted from the membership table.
pub const PeerSnapshot = struct {
    pubkey: [32]u8,
    state: PeerState,
};

/// A detected transition ready to be published.
pub const StateEvent = struct {
    pubkey: [32]u8,
    kind: DeltaKind,
};

/// Classify a single peer's state transition into a presence delta.
/// `from == null` means the peer was not previously tracked — no delta is
/// emitted (the SWIM onPeerJoin callback publishes the "join" event).
pub fn classify(from: ?PeerState, to: PeerState) ?DeltaKind {
    const f = from orelse return null;
    if (f == to) return null;
    return switch (to) {
        .alive => .recover, // suspected→alive recovery OR dead→alive rejoin
        .suspected => .suspect,
        .dead => .dead,
        .left => .left,
    };
}

/// Diff the current membership snapshot against the cached per-peer states,
/// updating the cache in place and writing detected transitions to `out`.
/// Returns the number of events written (capped at `out.len`; overflow
/// events are dropped — the next poll re-detects any still-changed state
/// only if it changes again, which is acceptable for a best-effort feed).
/// Cache entries for peers no longer present in `current` are pruned.
pub fn diffStates(
    cache: *std.AutoHashMap([32]u8, PeerState),
    current: []const PeerSnapshot,
    out: []StateEvent,
) usize {
    var n: usize = 0;
    for (current) |snap| {
        const gop = cache.getOrPut(snap.pubkey) catch continue;
        if (gop.found_existing) {
            if (classify(gop.value_ptr.*, snap.state)) |kind| {
                if (n < out.len) {
                    out[n] = .{ .pubkey = snap.pubkey, .kind = kind };
                    n += 1;
                }
            }
        }
        gop.value_ptr.* = snap.state;
    }

    // Prune cache entries for peers removed from the membership table
    // (eviction / explicit remove). Bounded scratch: leftovers are pruned
    // on later polls.
    if (cache.count() > current.len) {
        var stale_buf: [64][32]u8 = undefined;
        var stale_n: usize = 0;
        var it = cache.keyIterator();
        outer: while (it.next()) |key| {
            for (current) |snap| {
                if (std.mem.eql(u8, &snap.pubkey, key)) continue :outer;
            }
            if (stale_n < stale_buf.len) {
                stale_buf[stale_n] = key.*;
                stale_n += 1;
            }
        }
        for (stale_buf[0..stale_n]) |key| _ = cache.remove(key);
    }
    return n;
}

// ╔═══════════════════════════════════════════════╗
// ║  Delta JSON builders                           ║
// ╚═══════════════════════════════════════════════╝

/// {"event":"join","node":"<hex64>","name":"...","mesh_ip":"a.b.c.d","state":"alive","ts":N}
pub fn joinJson(
    allocator: std.mem.Allocator,
    pubkey: [32]u8,
    name: []const u8,
    mesh_ip: [4]u8,
    ts_ms: i64,
) ![]u8 {
    var json: std.ArrayListUnmanaged(u8) = .empty;
    errdefer json.deinit(allocator);
    var hex: [64]u8 = undefined;
    hexEncode(pubkey, &hex);
    try json.print(allocator, "{{\"event\":\"join\",\"node\":\"{s}\",\"name\":", .{hex[0..]});
    try appendJsonString(&json, allocator, name);
    try json.print(allocator, ",\"mesh_ip\":\"{d}.{d}.{d}.{d}\",\"state\":\"alive\",\"ts\":{d}}}", .{
        mesh_ip[0], mesh_ip[1], mesh_ip[2], mesh_ip[3], ts_ms,
    });
    return json.toOwnedSlice(allocator);
}

/// {"event":"<kind>","node":"<hex64>","state":"<new state>","ts":N}
/// Used for suspect/recover/left transitions from the poll AND for the
/// onPeerDead callback (kind = .dead).
pub fn stateEventJson(
    allocator: std.mem.Allocator,
    kind: DeltaKind,
    pubkey: [32]u8,
    ts_ms: i64,
) ![]u8 {
    var hex: [64]u8 = undefined;
    hexEncode(pubkey, &hex);
    return std.fmt.allocPrint(allocator, "{{\"event\":\"{s}\",\"node\":\"{s}\",\"state\":\"{s}\",\"ts\":{d}}}", .{
        kind.eventName(), hex[0..], kind.stateName(), ts_ms,
    });
}

/// {"event":"punched","node":"<hex64>","endpoint":"a.b.c.d:port","ts":N}
pub fn punchedJson(
    allocator: std.mem.Allocator,
    pubkey: [32]u8,
    addr: [4]u8,
    port: u16,
    ts_ms: i64,
) ![]u8 {
    var hex: [64]u8 = undefined;
    hexEncode(pubkey, &hex);
    return std.fmt.allocPrint(allocator, "{{\"event\":\"punched\",\"node\":\"{s}\",\"endpoint\":\"{d}.{d}.{d}.{d}:{d}\",\"ts\":{d}}}", .{
        hex[0..], addr[0], addr[1], addr[2], addr[3], port, ts_ms,
    });
}

// ╔═══════════════════════════════════════════════╗
// ║  Peer JSON view (EXEC cluster_presence)        ║
// ╚═══════════════════════════════════════════════╝

/// One peer's presence view, decoupled from the meshguard Peer struct so it
/// can be built (and tested) without a membership table.
pub const PeerView = struct {
    pubkey: [32]u8,
    name: []const u8,
    state: PeerState,
    mesh_ip: [4]u8,
    /// Milliseconds since the peer was last seen (monotonic delta — absolute
    /// monotonic timestamps are meaningless to clients).
    age_ms: u64,
    /// Last ping round-trip in microseconds, null if never measured.
    rtt_us: ?u64,
    incarnation: u64,
    /// Org public key when the peer authenticated via an org cert.
    org_pubkey: ?[32]u8,
};

pub fn peerStateName(state: PeerState) []const u8 {
    return switch (state) {
        .alive => "alive",
        .suspected => "suspected",
        .dead => "dead",
        .left => "left",
    };
}

/// Append one peer entry:
/// {"node":"<hex64>","name":"...","state":"...","mesh_ip":"a.b.c.d","age_ms":N,"rtt_us":N|null,"incarnation":N,"org":"<hex64>"|null}
pub fn appendPeerJson(
    json: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    view: PeerView,
) !void {
    var hex: [64]u8 = undefined;
    hexEncode(view.pubkey, &hex);
    try json.print(allocator, "{{\"node\":\"{s}\",\"name\":", .{hex[0..]});
    try appendJsonString(json, allocator, view.name);
    try json.print(allocator, ",\"state\":\"{s}\",\"mesh_ip\":\"{d}.{d}.{d}.{d}\",\"age_ms\":{d},\"rtt_us\":", .{
        peerStateName(view.state),
        view.mesh_ip[0],
        view.mesh_ip[1],
        view.mesh_ip[2],
        view.mesh_ip[3],
        view.age_ms,
    });
    if (view.rtt_us) |rtt| {
        try json.print(allocator, "{d}", .{rtt});
    } else {
        try json.appendSlice(allocator, "null");
    }
    try json.print(allocator, ",\"incarnation\":{d},\"org\":", .{view.incarnation});
    if (view.org_pubkey) |org| {
        var org_hex: [64]u8 = undefined;
        hexEncode(org, &org_hex);
        try json.print(allocator, "\"{s}\"", .{org_hex[0..]});
    } else {
        try json.appendSlice(allocator, "null");
    }
    try json.appendSlice(allocator, "}");
}

// ╔═══════════════════════════════════════════════╗
// ║  Small helpers                                 ║
// ╚═══════════════════════════════════════════════╝

/// Lowercase hex of a 32-byte key into a 64-byte buffer.
pub fn hexEncode(bytes: [32]u8, out: *[64]u8) void {
    const alphabet = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        out[i * 2] = alphabet[b >> 4];
        out[i * 2 + 1] = alphabet[b & 0x0f];
    }
}

/// Minimal JSON string encoder (quotes + escapes control chars).
pub fn appendJsonString(
    list: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    bytes: []const u8,
) !void {
    try list.append(allocator, '"');
    for (bytes) |byte| {
        switch (byte) {
            '"' => try list.appendSlice(allocator, "\\\""),
            '\\' => try list.appendSlice(allocator, "\\\\"),
            '\n' => try list.appendSlice(allocator, "\\n"),
            '\r' => try list.appendSlice(allocator, "\\r"),
            '\t' => try list.appendSlice(allocator, "\\t"),
            0...8, 11...12, 14...0x1f => {
                try list.appendSlice(allocator, "\\u00");
                const alphabet = "0123456789abcdef";
                try list.append(allocator, alphabet[byte >> 4]);
                try list.append(allocator, alphabet[byte & 0x0f]);
            },
            else => try list.append(allocator, byte),
        }
    }
    try list.append(allocator, '"');
}

// ╔═══════════════════════════════════════════════╗
// ║  Tests                                         ║
// ╚═══════════════════════════════════════════════╝

const testing = std.testing;

fn pk(fill: u8) [32]u8 {
    return .{fill} ** 32;
}

test "classify: full transition matrix" {
    // Untracked peer: join is the SWIM callback's job, no delta here.
    try testing.expect(classify(null, .alive) == null);
    try testing.expect(classify(null, .suspected) == null);
    // No change → no delta.
    try testing.expect(classify(.alive, .alive) == null);
    try testing.expect(classify(.dead, .dead) == null);
    // Transitions.
    try testing.expectEqual(DeltaKind.suspect, classify(.alive, .suspected).?);
    try testing.expectEqual(DeltaKind.recover, classify(.suspected, .alive).?);
    try testing.expectEqual(DeltaKind.recover, classify(.dead, .alive).?); // rejoin
    try testing.expectEqual(DeltaKind.recover, classify(.left, .alive).?);
    try testing.expectEqual(DeltaKind.dead, classify(.alive, .dead).?);
    try testing.expectEqual(DeltaKind.dead, classify(.suspected, .dead).?);
    try testing.expectEqual(DeltaKind.left, classify(.alive, .left).?);
}

test "diffStates: join/suspect/recover/dead/left sequence" {
    var cache = std.AutoHashMap([32]u8, PeerState).init(testing.allocator);
    defer cache.deinit();
    var out: [8]StateEvent = undefined;

    // New peer appears alive: tracked, but no delta (callback publishes join).
    const alive = [_]PeerSnapshot{.{ .pubkey = pk(1), .state = .alive }};
    try testing.expectEqual(@as(usize, 0), diffStates(&cache, &alive, &out));
    try testing.expectEqual(@as(u32, 1), cache.count());

    // Same state next poll: no delta.
    try testing.expectEqual(@as(usize, 0), diffStates(&cache, &alive, &out));

    // alive → suspected.
    const suspected = [_]PeerSnapshot{.{ .pubkey = pk(1), .state = .suspected }};
    try testing.expectEqual(@as(usize, 1), diffStates(&cache, &suspected, &out));
    try testing.expectEqual(DeltaKind.suspect, out[0].kind);
    try testing.expect(std.mem.eql(u8, &out[0].pubkey, &pk(1)));

    // suspected → alive (recover).
    try testing.expectEqual(@as(usize, 1), diffStates(&cache, &alive, &out));
    try testing.expectEqual(DeltaKind.recover, out[0].kind);

    // alive → dead.
    const dead = [_]PeerSnapshot{.{ .pubkey = pk(1), .state = .dead }};
    try testing.expectEqual(@as(usize, 1), diffStates(&cache, &dead, &out));
    try testing.expectEqual(DeltaKind.dead, out[0].kind);

    // dead → alive (rejoin surfaces as recover).
    try testing.expectEqual(@as(usize, 1), diffStates(&cache, &alive, &out));
    try testing.expectEqual(DeltaKind.recover, out[0].kind);

    // alive → left.
    const left = [_]PeerSnapshot{.{ .pubkey = pk(1), .state = .left }};
    try testing.expectEqual(@as(usize, 1), diffStates(&cache, &left, &out));
    try testing.expectEqual(DeltaKind.left, out[0].kind);
}

test "diffStates: multiple peers, only changed ones emit; removed peers pruned" {
    var cache = std.AutoHashMap([32]u8, PeerState).init(testing.allocator);
    defer cache.deinit();
    var out: [8]StateEvent = undefined;

    const initial = [_]PeerSnapshot{
        .{ .pubkey = pk(1), .state = .alive },
        .{ .pubkey = pk(2), .state = .alive },
        .{ .pubkey = pk(3), .state = .suspected },
    };
    try testing.expectEqual(@as(usize, 0), diffStates(&cache, &initial, &out));
    try testing.expectEqual(@as(u32, 3), cache.count());

    // Peer 2 goes suspected, peer 3 recovers, peer 1 unchanged.
    const next = [_]PeerSnapshot{
        .{ .pubkey = pk(1), .state = .alive },
        .{ .pubkey = pk(2), .state = .suspected },
        .{ .pubkey = pk(3), .state = .alive },
    };
    const n = diffStates(&cache, &next, &out);
    try testing.expectEqual(@as(usize, 2), n);
    var saw_suspect = false;
    var saw_recover = false;
    for (out[0..n]) |ev| {
        if (ev.kind == .suspect) {
            saw_suspect = true;
            try testing.expect(std.mem.eql(u8, &ev.pubkey, &pk(2)));
        }
        if (ev.kind == .recover) {
            saw_recover = true;
            try testing.expect(std.mem.eql(u8, &ev.pubkey, &pk(3)));
        }
    }
    try testing.expect(saw_suspect and saw_recover);

    // Peer 3 disappears from the table entirely: pruned, no event.
    const shrunk = [_]PeerSnapshot{
        .{ .pubkey = pk(1), .state = .alive },
        .{ .pubkey = pk(2), .state = .suspected },
    };
    try testing.expectEqual(@as(usize, 0), diffStates(&cache, &shrunk, &out));
    try testing.expectEqual(@as(u32, 2), cache.count());
    try testing.expect(cache.get(pk(3)) == null);

    // If it comes back it is a fresh (untracked) peer: no delta for it.
    const returned = [_]PeerSnapshot{
        .{ .pubkey = pk(1), .state = .alive },
        .{ .pubkey = pk(2), .state = .suspected },
        .{ .pubkey = pk(3), .state = .suspected },
    };
    try testing.expectEqual(@as(usize, 0), diffStates(&cache, &returned, &out));
    try testing.expectEqual(@as(u32, 3), cache.count());
}

test "diffStates: event overflow is capped, states still cached" {
    var cache = std.AutoHashMap([32]u8, PeerState).init(testing.allocator);
    defer cache.deinit();
    var out: [1]StateEvent = undefined;

    const initial = [_]PeerSnapshot{
        .{ .pubkey = pk(1), .state = .alive },
        .{ .pubkey = pk(2), .state = .alive },
    };
    _ = diffStates(&cache, &initial, &out);

    const both_suspected = [_]PeerSnapshot{
        .{ .pubkey = pk(1), .state = .suspected },
        .{ .pubkey = pk(2), .state = .suspected },
    };
    // Only one slot: one event reported, but BOTH cache entries updated
    // (no spurious re-emit next poll).
    try testing.expectEqual(@as(usize, 1), diffStates(&cache, &both_suspected, &out));
    try testing.expectEqual(@as(usize, 0), diffStates(&cache, &both_suspected, &out));
    try testing.expectEqual(PeerState.suspected, cache.get(pk(1)).?);
    try testing.expectEqual(PeerState.suspected, cache.get(pk(2)).?);
}

test "joinJson shape" {
    const msg = try joinJson(testing.allocator, pk(0xab), "node-1", .{ 10, 99, 0, 7 }, 1234);
    defer testing.allocator.free(msg);
    const expected = "{\"event\":\"join\",\"node\":\"" ++ ("ab" ** 32) ++ "\",\"name\":\"node-1\",\"mesh_ip\":\"10.99.0.7\",\"state\":\"alive\",\"ts\":1234}";
    try testing.expectEqualStrings(expected, msg);
}

test "stateEventJson shapes" {
    const suspect = try stateEventJson(testing.allocator, .suspect, pk(0x01), 99);
    defer testing.allocator.free(suspect);
    try testing.expectEqualStrings(
        "{\"event\":\"suspect\",\"node\":\"" ++ ("01" ** 32) ++ "\",\"state\":\"suspected\",\"ts\":99}",
        suspect,
    );

    const recover = try stateEventJson(testing.allocator, .recover, pk(0x02), 100);
    defer testing.allocator.free(recover);
    try testing.expectEqualStrings(
        "{\"event\":\"recover\",\"node\":\"" ++ ("02" ** 32) ++ "\",\"state\":\"alive\",\"ts\":100}",
        recover,
    );

    const dead = try stateEventJson(testing.allocator, .dead, pk(0x03), 101);
    defer testing.allocator.free(dead);
    try testing.expectEqualStrings(
        "{\"event\":\"dead\",\"node\":\"" ++ ("03" ** 32) ++ "\",\"state\":\"dead\",\"ts\":101}",
        dead,
    );
}

test "punchedJson shape" {
    const msg = try punchedJson(testing.allocator, pk(0xcd), .{ 192, 168, 1, 5 }, 51821, 777);
    defer testing.allocator.free(msg);
    try testing.expectEqualStrings(
        "{\"event\":\"punched\",\"node\":\"" ++ ("cd" ** 32) ++ "\",\"endpoint\":\"192.168.1.5:51821\",\"ts\":777}",
        msg,
    );
}

test "appendPeerJson: full and null-optional variants" {
    var json: std.ArrayListUnmanaged(u8) = .empty;
    defer json.deinit(testing.allocator);

    try appendPeerJson(&json, testing.allocator, .{
        .pubkey = pk(0x11),
        .name = "peer \"a\"",
        .state = .suspected,
        .mesh_ip = .{ 10, 99, 3, 4 },
        .age_ms = 1500,
        .rtt_us = 250,
        .incarnation = 7,
        .org_pubkey = pk(0x22),
    });
    const expected_full = "{\"node\":\"" ++ ("11" ** 32) ++
        "\",\"name\":\"peer \\\"a\\\"\",\"state\":\"suspected\",\"mesh_ip\":\"10.99.3.4\"," ++
        "\"age_ms\":1500,\"rtt_us\":250,\"incarnation\":7,\"org\":\"" ++ ("22" ** 32) ++ "\"}";
    try testing.expectEqualStrings(expected_full, json.items);

    json.clearRetainingCapacity();
    try appendPeerJson(&json, testing.allocator, .{
        .pubkey = pk(0x11),
        .name = "",
        .state = .alive,
        .mesh_ip = .{ 10, 99, 0, 1 },
        .age_ms = 0,
        .rtt_us = null,
        .incarnation = 0,
        .org_pubkey = null,
    });
    const expected_null = "{\"node\":\"" ++ ("11" ** 32) ++
        "\",\"name\":\"\",\"state\":\"alive\",\"mesh_ip\":\"10.99.0.1\"," ++
        "\"age_ms\":0,\"rtt_us\":null,\"incarnation\":0,\"org\":null}";
    try testing.expectEqualStrings(expected_null, json.items);
}
