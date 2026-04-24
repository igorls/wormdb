// Deterministic hash-embedder for CI and reproducible demos.
//
// NOT semantically meaningful — same text always produces the same vector,
// different texts produce different vectors, but the geometry isn't
// correlated with meaning. Good enough to exercise the vector-search
// plumbing end-to-end without pulling a model into CI. Swap for Ollama
// or an API-backed embedder in production.

const FNV_OFFSET = 2166136261n;
const FNV_PRIME = 16777619n;
const U32_MASK = 0xffffffffn;

function fnv1a(seed: bigint, bytes: Uint8Array): bigint {
  let h = seed;
  for (const b of bytes) {
    h = h ^ BigInt(b);
    h = (h * FNV_PRIME) & U32_MASK;
  }
  return h;
}

/// Tokenize a string into lowercase alphanumeric "words". Anything that
/// isn't [a-z0-9] splits. Short and Unicode-naive on purpose — we're
/// after a deterministic bag-of-words hash, not a real tokenizer.
function tokenize(text: string): string[] {
  return text
    .toLowerCase()
    .split(/[^a-z0-9]+/)
    .filter((t) => t.length > 0);
}

export type HashEmbedderOptions = {
  /// Output dimensionality. Default 128 — plenty for demo-scale similarity
  /// discrimination, small enough to keep bench memory tiny.
  dim?: number;
};

/// Build a fixed-dim f32 vector by hashing tokens into buckets with
/// signed increments, then L2-normalizing. Identical text → identical
/// bytes; small edits produce cosine similarity close to 1.
export function embed(text: string, options: HashEmbedderOptions = {}): Uint8Array {
  const dim = options.dim ?? 128;
  const vec = new Float32Array(dim);
  const tokens = tokenize(text);
  if (tokens.length === 0) {
    // All-zero input is pathological for cosine; nudge to a stable unit
    // vector so dim-freeze + search behave sanely.
    vec[0] = 1;
  } else {
    const encoder = new TextEncoder();
    for (const token of tokens) {
      const bytes = encoder.encode(token);
      // Two hashes per token: one for the bucket, one for the sign.
      const bucket = Number(fnv1a(FNV_OFFSET, bytes) % BigInt(dim));
      const signHash = fnv1a(FNV_OFFSET ^ 0x9e3779b9n, bytes);
      const sign = (signHash & 1n) === 0n ? 1 : -1;
      vec[bucket] += sign;
    }
  }

  // L2-normalize so cosine behaves intuitively on the output.
  let norm = 0;
  for (let i = 0; i < dim; i += 1) norm += vec[i] * vec[i];
  const inv = norm > 0 ? 1 / Math.sqrt(norm) : 0;
  for (let i = 0; i < dim; i += 1) vec[i] *= inv;

  // Return as a Uint8Array view into the f32 buffer. Little-endian on
  // all WormDB supported targets; the server expects raw f32 LE bytes.
  return new Uint8Array(vec.buffer, vec.byteOffset, vec.byteLength);
}

/// Identifier for the embedder — goes into `mem_init` so stats and
/// capabilities reporting can tell which embedder a namespace belongs to.
export function embedderId(options: HashEmbedderOptions = {}): string {
  const dim = options.dim ?? 128;
  return `hash-fnv1a.dim-${dim}.v1`;
}
