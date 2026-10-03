//! Org↔org trust delegation EXECs on the verifiable append-log (#66).
//!
//! EXEC trust_grant <from_org_hex64> <to_org_hex64> <caps_csv> <prefixes_csv>
//!                  [expires_at_ms=<ms>] [granted_at_ms=<ms>] sk=<hex128>|sig=<hex128>
//! EXEC trust_revoke <from_org_hex64> <to_org_hex64> <grant_seq>
//!                  [revoked_at_ms=<ms>] sk=<hex128>|sig=<hex128>
//! EXEC trust_fold <from_org_hex64> [to_org_hex64] [at_ms=<ms>]
//!
//! Grants and revocations are ordinary JSON events appended to the granting
//! org's well-known trust log "trust:<from_org_hex>" via the EXISTING
//! append-log primitive (src/proof/append_log.zig), so they are hash-chained,
//! WORM, and covered by the existing checkpoint/witness/proof-bundle EXECs.
//! A "witnessed grant" = an `append_log_checkpoint` covering the grant's seq
//! plus a peer countersignature via `append_log_witness_request` — nothing
//! trust-specific is needed for witnessing.
//!
//! Every event carries a detached Ed25519 signature by the GRANTING org's
//! ORG key over deterministic canonical bytes (src/proof/trust_log.zig).
//! `trust_grant`/`trust_revoke` verify the signature BEFORE appending
//! (deny-by-default: an unsigned or mis-signed event never lands), and
//! `trust_fold` re-verifies EVERY event when deriving the active capability
//! set — so a peer can independently verify the fold from the log alone.
//!
//! `trust_revoke` also bumps the process-wide fold generation
//! (trust_log.bumpFoldGeneration) so the replication path's cached dynamic
//! fold (cluster/org_trust.zig DynamicTrust) drops its cache immediately —
//! a revoked capability fails authorization on the next op.

const std = @import("std");
const Ctx = @import("context.zig").Ctx;
const append_log = @import("../proof/append_log.zig");
const trust_log = @import("../proof/trust_log.zig");
const Store = @import("../storage/store.zig").Store;
const Config = @import("../core/config.zig").Config;

const Ed25519 = std.crypto.sign.Ed25519;

const MAX_APPEND_ATTEMPTS: usize = 64;
/// Sanity bound on prefixes per grant (canonical bytes stay small).
const MAX_PREFIXES: usize = 64;

// ╔═══════════════════════════════════════════════╗
// ║  EXEC: trust_grant                             ║
// ╚═══════════════════════════════════════════════╝

