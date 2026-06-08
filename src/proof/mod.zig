//! Proof primitives for verifiable WORM logs.
//!
//! This package owns database-level proof material: checkpoint records,
//! canonical signing inputs, proof-bundle shape, and verifier scaffolding.
//! Accumulator internals (Merkle/MMR construction) live behind the verifier
//! callback so the proof format can stabilize independently.

pub const checkpoint = @import("checkpoint.zig");
pub const proof_bundle = @import("proof_bundle.zig");
pub const append_log = @import("append_log.zig");
pub const mmr = @import("mmr.zig");

pub const AccumulatorKind = checkpoint.AccumulatorKind;
pub const CheckpointRecord = checkpoint.CheckpointRecord;
pub const Hash = checkpoint.Hash;
pub const Signature = checkpoint.Signature;
pub const SignatureScheme = checkpoint.SignatureScheme;
pub const ProofBundle = proof_bundle.ProofBundle;
pub const BundleRecord = proof_bundle.BundleRecord;
pub const InclusionProof = proof_bundle.InclusionProof;
pub const AccumulatorVerifier = proof_bundle.AccumulatorVerifier;
pub const MmrAccumulator = mmr.Accumulator;
pub const MmrInclusionProof = mmr.InclusionProof;
pub const MmrPeak = mmr.Peak;

test {
    @import("std").testing.refAllDecls(@This());
}
