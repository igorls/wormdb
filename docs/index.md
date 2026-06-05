---
layout: home

hero:
  name: "WormDB"
  text: "Immutable KV, procedures, streams, and vector search in one Zig binary"
  tagline: "A WormWire-native data server for audit-safe records, atomic server-side workflows, pub/sub event streams, local ANN indexes, and optional mesh replication."
  actions:
    - theme: brand
      text: Start in 5 Minutes
      link: /getting-started/quick-start
    - theme: alt
      text: What is WormDB?
      link: /getting-started/
    - theme: alt
      text: Command Reference
      link: /protocol/commands

features:
  - title: WORM as a Storage Invariant
    details: Mark a key as write-once and the storage layer rejects every later overwrite or delete. Use it for ledgers, audit trails, compliance records, and provenance logs.
  - title: WormWire Binary Protocol
    details: Client and replication links use explicit WW/WR handshakes, 1-byte command IDs, 4-byte big-endian payload lengths, and a strict 16 MiB frame limit.
  - title: Compiled Zig Procedures
    details: EXEC handlers run inside the server with shard locking, so counters, transfers, vector workflows, and domain procedures finish in one round-trip.
  - title: Co-Located Vector Search
    details: Store embeddings through the same durable path, then query local HNSW, RaBitQ/BQ, or brute-force search with cosine, dot, or L2 metrics per namespace.
  - title: Mesh Replication on Linux
    details: Cluster mode uses meshguard for SWIM gossip, node identity, WireGuard tunnel setup, and persistent WormWire peer replication without an external coordinator.
  - title: Operator-Friendly Persistence
    details: WAL records include CRC32 protection, snapshots persist KV state and vector indexes, and STATUS/CLUSTER output stays machine-readable for scripts.
---
