/**
 * recall@K: for each query, what fraction of the ground-truth top-K is
 * returned in the adapter's top-K. Averaged across queries.
 *
 * Ground truth: `neighbors[q * gtK + i]` for i ∈ [0, gtK).
 * We use the first K of those as the reference set.
 */
export function recallAtK(
  predicted: Int32Array[], // per-query returned top-K indices
  neighbors: Int32Array,
  gtK: number,
  k: number,
): number {
  if (predicted.length === 0) return 0;
  if (k > gtK) throw new Error(`k (${k}) > ground-truth K (${gtK})`);
  let total = 0;
  for (let q = 0; q < predicted.length; q += 1) {
    const gt = new Set<number>();
    for (let i = 0; i < k; i += 1) gt.add(neighbors[q * gtK + i]);
    const got = predicted[q];
    let hits = 0;
    for (let i = 0; i < Math.min(k, got.length); i += 1) {
      if (gt.has(got[i])) hits += 1;
    }
    total += hits / k;
  }
  return total / predicted.length;
}

export function percentile(sorted: number[], p: number): number {
  if (sorted.length === 0) return 0;
  const idx = Math.min(sorted.length - 1, Math.floor(sorted.length * p));
  return sorted[idx];
}

export type LatencySummary = {
  n: number;
  meanMs: number;
  p50Ms: number;
  p95Ms: number;
  p99Ms: number;
};

export function summarizeLatencies(latenciesMs: number[]): LatencySummary {
  const sorted = [...latenciesMs].sort((a, b) => a - b);
  const sum = sorted.reduce((s, v) => s + v, 0);
  return {
    n: sorted.length,
    meanMs: sum / Math.max(sorted.length, 1),
    p50Ms: percentile(sorted, 0.5),
    p95Ms: percentile(sorted, 0.95),
    p99Ms: percentile(sorted, 0.99),
  };
}
