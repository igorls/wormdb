//! Storage module - WAL and in-memory store
//!
//! This module provides the storage layer for WormDB:
//! - WAL: Write-Ahead Log for durability
//! - Store: In-memory HashMap with WAL persistence

const std = @import("std");
const core = @import("../core/mod.zig");

pub const wal = @import("wal.zig");
pub const store = @import("store.zig");
pub const segment = @import("segment.zig");

// Re-export the frozen-segment reader.
pub const Segment = segment.Segment;

// Re-export types
pub const Wal = wal.Wal;
pub const WalIterator = wal.WalIterator;
pub const WalRecord = wal.WalRecord;
pub const Store = store.Store;
pub const WalRecordType = core.types.WalRecordType;
pub const StoreError = core.types.StoreError;

test {
    @import("std").testing.refAllDecls(@This());
}