pub fn grantExecute(ctx: *Ctx) anyerror!Ctx.Result {
    const usage = "trust_grant requires: <from_org_hex64> <to_org_hex64> <caps_csv> <prefixes_csv> [expires_at_ms=<ms>] [granted_at_ms=<ms>] sk=<hex128>|sig=<hex128>";
    const from_arg = ctx.arg(0) orelse return ctx.err(usage);
    const to_arg = ctx.arg(1) orelse return ctx.err(usage);
    const caps_arg = ctx.arg(2) orelse return ctx.err(usage);
    const prefixes_arg = ctx.arg(3) orelse return ctx.err(usage);

    const from_org = trust_log.parseOrgHex(from_arg) orelse
        return ctx.err("trust_grant: invalid from_org (need 64 hex chars)");
    const to_org = trust_log.parseOrgHex(to_arg) orelse
        return ctx.err("trust_grant: invalid to_org (need 64 hex chars)");

    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cap_bits = parseCapsCsv(arena, caps_arg) catch
        return ctx.err("trust_grant: caps must be a csv of read|write|append");
    const prefixes = parsePrefixesCsv(arena, prefixes_arg) catch
        return ctx.err("trust_grant: prefixes_csv must list 1..64 non-empty prefixes");

    var expires_at_ms: u64 = 0;
    var granted_at_ms: u64 = ctx.timestamp();
    var key_material: ?KeyMaterial = null;
    var i: usize = 4;
    while (i < ctx.argCount()) : (i += 1) {
        const arg = ctx.arg(i).?;
        if (std.mem.startsWith(u8, arg, "expires_at_ms=")) {
            expires_at_ms = std.fmt.parseUnsigned(u64, arg["expires_at_ms=".len..], 10) catch
                return ctx.err("trust_grant: invalid expires_at_ms=<ms>");
        } else if (std.mem.startsWith(u8, arg, "granted_at_ms=")) {
            granted_at_ms = std.fmt.parseUnsigned(u64, arg["granted_at_ms=".len..], 10) catch
                return ctx.err("trust_grant: invalid granted_at_ms=<ms>");
        } else if (parseKeyMaterial(arg)) |km| {
            if (key_material != null) return ctx.err("trust_grant: pass exactly one of sk= or sig=");
            key_material = km;
        } else {
            return ctx.err("trust_grant: unknown option");
        }
    }
    const km = key_material orelse
        return ctx.err("trust_grant: pass exactly one of sk= or sig=");

    const canonical = try trust_log.encodeGrantBytes(arena, .{
        .from_org = from_org,
        .to_org = to_org,
        .cap_bits = cap_bits,
        .prefixes = prefixes,
        .expires_at_ms = expires_at_ms,
        .granted_at_ms = granted_at_ms,
    });

    const sig = resolveSignature(km, canonical, from_org) catch |err| switch (err) {
        error.KeyOrgMismatch => return ctx.err("trust_grant: sk does not match from_org"),
        error.BadSignature => return ctx.err("trust_grant: signature does not verify against from_org"),
        else => return ctx.err("trust_grant: invalid key material"),
    };

    const payload = try grantPayload(arena, from_arg, to_arg, cap_bits, prefixes, expires_at_ms, granted_at_ms, sig);
    const log_id = try trust_log.logIdForOrg(arena, from_org);
    const result = appendWithRetry(arena, ctx.store, log_id, payload) catch
        return ctx.err("trust_grant: append failed");

    var event_hash_hex: [append_log.HASH_LEN * 2]u8 = undefined;
    _ = append_log.hashToHex(result.event_hash, &event_hash_hex);
    return ctx.value(try std.fmt.allocPrint(
        arena,
        "{{\"log_id\":\"{s}\",\"grant_seq\":{d},\"event_hash\":\"{s}\",\"expires_at_ms\":{d},\"granted_at_ms\":{d}}}",
        .{ log_id, result.seq, event_hash_hex[0..], expires_at_ms, granted_at_ms },
    ));
}

// ╔═══════════════════════════════════════════════╗
// ║  EXEC: trust_revoke                            ║
// ╚═══════════════════════════════════════════════╝

