//! Protocol module - wire format parsing
//!
//! This module handles parsing and formatting of client commands.

const std = @import("std");
pub const parser = @import("parser.zig");
pub const wire = @import("wire.zig");

pub const ProtocolError = parser.ProtocolError;
pub const parseCommand = parser.parseCommand;
pub const deinitCommand = parser.deinitCommand;
pub const formatResponse = parser.formatResponse;
pub const deinitResponse = parser.deinitResponse;

test {
    @import("std").testing.refAllDecls(@This());
}
