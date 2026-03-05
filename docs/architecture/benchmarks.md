# Benchmarks

WormDB ships with a browser-based benchmark dashboard that measures latency and throughput across four access patterns, directly from the browser.

## Access Architectures

| Lane              | Protocol  | Description                                          |
| :---------------- | :-------- | :--------------------------------------------------- |
| REST API          | HTTP/1.1  | Traditional REST gateway (`GET`/`POST /api/kv/:key`) |
| WormDB + Auth     | WebSocket | WormWire binary protocol with SCT authentication     |
| WormDB No Auth    | WebSocket | WormWire binary protocol, no auth overhead           |
| QUIC WebTransport | QUIC/H3   | WormWire over a persistent bidirectional QUIC stream |

## Results

Mixed read/write workload (80/20), 5,000 iterations, 16 KB payload, pipeline depth 32.

| Architecture          |   Ops/sec |    Mean |  Median |     P95 |     P99 |     Min |
| :-------------------- | --------: | ------: | ------: | ------: | ------: | ------: |
| **QUIC WebTransport** | **9,461** |  3.21ms |  2.76ms |  6.33ms |  8.55ms |  0.57ms |
| WormDB No Auth        |     5,235 |  6.09ms |  5.71ms |  9.83ms | 12.77ms |  1.84ms |
| WormDB + Auth         |     4,831 |  6.57ms |  5.94ms | 11.37ms | 14.83ms |  2.74ms |
| REST API              |     1,087 | 29.37ms | 28.40ms | 42.90ms | 51.40ms | 10.92ms |

> [!NOTE]
> Benchmarks were run on localhost inside Docker containers. Real-world results will vary with network latency, where QUIC's advantage grows with higher RTT due to its zero-round-trip connection setup and multiplexed streams.

## Pipelining

All lanes support configurable pipelining (1–64 concurrent in-flight commands). At pipeline depth 1 (sequential), each command waits for its response before sending the next. At higher depths, multiple commands are in-flight simultaneously.

QUIC benefits most from pipelining because WebTransport bidirectional streams avoid WebSocket's per-message framing overhead and HTTP's connection-level head-of-line blocking.

## Running the Benchmark

```bash
# Start the benchmark environment
docker compose -f docker-compose.web-bench.yaml up -d

# Open in browser
open http://localhost:8080/demo/benchmark.html
```

The dashboard allows configuring:

- **Test workload**: Write, Read, Mixed 80/20, or Burst
- **Iterations**: 50 – 5,000
- **Payload size**: 64 B – 16 KB
- **Warmup**: 0 – 10 iterations
- **Pipeline depth**: 1 (sequential) – 64 concurrent
