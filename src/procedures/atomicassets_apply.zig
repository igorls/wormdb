//! AtomicAssets live deltas as compiled procedures (WP-011) — the SHiP feed calls these per irreversible
//! block to keep the AA segment current. Each mutates the KV overlay (`aa:f:` forward override + `aa:o:`
//! per-owner add-set) durably (WAL + replicate). The re-validation spine (a read drops any candidate whose
//! current forward record no longer matches) means transfers/burns need no posting surgery.
//!
//! Single-writer assumption: the chain SHiP feed is one applier per chain, so the read-then-write of an
//! overlay key is race-free without holding a lock across it (reads use getCopy, writes use setDurable).

const std = @import("std");
const Ctx = @import("context.zig").Ctx;
const name = @import("../antelope/name.zig");
const aa = @import("../atomicassets/binfmt.zig");
const ov = @import("../atomicassets/overlay.zig");

/// EXEC aa_mint <asset_id> <owner> <collection> <schema> <template_id> <block_num> <template_mint>
pub fn mint(ctx: *Ctx) anyerror!Ctx.Result {
    const a = ctx.allocator;
    const id = ctx.argInt(u64, 0) orelse return ctx.err("aa_mint requires <asset_id> <owner> <collection> <schema> <template_id> <block_num> <template_mint>");
    const owner = ctx.arg(1) orelse return ctx.err("aa_mint missing owner");
    const collection = ctx.arg(2) orelse return ctx.err("aa_mint missing collection");
    const schema = ctx.arg(3) orelse return ctx.err("aa_mint missing schema");
    const template_id = ctx.argInt(i32, 4) orelse -1;
    const block_num = ctx.argInt(u32, 5) orelse 0;
    const template_mint = ctx.argInt(u32, 6) orelse 0;

    const blob = try ov.encodeAssetCore(a, name.encode(owner), name.encode(collection), name.encode(schema), template_id, block_num, template_mint);
    try ctx.setDurable(try ov.fwdKey(a, id), blob);
    try addToOwner(ctx, owner, id);
    return ctx.ok();
}

/// EXEC aa_transfer <asset_id> <new_owner>
pub fn transfer(ctx: *Ctx) anyerror!Ctx.Result {
    const a = ctx.allocator;
    const id = ctx.argInt(u64, 0) orelse return ctx.err("aa_transfer requires <asset_id> <new_owner>");
    const new_owner = ctx.arg(1) orelse return ctx.err("aa_transfer missing new_owner");

    const cur = (try ov.currentAsset(ctx.store, a, id)) orelse return ctx.err("unknown or burned asset");
    const asset = aa.decodeAsset(cur) orelse return ctx.err("bad asset record");
    var obuf: [13]u8 = undefined;
    const old_owner = name.decode(asset.owner, &obuf);

    if (asset.owner == name.encode(new_owner)) return ctx.ok(); // no-op

    // forward override with the new owner (all other fields + attrs preserved)
    try ctx.setDurable(try ov.fwdKey(a, id), try ov.withOwner(a, cur, name.encode(new_owner)));
    // add to the new owner's add-set; drop from the old owner's add-set if it was an overlay add
    try addToOwner(ctx, new_owner, id);
    try removeFromOwner(ctx, old_owner, id);
    return ctx.ok();
}

/// EXEC aa_burn <asset_id>
pub fn burn(ctx: *Ctx) anyerror!Ctx.Result {
    const a = ctx.allocator;
    const id = ctx.argInt(u64, 0) orelse return ctx.err("aa_burn requires <asset_id>");

    // best-effort: pull the current owner so we can drop it from that add-set
    if (try ov.currentAsset(ctx.store, a, id)) |cur| {
        if (aa.decodeAsset(cur)) |asset| {
            var obuf: [13]u8 = undefined;
            try removeFromOwner(ctx, name.decode(asset.owner, &obuf), id);
        }
    }
    try ctx.setDurable(try ov.fwdKey(a, id), ov.TOMB);
    return ctx.ok();
}

fn addToOwner(ctx: *Ctx, owner: []const u8, id: u64) !void {
    const a = ctx.allocator;
    const k = try ov.ownerKey(a, owner);
    const cur = (try ctx.getCopy(k)) orelse &[_]u8{};
    try ctx.setDurable(k, try ov.addAppend(a, cur, id));
}

fn removeFromOwner(ctx: *Ctx, owner: []const u8, id: u64) !void {
    const a = ctx.allocator;
    const k = try ov.ownerKey(a, owner);
    const cur = (try ctx.getCopy(k)) orelse return; // nothing to remove
    if (ov.addContains(cur, id)) try ctx.setDurable(k, try ov.addRemove(a, cur, id));
}

test {
    std.testing.refAllDecls(@This());
}
