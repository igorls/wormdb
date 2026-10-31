//! The Ford Toll: a sample law. Whoever crosses pays a share of what they carry into the treasury.
//!
//!   pass <handle> <carried>   pay the toll; returns what the traveller keeps
//!   set_rate <percent>        change the toll, 0 to 100 (default 10)
//!
//! Build: zig build laws   (or see build.zig for the exact flags)

const law = @import("law.zig");

export fn pass() void {
    var handle_buf: [64]u8 = undefined;
    const handle = law.argBytes(0, &handle_buf) orelse law.failWith("pass needs <handle> <carried>");
    const carried = law.argInt(1) orelse law.failWith("carried must be a whole number");
    if (carried < 0) law.failWith("carried must not be negative");

    const rate = law.getInt("rate") orelse 10;
    const toll = @divTrunc(carried * rate, 100);
    law.setInt("treasury", (law.getInt("treasury") orelse 0) + toll);

    var key_buf: [80]u8 = undefined;
    const paid_key = law.concat(&key_buf, "paid:", handle);
    law.setInt(paid_key, (law.getInt(paid_key) orelse 0) + toll);

    law.retInt(carried - toll);
}

export fn set_rate() void {
    const rate = law.argInt(0) orelse law.failWith("set_rate needs <percent>");
    if (rate < 0 or rate > 100) law.failWith("rate must be 0 to 100");
    law.setInt("rate", rate);
    law.retInt(rate);
}

/// Spins until the fuel runs out — what the host must survive.
export fn spin() void {
    var i: i64 = 0;
    while (law.getInt("never") == null) : (i += 1) {
        if (i < 0) break;
    }
}
