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
pub const witness = @import("witness.zig");
pub const prefix_root = @import("prefix_root.zig");
pub const trust_log = @import("trust_log.zig");

pub const AccumulatorKind = checkpoint.AccumulatorKind;
pub const CheckpointRecord = checkpoint.CheckpointRecord;
pub const Hash = checkpoint.Hash;
pub const Signature = checkpoint.Signature;
pub const SignatureScheme = checkpoint.SignatureScheme;
pub const WitnessRecord = witness.WitnessRecord;
pub const BundleKind = proof_bundle.BundleKind;
pub const ProofBundle = proof_bundle.ProofBundle;
pub const BundleRecord = proof_bundle.BundleRecord;
pub const InclusionProof = proof_bundle.InclusionProof;
pub const BundleInfo = proof_bundle.BundleInfo;
pub const OwnedProofBundle = proof_bundle.OwnedProofBundle;
pub const EncodedBundle = proof_bundle.EncodedBundle;
pub const AppendLogMmrBundleOptions = proof_bundle.AppendLogMmrBundleOptions;
pub const AccumulatorVerifier = proof_bundle.AccumulatorVerifier;
pub const MmrVerifierContext = proof_bundle.MmrVerifierContext;
pub const mmrAccumulatorVerifier = proof_bundle.mmrAccumulatorVerifier;
pub const encodeProofBundleCanonical = proof_bundle.encodeCanonical;
pub const decodeProofBundleCanonical = proof_bundle.decodeCanonical;
pub const buildAppendLogMmrBundle = proof_bundle.buildAppendLogMmrBundle;
pub const verifyAppendLogMmrBundle = proof_bundle.verifyAppendLogMmrBundle;
pub const verifyEncodedAppendLogMmrBundle = proof_bundle.verifyEncodedAppendLogMmrBundle;
pub const MmrAccumulator = mmr.Accumulator;
pub const MmrInclusionProof = mmr.InclusionProof;
pub const MmrPeak = mmr.Peak;
pub const PrefixRootSummary = prefix_root.Summary;
pub const encodeMmrInclusionProof = mmr.encodeInclusionProof;
pub const decodeMmrInclusionProof = mmr.decodeInclusionProof;

test {
    @import("std").testing.refAllDecls(@This());
}
