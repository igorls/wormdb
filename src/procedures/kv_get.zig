//! Built-in KV_GET procedure
//!
//! Atomic key read with access tracking.
//! EXEC kv_get <key>
//!
//! In a single atomic operation:
//! - Reads the value from <key> (returns error if missing)
//! - Increments global stats:reads counter
//! - Updates meta:<key> last_accessed and read count
//! - Returns the value
//!
//! This demonstrates read-with-side-effects: every GET automatically
//! maintains analytics that would require multiple round-trips otherwise.

const Ctx = @import("context.zig").Ctx;

pub fn execute(ctx: *Ctx) anyerror!Ctx.Result {
    const key = ctx.arg(0) orelse return ctx.err("kv_get requires 1 arg: <key>");

    // Build the metadata key. Copy immediately since fmt_buf is shared.
    const meta_key = ctx.fmt("meta:{s}", .{key});
    var meta_key_copy: [512]u8 = undefined;
    const meta_len = @min(meta_key.len, meta_key_copy.len);
    @memcpy(meta_key_copy[0..meta_len], meta_key[0..meta_len]);
    const meta_key_stable = meta_key_copy[0..meta_len];

    // Lock all involved shards before any reads/writes.
    ctx.lockKey(key);
    ctx.lockKey("stats:reads");
    ctx.lockKey(meta_key_stable);

    // 1. Read the actual value
    const val = ctx.get(key) orelse return ctx.err("key_not_found");

    // 2. Increment global reads counter
    const reads = ctx.getInt(i64, "stats:reads") orelse 0;
    ctx.setInt("stats:reads", reads + 1);

    // 3. Update per-key metadata (preserve existing fields, update reads + last_accessed)
    const now = ctx.timestamp();
    const existing_meta = ctx.get(meta_key_stable);
    var read_count: i64 = 1;
    var created_at: u64 = now;
    var write_count: i64 = 0;

    if (existing_meta) |raw| {
        var lines = splitLines(raw);
        while (lines.next()) |line| {
            if (startsWith(line, "reads=")) {
                const num_str = line["reads=".len..];
                if (parseInt(num_str)) |n| {
                    read_count = n + 1;
                }
            } else if (startsWith(line, "created=")) {
                const num_str = line["created=".len..];
                if (parseUint(num_str)) |n| {
                    created_at = n;
                }
            } else if (startsWith(line, "writes=")) {
                const num_str = line["writes=".len..];
                if (parseInt(num_str)) |n| {
                    write_count = n;
                }
            }
        }
    }

    const meta_val = ctx.fmt("created={d}\nupdated={d}\nwrites={d}\nreads={d}", .{ created_at, now, write_count, read_count });
    ctx.set(meta_key_stable, meta_val);

    // 4. Return the value
    return ctx.value(val);
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
