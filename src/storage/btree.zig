//! Radix-partitioned (first-byte) ordered B+Tree key index for `Store`.
//!
//! Replaces per-shard sorted `ArrayList(*Entry)` arrays so prefix scans, cursor
//! pagination, and `countPrefix` touch ONE bucket under a single `RwLock`
//! instead of locking and binary-searching all 256 hash shards.
//!
//! Concurrency & lock-order contract:
//! - Overwrites of existing heap entries NEVER touch `OrderedIndex` (0 overhead).
//! - New-key inserts, entry-pointer replacements, and deletes acquire `bucket.lock`
//!   (exclusive) while `shard.mutex` is held: global lock order is strictly
//!   `shard.mutex -> bucket.lock`.
//! - Readers acquire `bucket.lock` (shared) and either:
//!     (a) fast path: use non-blocking `shard.mutex.tryLock()` on `slot.value`
//!         (zero deadlock risk, zero key copy, zero hash-table probe), or
//!     (b) fallback on shard contention: drop `bucket.lock` and fetch via
//!         `CollectedKeys` + `shard.mutex.lock()`.

const std = @import("std");
const core = @import("../core/mod.zig");
const compat = core.compat;

pub const BUCKET_COUNT: usize = 256;
pub const LEAF_CAP: usize = 64;
pub const INTERNAL_CAP: usize = 64;
pub const INLINE_KEY_CAP: usize = 16;

pub const Cut = enum { first, last };

/// Owned compact key storage for internal separator keys (and leaf keys when
/// `borrow_long_leaf_keys == false`): keys `<= 16` bytes live inline; longer
/// keys allocate on the heap.
pub const OwnedKeyBytes = struct {
    storage: extern union {
        inline_buf: [INLINE_KEY_CAP]u8,
        heap_ptr: [*]u8,
    },
    len: u32,

    pub fn init(allocator: std.mem.Allocator, key: []const u8) !OwnedKeyBytes {
        if (key.len <= INLINE_KEY_CAP) {
            var buf: [INLINE_KEY_CAP]u8 = @splat(0);
            @memcpy(buf[0..key.len], key);
            return .{
                .storage = .{ .inline_buf = buf },
                .len = @intCast(key.len),
            };
        }
        const duped = try allocator.alloc(u8, key.len);
        @memcpy(duped, key);
        return .{
            .storage = .{ .heap_ptr = duped.ptr },
            .len = @intCast(key.len),
        };
    }

    pub fn deinit(self: *const OwnedKeyBytes, allocator: std.mem.Allocator) void {
        if (self.len > INLINE_KEY_CAP) {
            allocator.free(self.storage.heap_ptr[0..self.len]);
        }
    }

    pub inline fn slice(self: *const OwnedKeyBytes) []const u8 {
        if (self.len <= INLINE_KEY_CAP) {
            return self.storage.inline_buf[0..self.len];
        }
        return self.storage.heap_ptr[0..self.len];
    }
};

/// Borrowed-long compact key storage for leaf slots when the caller guarantees
/// `key` bytes outlive the slot's membership in `OrderedIndex` (true for `Store`
/// because `Entry.key` is only freed after `ordered.remove` / `ordered.replaceValue`
/// completes under exclusive `bucket.lock`). Keys `<= 16` bytes are STILL copied
/// inline for zero pointer chasing during scans; keys `> 16` bytes pay zero
/// heap allocation and zero free overhead.
pub const BorrowedKeyBytes = struct {
    storage: extern union {
        inline_buf: [INLINE_KEY_CAP]u8,
        borrowed_ptr: [*]const u8,
    },
    len: u32,

    pub fn init(_: std.mem.Allocator, key: []const u8) !BorrowedKeyBytes {
        if (key.len <= INLINE_KEY_CAP) {
            var buf: [INLINE_KEY_CAP]u8 = @splat(0);
            @memcpy(buf[0..key.len], key);
            return .{
                .storage = .{ .inline_buf = buf },
                .len = @intCast(key.len),
            };
        }
        return .{
            .storage = .{ .borrowed_ptr = key.ptr },
            .len = @intCast(key.len),
        };
    }

    pub inline fn deinit(_: *const BorrowedKeyBytes, _: std.mem.Allocator) void {}

    pub inline fn slice(self: *const BorrowedKeyBytes) []const u8 {
        if (self.len <= INLINE_KEY_CAP) {
            return self.storage.inline_buf[0..self.len];
        }
        return self.storage.borrowed_ptr[0..self.len];
    }
};

pub inline fn loadPrefix8(key: []const u8) u64 {
    if (key.len >= 8) {
        return std.mem.readInt(u64, key[0..8], .big);
    }
    var buf: [8]u8 = @splat(0);
    @memcpy(buf[0..key.len], key);
    return std.mem.readInt(u64, &buf, .big);
}

inline fn cmpKeyWithPrefix(p8_a: u64, a: []const u8, p8_b: u64, b: []const u8) std.math.Order {
    if (p8_a != p8_b) return if (p8_a < p8_b) .lt else .gt;
    return std.mem.order(u8, a, b);
}

inline fn prefixCompare(key: []const u8, prefix: []const u8) std.math.Order {
    const n = @min(key.len, prefix.len);
    const ord = std.mem.order(u8, key[0..n], prefix[0..n]);
    if (ord != .eq) return ord;
    if (key.len >= prefix.len) return .eq;
    return .lt;
}

/// Lightweight collected key reference copied out of `OrderedIndex` for the
/// lock-decoupled fallback path (releases `bucket.lock` BEFORE locking shards).
pub const KeyRef = struct {
    off: u32,
    len: u32,
    key_hash: u64,
    shard_idx: u8,
};

pub const CollectedKeys = struct {
    refs_stack: [64]KeyRef = undefined,
    refs_heap: std.ArrayListUnmanaged(KeyRef) = .empty,
    refs_len: usize = 0,
    bytes_stack: [4096]u8 = undefined,
    bytes_heap: std.ArrayListUnmanaged(u8) = .empty,
    bytes_len: usize = 0,
    use_heap_refs: bool = false,
    use_heap_bytes: bool = false,

    pub fn deinit(self: *CollectedKeys, allocator: std.mem.Allocator) void {
        self.refs_heap.deinit(allocator);
        self.bytes_heap.deinit(allocator);
    }

    pub inline fn refs(self: *const CollectedKeys) []const KeyRef {
        return if (self.use_heap_refs) self.refs_heap.items else self.refs_stack[0..self.refs_len];
    }

    pub inline fn keySlice(self: *const CollectedKeys, ref: KeyRef) []const u8 {
        const buf = if (self.use_heap_bytes) self.bytes_heap.items else self.bytes_stack[0..self.bytes_len];
        return buf[ref.off..][0..ref.len];
    }

    pub fn append(self: *CollectedKeys, allocator: std.mem.Allocator, key: []const u8, key_hash: u64, shard_idx: u8) !void {
        const off: usize = if (self.use_heap_bytes) self.bytes_heap.items.len else self.bytes_len;
        if (!self.use_heap_bytes) {
            if (self.bytes_len + key.len <= self.bytes_stack.len) {
                @memcpy(self.bytes_stack[self.bytes_len..][0..key.len], key);
                self.bytes_len += key.len;
            } else {
                try self.bytes_heap.ensureTotalCapacity(allocator, @max(8192, self.bytes_len + key.len));
                self.bytes_heap.appendSliceAssumeCapacity(self.bytes_stack[0..self.bytes_len]);
                try self.bytes_heap.appendSlice(allocator, key);
                self.use_heap_bytes = true;
            }
        } else {
            try self.bytes_heap.appendSlice(allocator, key);
        }

        const ref = KeyRef{
            .off = @intCast(off),
            .len = @intCast(key.len),
            .key_hash = key_hash,
            .shard_idx = shard_idx,
        };
        if (!self.use_heap_refs) {
            if (self.refs_len < self.refs_stack.len) {
                self.refs_stack[self.refs_len] = ref;
                self.refs_len += 1;
            } else {
                try self.refs_heap.ensureTotalCapacity(allocator, 128);
                self.refs_heap.appendSliceAssumeCapacity(self.refs_stack[0..self.refs_len]);
                try self.refs_heap.append(allocator, ref);
                self.use_heap_refs = true;
            }
        } else {
            try self.refs_heap.append(allocator, ref);
        }
    }

    pub fn reverseRefs(self: *CollectedKeys) void {
        const slice = if (self.use_heap_refs) self.refs_heap.items else self.refs_stack[0..self.refs_len];
        std.mem.reverse(KeyRef, slice);
    }

    pub fn clear(self: *CollectedKeys) void {
        self.refs_len = 0;
        self.bytes_len = 0;
        self.refs_heap.clearRetainingCapacity();
        self.bytes_heap.clearRetainingCapacity();
        self.use_heap_refs = false;
        self.use_heap_bytes = false;
    }
};

