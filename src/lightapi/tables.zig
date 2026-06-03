//! Light-API frozen-segment table ids.
//!
//! The generic `storage/segment.zig` core identifies tables by a plain `u32`.
//! These named constants are the Light-API application's contract with the
//! offline segment builder (hyperion-tools `wseg-build`): builder and reader
//! must agree on the numbers. Pass these where `Segment.lookup`/`has`/`keyCount`
//! take a `u32` table id.

/// holder name -> packed "<contract>\t<symbol>\t<dec>\t<amount>\n..."
pub const balances: u32 = 0;
/// (reserved) account -> binary resources
pub const resources: u32 = 1;
/// (reserved) account -> binary permission list
pub const perms: u32 = 2;
/// (reserved) `from` -> delegations made
pub const delband_from: u32 = 3;
/// (reserved) `to` -> delegations received
pub const delband_to: u32 = 4;
/// account name -> cc32d9 accinfo fragment ("resources":…,"linkauth":[…][,"code":…]})
pub const accinfo: u32 = 5;
/// tokenKey(contract,symbol) -> [u16 hdr]["contract:symbol"] + "acct\tamount\n"… (amount-desc)
pub const token_holders: u32 = 6;
/// fnv1a64(pubkey EOS|PUB_K1) -> "account\tperm\tweight\n"… (holders of that key)
pub const pub_keys: u32 = 7;

test {
    @import("std").testing.refAllDecls(@This());
}
