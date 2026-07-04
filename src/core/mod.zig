//! Core module - fundamental types and configuration
//!
//! This module provides the foundational types used throughout WormDB:
//! - Entry: Key-value entry with metadata
//! - Command: Client commands (GET, SET, etc.)
//! - Response: Server responses
//! - Config: Store configuration

const std = @import("std");

pub const types = @import("types.zig");
pub const config = @import("config.zig");
pub const compat = @import("compat.zig");
pub const predicate = @import("predicate.zig");
pub const hlc = @import("hlc.zig");

// Re-export commonly used types
pub const Entry = types.Entry;
pub const EntryFlags = types.EntryFlags;
pub const Command = types.Command;
pub const Response = types.Response;
pub const Timestamp = types.Timestamp;
pub const StoreError = types.StoreError;
pub const WalRecordType = types.WalRecordType;
pub const Config = config.Config;

test {
    @import("std").testing.refAllDecls(@This());
}
