# Vector Benchmark — WormDB vs Qdrant

Head-to-head ANN benchmark using standardized ann-benchmarks datasets.
All services run in docker on a shared bridge network.

## One-time setup

Build the WormDB binary (the image copies it from `zig-out/bin/`):

```bash
cd ../..
zig build -Dquic=false
```

## Run a benchmark

```bash
# From repo root
docker compose -f bench/vector/docker-compose.yml build

# WormDB, exact mode
docker compose -f bench/vector/docker-compose.yml run --rm harness \
    --adapter wormdb --mode exact --dataset sift-128-euclidean

# WormDB, BQ (quantized) mode
docker compose -f bench/vector/docker-compose.yml run --rm harness \
    --adapter wormdb --mode quantized --dataset sift-128-euclidean

# Qdrant, full-precision
docker compose -f bench/vector/docker-compose.yml run --rm harness \
    --adapter qdrant --mode exact --dataset sift-128-euclidean

# Qdrant, scalar(int8) quantization
docker compose -f bench/vector/docker-compose.yml run --rm harness \
    --adapter qdrant --mode quantized --dataset sift-128-euclidean

# Generate combined report
docker compose -f bench/vector/docker-compose.yml run --rm harness \
    bun run src/report.ts --dataset sift-128-euclidean

# Tear down
docker compose -f bench/vector/docker-compose.yml down -v
```

Results are written to `bench/vector/results/<dataset>/`. The dataset file is
cached in `bench/vector/data/` across runs.

## What gets measured

- **Insert wall time** — time from first VINSERT/upsert to last ack.
- **Time-until-queryable** — wall time until a 16-ID probe returns its
  expected top-1 (the honest metric; Qdrant builds HNSW async).
- **Recall@K** — fraction of the ground-truth top-K returned.
- **QPS (single-client)** — single persistent connection, serial queries.
- **QPS (concurrent)** — N independent clients in parallel (default N=8).
- **Latency p50 / p95 / p99** — per-query wall time.

Each adapter runs at every `--efs` level (default `16,32,64,128,256`) for
a recall/QPS frontier.

## Adapter differences to flag in any report

- **WormDB exact**   — brute-force over HNSW-indexed vectors.
- **WormDB quantized** — 1-bit binary quantization Hamming prefilter → exact rerank.
- **Qdrant exact**   — full-precision HNSW search.
- **Qdrant quantized** — scalar int8. *Not equivalent* to 1-bit BQ; label
  as "scalar(int8)" to avoid comparing like-for-like.

Both are configured with `M=16, ef_construction=200` as HNSW defaults.
WormDB does not currently support a runtime `ef_search` knob — the `--efs`
argument is honored by Qdrant only. This is flagged in the per-run notes.
