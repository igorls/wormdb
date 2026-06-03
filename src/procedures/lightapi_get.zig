//! Generic precomputed-response fetch for Light-API endpoints whose body is materialized at load
//! time (accinfo, usercount, holdercount, networks, codehash, …). EXEC lightapi_get <key> [default]

const Ctx = @import("context.zig").Ctx;

pub fn execute(ctx: *Ctx) anyerror!Ctx.Result {
    const key = ctx.arg(0) orelse return ctx.err("lightapi_get requires <key> [default]");
    if (try ctx.getCopy(key)) |v| return ctx.value(v);
    return ctx.value(ctx.arg(1) orelse "");
}