pub fn revokeExecute(ctx: *Ctx) anyerror!Ctx.Result {
    const usage = "trust_revoke requires: <from_org_hex64> <to_org_hex64> <grant_seq> [revoked_at_ms=<ms>] sk=<hex128>|sig=<hex128>";
    const from_arg = ctx.arg(0) orelse return ctx.err(usage);
    const to_arg = ctx.arg(1) orelse return ctx.err(usage);
    const grant_seq = ctx.argInt(u64, 2) orelse return ctx.err(usage);

    const from_org = trust_log.parseOrgHex(from_arg) orelse
        return ctx.err("trust_revoke: invalid from_org (need 64 hex chars)");
    const to_org = trust_log.parseOrgHex(to_arg) orelse
        return ctx.err("trust_revoke: invalid to_org (need 64 hex chars)");
    if (grant_seq == 0) return ctx.err(usage);

    var revoked_at_ms: u64 = ctx.timestamp();
    var key_material: ?KeyMaterial = null;
    var i: usize = 3;
    while (i < ctx.argCount()) : (i += 1) {
        const arg = ctx.arg(i).?;
        if (std.mem.startsWith(u8, arg, "revoked_at_ms=")) {
            revoked_at_ms = std.fmt.parseUnsigned(u64, arg["revoked_at_ms=".len..], 10) catch
                return ctx.err("trust_revoke: invalid revoked_at_ms=<ms>");
        } else if (parseKeyMaterial(arg)) |km| {
            if (key_material != null) return ctx.err("trust_revoke: pass exactly one of sk= or sig=");
            key_material = km;
        } else {
            return ctx.err("trust_revoke: unknown option");
        }
    }
    const km = key_material orelse
        return ctx.err("trust_revoke: pass exactly one of sk= or sig=");

    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The referenced grant must exist on the log and match (from, to).
    const log_id = try trust_log.logIdForOrg(arena, from_org);
    const loaded = trust_log.loadTrustEvents(arena, ctx.store, log_id) catch
        return ctx.err("trust_revoke: log scan failed");
    var found = false;
    for (loaded.events) |ev| {
        if (ev.kind != .grant or ev.seq != grant_seq) continue;
        if (!std.mem.eql(u8, ev.from_org[0..], from_org[0..])) continue;
        if (!std.mem.eql(u8, ev.to_org[0..], to_org[0..])) continue;
        found = true;
        break;
    }
    if (!found) return ctx.err("trust_revoke: grant_seq is not a matching trust.grant on this log");

    const canonical = try trust_log.encodeRevokeBytes(arena, .{
        .from_org = from_org,
        .to_org = to_org,
        .grant_seq = grant_seq,
        .revoked_at_ms = revoked_at_ms,
    });

    const sig = resolveSignature(km, canonical, from_org) catch |err| switch (err) {
        error.KeyOrgMismatch => return ctx.err("trust_revoke: sk does not match from_org"),
        error.BadSignature => return ctx.err("trust_revoke: signature does not verify against from_org"),
        else => return ctx.err("trust_revoke: invalid key material"),
    };

    const payload = try revokePayload(arena, from_arg, to_arg, grant_seq, revoked_at_ms, sig);
    const result = appendWithRetry(arena, ctx.store, log_id, payload) catch
        return ctx.err("trust_revoke: append failed");

    // Invalidate any cached dynamic fold NOW — the revoked capability must
    // fail replication authorization on the next op, not after the TTL.
    trust_log.bumpFoldGeneration();

    return ctx.value(try std.fmt.allocPrint(
        arena,
        "{{\"revoked\":true,\"seq\":{d},\"grant_seq\":{d},\"revoked_at_ms\":{d}}}",
        .{ result.seq, grant_seq, revoked_at_ms },
    ));
}

// ╔═══════════════════════════════════════════════╗
// ║  EXEC: trust_fold                              ║
// ╚═══════════════════════════════════════════════╝

