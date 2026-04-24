//! Procedure Context — ergonomic API for writing stored procedures.
//!
//! Wraps Store + args + allocator into a high-level interface that eliminates
//! boilerplate for argument parsing, locking, integer conversion, and responses.
//!
//! Usage:
//!   pub fn execute(ctx: *Ctx) Ctx.Result {
//!       const from = ctx.arg(0) orelse return ctx.err("missing from");
//!       const amt = ctx.argInt(i64, 1) orelse return ctx.err("bad amt");
//!       ctx.lockKey(from);
//!       const bal = ctx.getInt(i64, from) orelse 0;
//!       ctx.setInt(from, bal + amt);
//!       return ctx.valueInt(bal + amt);
//!   }

const std = @import("std");
const compat = @import("../core/compat.zig");
const Store = @import("../storage/store.zig").Store;
const Response = @import("../core/types.zig").Response;
const Cluster = @import("../cluster/mod.zig").Cluster;
const EventBus = @import("../event/mod.zig").EventBus;
const NamespaceRegistry = @import("../vector/index.zig").NamespaceRegistry;

const shardIndexFn = @import("../storage/store.zig").shardIndex;

pub const Ctx = struct {
    store: *Store,
    args: []const []const u8,
    allocator: std.mem.Allocator,
    /// Authenticated identity (SCT subject). Null if unauthenticated.
    _identity: ?[]const u8,
    /// Cluster handle — when present, `setDurable`/`setDurableWorm` replicate
    /// their writes to peers (matches wire-level SET semantics). Null in
    /// single-node mode or tests.
    cluster: ?*Cluster = null,
    /// Event bus for pub/sub emission from procedures. Null in tests.
    event_bus: ?*EventBus = null,
    /// Per-namespace HNSW index registry. Null → procedures fall back to
    /// BQ prefilter or brute-force search. See src/vector/index.zig.
    vector_registry: ?*NamespaceRegistry = null,

    // Lock tracking — max 16 distinct shards per procedure.
    // lockKey/lockKeys records shard indices here so they auto-unlock on deinit().
    locked_shards: [MAX_LOCKS]usize = undefined,
    lock_count: usize = 0,

    // Scratch buffers for setInt/fmt/valueInt — avoids heap allocation.
    int_buf: [32]u8 = undefined,
    fmt_buf: [512]u8 = undefined,

    const MAX_LOCKS = 16;

    pub const Result = Response;

    /// Held-lock snapshot. Returned by saveAndReleaseAllHeldShards so the
    /// procedure can re-acquire after an operation (store.set + replicate)
    /// that briefly needs no locks held.
    pub const HeldLocks = struct {
        indices: [MAX_LOCKS]usize,
        count: usize,
    };

    /// Initialize a context for a single procedure call.
    pub fn init(
        store: *Store,
        args: []const []const u8,
        allocator: std.mem.Allocator,
        id: ?[]const u8,
        cluster: ?*Cluster,
        event_bus: ?*EventBus,
        vector_registry: ?*NamespaceRegistry,
    ) Ctx {
        return .{
            .store = store,
            .args = args,
            .allocator = allocator,
            ._identity = id,
            .cluster = cluster,
            .event_bus = event_bus,
            .vector_registry = vector_registry,
        };
    }

    /// Release all shard locks acquired during this procedure.
    /// Called automatically by the executor after the procedure returns.
    pub fn deinit(self: *Ctx) void {
        // Unlock in reverse order for proper nesting
        while (self.lock_count > 0) {
            self.lock_count -= 1;
            self.store.shards[self.locked_shards[self.lock_count]].mutex.unlock();
        }
    }

    // ╔═══════════════════════════════════════════════╗
    // ║  Arguments                                     ║
    // ╚═══════════════════════════════════════════════╝

    /// Get argument by index, or null if out of bounds.
    pub fn arg(self: *const Ctx, index: usize) ?[]const u8 {
        if (index >= self.args.len) return null;
        return self.args[index];
    }

    /// Get argument as an integer, or null if missing or not parseable.
    pub fn argInt(self: *const Ctx, comptime T: type, index: usize) ?T {
        const val = self.arg(index) orelse return null;
        return std.fmt.parseInt(T, val, 10) catch null;
    }

    /// Number of arguments passed to this procedure.
    pub fn argCount(self: *const Ctx) usize {
        return self.args.len;
    }

    // ╔═══════════════════════════════════════════════╗
    // ║  Locking                                       ║
    // ╚═══════════════════════════════════════════════╝

    /// Lock the shard for a single key. Auto-unlocked on procedure return.
    /// Multiple calls to lockKey are safe — duplicates are skipped.
    pub fn lockKey(self: *Ctx, key: []const u8) void {
        const si = shardIndexFn(key);
        self.acquireShard(si);
    }

    /// Lock shards for two keys in deterministic order (prevents deadlocks).
    /// Auto-unlocked on procedure return.
    pub fn lockKeys2(self: *Ctx, key_a: []const u8, key_b: []const u8) void {
        const a = shardIndexFn(key_a);
        const b = shardIndexFn(key_b);

        if (a == b) {
            self.acquireShard(a);
            return;
        }

        // Always lock low index first to prevent deadlocks
        const low = @min(a, b);
        const high = @max(a, b);
        self.acquireShard(low);
        self.acquireShard(high);
    }

    /// Internal: acquire a shard lock if not already held.
    fn acquireShard(self: *Ctx, si: usize) void {
        // Check if already locked (prevents double-locking)
        for (self.locked_shards[0..self.lock_count]) |held| {
            if (held == si) return;
        }

        if (self.lock_count >= MAX_LOCKS) {
            // Safety: if we hit the limit, this is a programming error.
            // In release builds this silently does nothing (rather than crash the server).
            return;
        }

        self.store.shards[si].mutex.lock();
        self.locked_shards[self.lock_count] = si;
        self.lock_count += 1;
    }

    /// Internal: release a specific shard lock. Used by setDurable/setDurableWorm.
    fn releaseShard(self: *Ctx, si: usize) void {
        for (0..self.lock_count) |i| {
            if (self.locked_shards[i] == si) {
                self.store.shards[si].mutex.unlock();
                // Remove from tracking (swap with last)
                self.lock_count -= 1;
                if (i < self.lock_count) {
                    self.locked_shards[i] = self.locked_shards[self.lock_count];
                }
                return;
            }
        }
    }

    /// Release ALL currently-held shard locks and return a snapshot for
    /// later re-acquisition. Used by durable+replicated writes, which need
    /// no shard locks held during the cluster call — `replicateWrite` may
    /// trigger an anti-entropy `iterateAll` that locks every shard, which
    /// deadlocks against any locks held by the calling procedure.
    fn saveAndReleaseAllHeldShards(self: *Ctx) HeldLocks {
        var held: HeldLocks = .{ .indices = undefined, .count = self.lock_count };
        @memcpy(held.indices[0..held.count], self.locked_shards[0..self.lock_count]);

        // Release in reverse order (LIFO) to mirror deinit().
        while (self.lock_count > 0) {
            self.lock_count -= 1;
            self.store.shards[self.locked_shards[self.lock_count]].mutex.unlock();
        }
        return held;
    }

    /// Re-acquire shard locks in ascending index order. Sorting is required
    /// for deadlock safety against concurrent multi-shard lockers, which use
    /// ascending-order acquisition (see `lockKeys2` and the anti-entropy
    /// `iterateAll` loop). Small-n insertion sort — count is ≤ MAX_LOCKS (16).
    fn reacquireAllHeldShards(self: *Ctx, held_in: HeldLocks) void {
        var held = held_in;
        // Skip sort when count <= 1 — `for (1..0)` underflows on count==0,
        // which happens when a procedure uses deleteDurable with no prior
        // lockKey (e.g. vnsdrop's scan-then-delete pattern).
        if (held.count > 1) {
            for (1..held.count) |i| {
                const x = held.indices[i];
                var j = i;
                while (j > 0 and held.indices[j - 1] > x) : (j -= 1) {
                    held.indices[j] = held.indices[j - 1];
                }
                held.indices[j] = x;
            }
        }
        for (held.indices[0..held.count]) |si| {
            self.store.shards[si].mutex.lock();
            self.locked_shards[self.lock_count] = si;
            self.lock_count += 1;
        }
    }

    // ╔═══════════════════════════════════════════════╗
    // ║  Store Access                                  ║
    // ╚═══════════════════════════════════════════════╝

    /// Get the raw value for a key. Caller must hold the key's shard lock.
    pub fn get(self: *Ctx, key: []const u8) ?[]const u8 {
        const entry = self.store.getUnsafe(key) orelse return null;
        return entry.value;
    }

    /// Get an arena-owned copy of a key's value. Locks, copies, and unlocks
    /// internally — safe to call without holding any locks, and the returned
    /// slice remains valid after subsequent scans/writes. Use this when the
    /// value must outlive operations that re-lock shards (e.g. scanPrefix).
    pub fn getCopy(self: *Ctx, key: []const u8) !?[]const u8 {
        return self.store.getValueDupe(key, self.allocator);
    }

    /// Get the value for a key parsed as an integer.
    /// Returns null if key doesn't exist or value is not a valid integer.
    pub fn getInt(self: *Ctx, comptime T: type, key: []const u8) ?T {
        const val = self.get(key) orelse return null;
        return std.fmt.parseInt(T, val, 10) catch null;
    }

    /// Set a key to a string value. Caller must hold the key's shard lock.
    /// WARNING: Uses setUnsafe — bypasses WAL. Data lost on crash before snapshot.
    pub fn set(self: *Ctx, key: []const u8, val: []const u8) void {
        self.store.setUnsafe(key, val, false) catch {};
    }

    /// Set a key durably — goes through the full WAL path and (if a cluster
    /// handle is attached) replicates the write to peers. Matches wire-level
    /// SET semantics: local commit is authoritative; replication failures
    /// are logged but do not fail the write.
    ///
    /// All currently-held shard locks are released for the duration of the
    /// store.set + replicate. This is required because `replicateWrite` can
    /// trigger an anti-entropy scan that locks every shard — holding any
    /// shard lock through the call would deadlock the same thread.
    pub fn setDurable(self: *Ctx, key: []const u8, val: []const u8) !void {
        const held = self.saveAndReleaseAllHeldShards();
        defer self.reacquireAllHeldShards(held);

        try self.store.set(key, val, false);

        if (self.cluster) |c| {
            c.replicateWrite(key, val, false) catch |e| {
                std.log.warn("procedure replication failed: {s}", .{@errorName(e)});
            };
        }
    }

    /// Set a key durably as WORM (immutable once written). Replicated like
    /// `setDurable`; see that method's docs for the lock-dance rationale.
    pub fn setDurableWorm(self: *Ctx, key: []const u8, val: []const u8) !void {
        const held = self.saveAndReleaseAllHeldShards();
        defer self.reacquireAllHeldShards(held);

        try self.store.set(key, val, true);

        if (self.cluster) |c| {
            c.replicateWrite(key, val, true) catch |e| {
                std.log.warn("procedure replication failed: {s}", .{@errorName(e)});
            };
        }
    }

    /// Delete a key durably — goes through the WAL and replicates to peers.
    /// Returns `error.WormViolation` when the target key is immutable; the
    /// store's WORM check is authoritative. Lock dance mirrors `setDurable`.
    pub fn deleteDurable(self: *Ctx, key: []const u8) !void {
        const held = self.saveAndReleaseAllHeldShards();
        defer self.reacquireAllHeldShards(held);

        try self.store.delete(key);

        if (self.cluster) |c| {
            c.replicateDelete(key) catch |e| {
                std.log.warn("procedure delete replication failed: {s}", .{@errorName(e)});
            };
        }
    }

    /// Set a key to an integer value. Uses internal scratch buffer.
    pub fn setInt(self: *Ctx, key: []const u8, val: anytype) void {
        const str = std.fmt.bufPrint(&self.int_buf, "{d}", .{val}) catch return;
        self.set(key, str);
    }

    /// Check if a key exists. Caller must hold the key's shard lock.
    pub fn exists(self: *Ctx, key: []const u8) bool {
        return self.store.getUnsafe(key) != null;
    }

    /// Delete a key. Caller must hold the key's shard lock.
    /// Note: this is the unsafe internal delete (no WORM check, no WAL).
    /// For procedures this is appropriate since the lock is already held.
    pub fn del(self: *Ctx, key: []const u8) void {
        const si = shardIndexFn(key);
        const shard = &self.store.shards[si];
        if (shard.data.fetchRemove(key)) |removed| {
            self.store.destroyEntry(removed.value);
        }
    }

    /// Get entry metadata (timestamp).
    pub fn getTimestamp(self: *Ctx, key: []const u8) ?u64 {
        const entry = self.store.getUnsafe(key) orelse return null;
        return entry.timestamp;
    }

    // ╔═══════════════════════════════════════════════╗
    // ║  Responses                                     ║
    // ╚═══════════════════════════════════════════════╝

    /// Return success with no payload.
    pub fn ok(_: *const Ctx) Result {
        return .ok;
    }

    /// Return an error message. The string must be a comptime literal or
    /// have a lifetime that outlives the response (arena-allocated).
    pub fn err(self: *Ctx, msg: []const u8) Result {
        // Duplicate into the arena allocator so the response outlives the procedure.
        return .{ .err = self.allocator.dupe(u8, msg) catch "internal_error" };
    }

    /// Return a string value.
    pub fn value(self: *Ctx, data: []const u8) Result {
        return .{ .value = self.allocator.dupe(u8, data) catch null };
    }

    /// Return an integer value as a string.
    pub fn valueInt(self: *Ctx, val: anytype) Result {
        const str = std.fmt.bufPrint(&self.int_buf, "{d}", .{val}) catch return .{ .err = "format_error" };
        return self.value(str);
    }

    // ╔═══════════════════════════════════════════════╗
    // ║  Utilities                                     ║
    // ╚═══════════════════════════════════════════════╝

    /// Format a string using the internal scratch buffer.
    /// The returned slice is valid until the next fmt() call.
    pub fn fmt(self: *Ctx, comptime format: []const u8, fmtArgs: anytype) []const u8 {
        return std.fmt.bufPrint(&self.fmt_buf, format, fmtArgs) catch &.{};
    }

    /// Current server timestamp in milliseconds since epoch.
    pub fn timestamp(_: *const Ctx) u64 {
        return @intCast(compat.nowMs());
    }

    /// Compare two byte slices for equality.
    pub fn eql(_: *const Ctx, a: []const u8, b: []const u8) bool {
        return std.mem.eql(u8, a, b);
    }

    /// Get the authenticated identity (SCT subject) for this connection.
    /// Returns null if the connection is not authenticated.
    pub fn identity(self: *const Ctx) ?[]const u8 {
        return self._identity;
    }

    /// Publish an event to all subscribers of `channel`. No-op if the event
    /// bus is unattached (tests, single-node builds). Errors are logged and
    /// swallowed — pub/sub is best-effort from the procedure's perspective.
    pub fn publish(self: *Ctx, channel: []const u8, message: []const u8) void {
        const bus = self.event_bus orelse return;
        bus.publish(channel, message) catch |e| {
            std.log.warn("procedure publish to '{s}' failed: {s}", .{ channel, @errorName(e) });
        };
    }

    /// Generate random hex string. Returns a slice from the fmt scratch buffer.
    pub fn randomHex(self: *Ctx, byte_count: usize) []const u8 {
        const max = @min(byte_count, self.fmt_buf.len / 2);
        var rand_bytes: [256]u8 = undefined;
        const actual = @min(max, rand_bytes.len);
        compat.randomBytes(rand_bytes[0..actual]);

        var i: usize = 0;
        for (rand_bytes[0..actual]) |b| {
            const hex = "0123456789abcdef";
            self.fmt_buf[i] = hex[b >> 4];
            self.fmt_buf[i + 1] = hex[b & 0x0f];
            i += 2;
        }
        return self.fmt_buf[0..i];
    }

    // ╔═══════════════════════════════════════════════╗
    // ║  Key Scanning                                  ║
    // ╚═══════════════════════════════════════════════╝

    /// Scan for keys matching a prefix. Returns arena-allocated copies sorted by key (ascending).
    /// Locks each shard independently — does NOT require the caller to hold any locks.
    /// O(N) over total keys; cap with `limit` to bound cost.
    pub fn scan(self: *Ctx, prefix: []const u8, limit: usize) ![]Store.ScanResult {
        return self.store.scanPrefix(prefix, limit, self.allocator);
    }

    /// Callback-based prefix scan — yields borrowed key/value slices (no
    /// arena copy). See Store.scanPrefixCallback for the callback contract.
    ///
    /// The caller MUST NOT hold any shard locks when calling this — the scan
    /// will deadlock against its own held lock (same contract as `scan`).
    pub fn scanCallback(
        self: *Ctx,
        prefix: []const u8,
        context: *anyopaque,
        callback: *const fn (
            context: *anyopaque,
            key: []const u8,
            value: []const u8,
            timestamp: u64,
            is_worm: bool,
        ) Store.ScanAction,
    ) void {
        self.store.scanPrefixCallback(prefix, context, callback);
    }

    /// Count keys matching a prefix. Lightweight — no allocation.
    pub fn countKeys(self: *Ctx, prefix: []const u8) usize {
        return self.store.countPrefix(prefix);
    }
};

test "Ctx arg helpers" {
    const testing = std.testing;
    var store: Store = undefined; // not accessed in arg tests
    const args = &[_][]const u8{ "hello", "42", "bad" };
    var ctx = Ctx.init(&store, args, testing.allocator, null, null, null, null);
    defer ctx.deinit();

    try testing.expectEqualStrings("hello", ctx.arg(0).?);
    try testing.expectEqualStrings("42", ctx.arg(1).?);
    try testing.expect(ctx.arg(5) == null);
    try testing.expectEqual(@as(i64, 42), ctx.argInt(i64, 1).?);
    try testing.expect(ctx.argInt(i64, 2) == null); // "bad" is not a number
    try testing.expect(ctx.argInt(i64, 99) == null); // out of bounds
    try testing.expectEqual(@as(usize, 3), ctx.argCount());
    try testing.expect(ctx.identity() == null); // no identity
}
