//! Vector search module — SIMD-optimized similarity search
//!
//! Provides distance functions, binary quantization, and helpers
//! for storing and querying high-dimensional vectors in WormDB.
//!
//! Vectors are stored as raw f32 byte arrays in WormDB values,
//! using the key convention: vec:<namespace>:<id>

pub const distance = @import("distance.zig");
pub const topk = @import("topk.zig");
pub const TopK = topk.TopK;
pub const metric = @import("metric.zig");
pub const Metric = metric.Metric;
pub const DistFn = metric.DistFn;
pub const hnsw = @import("hnsw.zig");
pub const Hnsw = hnsw.Hnsw;
pub const HnswParams = hnsw.HnswParams;
pub const index = @import("index.zig");
pub const NamespaceIndex = index.NamespaceIndex;
pub const NamespaceRegistry = index.NamespaceRegistry;
pub const rabitq = @import("rabitq.zig");

// Re-export commonly used functions
pub const cosine = distance.cosine;
pub const dot = distance.dot;
pub const l2 = distance.l2;
pub const l2Squared = distance.l2Squared;
pub const hamming = distance.hamming;
pub const hammingSimilarity = distance.hammingSimilarity;
pub const binaryQuantize = distance.binaryQuantize;
pub const binaryQuantizedSize = distance.binaryQuantizedSize;
pub const bytesToF32 = distance.bytesToF32;
pub const f32ToBytes = distance.f32ToBytes;

test {
    @import("std").testing.refAllDecls(@This());
}
