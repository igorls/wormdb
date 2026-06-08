//! Append-friendly Merkle Mountain Range proof primitive.
//!
//! This module is intentionally storage-agnostic. It maintains an in-memory
//! accumulator over canonical leaf bytes, exposes deterministic roots, and
//! creates inclusion proofs that can be verified without access to the
//! accumulator.

const std = @import("std");

const Sha256 = std.crypto.hash.sha2.Sha256;

pub const HASH_LEN: usize = 32;
pub const Hash = [HASH_LEN]u8;

pub const DOMAIN_LEAF = "wormdb.proof.mmr.leaf.v1";
pub const DOMAIN_PARENT = "wormdb.proof.mmr.parent.v1";
pub const DOMAIN_ROOT = "wormdb.proof.mmr.root.v1";

pub const PROOF_MAGIC = "WDBMMR1";
pub const PROOF_VERSION: u16 = 1;
pub const PROOF_SIDE_LEFT: u8 = 0;
pub const PROOF_SIDE_RIGHT: u8 = 1;

pub const Error = std.mem.Allocator.Error || error{
    LeafIndexOutOfBounds,
    CorruptAccumulator,
    TooManyLeaves,
};

pub const SiblingSide = enum(u8) {
    left,
    right,
};

pub const PathItem = struct {
    /// The side of `hash` relative to the running proof hash.
    side: SiblingSide,
    hash: Hash,
};

pub const Peak = struct {
    height: u8,
    hash: Hash,
};

const Mountain = struct {
    start: u64,
    height: u8,
    hash: Hash,
};

pub const InclusionProof = struct {
    allocator: std.mem.Allocator,
    leaf_index: u64,
    leaf_count: u64,
    peak_index: usize,
    path: []PathItem,
    peaks: []Peak,

    pub fn deinit(self: *InclusionProof) void {
        self.allocator.free(self.path);
        self.allocator.free(self.peaks);
        self.* = undefined;
    }
};