/// Generic radix-partitioned (first-byte) ordered B+Tree storing `Value` per key.
pub fn OrderedIndex(comptime Value: type, comptime borrow_long_leaf_keys: bool) type {
    const LeafKey = if (borrow_long_leaf_keys) BorrowedKeyBytes else OwnedKeyBytes;

    return struct {
        const Self = @This();

        pub const LeafSlot = struct {
            key: LeafKey,
            value: Value,
            key_hash: u64,
            shard_idx: u8,
        };

        const NodeKind = enum(u8) { leaf, internal };

        pub const NodeHeader = struct {
            kind: NodeKind align(8),
            count: u16,
            subtree_count: u32,
        };

        pub const LeafNode = struct {
            hdr: NodeHeader,
            prev: ?*LeafNode = null,
            next: ?*LeafNode = null,
            prefix8: [LEAF_CAP]u64 = undefined,
            slots: [LEAF_CAP]LeafSlot = undefined,

            inline fn asHeader(self: *LeafNode) *NodeHeader {
                return &self.hdr;
            }

            fn findLowerBound(self: *const LeafNode, p8: u64, key: []const u8) usize {
                var lo: usize = 0;
                var hi: usize = self.hdr.count;
                while (lo < hi) {
                    const mid = lo + (hi - lo) / 2;
                    const mp = self.prefix8[mid];
                    if (mp < p8) {
                        lo = mid + 1;
                    } else if (mp > p8) {
                        hi = mid;
                    } else {
                        if (std.mem.order(u8, self.slots[mid].key.slice(), key) == .lt) {
                            lo = mid + 1;
                        } else {
                            hi = mid;
                        }
                    }
                }
                return lo;
            }

            fn findPrefixLowerBound(self: *const LeafNode, prefix: []const u8) usize {
                var lo: usize = 0;
                var hi: usize = self.hdr.count;
                while (lo < hi) {
                    const mid = lo + (hi - lo) / 2;
                    if (prefixCompare(self.slots[mid].key.slice(), prefix) == .lt) {
                        lo = mid + 1;
                    } else {
                        hi = mid;
                    }
                }
                return lo;
            }

            fn findPrefixUpperBound(self: *const LeafNode, prefix: []const u8) usize {
                var lo: usize = 0;
                var hi: usize = self.hdr.count;
                while (lo < hi) {
                    const mid = lo + (hi - lo) / 2;
                    if (prefixCompare(self.slots[mid].key.slice(), prefix) != .gt) {
                        lo = mid + 1;
                    } else {
                        hi = mid;
                    }
                }
                return lo;
            }
        };

        const InternalNode = struct {
            hdr: NodeHeader,
            /// Separator keys: `keys[i]` is the minimum key in `children[i + 1]`.
            prefix8: [INTERNAL_CAP]u64 = undefined,
            keys: [INTERNAL_CAP]OwnedKeyBytes = undefined,
            children: [INTERNAL_CAP + 1]*NodeHeader = undefined,

            inline fn asHeader(self: *InternalNode) *NodeHeader {
                return &self.hdr;
            }

            fn childIndexForKey(self: *const InternalNode, p8: u64, key: []const u8) usize {
                var lo: usize = 0;
                var hi: usize = self.hdr.count;
                while (lo < hi) {
                    const mid = lo + (hi - lo) / 2;
                    const mp = self.prefix8[mid];
                    if (mp < p8) {
                        lo = mid + 1;
                    } else if (mp > p8) {
                        hi = mid;
                    } else {
                        if (std.mem.order(u8, self.keys[mid].slice(), key) != .gt) {
                            lo = mid + 1;
                        } else {
                            hi = mid;
                        }
                    }
                }
                return lo;
            }

            fn childIndexForPrefixLo(self: *const InternalNode, prefix: []const u8) usize {
                var lo: usize = 0;
                var hi: usize = self.hdr.count;
                while (lo < hi) {
                    const mid = lo + (hi - lo) / 2;
                    if (prefixCompare(self.keys[mid].slice(), prefix) == .lt) {
                        lo = mid + 1;
                    } else {
                        hi = mid;
                    }
                }
                return lo;
            }

            fn childIndexForPrefixHi(self: *const InternalNode, prefix: []const u8) usize {
                var lo: usize = 0;
                var hi: usize = self.hdr.count;
                while (lo < hi) {
                    const mid = lo + (hi - lo) / 2;
                    if (prefixCompare(self.keys[mid].slice(), prefix) != .gt) {
                        lo = mid + 1;
                    } else {
                        hi = mid;
                    }
                }
                return lo;
            }
        };

        inline fn asLeaf(hdr: *NodeHeader) *LeafNode {
            return @fieldParentPtr("hdr", hdr);
        }

        inline fn asInternal(hdr: *NodeHeader) *InternalNode {
            return @fieldParentPtr("hdr", hdr);
        }

        /// Deepest root-to-leaf path `insertLocked` records. Splits leave nodes at
        /// least half full, so reaching this height would take ~32^16 inserts.
        const MAX_DEPTH: usize = 16;

        const PathEntry = struct {
            node: *InternalNode,
            /// Index of the child the descent followed.
            ci: usize,
        };

        pub const SeekPos = struct {
            leaf: *LeafNode,
            idx: usize,
        };

        /// Single-bucket ordered B+Tree protected by a compact `RwLock`.
        pub const BucketTree = struct {
            lock: compat.RwLock = .{},
            root: ?*NodeHeader = null,
            first_leaf: ?*LeafNode = null,
            last_leaf: ?*LeafNode = null,
            len: usize = 0,
            bulk_loading: bool = false,

            pub fn deinit(self: *BucketTree, allocator: std.mem.Allocator) void {
                if (self.bulk_loading) {
                    // Bulk-load leaves are chained on `first_leaf` without internal nodes yet.
                    var leaf = self.first_leaf;
                    while (leaf) |lf| {
                        const next = lf.next;
                        for (lf.slots[0..lf.hdr.count]) |*s| s.key.deinit(allocator);
                        allocator.destroy(lf);
                        leaf = next;
                    }
                } else if (self.root) |r| {
                    freeNodeRecursive(allocator, r);
                }
                self.root = null;
                self.first_leaf = null;
                self.last_leaf = null;
                self.len = 0;
                self.bulk_loading = false;
            }

            fn freeNodeRecursive(allocator: std.mem.Allocator, hdr: *NodeHeader) void {
                switch (hdr.kind) {
                    .leaf => {
                        const leaf = asLeaf(hdr);
                        for (leaf.slots[0..leaf.hdr.count]) |*s| s.key.deinit(allocator);
                        allocator.destroy(leaf);
                    },
                    .internal => {
                        const node = asInternal(hdr);
                        const n: usize = node.hdr.count;
                        for (node.keys[0..n]) |*k| k.deinit(allocator);
                        for (node.children[0 .. n + 1]) |ch| freeNodeRecursive(allocator, ch);
                        allocator.destroy(node);
                    },
                }
            }

            /// O(1) amortized sorted bulk append used during single-threaded `loadSnapshot`.
            /// Builds a doubly-linked leaf chain without locking, tree descent, or splits.
            /// Caller MUST call `finishBulkUnlocked` before issuing queries or normal inserts.
            /// Falls back gracefully if keys arrive out of order.
            pub fn appendBulkUnlocked(
                self: *BucketTree,
                allocator: std.mem.Allocator,
                key: []const u8,
                value: Value,
                key_hash: u64,
                shard_idx: u8,
            ) !void {
                const p8 = loadPrefix8(key);
                if (self.last_leaf == null) {
                    const leaf = try allocator.create(LeafNode);
                    errdefer allocator.destroy(leaf);
                    const kb = try LeafKey.init(allocator, key);
                    leaf.* = .{ .hdr = .{ .kind = .leaf, .count = 1, .subtree_count = 1 } };
                    leaf.prefix8[0] = p8;
                    leaf.slots[0] = .{ .key = kb, .value = value, .key_hash = key_hash, .shard_idx = shard_idx };
                    self.root = leaf.asHeader();
                    self.first_leaf = leaf;
                    self.last_leaf = leaf;
                    self.len = 1;
                    self.bulk_loading = true;
                    return;
                }

                if (!self.bulk_loading) {
                    return self.insertLocked(allocator, key, value, key_hash, shard_idx);
                }

                const tail = self.last_leaf.?;
                const last_i = tail.hdr.count - 1;
                if (cmpKeyWithPrefix(tail.prefix8[last_i], tail.slots[last_i].key.slice(), p8, key) != .lt) {
                    // Out-of-order or duplicate key in snapshot: finalize chain and use normal insert.
                    try self.finishBulkUnlocked(allocator);
                    return self.insertLocked(allocator, key, value, key_hash, shard_idx);
                }

                const kb = try LeafKey.init(allocator, key);
                errdefer kb.deinit(allocator);

                if (tail.hdr.count < LEAF_CAP) {
                    const idx = tail.hdr.count;
                    tail.prefix8[idx] = p8;
                    tail.slots[idx] = .{ .key = kb, .value = value, .key_hash = key_hash, .shard_idx = shard_idx };
                    tail.hdr.count += 1;
                    tail.hdr.subtree_count += 1;
                    self.len += 1;
                    return;
                }

                const next_leaf = try allocator.create(LeafNode);
                next_leaf.* = .{
                    .hdr = .{ .kind = .leaf, .count = 1, .subtree_count = 1 },
                    .prev = tail,
                    .next = null,
                };
                next_leaf.prefix8[0] = p8;
                next_leaf.slots[0] = .{ .key = kb, .value = value, .key_hash = key_hash, .shard_idx = shard_idx };
                tail.next = next_leaf;
                self.last_leaf = next_leaf;
                self.len += 1;
            }

            /// Build internal B+Tree levels bottom-up over the bulk-loaded leaf chain in O(N / LEAF_CAP).
            pub fn finishBulkUnlocked(self: *BucketTree, allocator: std.mem.Allocator) !void {
                if (!self.bulk_loading) return;
                const first = self.first_leaf orelse {
                    self.bulk_loading = false;
                    return;
                };
                if (first.next == null) {
                    self.root = first.asHeader();
                    self.bulk_loading = false;
                    return;
                }

                const LevelItem = struct {
                    hdr: *NodeHeader,
                    min_p8: u64,
                    min_key: []const u8,
                };
                var cur_level: std.ArrayListUnmanaged(LevelItem) = .empty;
                defer cur_level.deinit(allocator);
                var next_level: std.ArrayListUnmanaged(LevelItem) = .empty;
                defer next_level.deinit(allocator);

                var lf: ?*LeafNode = first;
                while (lf) |leaf| {
                    try cur_level.append(allocator, .{
                        .hdr = leaf.asHeader(),
                        .min_p8 = leaf.prefix8[0],
                        .min_key = leaf.slots[0].key.slice(),
                    });
                    lf = leaf.next;
                }

                const max_children: usize = INTERNAL_CAP + 1;
                while (cur_level.items.len > 1) {
                    next_level.clearRetainingCapacity();
                    var i: usize = 0;
                    const total = cur_level.items.len;
                    while (i < total) {
                        const take = @min(max_children, total - i);
                        const node = try allocator.create(InternalNode);
                        errdefer allocator.destroy(node);
                        node.* = .{
                            .hdr = .{ .kind = .internal, .count = @intCast(take - 1), .subtree_count = 0 },
                        };
                        var sum: u32 = 0;
                        var sep_built: usize = 0;
                        errdefer for (node.keys[0..sep_built]) |*k| k.deinit(allocator);

                        for (0..take) |j| {
                            const item = cur_level.items[i + j];
                            node.children[j] = item.hdr;
                            sum += item.hdr.subtree_count;
                            if (j > 0) {
                                node.prefix8[j - 1] = item.min_p8;
                                node.keys[j - 1] = try OwnedKeyBytes.init(allocator, item.min_key);
                                sep_built = j;
                            }
                        }
                        node.hdr.subtree_count = sum;
                        try next_level.append(allocator, .{
                            .hdr = node.asHeader(),
                            .min_p8 = cur_level.items[i].min_p8,
                            .min_key = cur_level.items[i].min_key,
                        });
                        i += take;
                    }
                    std.mem.swap(std.ArrayListUnmanaged(LevelItem), &cur_level, &next_level);
                }

                self.root = cur_level.items[0].hdr;
                self.bulk_loading = false;
            }

            pub fn insertLocked(
                self: *BucketTree,
                allocator: std.mem.Allocator,
                key: []const u8,
                value: Value,
                key_hash: u64,
                shard_idx: u8,
            ) !void {
                const p8 = loadPrefix8(key);
                if (self.root == null) {
                    const leaf = try allocator.create(LeafNode);
                    errdefer allocator.destroy(leaf);
                    const kb = try LeafKey.init(allocator, key);
                    leaf.* = .{
                        .hdr = .{ .kind = .leaf, .count = 1, .subtree_count = 1 },
                    };
                    leaf.prefix8[0] = p8;
                    leaf.slots[0] = .{ .key = kb, .value = value, .key_hash = key_hash, .shard_idx = shard_idx };
                    self.root = leaf.asHeader();
                    self.first_leaf = leaf;
                    self.last_leaf = leaf;
                    self.len = 1;
                    return;
                }

                // O(1) single-leaf tail-append fast path.
                if (self.last_leaf) |tail| {
                    if (self.root.? == tail.asHeader() and tail.hdr.count < LEAF_CAP) {
                        const last_i = tail.hdr.count - 1;
                        if (cmpKeyWithPrefix(tail.prefix8[last_i], tail.slots[last_i].key.slice(), p8, key) == .lt) {
                            const kb = try LeafKey.init(allocator, key);
                            const idx = tail.hdr.count;
                            tail.prefix8[idx] = p8;
                            tail.slots[idx] = .{ .key = kb, .value = value, .key_hash = key_hash, .shard_idx = shard_idx };
                            tail.hdr.count += 1;
                            tail.hdr.subtree_count += 1;
                            self.len += 1;
                            return;
                        }
                    }
                }

                // Descend to the target leaf, recording the path. Every allocation an
                // insert can need (leaf key, split nodes, separator copy, new root) is
                // made before the first mutation, so a failed insert leaves the tree
                // exactly as it was: no orphaned split node, no drifted subtree count.
                var path: [MAX_DEPTH]PathEntry = undefined;
                var depth: usize = 0;
                var cur = self.root.?;
                while (cur.kind == .internal) {
                    if (depth == MAX_DEPTH) return error.OutOfMemory;
                    const node = asInternal(cur);
                    const ci = node.childIndexForKey(p8, key);
                    path[depth] = .{ .node = node, .ci = ci };
                    depth += 1;
                    cur = node.children[ci];
                }
                const leaf = asLeaf(cur);
                const idx = leaf.findLowerBound(p8, key);
                const cnt: usize = leaf.hdr.count;
                if (idx < cnt and leaf.prefix8[idx] == p8 and std.mem.eql(u8, leaf.slots[idx].key.slice(), key)) {
                    leaf.slots[idx].value = value;
                    if (comptime borrow_long_leaf_keys) {
                        if (key.len > INLINE_KEY_CAP) {
                            leaf.slots[idx].key.storage.borrowed_ptr = key.ptr;
                        }
                    }
                    return;
                }

                const kb = try LeafKey.init(allocator, key);
                errdefer kb.deinit(allocator);

                if (cnt < LEAF_CAP) {
                    if (idx < cnt) {
                        std.mem.copyBackwards(u64, leaf.prefix8[idx + 1 .. cnt + 1], leaf.prefix8[idx..cnt]);
                        std.mem.copyBackwards(LeafSlot, leaf.slots[idx + 1 .. cnt + 1], leaf.slots[idx..cnt]);
                    }
                    leaf.prefix8[idx] = p8;
                    leaf.slots[idx] = .{ .key = kb, .value = value, .key_hash = key_hash, .shard_idx = shard_idx };
                    leaf.hdr.count += 1;
                    leaf.hdr.subtree_count += 1;
                    for (path[0..depth]) |pe| pe.node.hdr.subtree_count += 1;
                    self.len += 1;
                    return;
                }

                // The leaf is full. The split propagates up through every full internal
                // node directly above it; if all of them are full the tree grows a root.
                var n_split: usize = 0;
                while (n_split < depth and path[depth - 1 - n_split].node.hdr.count == INTERNAL_CAP) n_split += 1;
                const n_internal: usize = n_split + @intFromBool(n_split == depth);

                var tmp_lp8: [LEAF_CAP + 1]u64 = undefined;
                var tmp_slots: [LEAF_CAP + 1]LeafSlot = undefined;
                @memcpy(tmp_lp8[0..idx], leaf.prefix8[0..idx]);
                @memcpy(tmp_slots[0..idx], leaf.slots[0..idx]);
                tmp_lp8[idx] = p8;
                tmp_slots[idx] = .{ .key = kb, .value = value, .key_hash = key_hash, .shard_idx = shard_idx };
                @memcpy(tmp_lp8[idx + 1 .. LEAF_CAP + 1], leaf.prefix8[idx..LEAF_CAP]);
                @memcpy(tmp_slots[idx + 1 .. LEAF_CAP + 1], leaf.slots[idx..LEAF_CAP]);

                const left_n: usize = if (idx == LEAF_CAP) (LEAF_CAP * 3) / 4 else (LEAF_CAP + 1) / 2;
                const right_n: usize = (LEAF_CAP + 1) - left_n;

                const right_leaf = try allocator.create(LeafNode);
                errdefer allocator.destroy(right_leaf);
                const leaf_sep_key = try OwnedKeyBytes.init(allocator, tmp_slots[left_n].key.slice());
                errdefer leaf_sep_key.deinit(allocator);
                var new_internals: [MAX_DEPTH + 1]*InternalNode = undefined;
                var n_alloc: usize = 0;
                errdefer for (new_internals[0..n_alloc]) |n| allocator.destroy(n);
                while (n_alloc < n_internal) : (n_alloc += 1) {
                    new_internals[n_alloc] = try allocator.create(InternalNode);
                }

                // ── Infallible from here on ──────────────────────────────────────
                @memcpy(leaf.prefix8[0..left_n], tmp_lp8[0..left_n]);
                @memcpy(leaf.slots[0..left_n], tmp_slots[0..left_n]);
                leaf.hdr.count = @intCast(left_n);
                leaf.hdr.subtree_count = @intCast(left_n);

                right_leaf.* = .{
                    .hdr = .{ .kind = .leaf, .count = @intCast(right_n), .subtree_count = @intCast(right_n) },
                    .prev = leaf,
                    .next = leaf.next,
                };
                @memcpy(right_leaf.prefix8[0..right_n], tmp_lp8[left_n .. LEAF_CAP + 1]);
                @memcpy(right_leaf.slots[0..right_n], tmp_slots[left_n .. LEAF_CAP + 1]);

                if (leaf.next) |old_next| {
                    old_next.prev = right_leaf;
                } else {
                    self.last_leaf = right_leaf;
                }
                leaf.next = right_leaf;

                // Pending split to hand to the parent level.
                var sp_p8: u64 = tmp_lp8[left_n];
                var sp_key: OwnedKeyBytes = leaf_sep_key;
                var sp_right: *NodeHeader = right_leaf.asHeader();
                var pending = true;
                var used: usize = 0;

                var level = depth;
                while (level > 0) {
                    level -= 1;
                    const node = path[level].node;
                    const ci = path[level].ci;
                    node.hdr.subtree_count += 1;
                    if (!pending) continue;

                    const ncnt: usize = node.hdr.count;
                    if (ncnt < INTERNAL_CAP) {
                        if (ci < ncnt) {
                            std.mem.copyBackwards(u64, node.prefix8[ci + 1 .. ncnt + 1], node.prefix8[ci..ncnt]);
                            std.mem.copyBackwards(OwnedKeyBytes, node.keys[ci + 1 .. ncnt + 1], node.keys[ci..ncnt]);
                            std.mem.copyBackwards(*NodeHeader, node.children[ci + 2 .. ncnt + 2], node.children[ci + 1 .. ncnt + 1]);
                        }
                        node.prefix8[ci] = sp_p8;
                        node.keys[ci] = sp_key;
                        node.children[ci + 1] = sp_right;
                        node.hdr.count += 1;
                        pending = false;
                        continue;
                    }

                    const right = new_internals[used];
                    used += 1;
                    var tmp_p8: [INTERNAL_CAP + 1]u64 = undefined;
                    var tmp_keys: [INTERNAL_CAP + 1]OwnedKeyBytes = undefined;
                    var tmp_ch: [INTERNAL_CAP + 2]*NodeHeader = undefined;

                    @memcpy(tmp_p8[0..ci], node.prefix8[0..ci]);
                    @memcpy(tmp_keys[0..ci], node.keys[0..ci]);
                    @memcpy(tmp_ch[0 .. ci + 1], node.children[0 .. ci + 1]);
                    tmp_p8[ci] = sp_p8;
                    tmp_keys[ci] = sp_key;
                    tmp_ch[ci + 1] = sp_right;
                    @memcpy(tmp_p8[ci + 1 .. INTERNAL_CAP + 1], node.prefix8[ci..INTERNAL_CAP]);
                    @memcpy(tmp_keys[ci + 1 .. INTERNAL_CAP + 1], node.keys[ci..INTERNAL_CAP]);
                    @memcpy(tmp_ch[ci + 2 .. INTERNAL_CAP + 2], node.children[ci + 1 .. INTERNAL_CAP + 1]);

                    const mid: usize = (INTERNAL_CAP + 1) / 2;
                    const rn: usize = INTERNAL_CAP - mid;

                    @memcpy(node.prefix8[0..mid], tmp_p8[0..mid]);
                    @memcpy(node.keys[0..mid], tmp_keys[0..mid]);
                    @memcpy(node.children[0 .. mid + 1], tmp_ch[0 .. mid + 1]);
                    node.hdr.count = @intCast(mid);
                    var lsum: u32 = 0;
                    for (node.children[0 .. mid + 1]) |ch| lsum += ch.subtree_count;
                    node.hdr.subtree_count = lsum;

                    right.* = .{
                        .hdr = .{ .kind = .internal, .count = @intCast(rn), .subtree_count = 0 },
                    };
                    @memcpy(right.prefix8[0..rn], tmp_p8[mid + 1 .. INTERNAL_CAP + 1]);
                    @memcpy(right.keys[0..rn], tmp_keys[mid + 1 .. INTERNAL_CAP + 1]);
                    @memcpy(right.children[0 .. rn + 1], tmp_ch[mid + 1 .. INTERNAL_CAP + 2]);
                    var rsum: u32 = 0;
                    for (right.children[0 .. rn + 1]) |ch| rsum += ch.subtree_count;
                    right.hdr.subtree_count = rsum;

                    sp_p8 = tmp_p8[mid];
                    sp_key = tmp_keys[mid];
                    sp_right = right.asHeader();
                }

                if (pending) {
                    const new_root = new_internals[used];
                    used += 1;
                    new_root.* = .{
                        .hdr = .{
                            .kind = .internal,
                            .count = 1,
                            .subtree_count = self.root.?.subtree_count + sp_right.subtree_count,
                        },
                    };
                    new_root.prefix8[0] = sp_p8;
                    new_root.keys[0] = sp_key;
                    new_root.children[0] = self.root.?;
                    new_root.children[1] = sp_right;
                    self.root = new_root.asHeader();
                }
                std.debug.assert(used == n_internal);
                self.len += 1;
            }

            pub fn replaceValueLocked(self: *BucketTree, allocator: std.mem.Allocator, key: []const u8, value: Value) void {
                var cur = self.root orelse return;
                const p8 = loadPrefix8(key);
                while (cur.kind == .internal) {
                    const node = asInternal(cur);
                    cur = node.children[node.childIndexForKey(p8, key)];
                }
                const leaf = asLeaf(cur);
                const idx = leaf.findLowerBound(p8, key);
                if (idx < leaf.hdr.count and leaf.prefix8[idx] == p8 and std.mem.eql(u8, leaf.slots[idx].key.slice(), key)) {
                    leaf.slots[idx].value = value;
                    if (comptime borrow_long_leaf_keys) {
                        // Refresh borrowed pointer so freeing the replaced Entry cannot dangle.
                        if (key.len > INLINE_KEY_CAP) {
                            leaf.slots[idx].key.storage.borrowed_ptr = key.ptr;
                        }
                    } else {
                        _ = allocator;
                    }
                }
            }

            pub fn removeLocked(self: *BucketTree, allocator: std.mem.Allocator, key: []const u8) bool {
                const root = self.root orelse return false;
                const p8 = loadPrefix8(key);
                const removed = self.removeNode(allocator, root, p8, key);
                if (!removed) return false;
                self.len -= 1;

                // Collapse empty root or single-child internal root.
                while (self.root) |r| {
                    if (r.kind == .leaf) {
                        if (r.count == 0) {
                            const leaf = asLeaf(r);
                            allocator.destroy(leaf);
                            self.root = null;
                            self.first_leaf = null;
                            self.last_leaf = null;
                        }
                        break;
                    } else {
                        const node = asInternal(r);
                        if (node.hdr.subtree_count == 0) {
                            // All child subtrees were already pruned and destroyed in `removeNode`.
                            for (node.keys[0..node.hdr.count]) |*k| k.deinit(allocator);
                            allocator.destroy(node);
                            self.root = null;
                            self.first_leaf = null;
                            self.last_leaf = null;
                            break;
                        }
                        if (node.hdr.count == 0) {
                            const only_child = node.children[0];
                            allocator.destroy(node);
                            self.root = only_child;
                        } else break;
                    }
                }
                return true;
            }

            fn removeNode(self: *BucketTree, allocator: std.mem.Allocator, hdr: *NodeHeader, p8: u64, key: []const u8) bool {
                switch (hdr.kind) {
                    .leaf => {
                        const leaf = asLeaf(hdr);
                        const idx = leaf.findLowerBound(p8, key);
                        const cnt: usize = leaf.hdr.count;
                        if (idx >= cnt or leaf.prefix8[idx] != p8 or !std.mem.eql(u8, leaf.slots[idx].key.slice(), key)) {
                            return false;
                        }
                        leaf.slots[idx].key.deinit(allocator);
                        if (idx + 1 < cnt) {
                            std.mem.copyForwards(u64, leaf.prefix8[idx .. cnt - 1], leaf.prefix8[idx + 1 .. cnt]);
                            std.mem.copyForwards(LeafSlot, leaf.slots[idx .. cnt - 1], leaf.slots[idx + 1 .. cnt]);
                        }
                        leaf.hdr.count -= 1;
                        leaf.hdr.subtree_count -= 1;
                        return true;
                    },
                    .internal => {
                        const node = asInternal(hdr);
                        const ci = node.childIndexForKey(p8, key);
                        const child = node.children[ci];
                        if (!self.removeNode(allocator, child, p8, key)) return false;
                        node.hdr.subtree_count -= 1;

                        if (child.subtree_count == 0) {
                            if (child.kind == .leaf) {
                                const dead = asLeaf(child);
                                if (dead.prev) |p| p.next = dead.next else self.first_leaf = dead.next;
                                if (dead.next) |n| n.prev = dead.prev else self.last_leaf = dead.prev;
                                allocator.destroy(dead);
                            } else {
                                const dead = asInternal(child);
                                for (dead.keys[0..dead.hdr.count]) |*k| k.deinit(allocator);
                                allocator.destroy(dead);
                            }

                            const cnt: usize = node.hdr.count;
                            if (cnt == 0) {
                                return true;
                            }
                            const sep_idx: usize = if (ci == 0) 0 else ci - 1;
                            node.keys[sep_idx].deinit(allocator);
                            if (sep_idx + 1 < cnt) {
                                std.mem.copyForwards(u64, node.prefix8[sep_idx .. cnt - 1], node.prefix8[sep_idx + 1 .. cnt]);
                                std.mem.copyForwards(OwnedKeyBytes, node.keys[sep_idx .. cnt - 1], node.keys[sep_idx + 1 .. cnt]);
                            }
                            if (ci < cnt) {
                                std.mem.copyForwards(*NodeHeader, node.children[ci..cnt], node.children[ci + 1 .. cnt + 1]);
                            }
                            node.hdr.count -= 1;
                        }
                        return true;
                    },
                }
            }

            /// Find the first leaf/index with key `>= prefix` (or strictly `> after` when set).
            pub fn seekFirst(self: *const BucketTree, prefix: []const u8, after: ?[]const u8) ?SeekPos {
                var cur = self.root orelse return null;
                if (after) |cursor| {
                    const use_cursor = prefix.len == 0 or std.mem.order(u8, cursor, prefix) != .lt;
                    if (use_cursor) {
                        const cp8 = loadPrefix8(cursor);
                        while (cur.kind == .internal) {
                            const node = asInternal(cur);
                            cur = node.children[node.childIndexForKey(cp8, cursor)];
                        }
                        var leaf = asLeaf(cur);
                        var idx = leaf.findLowerBound(cp8, cursor);
                        if (idx < leaf.hdr.count and leaf.prefix8[idx] == cp8 and std.mem.eql(u8, leaf.slots[idx].key.slice(), cursor)) {
                            idx += 1;
                        }
                        while (idx >= leaf.hdr.count) {
                            leaf = leaf.next orelse return null;
                            idx = 0;
                        }
                        if (prefix.len > 0 and !std.mem.startsWith(u8, leaf.slots[idx].key.slice(), prefix)) return null;
                        return .{ .leaf = leaf, .idx = idx };
                    }
                }

                if (prefix.len == 0) {
                    const first = self.first_leaf orelse return null;
                    if (first.hdr.count == 0) return null;
                    return .{ .leaf = first, .idx = 0 };
                }

                while (cur.kind == .internal) {
                    const node = asInternal(cur);
                    cur = node.children[node.childIndexForPrefixLo(prefix)];
                }
                var leaf = asLeaf(cur);
                var idx = leaf.findPrefixLowerBound(prefix);
                while (idx >= leaf.hdr.count) {
                    leaf = leaf.next orelse return null;
                    idx = 0;
                }
                if (!std.mem.startsWith(u8, leaf.slots[idx].key.slice(), prefix)) return null;
                return .{ .leaf = leaf, .idx = idx };
            }

            /// Find the LAST leaf/index matching `prefix` (and strictly `> after` when set).
            pub fn seekLast(self: *const BucketTree, prefix: []const u8, after: ?[]const u8) ?SeekPos {
                var cur = self.root orelse return null;
                var leaf: *LeafNode = undefined;
                var idx: usize = undefined;
                if (prefix.len == 0) {
                    leaf = self.last_leaf orelse return null;
                    if (leaf.hdr.count == 0) return null;
                    idx = leaf.hdr.count - 1;
                } else {
                    while (cur.kind == .internal) {
                        const node = asInternal(cur);
                        cur = node.children[node.childIndexForPrefixHi(prefix)];
                    }
                    leaf = asLeaf(cur);
                    const ub = leaf.findPrefixUpperBound(prefix);
                    if (ub > 0) {
                        idx = ub - 1;
                    } else {
                        leaf = leaf.prev orelse return null;
                        while (leaf.hdr.count == 0) {
                            leaf = leaf.prev orelse return null;
                        }
                        idx = leaf.hdr.count - 1;
                    }
                    if (!std.mem.startsWith(u8, leaf.slots[idx].key.slice(), prefix)) return null;
                }
                if (after) |cursor| {
                    if (std.mem.order(u8, leaf.slots[idx].key.slice(), cursor) != .gt) return null;
                }
                return .{ .leaf = leaf, .idx = idx };
            }

            fn countPrefixRangeLocked(self: *const BucketTree, prefix: []const u8) usize {
                const root = self.root orelse return 0;
                if (prefix.len == 0) return self.len;
                const lo_rank = rankPrefixLo(root, prefix);
                const hi_rank = rankPrefixHi(root, prefix);
                return if (hi_rank > lo_rank) hi_rank - lo_rank else 0;
            }

            fn rankPrefixLo(hdr: *const NodeHeader, prefix: []const u8) usize {
                var cur = hdr;
                var rank: usize = 0;
                while (cur.kind == .internal) {
                    const node: *const InternalNode = @fieldParentPtr("hdr", cur);
                    const ci = node.childIndexForPrefixLo(prefix);
                    for (node.children[0..ci]) |ch| rank += ch.subtree_count;
                    cur = node.children[ci];
                }
                const leaf: *const LeafNode = @fieldParentPtr("hdr", cur);
                return rank + leaf.findPrefixLowerBound(prefix);
            }

            fn rankPrefixHi(hdr: *const NodeHeader, prefix: []const u8) usize {
                var cur = hdr;
                var rank: usize = 0;
                while (cur.kind == .internal) {
                    const node: *const InternalNode = @fieldParentPtr("hdr", cur);
                    const ci = node.childIndexForPrefixHi(prefix);
                    for (node.children[0..ci]) |ch| rank += ch.subtree_count;
                    cur = node.children[ci];
                }
                const leaf: *const LeafNode = @fieldParentPtr("hdr", cur);
                return rank + leaf.findPrefixUpperBound(prefix);
            }

            pub fn hasPrefixLocked(self: *const BucketTree, prefix: []const u8) bool {
                return self.seekFirst(prefix, null) != null;
            }
        };

        allocator: std.mem.Allocator,
        empty_lock: compat.RwLock = .{},
        has_empty: bool = false,
        empty_value: Value = undefined,
        empty_shard: u8 = 0,
        empty_hash: u64 = 0,
        buckets: [BUCKET_COUNT]BucketTree,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .buckets = @splat(.{}),
            };
        }

        pub fn deinit(self: *Self) void {
            for (&self.buckets) |*b| b.deinit(self.allocator);
        }

        pub fn insert(self: *Self, key: []const u8, value: Value, shard_idx: usize) !void {
            const kh = std.hash_map.hashString(key);
            if (key.len == 0) {
                self.empty_lock.lock();
                defer self.empty_lock.unlock();
                self.has_empty = true;
                self.empty_value = value;
                self.empty_shard = @intCast(shard_idx);
                self.empty_hash = kh;
                return;
            }
            const b = &self.buckets[key[0]];
            b.lock.lock();
            defer b.lock.unlock();
            try b.insertLocked(self.allocator, key, value, kh, @intCast(shard_idx));
        }

        /// Single-threaded bulk append for sorted `loadSnapshot` ingestion.
        /// Call `finishBulkLoad()` once all entries are appended.
        pub fn appendBulkUnlocked(self: *Self, key: []const u8, value: Value, shard_idx: usize) !void {
            return self.appendBulkUnlockedWithHash(key, value, std.hash_map.hashString(key), shard_idx);
        }

        pub fn appendBulkUnlockedWithHash(self: *Self, key: []const u8, value: Value, key_hash: u64, shard_idx: usize) !void {
            if (key.len == 0) {
                self.has_empty = true;
                self.empty_value = value;
                self.empty_shard = @intCast(shard_idx);
                self.empty_hash = key_hash;
                return;
            }
            try self.buckets[key[0]].appendBulkUnlocked(self.allocator, key, value, key_hash, @intCast(shard_idx));
        }

        pub fn finishBulkLoad(self: *Self) !void {
            for (&self.buckets) |*b| {
                if (b.bulk_loading) {
                    try b.finishBulkUnlocked(self.allocator);
                }
            }
        }

        pub fn replaceValue(self: *Self, key: []const u8, value: Value) void {
            if (key.len == 0) {
                self.empty_lock.lock();
                defer self.empty_lock.unlock();
                if (self.has_empty) self.empty_value = value;
                return;
            }
            const b = &self.buckets[key[0]];
            b.lock.lock();
            defer b.lock.unlock();
            b.replaceValueLocked(self.allocator, key, value);
        }

        pub fn remove(self: *Self, key: []const u8) void {
            if (key.len == 0) {
                self.empty_lock.lock();
                defer self.empty_lock.unlock();
                self.has_empty = false;
                return;
            }
            const b = &self.buckets[key[0]];
            b.lock.lock();
            defer b.lock.unlock();
            _ = b.removeLocked(self.allocator, key);
        }

        pub fn countPrefix(self: *Self, prefix: []const u8) usize {
            if (prefix.len > 0) {
                const b = &self.buckets[prefix[0]];
                b.lock.lockShared();
                defer b.lock.unlockShared();
                return b.countPrefixRangeLocked(prefix);
            }
            var total: usize = 0;
            {
                self.empty_lock.lockShared();
                defer self.empty_lock.unlockShared();
                if (self.has_empty) total += 1;
            }
            for (&self.buckets) |*b| {
                b.lock.lockShared();
                total += b.len;
                b.lock.unlockShared();
            }
            return total;
        }

        pub fn hasPrefix(self: *Self, prefix: []const u8) bool {
            if (prefix.len > 0) {
                const b = &self.buckets[prefix[0]];
                b.lock.lockShared();
                defer b.lock.unlockShared();
                return b.hasPrefixLocked(prefix);
            }
            {
                self.empty_lock.lockShared();
                defer self.empty_lock.unlockShared();
                if (self.has_empty) return true;
            }
            for (&self.buckets) |*b| {
                b.lock.lockShared();
                const non_empty = b.len > 0;
                b.lock.unlockShared();
                if (non_empty) return true;
            }
            return false;
        }

        /// Lock-decoupled range collector (never touches shard locks).
        pub fn collectRange(
            self: *Self,
            allocator: std.mem.Allocator,
            prefix: []const u8,
            after: ?[]const u8,
            limit: usize,
            cut: Cut,
            out: *CollectedKeys,
        ) !void {
            if (prefix.len > 0) {
                const b = &self.buckets[prefix[0]];
                b.lock.lockShared();
                defer b.lock.unlockShared();
                try collectBucketLocked(b, allocator, prefix, after, limit, cut, out);
                return;
            }

            if (limit > 0 and cut == .last) {
                var remaining = limit;
                var bi: usize = BUCKET_COUNT;
                while (bi > 0 and remaining > 0) {
                    bi -= 1;
                    if (after) |cursor| {
                        if (cursor.len > 0 and bi < cursor[0]) break;
                    }
                    const b = &self.buckets[bi];
                    b.lock.lockShared();
                    defer b.lock.unlockShared();
                    const before = out.refs().len;
                    try collectBucketDescLocked(b, allocator, "", after, remaining, out);
                    remaining -= (out.refs().len - before);
                }
                if (remaining > 0 and after == null) {
                    self.empty_lock.lockShared();
                    const has_e = self.has_empty;
                    const es = self.empty_shard;
                    const eh = self.empty_hash;
                    self.empty_lock.unlockShared();
                    if (has_e) try out.append(allocator, "", eh, es);
                }
                out.reverseRefs();
                return;
            }

            if (after == null) {
                self.empty_lock.lockShared();
                const has_e = self.has_empty;
                const es = self.empty_shard;
                const eh = self.empty_hash;
                self.empty_lock.unlockShared();
                if (has_e) {
                    try out.append(allocator, "", eh, es);
                    if (limit > 0 and out.refs().len >= limit) return;
                }
            }
            const start_b: usize = if (after) |c| (if (c.len > 0) c[0] else 0) else 0;
            for (start_b..BUCKET_COUNT) |bi| {
                const b = &self.buckets[bi];
                b.lock.lockShared();
                defer b.lock.unlockShared();
                const rem = if (limit == 0) 0 else limit - out.refs().len;
                try collectBucketAscLocked(b, allocator, "", after, rem, out);
                if (limit > 0 and out.refs().len >= limit) return;
            }
        }

        fn collectBucketLocked(
            b: *const BucketTree,
            allocator: std.mem.Allocator,
            prefix: []const u8,
            after: ?[]const u8,
            limit: usize,
            cut: Cut,
            out: *CollectedKeys,
        ) !void {
            if (limit > 0 and cut == .last) {
                try collectBucketDescLocked(b, allocator, prefix, after, limit, out);
                out.reverseRefs();
            } else {
                try collectBucketAscLocked(b, allocator, prefix, after, limit, out);
            }
        }

        fn collectBucketAscLocked(
            b: *const BucketTree,
            allocator: std.mem.Allocator,
            prefix: []const u8,
            after: ?[]const u8,
            limit: usize,
            out: *CollectedKeys,
        ) !void {
            const start = b.seekFirst(prefix, after) orelse return;
            var leaf: ?*LeafNode = start.leaf;
            var idx = start.idx;
            var taken: usize = 0;
            while (leaf) |lf| {
                while (idx < lf.hdr.count) : (idx += 1) {
                    const slot = &lf.slots[idx];
                    const k = slot.key.slice();
                    if (prefix.len > 0 and !std.mem.startsWith(u8, k, prefix)) return;
                    try out.append(allocator, k, slot.key_hash, slot.shard_idx);
                    taken += 1;
                    if (limit > 0 and taken >= limit) return;
                }
                leaf = lf.next;
                idx = 0;
            }
        }

        fn collectBucketDescLocked(
            b: *const BucketTree,
            allocator: std.mem.Allocator,
            prefix: []const u8,
            after: ?[]const u8,
            limit: usize,
            out: *CollectedKeys,
        ) !void {
            const start = b.seekLast(prefix, after) orelse return;
            var leaf: ?*LeafNode = start.leaf;
            var idx = start.idx;
            var taken: usize = 0;
            while (leaf) |lf| {
                while (true) {
                    const slot = &lf.slots[idx];
                    const k = slot.key.slice();
                    if (prefix.len > 0 and !std.mem.startsWith(u8, k, prefix)) return;
                    if (after) |cursor| {
                        if (std.mem.order(u8, k, cursor) != .gt) return;
                    }
                    try out.append(allocator, k, slot.key_hash, slot.shard_idx);
                    taken += 1;
                    if (limit > 0 and taken >= limit) return;
                    if (idx == 0) break;
                    idx -= 1;
                }
                leaf = lf.prev;
                if (leaf) |prev_lf| {
                    if (prev_lf.hdr.count == 0) break;
                    idx = prev_lf.hdr.count - 1;
                }
            }
        }

        /// Iterate every entry in global ascending order for `writeSnapshot`,
        /// yielding `Value` directly without hash-table lookups.
        pub fn visitAllSorted(
            self: *Self,
            ctx: anytype,
            comptime cb: fn (@TypeOf(ctx), Value) anyerror!void,
        ) !void {
            {
                self.empty_lock.lockShared();
                defer self.empty_lock.unlockShared();
                if (self.has_empty) {
                    try cb(ctx, self.empty_value);
                }
            }
            for (&self.buckets) |*b| {
                b.lock.lockShared();
                defer b.lock.unlockShared();
                var leaf = b.first_leaf;
                while (leaf) |lf| {
                    for (lf.slots[0..lf.hdr.count]) |*s| {
                        try cb(ctx, s.value);
                    }
                    leaf = lf.next;
                }
            }
        }
    };
}

