//! Light-API frozen-segment table ids (the `0..=10` slice of the shared `.wseg`
//! table-id namespace). The engine's `Segment` is domain-agnostic — `lookup`/
//! `has`/`keyCount` take an opaque `u32` — so these names live here, in the
//! Light-API domain, exactly as AtomicAssets owns its ids in
//! `atomicassets/binfmt.zig` (`11..=21`). The builder (hyperion-tools) and these
//! readers must agree on the numbers.

pub const TableId = struct {
    pub const balances: u32 = 0; // holder name -> packed "<contract>\t<symbol>\t<dec>\t<amount>\n..."
    pub const resources: u32 = 1; // (reserved) account -> binary resources
    pub const perms: u32 = 2; // (reserved) account -> binary permission list
    pub const delband_from: u32 = 3; // (reserved) `from` -> delegations made
    pub const delband_to: u32 = 4; // (reserved) `to` -> delegations received
    pub const accinfo: u32 = 5; // account -> cc32d9 accinfo fragment; key count = usercount
    pub const token_holders: u32 = 6; // tokenKey(contract,symbol) -> holders (amount-desc)
    pub const pub_keys: u32 = 7; // fnv1a64(pubkey) -> holders of that key
    pub const top_ram: u32 = 8; // sentinel 0 -> [u32 count]["owner\tram\n"…] (ram-desc)
    pub const top_stake: u32 = 9; // sentinel 0 -> [u32 count]["owner\tstake\n"…] (cpu+net-desc)
    pub const codehash: u32 = 10; // fnv1a64(code_hash hex) -> accounts with that code
};

test {
    @import("std").testing.refAllDecls(@This());
}