pub const Accumulator = struct {
    allocator: std.mem.Allocator,
    leaf_count: u64 = 0,
    peaks: std.ArrayListUnmanaged(Mountain) = .empty,
    nodes: std.AutoHashMapUnmanaged(u128, Hash) = .empty,

    pub fn init(allocator: std.mem.Allocator) Accumulator {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Accumulator) void {
        self.peaks.deinit(self.allocator);
        self.nodes.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn len(self: *const Accumulator) u64 {
        return self.leaf_count;
    }

    pub fn root(self: *const Accumulator) Hash {
        return rootFromMountains(self.leaf_count, self.peaks.items);
    }

    /// Append canonical leaf bytes and return the updated root.
    ///
    /// The update touches only the new leaf and any right-edge peaks that need
    /// to be merged, so historical leaves are never re-read or re-hashed.
    pub fn append(self: *Accumulator, leaf: []const u8) Error!Hash {
        if (self.leaf_count == std.math.maxInt(u64)) return error.TooManyLeaves;

        const leaf_index = self.leaf_count;
        var carry = Mountain{
            .start = leaf_index,
            .height = 0,
            .hash = hashLeaf(leaf_index, leaf),
        };
        try self.nodes.put(self.allocator, nodeKey(carry.start, carry.height), carry.hash);

        while (self.peaks.items.len > 0) {
            const left = self.peaks.items[self.peaks.items.len - 1];
            if (left.height != carry.height) break;
            _ = self.peaks.pop();

            const expected_right_start = left.start + peakSize(left.height);
            if (expected_right_start != carry.start) return error.CorruptAccumulator;
            carry = .{
                .start = left.start,
                .height = left.height + 1,
                .hash = hashParent(left.height + 1, left.hash, carry.hash),
            };
            try self.nodes.put(self.allocator, nodeKey(carry.start, carry.height), carry.hash);
        }

        try self.peaks.append(self.allocator, carry);
        self.leaf_count += 1;
        return self.root();
    }

    pub fn copyPeaks(self: *const Accumulator, allocator: std.mem.Allocator) std.mem.Allocator.Error![]Peak {
        const out = try allocator.alloc(Peak, self.peaks.items.len);
        for (self.peaks.items, 0..) |peak, i| {
            out[i] = .{ .height = peak.height, .hash = peak.hash };
        }
        return out;
    }

    pub fn prove(self: *const Accumulator, leaf_index: u64, allocator: std.mem.Allocator) Error!InclusionProof {
        if (leaf_index >= self.leaf_count) return error.LeafIndexOutOfBounds;

        const peak_index = self.findPeakIndex(leaf_index) orelse return error.CorruptAccumulator;
        const peak = self.peaks.items[peak_index];
        const path_len: usize = peak.height;
        const path = try allocator.alloc(PathItem, path_len);
        errdefer allocator.free(path);

        var current_start = leaf_index;
        var level: u8 = 0;
        while (level < peak.height) : (level += 1) {
            const size = peakSize(level);
            const pair_size = size * 2;
            const pair_start = peak.start + ((current_start - peak.start) / pair_size) * pair_size;
            const current_is_left = current_start == pair_start;
            const sibling_start = if (current_is_left) current_start + size else current_start - size;
            const sibling_hash = self.nodes.get(nodeKey(sibling_start, level)) orelse return error.CorruptAccumulator;

            path[level] = .{
                .side = if (current_is_left) .right else .left,
                .hash = sibling_hash,
            };
            current_start = pair_start;
        }

        const peaks_copy = try self.copyPeaks(allocator);
        errdefer allocator.free(peaks_copy);

        return .{
            .allocator = allocator,
            .leaf_index = leaf_index,
            .leaf_count = self.leaf_count,
            .peak_index = peak_index,
            .path = path,
            .peaks = peaks_copy,
        };
    }

    fn findPeakIndex(self: *const Accumulator, leaf_index: u64) ?usize {
        for (self.peaks.items, 0..) |peak, i| {
            const end = peak.start + peakSize(peak.height);
            if (leaf_index >= peak.start and leaf_index < end) return i;
        }
        return null;
    }
};

pub fn emptyRoot() Hash {
    return rootFromPeaks(0, &.{});
}

pub fn hashLeaf(leaf_index: u64, leaf: []const u8) Hash {
    var out: Hash = undefined;
    var h = Sha256.init(.{});
    h.update(DOMAIN_LEAF);
    h.update(&[_]u8{0});
    updateU64(&h, leaf_index);
    updateU64(&h, @intCast(leaf.len));
    h.update(leaf);
    h.final(&out);
    return out;
}

pub fn hashParent(parent_height: u8, left: Hash, right: Hash) Hash {
    var out: Hash = undefined;
    var h = Sha256.init(.{});
    h.update(DOMAIN_PARENT);
    h.update(&[_]u8{0});
    h.update(&[_]u8{parent_height});
    h.update(&left);
    h.update(&right);
    h.final(&out);
    return out;
}

pub fn rootFromPeaks(leaf_count: u64, peaks: []const Peak) Hash {
    var out: Hash = undefined;
    var h = Sha256.init(.{});
    h.update(DOMAIN_ROOT);
    h.update(&[_]u8{0});
    updateU64(&h, leaf_count);
    updateU64(&h, @intCast(peaks.len));
    for (peaks) |peak| {
        h.update(&[_]u8{peak.height});
        h.update(&peak.hash);
    }
    h.final(&out);
    return out;
}

/// Encode inclusion proof bytes for proof bundles and external verifiers.
///
/// Format, all unsigned big-endian:
/// `[magic][u16 version][u64 leaf_index][u64 leaf_count][u32 peak_index]`
/// `[u32 path_len]([u8 side][32B hash])*[u32 peak_count]([u8 height][32B hash])*`
pub fn encodeInclusionProof(allocator: std.mem.Allocator, proof: InclusionProof) ![]u8 {
    if (proof.peak_index > std.math.maxInt(u32)) return error.ProofTooLarge;
    if (proof.path.len > std.math.maxInt(u32)) return error.ProofTooLarge;
    if (proof.peaks.len > std.math.maxInt(u32)) return error.ProofTooLarge;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try appendBytes(&out, allocator, PROOF_MAGIC);
    try appendU16(&out, allocator, PROOF_VERSION);
    try appendU64(&out, allocator, proof.leaf_index);
    try appendU64(&out, allocator, proof.leaf_count);
    try appendU32(&out, allocator, @intCast(proof.peak_index));
    try appendU32(&out, allocator, @intCast(proof.path.len));
    for (proof.path) |item| {
        try appendU8(&out, allocator, switch (item.side) {
            .left => PROOF_SIDE_LEFT,
            .right => PROOF_SIDE_RIGHT,
        });
        try appendBytes(&out, allocator, item.hash[0..]);
    }
    try appendU32(&out, allocator, @intCast(proof.peaks.len));
    for (proof.peaks) |peak| {
        try appendU8(&out, allocator, peak.height);
        try appendBytes(&out, allocator, peak.hash[0..]);
    }

    return try out.toOwnedSlice(allocator);
}

/// Decode proof bytes produced by `encodeInclusionProof`.
///
/// Caller owns the returned proof and must call `deinit`.
pub fn decodeInclusionProof(allocator: std.mem.Allocator, bytes: []const u8) !InclusionProof {
    var pos: usize = 0;

    const magic = try readBytes(bytes, &pos, PROOF_MAGIC.len);
    if (!std.mem.eql(u8, magic, PROOF_MAGIC)) return error.InvalidProofBytes;
    const version = try readU16(bytes, &pos);
    if (version != PROOF_VERSION) return error.UnsupportedProofVersion;

    const leaf_index = try readU64(bytes, &pos);
    const leaf_count = try readU64(bytes, &pos);
    const peak_index = try readU32(bytes, &pos);
    const path_len = try readU32(bytes, &pos);
    const path = try allocator.alloc(PathItem, @intCast(path_len));
    errdefer allocator.free(path);

    for (path) |*item| {
        const side_byte = try readU8(bytes, &pos);
        item.side = switch (side_byte) {
            PROOF_SIDE_LEFT => .left,
            PROOF_SIDE_RIGHT => .right,
            else => return error.InvalidProofBytes,
        };
        item.hash = try readHash(bytes, &pos);
    }

    const peak_count = try readU32(bytes, &pos);
    const peaks = try allocator.alloc(Peak, @intCast(peak_count));
    errdefer allocator.free(peaks);

    for (peaks) |*peak| {
        peak.height = try readU8(bytes, &pos);
        peak.hash = try readHash(bytes, &pos);
    }

    if (pos != bytes.len) return error.InvalidProofBytes;

    return .{
        .allocator = allocator,
        .leaf_index = leaf_index,
        .leaf_count = leaf_count,
        .peak_index = peak_index,
        .path = path,
        .peaks = peaks,
    };
}

pub fn verifyInclusion(proof: InclusionProof, leaf: []const u8, expected_root: Hash) bool {
    if (proof.leaf_count == 0) return false;
    if (proof.leaf_index >= proof.leaf_count) return false;
    if (proof.peak_index >= proof.peaks.len) return false;
    if (!peaksAreCanonical(proof.leaf_count, proof.peaks)) return false;

    const peak_start = peakStart(proof.peaks[0..proof.peak_index]) orelse return false;
    const peak = proof.peaks[proof.peak_index];
    const peak_end = peak_start + peakSize(peak.height);
    if (proof.leaf_index < peak_start or proof.leaf_index >= peak_end) return false;
    if (proof.path.len != peak.height) return false;

    var current = hashLeaf(proof.leaf_index, leaf);
    var current_start = proof.leaf_index;
    for (proof.path, 0..) |item, level_usize| {
        if (level_usize >= 64) return false;
        const level: u8 = @intCast(level_usize);
        const size = peakSize(level);
        const pair_size = size * 2;
        const pair_start = peak_start + ((current_start - peak_start) / pair_size) * pair_size;
        const current_is_left = current_start == pair_start;

        if (current_is_left) {
            if (item.side != .right) return false;
            current = hashParent(level + 1, current, item.hash);
        } else {
            if (item.side != .left) return false;
            current = hashParent(level + 1, item.hash, current);
        }
        current_start = pair_start;
    }

    if (!hashesEqual(current, peak.hash)) return false;
    return hashesEqual(rootFromPeaks(proof.leaf_count, proof.peaks), expected_root);
}

fn rootFromMountains(leaf_count: u64, peaks: []const Mountain) Hash {
    var out: Hash = undefined;
    var h = Sha256.init(.{});
    h.update(DOMAIN_ROOT);
    h.update(&[_]u8{0});
    updateU64(&h, leaf_count);
    updateU64(&h, @intCast(peaks.len));
    for (peaks) |peak| {
        h.update(&[_]u8{peak.height});
        h.update(&peak.hash);
    }
    h.final(&out);
    return out;
}

fn peaksAreCanonical(leaf_count: u64, peaks: []const Peak) bool {
    if (leaf_count == 0) return peaks.len == 0;
    if (peaks.len == 0) return false;

    var total: u64 = 0;
    var prev_height: ?u8 = null;
    for (peaks) |peak| {
        if (peak.height >= 64) return false;
        if (prev_height) |prev| {
            if (peak.height >= prev) return false;
        }
        const size = peakSize(peak.height);
        if (std.math.maxInt(u64) - total < size) return false;
        total += size;
        prev_height = peak.height;
    }
    return total == leaf_count;
}

fn peakStart(peaks_before: []const Peak) ?u64 {
    var start: u64 = 0;
    for (peaks_before) |peak| {
        if (peak.height >= 64) return null;
        const size = peakSize(peak.height);
        if (std.math.maxInt(u64) - start < size) return null;
        start += size;
    }
    return start;
}

fn peakSize(height: u8) u64 {
    return @as(u64, 1) << @intCast(height);
}

fn nodeKey(start: u64, height: u8) u128 {
    return (@as(u128, start) << 8) | @as(u128, height);
}

fn updateU64(h: *Sha256, value: u64) void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, buf[0..8], value, .big);
    h.update(&buf);
}

