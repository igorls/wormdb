//! Light-API `/key/PUBKEY` — accounts whose permissions include PUBKEY, each hydrated with its full
//! permission list. EXEC lightapi_key <pubkey>
//!
//! Output: `{"<chain>":{"accounts":{"<acct>":[<perms>],…},"chain":{…}}}` — or `{}` if nothing
//! matches. The matching accounts come from the segment `pub_keys` table (table 7, the same the WS
//! get_accounts_from_keys streams: fnv1a64(pubkey) → "account\tperm\tweight\n"…); each account's full
//! permissions are read from its `accinfo` record (binary → rendered, or the live JSON overlay) and
//! the `"permissions":[…]` array is spliced out.

const std = @import("std");
const Ctx = @import("context.zig").Ctx;
const name = @import("../antelope/name.zig");
const la = @import("../lightapi/tables.zig");
const accinfo_bin = @import("accinfo_bin.zig");
const chainmod = @import("lightapi_chain.zig");

/// Return the balanced `"permissions":[…]` array slice from a cc32d9 accinfo JSON fragment, or null.
fn extractPermsArray(frag: []const u8) ?[]const u8 {
    const needle = "\"permissions\":";
    const at = std.mem.indexOf(u8, frag, needle) orelse return null;
    const arr_start = at + needle.len;
    if (arr_start >= frag.len or frag[arr_start] != '[') return null;
    var depth: i32 = 0;
    var in_str = false;
    var esc = false;
    var i = arr_start;
    while (i < frag.len) : (i += 1) {
        const c = frag[i];
        if (in_str) {
            if (esc) esc = false else if (c == '\\') esc = true else if (c == '"') in_str = false;
        } else if (c == '"') {
            in_str = true;
        } else if (c == '[') {
            depth += 1;
        } else if (c == ']') {
            depth -= 1;
            if (depth == 0) return frag[arr_start .. i + 1];
        }
    }
    return null;
}

fn lessThan(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.order(u8, x, y) == .lt;
}

pub fn execute(ctx: *Ctx) anyerror!Ctx.Result {
    const pubkey = ctx.arg(0) orelse return ctx.err("need <pubkey>");
    const a = ctx.allocator;

    const seg = ctx.store.segment("lightapi") orelse return ctx.value("{}");
    const blob = seg.lookup(la.TableId.pub_keys, name.keyHash(pubkey)) orelse return ctx.value("{}");

    // Unique matching accounts (a key can appear in several of an account's permissions).
    var accts: std.ArrayListUnmanaged([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, blob, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var f = std.mem.splitScalar(u8, line, '\t');
        const acct = f.next() orelse continue;
        var dup = false;
        for (accts.items) |e| {
            if (std.mem.eql(u8, e, acct)) {
                dup = true;
                break;
            }
        }
        if (!dup) try accts.append(a, acct);
    }
    if (accts.items.len == 0) return ctx.value("{}");
    std.mem.sort([]const u8, accts.items, {}, lessThan);

    const chains = (try ctx.getCopy("lachains")) orelse return ctx.value("{}");
    const chain_name = std.mem.sliceTo(chains, ',');

    var json: std.ArrayListUnmanaged(u8) = .empty;
    try json.appendSlice(a, "{\"");
    try json.appendSlice(a, chain_name);
    try json.appendSlice(a, "\":{\"accounts\":{");
    for (accts.items, 0..) |acct, idx| {
        const frag: ?[]const u8 = blk: {
            if (try ctx.getCopy(ctx.fmt("acci:{s}:{s}", .{ chain_name, acct }))) |o| break :blk o;
            break :blk seg.lookup(la.TableId.accinfo, name.encode(acct));
        };
        var perms: []const u8 = "[]";
        if (frag) |f| {
            if (accinfo_bin.isBinary(f)) {
                var rendered: std.ArrayListUnmanaged(u8) = .empty;
                if (accinfo_bin.render(&rendered, a, f)) |_| {
                    if (extractPermsArray(rendered.items)) |p| perms = p;
                } else |_| {}
            } else if (extractPermsArray(f)) |p| {
                perms = p;
            }
        }
        if (idx > 0) try json.append(a, ',');
        try json.append(a, '"');
        try json.appendSlice(a, acct);
        try json.appendSlice(a, "\":");
        try json.appendSlice(a, perms);
    }
    try json.appendSlice(a, "},\"chain\":");
    try json.appendSlice(a, (try chainmod.block(ctx, a, chain_name)) orelse "{}");
    try json.appendSlice(a, "}}");
    return ctx.value(try json.toOwnedSlice(a));
}

test {
    std.testing.refAllDecls(@This());
}
