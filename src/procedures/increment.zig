//! Built-in INCREMENT procedure
//!
//! Atomic increment/decrement with return value.
//! EXEC increment <key> [<delta>]
//!
//! - If key doesn't exist, initializes to 0 before adding delta
//! - delta defaults to 1 if not provided
//! - Returns the new value

const Ctx = @import("context.zig").Ctx;

pub fn execute(ctx: *Ctx) anyerror!Ctx.Result {
    const key = ctx.arg(0) orelse return ctx.err("increment requires at least 1 arg: <key> [<delta>]");
    const delta = ctx.argInt(i64, 1) orelse 1;

    ctx.lockKey(key);

    const current = ctx.getInt(i64, key) orelse 0;
    const new_val = current + delta;
    ctx.setInt(key, new_val);
    return ctx.valueInt(new_val);
}