fn appendU8(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: u8) !void {
    try out.append(allocator, value);
}

fn appendU16(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: u16) !void {
    var buf: [2]u8 = undefined;
    std.mem.writeInt(u16, buf[0..2], value, .big);
    try out.appendSlice(allocator, &buf);
}

fn appendU32(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], value, .big);
    try out.appendSlice(allocator, &buf);
}

fn appendU64(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: u64) !void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, buf[0..8], value, .big);
    try out.appendSlice(allocator, &buf);
}

fn appendBytes(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, bytes: []const u8) !void {
    try out.appendSlice(allocator, bytes);
}

fn readU8(bytes: []const u8, pos: *usize) !u8 {
    const b = try readBytes(bytes, pos, 1);
    return b[0];
}

fn readU16(bytes: []const u8, pos: *usize) !u16 {
    const b = try readBytes(bytes, pos, 2);
    return std.mem.readInt(u16, b[0..2], .big);
}

fn readU32(bytes: []const u8, pos: *usize) !u32 {
    const b = try readBytes(bytes, pos, 4);
    return std.mem.readInt(u32, b[0..4], .big);
}

fn readU64(bytes: []const u8, pos: *usize) !u64 {
    const b = try readBytes(bytes, pos, 8);
    return std.mem.readInt(u64, b[0..8], .big);
}

