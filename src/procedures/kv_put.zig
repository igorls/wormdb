//! Built-in KV_PUT procedure
//!
//! Atomic key write with analytics tracking.
//! EXEC kv_put <key> <value>
//!
//! In a single atomic operation:
//! - Writes the value to <key>
//! - Increments global stats:writes counter
//! - Creates/updates meta:<key> with timestamps and write count
//! - Returns OK
//!
//! This demonstrates multi-key read-modify-write that raw SET cannot do:
//! the write counter and metadata are always consistent with the data.

const Ctx = @import("context.zig").Ctx;

pub fn execute(ctx: *Ctx) anyerror!Ctx.Result {
    const key = ctx.arg(0) orelse return ctx.err("kv_put requires 2 args: <key> <value>");
    const val = ctx.arg(1) orelse return ctx.err("kv_put requires 2 args: <key> <value>");

    // Build the metadata key. Copy immediately since fmt_buf is shared.
    const meta_key = ctx.fmt("meta:{s}", .{key});
    var meta_key_copy: [512]u8 = undefined;
    const meta_len = @min(meta_key.len, meta_key_copy.len);
    @memcpy(meta_key_copy[0..meta_len], meta_key[0..meta_len]);
    const meta_key_stable = meta_key_copy[0..meta_len];

    // Lock all involved shards before any reads/writes.
    ctx.lockKey(key);
    ctx.lockKey("stats:writes");
    ctx.lockKey(meta_key_stable);

    // 1. Write the actual value
    ctx.set(key, val);

    // 2. Increment global writes counter
    const writes = ctx.getInt(i64, "stats:writes") orelse 0;
    ctx.setInt("stats:writes", writes + 1);

    // 3. Update per-key metadata
    const now = ctx.timestamp();
    const existing_meta = ctx.get(meta_key_stable);
    var write_count: i64 = 1;
    var created_at: u64 = now;

    if (existing_meta) |raw| {
        // Parse existing metadata: "created=<ts>\nupdated=<ts>\nwrites=<n>\nreads=<n>"
        var lines = splitLines(raw);
        while (lines.next()) |line| {
            if (startsWith(line, "writes=")) {
                const num_str = line["writes=".len..];
                if (parseInt(num_str)) |n| {
                    write_count = n + 1;
                }
            } else if (startsWith(line, "created=")) {
                const num_str = line["created=".len..];
                if (parseUint(num_str)) |n| {
                    created_at = n;
                }
            }
        }
    }

    const meta_val = ctx.fmt("created={d}\nupdated={d}\nwrites={d}\nreads=0", .{ created_at, now, write_count });
    ctx.set(meta_key_stable, meta_val);

    return ctx.ok();
}

// ── Tiny parsers (no allocator needed) ─────────────────────────

fn startsWith(haystack: []const u8, prefix: []const u8) bool {
    if (haystack.len < prefix.len) return false;
    return @import("std").mem.eql(u8, haystack[0..prefix.len], prefix);
}

fn parseInt(s: []const u8) ?i64 {
    return @import("std").fmt.parseInt(i64, s, 10) catch null;
}

fn parseUint(s: []const u8) ?u64 {
    return @import("std").fmt.parseInt(u64, s, 10) catch null;
}

const LineIterator = struct {
    data: []const u8,
    pos: usize,

    fn next(self: *LineIterator) ?[]const u8 {
        if (self.pos >= self.data.len) return null;
        const start = self.pos;
        while (self.pos < self.data.len and self.data[self.pos] != '\n') {
            self.pos += 1;
        }
        const line = self.data[start..self.pos];
        if (self.pos < self.data.len) self.pos += 1; // skip '\n'
        return line;
    }
};

fn splitLines(data: []const u8) LineIterator {
    return .{ .data = data, .pos = 0 };
}