// ── Unit Tests ────────────────────────────────────────────────────────

test "OrderedIndex insert, split, range, cursor, countPrefix, and full delete-to-zero" {
    const testing = std.testing;
    const Idx = OrderedIndex(usize, false);
    var idx = Idx.init(testing.allocator);
    defer idx.deinit();

    // Insert 5,000 keys out of order across multiple prefixes + empty key + >16B long keys.
    try idx.insert("", 0, 0);
    var kbuf: [64]u8 = undefined;
    for (0..2500) |i| {
        const rev = 2499 - i;
        const k1 = try std.fmt.bufPrint(&kbuf, "item:{d:0>6}", .{rev});
        try idx.insert(k1, rev, rev & 255);
        const k2 = try std.fmt.bufPrint(&kbuf, "long_prefix_exceeds_inline_16b:{d:0>6}", .{i});
        try idx.insert(k2, i, i & 255);
    }

    try testing.expectEqual(@as(usize, 5001), idx.countPrefix(""));
    try testing.expectEqual(@as(usize, 2500), idx.countPrefix("item:"));
    try testing.expectEqual(@as(usize, 2500), idx.countPrefix("long_prefix_exceeds_inline_16b:"));
    try testing.expectEqual(@as(usize, 0), idx.countPrefix("missing:"));
    try testing.expect(idx.hasPrefix("item:"));
    try testing.expect(!idx.hasPrefix("missing:"));

    // First 10 ascending
    var out = CollectedKeys{};
    defer out.deinit(testing.allocator);
    try idx.collectRange(testing.allocator, "item:", null, 10, .first, &out);
    try testing.expectEqual(@as(usize, 10), out.refs().len);
    try testing.expectEqualStrings("item:000000", out.keySlice(out.refs()[0]));
    try testing.expectEqualStrings("item:000009", out.keySlice(out.refs()[9]));

    // Last 10 ascending
    out.clear();
    try idx.collectRange(testing.allocator, "item:", null, 10, .last, &out);
    try testing.expectEqual(@as(usize, 10), out.refs().len);
    try testing.expectEqualStrings("item:002490", out.keySlice(out.refs()[0]));
    try testing.expectEqualStrings("item:002499", out.keySlice(out.refs()[9]));

    // Cursor pagination
    out.clear();
    try idx.collectRange(testing.allocator, "item:", "item:000009", 5, .first, &out);
    try testing.expectEqual(@as(usize, 5), out.refs().len);
    try testing.expectEqualStrings("item:000010", out.keySlice(out.refs()[0]));
    try testing.expectEqualStrings("item:000014", out.keySlice(out.refs()[4]));

    // Delete EVERY key down to 0 (exercises multi-level internal root collapse) then re-insert!
    for (0..2500) |i| {
        const k1 = try std.fmt.bufPrint(&kbuf, "item:{d:0>6}", .{i});
        idx.remove(k1);
        const rev = 2499 - i;
        const k2 = try std.fmt.bufPrint(&kbuf, "long_prefix_exceeds_inline_16b:{d:0>6}", .{rev});
        idx.remove(k2);
    }
    idx.remove("");
    try testing.expectEqual(@as(usize, 0), idx.countPrefix(""));
    try testing.expect(!idx.hasPrefix(""));

    // Re-insert after total emptiness
    try idx.insert("item:999999", 999999, 1);
    try testing.expectEqual(@as(usize, 1), idx.countPrefix("item:"));
    out.clear();
    try idx.collectRange(testing.allocator, "item:", null, 5, .first, &out);
    try testing.expectEqual(@as(usize, 1), out.refs().len);
    try testing.expectEqualStrings("item:999999", out.keySlice(out.refs()[0]));
}

