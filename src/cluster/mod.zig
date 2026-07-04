//! Cluster module - distributed features
//!
//! Integration with meshguard for P2P discovery and replication.
//! - Discovery via meshguard control socket (Unix domain socket)
//! - Replication via WormWire TCP over WireGuard tunnels

const std = @import("std");
pub const node = @import("node.zig");
pub const org_trust = @import("org_trust.zig");

pub const Cluster = node.Cluster;
pub const ClusterNode = node.ClusterNode;
pub const ClusterStatus = node.ClusterStatus;
pub const ClusterConfig = node.ClusterConfig;
pub const OrgTrust = org_trust.OrgTrust;

test {
    @import("std").testing.refAllDecls(@This());
}