fn readHash(bytes: []const u8, pos: *usize) !Hash {
    const b = try readBytes(bytes, pos, HASH_LEN);
    var hash: Hash = undefined;
    @memcpy(hash[0..], b);
    return hash;
}

fn readBytes(bytes: []const u8, pos: *usize, len: usize) ![]const u8 {
    if (pos.* > bytes.len) return error.InvalidProofBytes;
    if (len > bytes.len - pos.*) return error.InvalidProofBytes;
    const out = bytes[pos.* .. pos.* + len];
    pos.* += len;
    return out;
}

fn hashesEqual(a: Hash, b: Hash) bool {
    return std.mem.eql(u8, &a, &b);
}

fn appendLeaves(acc: *Accumulator, leaves: []const []const u8) !void {
    for (leaves) |leaf| _ = try acc.append(leaf);
}

test "mmr: empty and single leaf roots" {
    const testing = std.testing;
    var acc = Accumulator.init(testing.allocator);
    defer acc.deinit();

    try testing.expectEqual(@as(u64, 0), acc.len());
    try testing.expectEqualSlices(u8, &emptyRoot(), &acc.root());

    const root = try acc.append("alpha");
    try testing.expectEqual(@as(u64, 1), acc.len());
    try testing.expect(!hashesEqual(emptyRoot(), root));

    var proof = try acc.prove(0, testing.allocator);
    defer proof.deinit();
    try testing.expectEqual(@as(usize, 0), proof.path.len);
    try testing.expect(verifyInclusion(proof, "alpha", root));
}

test "mmr: multiple leaf roots are deterministic" {
    const testing = std.testing;
    const leaves = [_][]const u8{ "alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf" };

    var a = Accumulator.init(testing.allocator);
    defer a.deinit();
    var b = Accumulator.init(testing.allocator);
    defer b.deinit();

    try appendLeaves(&a, &leaves);
    try appendLeaves(&b, &leaves);

    try testing.expectEqual(@as(u64, leaves.len), a.len());
    try testing.expectEqualSlices(u8, &a.root(), &b.root());
    try testing.expectEqual(@as(usize, 3), a.peaks.items.len);
    try testing.expectEqual(@as(u8, 2), a.peaks.items[0].height);
    try testing.expectEqual(@as(u8, 1), a.peaks.items[1].height);
    try testing.expectEqual(@as(u8, 0), a.peaks.items[2].height);
}

test "mmr: inclusion proofs verify for every leaf" {
    const testing = std.testing;
    const leaves = [_][]const u8{ "alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel", "india" };

    var acc = Accumulator.init(testing.allocator);
    defer acc.deinit();
    try appendLeaves(&acc, &leaves);
    const root = acc.root();

    for (leaves, 0..) |leaf, i| {
        var proof = try acc.prove(@intCast(i), testing.allocator);
        defer proof.deinit();
        try testing.expect(verifyInclusion(proof, leaf, root));
    }
}

