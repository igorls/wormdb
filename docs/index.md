---
layout: home

hero:
  name: "WormDB"
  text: "Data That Can't Be Rewritten"
  tagline: "A distributed key-value store built in Zig with write-once immutability, embedded stored procedures, a binary wire protocol, and mesh-based clustering."
  image:
    src: /logo.svg
    alt: WormDB
  actions:
    - theme: brand
      text: What is WormDB?
      link: /getting-started/
    - theme: alt
      text: Quick Start
      link: /getting-started/quick-start
    - theme: alt
      text: Architecture
      link: /architecture/

features:
  - title: 🔒 Write-Once Immutability
    details: WORM keys are permanently sealed on first write — no overwrites, no deletes. Built for audit logs, compliance records, and financial ledgers where history must never change.
  - title: ⚡ Binary Wire Protocol
    details: WormWire v1 uses strict framed binary encoding with explicit command IDs, big-endian lengths, and a 16 MiB payload limit. No text parsing overhead.
  - title: 🧩 Embedded Procedures
    details: Execute compiled Zig procedures server-side with automatic shard locking. Atomic multi-key operations like transfers and counters, without round-trip latency.
  - title: 🔧 Pluggable IO Backends
    details: Choose threadpool for compatibility, epoll for event-driven workloads, or io_uring for maximum throughput on modern Linux kernels.
  - title: 🌐 Mesh Clustering
    details: Nodes discover each other via SWIM gossip and replicate writes over persistent WormWire peer channels. No external coordination service required.
  - title: 📊 Built-In Observability
    details: STATUS, CLUSTER STATUS, and CLUSTER PEERS return structured key=value output designed for scripting, monitoring dashboards, and automation pipelines.
---