pub fn foldExecute(ctx: *Ctx) anyerror!Ctx.Result {
    const usage = "trust_fold requires: <from_org_hex64> [to_org_hex64] [at_ms=<ms>]";
    const from_arg = ctx.arg(0) orelse return ctx.err(usage);
    const from_org = trust_log.parseOrgHex(from_arg) orelse
        return ctx.err("trust_fold: invalid from_org (need 64 hex chars)");

    var to_filter: ?[32]u8 = null;
    var at_ms: u64 = ctx.timestamp();
    var i: usize = 1;
    while (i < ctx.argCount()) : (i += 1) {
        const arg = ctx.arg(i).?;
        if (std.mem.startsWith(u8, arg, "at_ms=")) {
            at_ms = std.fmt.parseUnsigned(u64, arg["at_ms=".len..], 10) catch
                return ctx.err("trust_fold: invalid at_ms=<ms>");
        } else if (trust_log.parseOrgHex(arg)) |to| {
            if (to_filter != null) return ctx.err("trust_fold: unknown option");
            to_filter = to;
        } else {
            return ctx.err("trust_fold: unknown option");
        }
    }

    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const log_id = try trust_log.logIdForOrg(arena, from_org);
    const loaded = trust_log.loadTrustEvents(arena, ctx.store, log_id) catch
        return ctx.err("trust_fold: log scan failed");
    const fold = try trust_log.foldTrust(arena, from_org, loaded.events, at_ms);

    var json: std.ArrayListUnmanaged(u8) = .empty;
    try json.appendSlice(arena, "{\"org\":\"");
    try appendOrgHex(&json, arena, from_org);
    try json.appendSlice(arena, "\",\"at_ms\":");
    try appendU64(&json, arena, at_ms);
    try json.appendSlice(arena, ",\"capabilities\":[");
    var emitted: usize = 0;
    for (fold.capabilities) |cap| {
        if (to_filter) |to| {
            if (!std.mem.eql(u8, cap.to_org[0..], to[0..])) continue;
        }
        if (emitted > 0) try json.appendSlice(arena, ",");
        emitted += 1;
        try json.appendSlice(arena, "{\"to_org\":\"");
        try appendOrgHex(&json, arena, cap.to_org);
        try json.appendSlice(arena, "\",\"caps\":[");
        var cap_emitted: usize = 0;
        inline for (trust_log.CAP_NAMES) |entry| {
            if (cap.cap_bits & entry.bit != 0) {
                if (cap_emitted > 0) try json.appendSlice(arena, ",");
                cap_emitted += 1;
                try json.appendSlice(arena, "\"");
                try json.appendSlice(arena, entry.name);
                try json.appendSlice(arena, "\"");
            }
        }
        try json.appendSlice(arena, "],\"prefixes\":[");
        for (cap.prefixes, 0..) |prefix, pi| {
            if (pi > 0) try json.appendSlice(arena, ",");
            try appendJsonString(&json, arena, prefix);
        }
        try json.appendSlice(arena, "],\"grant_seq\":");
        try appendU64(&json, arena, cap.grant_seq);
        try json.appendSlice(arena, ",\"expires_at_ms\":");
        try appendU64(&json, arena, cap.expires_at_ms);
        try json.appendSlice(arena, ",\"granted_at_ms\":");
        try appendU64(&json, arena, cap.granted_at_ms);
        try json.appendSlice(arena, "}");
    }
    try json.appendSlice(arena, "],\"invalid_events\":");
    try appendU64(&json, arena, fold.invalid_events + loaded.malformed);
    try json.appendSlice(arena, ",\"verified\":true}");

    return ctx.value(json.items);
}

// ╔═══════════════════════════════════════════════╗
// ║  Helpers                                       ║
// ╚═══════════════════════════════════════════════╝

const KeyMaterial = union(enum) {
    /// 64-byte Ed25519 secret key of the granting org — sign server-side.
    sk: [64]u8,
    /// Pre-computed detached signature over the canonical bytes.
    sig: [64]u8,
};

fn parseKeyMaterial(arg: []const u8) ?KeyMaterial {
    if (std.mem.startsWith(u8, arg, "sk=")) {
        const bytes = trust_log.parseSigHex(arg["sk=".len..]) orelse return null;
        return .{ .sk = bytes };
    }
    if (std.mem.startsWith(u8, arg, "sig=")) {
        const bytes = trust_log.parseSigHex(arg["sig=".len..]) orelse return null;
        return .{ .sig = bytes };
    }
    return null;
}

/// Sign (sk=) or take the attached signature (sig=), then verify it against
/// the granting org's public key. Deny-by-default: nothing is appended
/// unless the signature verifies.
fn resolveSignature(km: KeyMaterial, canonical: []const u8, from_org: [32]u8) ![64]u8 {
    const sig: [64]u8 = switch (km) {
        .sk => |sk_bytes| blk: {
            const sk = Ed25519.SecretKey.fromBytes(sk_bytes) catch return error.BadKey;
            const kp = Ed25519.KeyPair.fromSecretKey(sk) catch return error.BadKey;
            if (!std.mem.eql(u8, &kp.public_key.toBytes(), from_org[0..]))
                return error.KeyOrgMismatch;
            const s = kp.sign(canonical, null) catch return error.BadKey;
            break :blk s.toBytes();
        },
        .sig => |s| s,
    };
    if (!trust_log.verifyBytes(canonical, sig, from_org)) return error.BadSignature;
    return sig;
}