test "OrderedIndex bulk load builds multi-level tree and supports queries + deletes" {
    const testing = std.testing;
    const Idx = OrderedIndex(usize, false);
    var idx = Idx.init(testing.allocator);
    defer idx.deinit();

    try idx.appendBulkUnlocked("", 0, 0);
    var kbuf: [32]u8 = undefined;
    for (0..10_000) |i| {
        const k = try std.fmt.bufPrint(&kbuf, "key:{d:0>6}", .{i});
        try idx.appendBulkUnlocked(k, i, i & 255);
    }
    try idx.finishBulkLoad();

    try testing.expectEqual(@as(usize, 10_001), idx.countPrefix(""));
    try testing.expectEqual(@as(usize, 10_000), idx.countPrefix("key:"));

    var out = CollectedKeys{};
    defer out.deinit(testing.allocator);
    try idx.collectRange(testing.allocator, "key:", "key:004999", 5, .first, &out);
    try testing.expectEqual(@as(usize, 5), out.refs().len);
    try testing.expectEqualStrings("key:005000", out.keySlice(out.refs()[0]));
    try testing.expectEqualStrings("key:005004", out.keySlice(out.refs()[4]));

    // Interleaved insert + delete after bulk load
    try idx.insert("key:005000a", 12345, 7);
    try testing.expectEqual(@as(usize, 10_001), idx.countPrefix("key:"));
    idx.remove("key:005000");
    try testing.expectEqual(@as(usize, 10_000), idx.countPrefix("key:"));
}

