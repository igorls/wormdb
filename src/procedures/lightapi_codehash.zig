//! Light-API `/codehash/SHA256` — accounts whose contract code hash == SHA256, grouped per chain.
//! EXEC lightapi_codehash <hash>
//!
//! Output: `{"<chain>":{"accounts":{"<acct>":{"account_name":"<acct>","code_hash":"<hash>"},…},
//! "chain":{…}}}` — or `{}` when the hash matches nothing (or is malformed). Reads the frozen
//! codehash reverse-index (table 10): fnv1a64(hash) → `[u16 hdr_len][hash hex]["account\n"…]`.

const std = @import("std");
const Ctx = @import("context.zig").Ctx;
const name = @import("../core/name.zig");
const chainmod = @import("lightapi_chain.zig");

fn isHex64(s: []const u8) bool {
    if (s.len != 64) return false;
    for (s) |c| {
        if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'))) return false;
    }
    return true;
}

pub fn execute(ctx: *Ctx) anyerror!Ctx.Result {
    const raw = ctx.arg(0) orelse return ctx.err("need <hash>");
    const a = ctx.allocator;

    const hash = try a.alloc(u8, raw.len);
    for (raw, 0..) |c, i| hash[i] = std.ascii.toLower(c);
    if (!isHex64(hash)) return ctx.value("{}");

    const seg = ctx.store.lightapi_segment orelse return ctx.value("{}");
    const blob = seg.lookup(.codehash, name.keyHash(hash)) orelse return ctx.value("{}");
    if (blob.len < 2) return ctx.value("{}");
    const hdr_len = std.mem.readInt(u16, blob[0..2], .little);
    const after = 2 + @as(usize, hdr_len);
    if (after > blob.len) return ctx.value("{}");
    if (!std.mem.eql(u8, blob[2..after], hash)) return ctx.value("{}"); // fnv collision guard
    const accts = blob[after..];

    // The segment is single-chain: take the configured chain from `lachains` (first entry).
    const chains = (try ctx.getCopy("lachains")) orelse return ctx.value("{}");
    const chain_name = std.mem.sliceTo(chains, ',');
    const chain_block = (try chainmod.block(ctx, a, chain_name)) orelse return ctx.value("{}");

    var json: std.ArrayListUnmanaged(u8) = .empty;
    try json.appendSlice(a, "{\"");
    try json.appendSlice(a, chain_name);
    try json.appendSlice(a, "\":{\"accounts\":{");
    var i: usize = 0;
    var it = std.mem.splitScalar(u8, accts, '\n');
    while (it.next()) |acct| {
        if (acct.len == 0) continue;
        if (i > 0) try json.append(a, ',');
        i += 1;
        try json.append(a, '"');
        try json.appendSlice(a, acct);
        try json.appendSlice(a, "\":{\"account_name\":\"");
        try json.appendSlice(a, acct);
        try json.appendSlice(a, "\",\"code_hash\":\"");
        try json.appendSlice(a, hash);
        try json.appendSlice(a, "\"}");
    }
    if (i == 0) return ctx.value("{}"); // no accounts → omit the network entirely (cc32d9)
    try json.appendSlice(a, "},\"chain\":");
    try json.appendSlice(a, chain_block);
    try json.appendSlice(a, "}}");
    return ctx.value(try json.toOwnedSlice(a));
}

test {
    std.testing.refAllDecls(@This());
}