fn parseCapsCsv(allocator: std.mem.Allocator, csv: []const u8) !u8 {
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer names.deinit(allocator);
    var it = std.mem.splitScalar(u8, csv, ',');
    while (it.next()) |name| {
        if (name.len == 0) return error.BadCaps;
        try names.append(allocator, name);
    }
    return trust_log.capBitsFromNames(names.items) orelse error.BadCaps;
}

/// Split the comma-separated prefix list. Prefixes containing a comma cannot
/// be expressed through this EXEC (the canonical byte format itself has no
/// such limit — length-prefixed).
fn parsePrefixesCsv(allocator: std.mem.Allocator, csv: []const u8) ![]const []const u8 {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer list.deinit(allocator);
    var it = std.mem.splitScalar(u8, csv, ',');
    while (it.next()) |prefix| {
        if (prefix.len == 0) return error.BadPrefixes;
        try list.append(allocator, prefix);
    }
    if (list.items.len == 0 or list.items.len > MAX_PREFIXES) return error.BadPrefixes;
    return list.toOwnedSlice(allocator);
}

/// Append via the existing primitive, retrying WORM sequence collisions
/// (same pattern as coordination.zig). Returns the arena-owned result.
fn appendWithRetry(
    allocator: std.mem.Allocator,
    store: *Store,
    log_id: []const u8,
    payload: []const u8,
) !append_log.AppendResult {
    var attempts: usize = 0;
    while (attempts < MAX_APPEND_ATTEMPTS) : (attempts += 1) {
        const result = append_log.append(allocator, store, log_id, payload, &.{}, .{}) catch |err| switch (err) {
            error.SequenceReuse => continue,
            else => return err,
        };
        return result;
    }
    return error.SequenceContention;
}

fn grantPayload(
    allocator: std.mem.Allocator,
    from_hex: []const u8,
    to_hex: []const u8,
    cap_bits: u8,
    prefixes: []const []const u8,
    expires_at_ms: u64,
    granted_at_ms: u64,
    sig: [64]u8,
) ![]u8 {
    var json: std.ArrayListUnmanaged(u8) = .empty;
    errdefer json.deinit(allocator);
    try json.appendSlice(allocator, "{\"t\":\"trust.grant\",\"from_org\":\"");
    try appendLowerHex(&json, allocator, from_hex);
    try json.appendSlice(allocator, "\",\"to_org\":\"");
    try appendLowerHex(&json, allocator, to_hex);
    try json.appendSlice(allocator, "\",\"caps\":[");
    var emitted: usize = 0;
    inline for (trust_log.CAP_NAMES) |entry| {
        if (cap_bits & entry.bit != 0) {
            if (emitted > 0) try json.appendSlice(allocator, ",");
            emitted += 1;
            try json.appendSlice(allocator, "\"");
            try json.appendSlice(allocator, entry.name);
            try json.appendSlice(allocator, "\"");
        }
    }
    try json.appendSlice(allocator, "],\"prefixes\":[");
    for (prefixes, 0..) |prefix, i| {
        if (i > 0) try json.appendSlice(allocator, ",");
        try appendJsonString(&json, allocator, prefix);
    }
    try json.appendSlice(allocator, "],\"expires_at_ms\":");
    try appendU64(&json, allocator, expires_at_ms);
    try json.appendSlice(allocator, ",\"granted_at_ms\":");
    try appendU64(&json, allocator, granted_at_ms);
    try json.appendSlice(allocator, ",\"sig\":\"");
    try appendSigHex(&json, allocator, sig);
    try json.appendSlice(allocator, "\"}");
    return json.toOwnedSlice(allocator);
}

