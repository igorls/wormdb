# WormDB Production Readiness Plan

> **Reviewed against codebase on 2026-07-12.**
> Items marked ✅ **EXIST** are already implemented; items marked ❌ **MISSING** are gaps.

## Goal: The "Operational" Baseline
**Definition of Done**: The system can be deployed to a cluster, monitored in real-time, secured against unauthorized access, and recovered from a total node failure without data loss.

---

## 🛠 Phase 1: Observability & Telemetry (The "Visibility" Sprint)
*Before we scale, we must be able to see what is happening inside the engine.*

### 1.1 Prometheus Metrics Exporter
- **Status**: ❌ **MISSING** (but infrastructure exists)
- **What exists**: `src/server/metrics.zig` has a `ServerMetrics` struct with atomic counters for TCP connections, commands in-flight/completed/succeeded, gateway connections, per-IP rejections, etc. These are surfaced via the `STATUS` command (pull-based, in-process).
- **What's needed**: A lightweight HTTP endpoint (in Zig) that exports these existing counters in OpenMetrics/Prometheus format. The counters are already there — we just need the wire format and an HTTP listener.
- **Additional metrics to add**: `wormdb_kv_latency_p99`, `wormdb_vector_recall`, `wormdb_wal_bytes_written`, `wormdb_shard_lock_contention_ms` (these don't exist yet).

### 1.2 Structured JSON Logging
- **Status**: ❌ **MISSING**
- **What exists**: `std.log.info/warn/err` calls throughout the codebase (unstructured, plain text).
- **What's needed**: A leveled structured logger (JSON output) for log aggregation (ELK/Loki). Replace `std.log` calls with a structured logger that includes timestamps, levels, and contextual fields.

### 1.3 Deep Health Checks
- **Status**: ⚠️ **PARTIAL**
- **What exists**: 
  - `mem_health` stored procedure (`src/procedures/memory.zig`) checks HNSW index catch-up state, pending vectors, and index integrity per namespace.
  - Cluster `root_sync` state tracking (`src/cluster/node.zig`) reports `unknown/healthy/behind/ahead/diverged` per peer.
- **What's needed**: A unified `/health` HTTP endpoint that aggregates:
  - Disk write permissions for the WAL.
  - HNSW index integrity (from `mem_health`).
  - Peer connectivity status (from `root_sync` state).
  - WAL writability and snapshot path health.

### 1.4 Baseline Soak Test
- **Status**: ❌ **MISSING**
- **What's needed**: A 48-hour continuous load test at 80% CPU/RAM capacity to detect slow memory leaks in the Zig allocator. No soak testing infrastructure exists yet.

---

## 🔒 Phase 2: Security & Access Control (The "Lockdown" Sprint)
*Moving the database from a "trusted environment" to a "hostile environment."*

### 2.1 WormWire TLS (Raw TCP)
- **Status**: ⚠️ **PARTIAL**
- **What exists**: TLS is already supported for the **QUIC/WebTransport gateway** (`quic_enabled`, `tls_cert_path`, `tls_key_path` in `GatewayConfig`). The QUIC gateway (`src/server/quic_gateway.zig`) sets up TLS certificate config. QUIC is compile-time gated behind `-Dquic=true`.
- **What's missing**: The raw TCP WormWire protocol (port 6389) has **no TLS**. Client-to-server communication over TCP is unencrypted.
- **What's needed**: Wrap the TCP listener in TLS (either natively in Zig via `bearssl`/`mbedtls`, or via a reverse proxy sidecar). The QUIC path is already covered.

### 2.2 API Key Authentication
- **Status**: ✅ **ALREADY IMPLEMENTED**
- **What exists**: A full **Signed Capability Token (SCT)** system in `src/server/auth.zig`:
  - Ed25519-signed binary tokens (stateless, no server-side session storage).
  - Token format: `[payload][64B Ed25519 signature]` with `iat`, `exp`, `subject`, `jti`, and capabilities.
  - Config: `auth.require_auth` (default: `true`), `auth.public_keys` (Ed25519 verification keys), `auth.token_max_age_s`.
  - Per-transport opt-out: `server.auth_enabled` and `gateway.auth_enabled` (both default `true`).
  - Server-side token minting: `auth.mint_secret_key` for `auth_mint_scoped` procedure.
  - Token revocation: Revoked `jti`s stored as durable keys (`auth:revoked:<jti>`).
- **What's needed**: Nothing for core auth. Could improve UX (token management CLI, rotation tooling).

### 2.3 Command-Level RBAC
- **Status**: ✅ **ALREADY IMPLEMENTED**
- **What exists**: The SCT system includes full capability-based authorization:
  - `Operation` enum: `get`, `set`, `delete`, `subscribe`, `publish`, `exec`, `all` (wildcard).
  - `MatchType` enum: `exact`, `prefix`, `wildcard`.
  - `commandPermitted()` maps each `CommandId` to an `Operation` and checks capabilities.
  - `VBULKINSERT` is authorized per-item (multi-target).
  - Namespace-scoped tokens: `auth_mint_scoped` mints least-privilege tokens for a single namespace.
  - Two authority levels: Admin (wildcard) and Namespace-scoped tokens.
- **What's needed**: Nothing for RBAC. Already has deny-by-default enforcement.

---

## 🚀 Phase 3: Resilience & High Availability (The "Fault Tolerance" Sprint)
*Ensuring the cluster survives the "Chaos Monkey" (node crashes, network partitions).*

### 3.1 State Transfer Mechanism
- **Status**: ⚠️ **PARTIAL**
- **What exists**: The cluster layer (`src/cluster/node.zig`) has:
  - Anti-entropy **full-state sync** when new peers join.
  - `RootSyncState` tracking: `unknown`, `healthy`, `behind`, `ahead`, `diverged` per peer.
  - `root_sync_missing_ranges` counter.
  - Root sync skips when peer is already `healthy`.
- **What's missing**: 
  - **Incremental sync** (only transfer changed ranges, not full state).
  - **Snapshot streaming** (stream a snapshot + WAL replay from a healthy peer, instead of key-by-key sync).
  - **Bandwidth limiting** to prevent resync from saturating the network.

### 3.2 Quorum-Based Consistency
- **Status**: ❌ **MISSING**
- **What exists**: No quorum/voting mechanism. Replication is fire-and-forget (cluster failures are logged, never fail the client write). The cluster is AP-leaning.
- **What's needed**: 
  - A voting mechanism for critical operations (WORM settings changes, cluster membership).
  - Split-brain prevention (only a quorum partition can accept writes).
  - Configurable consistency level (e.g., `write_consistency: one|quorum|all`).

### 3.3 S3 Snapshot Archiving
- **Status**: ❌ **MISSING**
- **What's needed**: Automate rotation of the non-blocking snapshots to an off-site object store (S3/MinIO). No S3 integration code exists. Can be implemented as a post-snapshot hook or external cron job.

---

## ⚙️ Phase 4: Operational Excellence (The "Day 2" Sprint)
*Reducing the friction of deployment and maintenance.*

### 4.1 Dynamic Configuration
- **Status**: ⚠️ **PARTIAL**
- **What exists**: JSON config files (`wormdb.json`) with CLI flag overrides. All config sections (`store`, `server`, `cluster`, `gateway`, `auth`, `org_trust`) are already in `src/core/config.zig` with sensible defaults. CLI flags override file values.
- **What's missing**: 
  - **Hot-reload**: No SIGHUP handler or runtime config reload. Config changes require restart.
  - Some constants (shard count = 256, HNSW parameters) are still hardcoded and not exposed in config.

### 4.2 Enhanced Admin TUI/UI
- **Status**: ⚠️ **PARTIAL**
- **What exists**: A Vue-based website (`website/`) and browser app (`apps/browser/`), plus a landing page (`landing/`). The `STATUS` command surfaces metrics in a text format.
- **What's needed**: Real-time dashboard showing shard distribution, vector search performance heatmaps, cluster topology, and live metrics from `ServerMetrics`.

### 4.3 Production CI/CD Pipeline
- **Status**: ⚠️ **PARTIAL**
- **What exists**: Docker support (`Dockerfile`, multiple `docker-compose.*.yml` for demo/bench/cluster). `zig build` supports cross-compilation. GitHub Actions is listed in tech stack.
- **What's needed**: A formalized CI pipeline that builds optimized binaries for `x86_64-windows`, `x86_64-linux`, and `aarch64-linux`, running the full `zig build test` suite against each target. Release artifact publishing.

---

## 📉 Updated Priority Matrix

| Priority | Item | Status | Effort | Impact | Reason |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **P0** | **Prometheus Metrics Export** | ❌ (counters exist, export missing) | Low | Massive | Counters are already there — just need HTTP + OpenMetrics format. |
| **P0** | **Structured JSON Logging** | ❌ | Medium | High | Necessary for log aggregation in distributed deployments. |
| **P0** | **TCP TLS Encryption** | ❌ (QUIC TLS exists) | Medium | Critical | Raw TCP WormWire is unencrypted; QUIC path is covered. |
| **P1** | **Quorum-Based Consistency** | ❌ | High | High | Prevents split-brain; essential for WORM audit trail integrity. |
| **P1** | **Incremental State Transfer** | ⚠️ (full sync exists) | High | High | Full-state sync doesn't scale; need delta sync + snapshot streaming. |
| **P1** | **Unified /health Endpoint** | ⚠️ (parts exist) | Low | High | `mem_health` + `root_sync` exist but aren't unified into an HTTP check. |
| **P2** | **Config Hot-Reload** | ⚠️ (JSON config exists) | Medium | Medium | Config files work; need SIGHUP + expose hardcoded constants. |
| **P2** | **S3 Snapshot Archiving** | ❌ | Medium | Medium | Final safety net for disaster recovery. |
| **P2** | **Soak Test Infrastructure** | ❌ | Medium | Medium | Needed to validate memory safety under sustained load. |
| ~~P0~~ | ~~API Key Auth~~ | ✅ **DONE** | — | — | SCT system with Ed25519 is fully implemented. |
| ~~P1~~ | ~~Command-Level RBAC~~ | ✅ **DONE** | — | — | Capability-based authorization is fully implemented. |

---

## Summary of Codebase Review

**Already production-ready**:
- ✅ Authentication (SCT/Ed25519 tokens, stateless, with revocation)
- ✅ Authorization (capability-based RBAC with operation + pattern matching)
- ✅ Per-transport auth enforcement (secure by default on TCP, WebSocket, QUIC)
- ✅ QUIC/WebTransport TLS
- ✅ Two-phase non-blocking snapshots
- ✅ WAL with CRC32 integrity
- ✅ Cluster discovery (SWIM, certificate-gated under org trust) + mutually authenticated, encrypted replication (W3 handshake, ChaCha20-Poly1305 per session, independent of the WireGuard route)
- ✅ Anti-entropy full-state sync for new peers
- ✅ JSON config + CLI overrides
- ✅ Docker support
- ✅ Internal metrics counters (ServerMetrics)

**Critical gaps for production**:
- ❌ Prometheus/OpenMetrics export endpoint
- ❌ Structured JSON logging
- ❌ TLS on raw TCP WormWire
- ❌ Quorum / split-brain protection
- ❌ Incremental state transfer
- ❌ S3 snapshot archiving
- ❌ Config hot-reload