test "OrderedIndex insert leaves the tree untouched when an allocation fails" {
    const testing = std.testing;
    const Idx = OrderedIndex(usize, true);

    // Borrowed long keys need stable backing memory that outlives the index.
    var key_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer key_arena.deinit();
    const n_keys: usize = 4200;
    const keys = try key_arena.allocator().alloc([]const u8, n_keys);
    for (keys, 0..) |*k, i| {
        k.* = try std.fmt.allocPrint(key_arena.allocator(), "k:long-key-past-inline-cap:{d:0>6}", .{i});
    }

    // Ascending evens grow the tree by tail splits until the root internal node
    // itself splits; descending odds then force mid-leaf splits everywhere.
    const order = try key_arena.allocator().alloc(usize, n_keys);
    for (0..n_keys / 2) |i| order[i] = 2 * i;
    for (0..n_keys / 2) |i| order[n_keys / 2 + i] = n_keys - 1 - 2 * i;

    const Check = struct {
        fn run(idx: *Idx, all_keys: []const []const u8, present: []const usize) !void {
            const b = &idx.buckets['k'];
            try testing.expectEqual(present.len, b.len);
            try testing.expectEqual(present.len, idx.countPrefix("k"));

            // The leaf chain holds exactly the present keys, in strictly ascending order.
            var chained: usize = 0;
            var prev: ?[]const u8 = null;
            var leaf = b.first_leaf;
            while (leaf) |lf| : (leaf = lf.next) {
                for (lf.slots[0..lf.hdr.count]) |*s| {
                    const k = s.key.slice();
                    if (prev) |p| try testing.expect(std.mem.order(u8, p, k) == .lt);
                    prev = k;
                    chained += 1;
                }
            }
            try testing.expectEqual(present.len, chained);

            // Every present key is reachable by descending from the root.
            for (present) |ki| {
                const pos = b.seekFirst(all_keys[ki], null) orelse return error.TestUnexpectedResult;
                try testing.expectEqualStrings(all_keys[ki], pos.leaf.slots[pos.idx].key.slice());
                try testing.expectEqual(ki, pos.leaf.slots[pos.idx].value);
            }
        }
    };

    // Fail each allocation the workload makes, one per run, until a run needs none failed.
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        var idx = Idx.init(failing.allocator());
        defer idx.deinit();

        var failed = false;
        for (order, 0..) |ki, done| {
            idx.insert(keys[ki], ki, ki & 255) catch |err| {
                try testing.expectEqual(error.OutOfMemory, err);
                try testing.expect(!failed);
                failed = true;
                try Check.run(&idx, keys, order[0..done]);
                failing.fail_index = std.math.maxInt(usize);
                try idx.insert(keys[ki], ki, ki & 255);
            };
        }
        try Check.run(&idx, keys, order);
        if (!failed) break;
    }
    // The workload must have exercised leaf, internal and root splits.
    try testing.expect(fail_index > 100);
}
