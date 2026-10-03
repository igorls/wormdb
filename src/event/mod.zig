//! Event module - pub/sub event bus
//!
//! Provides publish/subscribe messaging for real-time updates.

const std = @import("std");
pub const bus = @import("bus.zig");

pub const EventBus = bus.EventBus;
pub const Subscriber = bus.Subscriber;
pub const Channel = bus.Channel;
pub const LifetimeHooks = bus.LifetimeHooks;

test {
    @import("std").testing.refAllDecls(@This());
}