fn revokePayload(
    allocator: std.mem.Allocator,
    from_hex: []const u8,
    to_hex: []const u8,
    grant_seq: u64,
    revoked_at_ms: u64,
    sig: [64]u8,
) ![]u8 {
    var json: std.ArrayListUnmanaged(u8) = .empty;
    errdefer json.deinit(allocator);
    try json.appendSlice(allocator, "{\"t\":\"trust.revoke\",\"from_org\":\"");
    try appendLowerHex(&json, allocator, from_hex);
    try json.appendSlice(allocator, "\",\"to_org\":\"");
    try appendLowerHex(&json, allocator, to_hex);
    try json.appendSlice(allocator, "\",\"grant_seq\":");
    try appendU64(&json, allocator, grant_seq);
    try json.appendSlice(allocator, ",\"revoked_at_ms\":");
    try appendU64(&json, allocator, revoked_at_ms);
    try json.appendSlice(allocator, ",\"sig\":\"");
    try appendSigHex(&json, allocator, sig);
    try json.appendSlice(allocator, "\"}");
    return json.toOwnedSlice(allocator);
}

/// Append caller-supplied hex normalized to lowercase (hex args may arrive
/// uppercase; the stored JSON and log ids are canonical lowercase).
fn appendLowerHex(list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, hex: []const u8) !void {
    for (hex) |c| {
        try list.append(allocator, std.ascii.toLower(c));
    }
}

fn appendOrgHex(list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, org: [32]u8) !void {
    const hex = std.fmt.bytesToHex(org, .lower);
    try list.appendSlice(allocator, hex[0..]);
}

fn appendSigHex(list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, sig: [64]u8) !void {
    const hex = std.fmt.bytesToHex(sig, .lower);
    try list.appendSlice(allocator, hex[0..]);
}

fn appendU64(list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, n: u64) !void {
    var buf: [20]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch "0";
    try list.appendSlice(allocator, s);
}

fn appendJsonString(list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, bytes: []const u8) !void {
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
const Response = @import("../core/types.zig").Response;
const org_trust = @import("../cluster/org_trust.zig");
const Org = org_trust.Org;

fn runProc(store: *Store, func: *const fn (*Ctx) anyerror!Response, args: []const []const u8, allocator: std.mem.Allocator) !Response {
    var ctx = Ctx.init(store, args, allocator, null, null, null, null);
    defer ctx.deinit();
    return try func(&ctx);
}

fn hexOf(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const alphabet = "0123456789abcdef";
    const out = try allocator.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |b, i| {
        out[i * 2] = alphabet[b >> 4];
        out[i * 2 + 1] = alphabet[b & 0x0f];
    }
    return out;
}

fn extractJsonU64(json: []const u8, field: []const u8) ?u64 {
    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\":", .{field}) catch return null;
    const start = std.mem.indexOf(u8, json, needle) orelse return null;
    const pos = start + needle.len;
    var end = pos;
    while (end < json.len and json[end] >= '0' and json[end] <= '9') : (end += 1) {}
    if (end == pos) return null;
    return std.fmt.parseUnsigned(u64, json[pos..end], 10) catch null;
}

