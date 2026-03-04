//! Built-in TRANSFER procedure
//!
//! Atomic debit/credit between two accounts.
//! EXEC transfer <from_key> <to_key> <amount>
//!
//! - Reads both balances
//! - Rejects with "insufficient_funds" if from_balance < amount
//! - Atomically writes new balances for both accounts

const Ctx = @import("context.zig").Ctx;

pub fn execute(ctx: *Ctx) anyerror!Ctx.Result {
    const from = ctx.arg(0) orelse return ctx.err("transfer requires 3 args: <from> <to> <amount>");
    const to = ctx.arg(1) orelse return ctx.err("transfer requires 3 args: <from> <to> <amount>");
    const amount = ctx.argInt(i64, 2) orelse return ctx.err("invalid amount");

    if (amount <= 0) return ctx.err("amount must be positive");

    ctx.lockKeys2(from, to);

    const from_bal = ctx.getInt(i64, from) orelse return ctx.err("from account not found");
    const to_bal = ctx.getInt(i64, to) orelse return ctx.err("to account not found");

    if (from_bal < amount) return ctx.err("insufficient_funds");

    ctx.setInt(from, from_bal - amount);
    ctx.setInt(to, to_bal + amount);
    return ctx.ok();
}