test "mmr: proof tampering is rejected" {
    const testing = std.testing;
    const leaves = [_][]const u8{ "alpha", "bravo", "charlie", "delta", "echo" };

    var acc = Accumulator.init(testing.allocator);
    defer acc.deinit();
    try appendLeaves(&acc, &leaves);
    const root = acc.root();

    {
        var proof = try acc.prove(2, testing.allocator);
        defer proof.deinit();
        try testing.expect(!verifyInclusion(proof, "CHARLIE", root));
    }

    {
        var proof = try acc.prove(2, testing.allocator);
        defer proof.deinit();
        proof.path[0].hash[0] ^= 0xff;
        try testing.expect(!verifyInclusion(proof, leaves[2], root));
    }

    {
        var proof = try acc.prove(2, testing.allocator);
        defer proof.deinit();
        proof.peaks[proof.peak_index].hash[0] ^= 0xff;
        try testing.expect(!verifyInclusion(proof, leaves[2], root));
    }

    {
        var proof = try acc.prove(2, testing.allocator);
        defer proof.deinit();
        var bad_root = root;
        bad_root[0] ^= 0xff;
        try testing.expect(!verifyInclusion(proof, leaves[2], bad_root));
    }
}

test "mmr: inclusion proof bytes round trip" {
    const testing = std.testing;
    const leaves = [_][]const u8{ "alpha", "bravo", "charlie", "delta", "echo" };

    var acc = Accumulator.init(testing.allocator);
    defer acc.deinit();
    try appendLeaves(&acc, &leaves);
    const root = acc.root();

    var proof = try acc.prove(3, testing.allocator);
    defer proof.deinit();

    const encoded = try encodeInclusionProof(testing.allocator, proof);
    defer testing.allocator.free(encoded);

    var decoded = try decodeInclusionProof(testing.allocator, encoded);
    defer decoded.deinit();

    try testing.expectEqual(proof.leaf_index, decoded.leaf_index);
    try testing.expectEqual(proof.leaf_count, decoded.leaf_count);
    try testing.expectEqual(proof.peak_index, decoded.peak_index);
    try testing.expectEqual(proof.path.len, decoded.path.len);
    try testing.expectEqual(proof.peaks.len, decoded.peaks.len);
    try testing.expect(verifyInclusion(decoded, leaves[3], root));
}

test "mmr: encoded proof tampering is rejected" {
    const testing = std.testing;
    const leaves = [_][]const u8{ "alpha", "bravo", "charlie", "delta", "echo" };

    var acc = Accumulator.init(testing.allocator);
    defer acc.deinit();
    try appendLeaves(&acc, &leaves);
    const root = acc.root();

    var proof = try acc.prove(2, testing.allocator);
    defer proof.deinit();

    const encoded = try encodeInclusionProof(testing.allocator, proof);
    defer testing.allocator.free(encoded);

    {
        var bad = try testing.allocator.dupe(u8, encoded);
        defer testing.allocator.free(bad);
        bad[0] ^= 0xff;
        try testing.expectError(error.InvalidProofBytes, decodeInclusionProof(testing.allocator, bad));
    }

    {
        var bad = try testing.allocator.dupe(u8, encoded);
        defer testing.allocator.free(bad);
        bad[encoded.len - 1] ^= 0xff;
        var decoded = try decodeInclusionProof(testing.allocator, bad);
        defer decoded.deinit();
        try testing.expect(!verifyInclusion(decoded, leaves[2], root));
    }
}

test "mmr: old proofs remain valid for old roots after appends" {
    const testing = std.testing;
    const prefix = [_][]const u8{ "alpha", "bravo", "charlie" };

    var acc = Accumulator.init(testing.allocator);
    defer acc.deinit();
    try appendLeaves(&acc, &prefix);

    const root3 = acc.root();
    var proof3 = try acc.prove(1, testing.allocator);
    defer proof3.deinit();
    try testing.expect(verifyInclusion(proof3, "bravo", root3));

    _ = try acc.append("delta");
    _ = try acc.append("echo");
    const root5 = acc.root();

    try testing.expect(!hashesEqual(root3, root5));
    try testing.expect(verifyInclusion(proof3, "bravo", root3));
    try testing.expect(!verifyInclusion(proof3, "bravo", root5));

    var current_proof = try acc.prove(1, testing.allocator);
    defer current_proof.deinit();
    try testing.expect(verifyInclusion(current_proof, "bravo", root5));
}