test "trust EXEC lifecycle: grant → fold shows it, revoke → fold hides it" {
    var store = try Store.init(testing.allocator, Config{ .persistence = .none });
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const org_a = Org.generateOrgKeyPair(); // granting org
    const org_b: [32]u8 = @splat(0x22); // delegated org (identity only)
    const a_hex = try hexOf(allocator, &org_a.public_key.toBytes());
    const b_hex = try hexOf(allocator, &org_b);
    const sk_arg = try std.fmt.allocPrint(allocator, "sk={s}", .{try hexOf(allocator, &org_a.secret_key.toBytes())});

    // Grant write on mem:acme: to org B.
    const granted = try runProc(&store, grantExecute, &.{
        a_hex, b_hex, "write", "mem:acme:", sk_arg,
    }, allocator);
    const granted_value = granted.value.?;
    const grant_seq = extractJsonU64(granted_value, "grant_seq").?;
    try testing.expect(grant_seq > 0);
    try testing.expect(std.mem.containsAtLeast(u8, granted_value, 1, "\"log_id\":\"trust:"));

    // Fold shows the active capability, independently signature-verified.
    const folded = try runProc(&store, foldExecute, &.{a_hex}, allocator);
    const folded_value = folded.value.?;
    try testing.expect(std.mem.containsAtLeast(u8, folded_value, 1, b_hex));
    try testing.expect(std.mem.containsAtLeast(u8, folded_value, 1, "\"caps\":[\"write\"]"));
    try testing.expect(std.mem.containsAtLeast(u8, folded_value, 1, "\"prefixes\":[\"mem:acme:\"]"));
    try testing.expect(std.mem.containsAtLeast(u8, folded_value, 1, "\"invalid_events\":0"));
    try testing.expect(std.mem.containsAtLeast(u8, folded_value, 1, "\"verified\":true"));

    // Fold filtered to a different to_org is empty.
    const other_hex = try hexOf(allocator, &([_]u8{0x33} ** 32));
    const filtered = try runProc(&store, foldExecute, &.{ a_hex, other_hex }, allocator);
    try testing.expect(std.mem.containsAtLeast(u8, filtered.value.?, 1, "\"capabilities\":[]"));

    // Revoke of a nonexistent grant errs.
    const missing = try runProc(&store, revokeExecute, &.{ a_hex, b_hex, "99", sk_arg }, allocator);
    try testing.expectEqualStrings("trust_revoke: grant_seq is not a matching trust.grant on this log", missing.err);

    // Revoke the real grant.
    var seq_buf: [20]u8 = undefined;
    const seq_arg = try std.fmt.bufPrint(&seq_buf, "{d}", .{grant_seq});
    const revoked = try runProc(&store, revokeExecute, &.{ a_hex, b_hex, seq_arg, sk_arg }, allocator);
    try testing.expect(std.mem.containsAtLeast(u8, revoked.value.?, 1, "\"revoked\":true"));

    // Fold no longer lists the capability, and nothing is invalid.
    const refolded = try runProc(&store, foldExecute, &.{a_hex}, allocator);
    try testing.expect(std.mem.containsAtLeast(u8, refolded.value.?, 1, "\"capabilities\":[]"));
    try testing.expect(std.mem.containsAtLeast(u8, refolded.value.?, 1, "\"invalid_events\":0"));
}

test "trust_grant: expiry via at_ms, precomputed sig=, and bad-signature rejection" {
    var store = try Store.init(testing.allocator, Config{ .persistence = .none });
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const org_a = Org.generateOrgKeyPair();
    const org_b: [32]u8 = @splat(0x22);
    const a_pub = org_a.public_key.toBytes();
    const a_hex = try hexOf(allocator, &a_pub);
    const b_hex = try hexOf(allocator, &org_b);

    // Client-side signing (sig=): build the canonical bytes and sign locally.
    const prefixes = [_][]const u8{"globex:"};
    const canonical = try trust_log.encodeGrantBytes(allocator, .{
        .from_org = a_pub,
        .to_org = org_b,
        .cap_bits = trust_log.CAP_READ | trust_log.CAP_APPEND,
        .prefixes = prefixes[0..],
        .expires_at_ms = 5000,
        .granted_at_ms = 100,
    });
    const sig = try trust_log.signBytes(canonical, org_a.secret_key.toBytes());
    const sig_arg = try std.fmt.allocPrint(allocator, "sig={s}", .{try hexOf(allocator, &sig)});

    const granted = try runProc(&store, grantExecute, &.{
        a_hex, b_hex, "read,append", "globex:", "expires_at_ms=5000", "granted_at_ms=100", sig_arg,
    }, allocator);
    try testing.expect(extractJsonU64(granted.value.?, "grant_seq") != null);

    // Before expiry: active. At/after expiry: gone.
    const before = try runProc(&store, foldExecute, &.{ a_hex, "at_ms=4999" }, allocator);
    try testing.expect(std.mem.containsAtLeast(u8, before.value.?, 1, "\"caps\":[\"read\",\"append\"]"));
    const after = try runProc(&store, foldExecute, &.{ a_hex, "at_ms=5000" }, allocator);
    try testing.expect(std.mem.containsAtLeast(u8, after.value.?, 1, "\"capabilities\":[]"));

    // A signature over DIFFERENT parameters is rejected before append.
    const wrong = try runProc(&store, grantExecute, &.{
        a_hex, b_hex, "write", "globex:", "expires_at_ms=5000", "granted_at_ms=100", sig_arg,
    }, allocator);
    try testing.expectEqualStrings("trust_grant: signature does not verify against from_org", wrong.err);

    // An sk that is not from_org's key is rejected.
    const other = Org.generateOrgKeyPair();
    const wrong_sk = try std.fmt.allocPrint(allocator, "sk={s}", .{try hexOf(allocator, &other.secret_key.toBytes())});
    const mismatch = try runProc(&store, grantExecute, &.{ a_hex, b_hex, "write", "globex:", wrong_sk }, allocator);
    try testing.expectEqualStrings("trust_grant: sk does not match from_org", mismatch.err);

    // Missing key material / bad caps / bad prefixes err.
    const nokey = try runProc(&store, grantExecute, &.{ a_hex, b_hex, "write", "globex:" }, allocator);
    try testing.expectEqualStrings("trust_grant: pass exactly one of sk= or sig=", nokey.err);
    const badcaps = try runProc(&store, grantExecute, &.{ a_hex, b_hex, "admin", "globex:", sig_arg }, allocator);
    try testing.expectEqualStrings("trust_grant: caps must be a csv of read|write|append", badcaps.err);
    const badprefix = try runProc(&store, grantExecute, &.{ a_hex, b_hex, "write", "", sig_arg }, allocator);
    try testing.expectEqualStrings("trust_grant: prefixes_csv must list 1..64 non-empty prefixes", badprefix.err);
}

test "dynamic authorization: delegated org allowed, denied after revoke via generation bump" {
    var store = try Store.init(testing.allocator, Config{ .persistence = .none });
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const our_org = Org.generateOrgKeyPair();
    const delegated: [32]u8 = @splat(0x44);
    const stranger: [32]u8 = @splat(0x55);
    const our_hex = try hexOf(allocator, &our_org.public_key.toBytes());
    const delegated_hex = try hexOf(allocator, &delegated);
    const sk_arg = try std.fmt.allocPrint(allocator, "sk={s}", .{try hexOf(allocator, &our_org.secret_key.toBytes())});

    // Our org grants write on mem:acme: to the delegated org.
    const granted = try runProc(&store, grantExecute, &.{
        our_hex, delegated_hex, "write", "mem:acme:", sk_arg,
    }, allocator);
    const grant_seq = extractJsonU64(granted.value.?, "grant_seq").?;

    var dyn = org_trust.DynamicTrust.init(testing.allocator, &store, our_org.public_key.toBytes());
    defer dyn.deinit();

    // The replication-path composition: static grants fail → dynamic decides.
    const trust = org_trust.OrgTrust{ .enforce = true, .dynamic = &dyn };
    try testing.expect(!trust.keyAuthorized(delegated, "mem:acme:doc:1")); // static: no config grant

    try testing.expect(dyn.authorized(delegated, "mem:acme:doc:1", org_trust.CAP_WRITE));
    try testing.expect(!dyn.authorized(delegated, "other:key", org_trust.CAP_WRITE)); // prefix miss
    try testing.expect(!dyn.authorized(delegated, "mem:acme:doc:1", org_trust.CAP_APPEND)); // cap miss
    try testing.expect(!dyn.authorized(stranger, "mem:acme:doc:1", org_trust.CAP_WRITE)); // org miss

    // Revoke — the EXEC bumps the fold generation, so the cached fold (well
    // within its 5s TTL) is discarded and the next op is denied.
    var seq_buf: [20]u8 = undefined;
    const seq_arg = try std.fmt.bufPrint(&seq_buf, "{d}", .{grant_seq});
    const revoked = try runProc(&store, revokeExecute, &.{ our_hex, delegated_hex, seq_arg, sk_arg }, allocator);
    try testing.expect(std.mem.containsAtLeast(u8, revoked.value.?, 1, "\"revoked\":true"));

    try testing.expect(!dyn.authorized(delegated, "mem:acme:doc:1", org_trust.CAP_WRITE));
}
