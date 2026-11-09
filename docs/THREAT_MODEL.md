# WormDB Threat Surface Audit: database-as-API deployments

- Date: 2026-11-08
- Revision: `main` at `bbbccb4` plus the untracked working files present in the checkout
- Method: full read of every network-facing code path (wire codec, TCP/WebSocket/QUIC
  listeners, executor, SCT auth, all built-in procedures, event bus, cluster and
  replication, storage load paths, config, reference clients, Dockerfile). No fuzzing or
  live exploitation was performed. Every finding cites the code that supports it.
- Threat model: untrusted applications and browsers hold SCT tokens and connect to WormDB
  directly over the WebSocket gateway, raw TCP, or QUIC. There is no application tier
  between the client and the database. Optionally several nodes form a cluster.
- Status (2026-11-08, same day): every P0 item in section 6.2 is fixed in the working
  tree — A1, A2, B3, C1, C3 (rate limits and per-IP caps; namespace quotas remain P1),
  D1, D2 and F1. Each fixed finding carries a **Status** line below. Items marked P1/P2
  are still open; this document can now live on a public branch.

## 1. Summary

The core security machinery is in good shape and has already been through one hardening
round (REVIEW-016): token verification, the single executor-level capability gate, the
replication handshake, frame bounds, admission budgets and read deadlines are all solid.
The problems that matter for direct-to-app use sit at the edges of that model:

1. **Capability scope stops at the procedure name.** `EXEC` is authorized only on the
   procedure name. Outside the `mem_*` family and `auth_mint_scoped`, no built-in
   procedure checks key scope. A token with `exec` on `scan`, `kv_put`, `increment`,
   `transfer`, `vsearch`, `vnsdrop` or `append_log_append` reads or writes the whole
   keyspace regardless of its `get`/`set`/`delete` capabilities, and several of those
   writes also bypass the WAL and replication. The shipped browser demo mints
   `exec wildcard` tokens for every chat user, which makes every demo user a database admin
   in practice.
2. **One stuck subscriber slows every publisher.** Event fan-out runs synchronously on
   the publishing connection's thread with a 2 s send timeout, and a failed send never
   closes the subscriber. An authenticated client that subscribes and stops reading adds
   up to 2 s to every publish on that channel until its token expires.
3. **Cluster membership is open and outbound replication authenticates nobody.** WormDB
   never enables meshguard's SWIM trust, replication connects to the peer's raw IP rather
   than through the WireGuard tunnel whenever that IP is known, and a node that appears in
   gossip receives a full anti-entropy dump of the database. Anyone who can reach the gossip
   UDP port and the client TCP port can exfiltrate everything, with or without `org_trust`.
4. **No confidentiality on the client transports.** Raw TCP and the WebSocket gateway are
   plaintext, so bearer tokens and data are sniffable. The gateway ignores
   `server.bind_address` and always binds 0.0.0.0.
5. **No per-token resource limits.** A single write-scoped token can fill RAM and disk,
   force 16 MiB allocations before authenticating, or burn CPU with multi-megabyte vectors
   and `vrabitq` runs. There is no rate limiting anywhere.

Section 4 has 33 findings with code references and fixes. Section 6 has the deployment
checklist for running WormDB as the API today and the remediation order.

Of the five headline issues, 1, 2 and 3 are fixed, 5 is fixed except for per-namespace
storage quotas, and 4 (transport confidentiality for clients) remains a deployment
requirement: terminate TLS in front of the gateway and keep 6389 private.

## 2. Attack surface map

| Entry point | Default exposure | Reachable before AUTH | Auth | Transport security |
| --- | --- | --- | --- | --- |
| WormWire TCP, 6389/tcp | `server.bind_address` = 0.0.0.0 ([config.zig:46](../src/core/config.zig)) | Handshake magic; any frame is read and parsed (up to 16 MiB allocated); `STATUS`, `CLUSTER_STATUS`, `CLUSTER_PEERS`, `AUTH` | SCT via `AUTH` frame | None |
| Replication `WR` / `W2` on the same port | Same socket as clients | `W2`: challenge/response only. `WR` with `--cluster-open`: full unauthenticated read/write | Org certificate (`W2`) or nothing (`WR`) | None unless the peer address is unknown and traffic falls back to WireGuard |
| WebSocket gateway, 6390/tcp | Opt-in; binds 0.0.0.0 unconditionally ([gateway.zig:213](../src/server/gateway.zig)) | HTTP request up to 4 KiB; WS frames up to 16 MiB allocated; ping/pong; JSON-RPC text frames and `GET /api/...` routes (fail closed when auth is on) | SCT via `AUTH` frame | None (no TLS; `wss://` needs a proxy) |
| QUIC/WebTransport, 6393/udp | Compile-time opt-in (`-Dquic`) | Connection validator accepts everything ([quic_gateway.zig:173](../src/server/quic_gateway.zig)) | SCT via `AUTH` frame; expiry never re-checked | TLS 1.3 |
| SWIM gossip, 51821/udp | On when `cluster.name` is set | Any host can join the membership table (trust never enabled, [node.zig:401](../src/cluster/node.zig)) | None | None |
| WireGuard, 51830/udp | On when clustered (Linux) | Kernel WG | WG keys derived from node identity | WG, but replication does not use it when the peer's real IP is known ([node.zig:174](../src/cluster/node.zig)) |
| Filesystem | Operator | `wormdb.json` holds `auth.mint_secret_key` in plaintext; data dir holds WAL, snapshot, cluster identity (0600), node cert | OS permissions | n/a |
| Embedding API (`src/lib.zig`, `src/ffi.zig`) | Library consumers | `ExecContext.auth` defaults to `.trusted` ([executor.zig:35](../src/server/executor.zig)); uring/epoll backends have no AUTH handling ([uring.zig:109](../src/server/uring.zig)) | Caller's responsibility | n/a |

## 3. The capability model as implemented

An SCT is `[iat][exp][subject][jti][caps...][Ed25519 sig]`. Each capability is an
operation (`get`, `set`, `delete`, `subscribe`, `publish`, `exec`, `all`) plus an exact,
prefix or wildcard pattern ([auth.zig:71](../src/server/auth.zig)). The executor enforces
it once per command ([auth.zig:460](../src/server/auth.zig)):

- `GET`/`SET`/`DEL`: op on the key. `VINSERT`/`VDELETE`: `set`/`delete` on the vector key.
  `VBULKINSERT`: `set` on every item key. `VRABITQ_INSTALL`: `set` on the namespace.
- `SUB`/`UNSUB`: `subscribe` on the channel (checked again at delivery time).
  `PUB`: `publish` on the channel.
- `EXEC`: `exec` on the procedure **name only**. Arguments are not inspected.
- `SAVE`: `all` with a wildcard or empty-prefix pattern.
- Public, no token needed: `STATUS`, `CLUSTER_STATUS`, `CLUSTER_PEERS`, `AUTH`.

Because `EXEC` is checked by name, what a token can really do depends on which procedures
check scope internally. This table is the practical answer:

| Procedure | Internal scope check | Effective reach of `exec <name>` |
| --- | --- | --- |
| `mem_*` (13 procedures) | `ctx.requireNamespace` on the namespace argument ([memory.zig](../src/procedures/memory.zig)) | Correctly confined to namespaces the token holds `get`/`set`/`delete` for |
| `auth_mint_scoped` | Admin or `exec auth:mint:<ns>` | Mints namespace tokens; an `exec` wildcard or empty prefix qualifies as mint authority |
| `kv_put`, `increment`, `transfer` | None | Write any key via `ctx.set` (no WAL, no replication, WORM still respected) |
| `kv_get` | None | Read any key, and write `meta:<key>` and `stats:reads` |
| `scan` | None | Read up to 1000 keys of any prefix, including the empty prefix |
| `chat_send` | Identity only | Write `chat:<any room>:...` and publish on `chat:<any room>` |
| `chat_history` | None | Read any room |
| `vsearch`, `vsearch_local_raw`, `vsearch_cluster`, `vsim`, `vstats` | None | Search and read vectors in any namespace; `vsearch_cluster` fans out to peers |
| `vinsert`, `vdelete` | None | Durable, replicated write/delete of any `vec:*` key |
| `vnsdrop` | None | Delete an entire vector namespace |
| `vreindex`, `vrabitq` | None | CPU-heavy rebuilds; `vrabitq` broadcasts a dim x dim matrix to every peer |
| `append_log_*` (11 procedures) | None | Append to or read any log; import witnesses |
| `append_log_claim*` (4 procedures) | None | Coordination with a client-chosen worker identity |
| `trust_grant`, `trust_revoke`, `trust_fold` | Org signature | Self-authorizing by org key; accepts the org secret key as an argument |
| `cluster_presence`, `proof_prefix_root` | None | Cluster topology; Merkle-style roots for any prefix |

Everything in that table except `mem_*` should be treated as an administrative procedure
until it gains scope checks.

## 4. Findings

Severity is for the direct-to-app model (Internet-exposed, multi-tenant tokens). Each
finding gives the code location, the concrete attack, and a fix.

### A. Authorization model

**A1. Built-in procedures do not check key scope.** Severity: High (Critical with the
demo's token policy).
Where: [executor.zig:232](../src/server/executor.zig) dispatches `EXEC` after a name-only
check; [scan.zig:21](../src/procedures/scan.zig), [kv_put.zig:34](../src/procedures/kv_put.zig),
[increment.zig:20](../src/procedures/increment.zig), [transfer.zig](../src/procedures/transfer.zig),
[kv_get.zig](../src/procedures/kv_get.zig), [chat_history.zig](../src/procedures/chat_history.zig),
[vsearch.zig](../src/procedures/vsearch.zig), [vnsdrop.zig:96](../src/procedures/vnsdrop.zig),
[vreindex.zig:88](../src/procedures/vreindex.zig), [vrabitq.zig:166](../src/procedures/vrabitq.zig),
[append_log.zig:33](../src/procedures/append_log.zig), [coordination.zig:347](../src/procedures/coordination.zig)
never call `ctx.permits` or `ctx.requireNamespace`.
Attack: a token minted for a "read-only dashboard" with `exec exact scan` runs
`EXEC scan "" 1000` and reads every tenant's data, including `__meta:*` and any future
`auth:*` records. A token with `exec exact kv_put` writes any key. `ctx.set` goes through
`store.setUnsafe` ([context.zig:302](../src/procedures/context.zig)), so those writes skip the
WAL and replication: the attacker also creates state that diverges between nodes and
vanishes on restart.
Fix: add a `ctx.requireKey(op, key)` helper and call it in every built-in that touches a
caller-supplied key, prefix or namespace; or add a `requires_admin` flag to the registry
entry so these procedures need `all`/wildcard authority. Make the domain seam
([domain.zig](../src/procedures/domain.zig)) document the same obligation for external
procedures.
**Status: fixed.** `Ctx.requireRead/Write/Delete` (single key) and `Ctx.requirePrefix`
(range) in [context.zig](../src/procedures/context.zig); every built-in that takes a
caller-supplied key, prefix, namespace or log id now checks the capabilities a raw
GET/SET/DEL over the same keys would need (`scan`, `kv_*`, `increment`, `transfer`,
`chat_*`, `vsim`, `vinsert`, `vdelete`, `vstats`, `vsearch*`, `vreindex`, `vrabitq`,
`vnsdrop`, `proof_prefix_root`, `cluster_presence agents_log=`, all `append_log_*` and
claim procedures). Range checks only accept prefix/wildcard capabilities
(`TokenState.permitsPrefix`) — an exact capability never covers a scan.
`requireNamespace` uses the same rule. Procedures that build their own keys and bind the
caller's identity into the record (`chat_send`) check a procedure-only pseudo-target
(`Ctx.requireExecTarget("chat:<room>")`) instead of a raw `set`, so posting rights never
imply raw write rights. The executor maps `error.PermissionDenied` to the standard
`permission denied` response. Trusted callers (replication, maintenance) are unaffected.
Domain packages must call the same helpers; the seam does not do it for them.

**A2. `exec` wildcard or empty-prefix tokens can mint tokens for any namespace.**
Severity: Medium.
Where: `canMint` in [auth_mint_scoped.zig](../src/procedures/auth_mint_scoped.zig) accepts
`permits(.exec, "auth_mint_scoped")` plus `permits(.exec, "auth:mint:<ns>")`; both pass
for an `exec` wildcard. The demo token in
[auth-provider.ts:72](../apps/browser/demo/auth-provider.ts) is exactly that.
Attack: with `auth.mint_secret_key` configured, any demo user mints a read/write token
for every memory namespace.
Fix: require a distinct operation for mint authority instead of overloading `exec`, or
require `all` authority for minting.
**Status: fixed.** `canMint` now requires an explicit `exec` capability covering
`auth:mint:<ns>` (`TokenState.permitsExplicit`): exact, or a prefix that spells out at least
the `auth:` family. An `exec` wildcard, an empty prefix and family-short prefixes such as
`auth` no longer confer mint authority. Admin (`all` wildcard) still mints. The same rule
guards every procedure pseudo-target (`Ctx.requireExecTarget`).

**A3. Clients with `publish` can forge server events.** Severity: Medium.
Where: `PUB` is a plain capability check ([auth.zig:460](../src/server/auth.zig));
procedures publish on the same channels ([memory.zig](../src/procedures/memory.zig),
[vector_ops.zig](../src/procedures/vector_ops.zig)).
Attack: a client holding `publish prefix "mem:astrid:"` publishes a fabricated `added`
event; every other subscriber treats it as a server-originated state change. In a game or
collaborative app this is cheating or spoofing.
Fix: never grant `publish` to end-user tokens; emit state events only from procedures.
Longer term, reserve a channel prefix for server-emitted events that `PUB` cannot target.

**A4. Token revocation is designed but not implemented.** Severity: Medium.
Where: [docs/AUTH_SCOPED.md](AUTH_SCOPED.md) specifies `auth:revoked:<jti>` and
`EXEC auth_revoke`; `verifyAndParse` ([auth.zig:129](../src/server/auth.zig)) never
consults the store, and `auth_revoke` is not in the registry.
Impact: a leaked token is valid until `exp`. With the default `token_max_age_s` of 3600
that is an hour of unrevokable access.
Fix: implement the documented check at `AUTH` and at the periodic expiry check, or state
clearly that TTL is the only revocation and keep namespace TTLs in minutes.

**A5. `STATUS`, `CLUSTER_STATUS` and `CLUSTER_PEERS` are public.** Severity: Medium.
Where: `operationForCommand` returns null for them ([auth.zig](../src/server/auth.zig));
`peerList` in [node.zig](../src/cluster/node.zig) prints mesh IPs, gossip endpoints and
link state.
Impact: unauthenticated reconnaissance of key counts, WAL size, connection load, and the
real IP:port of every cluster peer, which is exactly what finding D1 needs.
Fix: require a token for `CLUSTER_PEERS` (and ideally `STATUS`), or restrict them to
loopback.

**A6. Coordination and append-log identities are client-supplied.** Severity: Medium.
Where: `worker_id` argument at [coordination.zig:347](../src/procedures/coordination.zig)
and `ts=` at [append_log.zig](../src/procedures/append_log.zig).
Attack: any client with `exec` on `append_log_claim` claims or releases tasks as another
worker, and backdates ingest timestamps. `chat_send` already uses `ctx.identity()` when a
token is present; these should too.
Fix: when `ctx.identity()` is non-null, use it as the worker identity and ignore or
validate the argument.

**A7. `chat_history` splices stored values into its JSON array verbatim.** Severity: Low.
Where: [chat_history.zig:44](../src/procedures/chat_history.zig).
Attack: any writer able to `SET chat:<room>:...` (or call `kv_put`) stores a non-JSON
value and breaks `chat_history` for that room, or injects extra fields clients trust.
Fix: validate stored values are JSON objects before splicing, or re-escape them.

**A8. Internal error names reach clients.** Severity: Low.
Where: [executor.zig:248](../src/server/executor.zig) returns `@errorName(e)` for
procedure failures.
Fix: map to a fixed set of client-facing messages; log the error name server-side.

**A9. Fragile defaults for embedders.** Severity: Low.
Where: `ExecContext.auth` defaults to `.trusted` ([executor.zig:35](../src/server/executor.zig));
the uring and epoll backends pass `.enforce(null)` or `.disabled` and have no AUTH frame
handling ([uring.zig:109](../src/server/uring.zig)). Minted namespace tokens carry
`exec prefix "mem_"`, which also matches any future or domain procedure named `mem_*`.
Fix: make `auth` a required field; keep `validateBackend` ([main.zig:356](../src/main.zig))
refusing the non-auth backends; use exact names in minted capabilities.

### B. Transport and protocol

**B1. Raw TCP and the WebSocket gateway are plaintext.** Severity: High (known gap).
Where: [tcp.zig](../src/server/tcp.zig) and [gateway.zig](../src/server/gateway.zig) have
no TLS; only QUIC does. [docs/PRODUCTION_READINESS.md](PRODUCTION_READINESS.md) lists this
as P0.
Attack: bearer SCTs and all data are readable and replayable by anyone on the path.
Fix: for browsers, terminate TLS in a reverse proxy and advertise only `wss://` endpoints;
never expose 6389 beyond a private network. Native TLS on both listeners remains the
right long-term fix.

**B2. Gateway binds 0.0.0.0 and has no Origin check.** Severity: Medium.
Where: [gateway.zig:213](../src/server/gateway.zig) hardcodes the address;
`extractWebSocketKey` ([gateway.zig:941](../src/server/gateway.zig)) is the only handshake
validation; no `Origin` or CORS handling anywhere.
Attack: with `gateway.auth_enabled: false` (documented as the way to expose a "public
read-only HTTP/JSON-RPC API"), any web page a user visits can open `ws://` to a WormDB
reachable from that user's network and run every command. With auth enabled the token
requirement blocks this, but the gateway still cannot be confined to loopback behind a
proxy.
Fix: honor `server.bind_address` (or add `gateway.bind_address`); add an `Origin`
allowlist; refuse to start an auth-disabled gateway on a non-loopback address without an
explicit flag, mirroring `--cluster-open`.

**B3. Full frames are allocated and parsed before authentication.** Severity: Medium.
Where: [wire.zig:80](../src/protocol/wire.zig) allocates `payload_len` (up to 16 MiB) from
the header, then reads; [gateway.zig:806](../src/server/gateway.zig) does the same for WS
frames. The TCP per-connection arena is reset with `.retain_capacity`
([tcp.zig](../src/server/tcp.zig)), so the 16 MiB stays mapped for the connection's life.
Attack: 1024 unauthenticated TCP connections each declare a 16 MiB frame and trickle
bytes: 16 GiB reserved for up to 30 s per round, repeatable indefinitely. The 256-connection
gateway budget gives 4 GiB.
Fix: cap frames at a few KiB until `AUTH` succeeds (a token is well under 1 KiB), size the
arena reset with `.retain_with_limit`, and read in bounded chunks.
**Status: fixed.** Enforcing TCP and WebSocket listeners accept at most 16 KiB per frame
until the connection has authenticated (`wire.readFrameZeroCopyLimited`,
`readWsFrame(max_payload)`), and per-connection arenas are reset with
`.retain_with_limit = 256 KiB`, so a large frame no longer stays mapped for the
connection's lifetime. QUIC (compile-time opt-in) is unchanged (B6).

**B4. `EXEC` allocates its argument array before validating the count.** Severity: Low.
Where: [wire.zig:188](../src/protocol/wire.zig) allocates `arg_count * 16` bytes from an
untrusted `u32` before checking that the payload could hold that many fields. The
`VBULKINSERT` parser already has the right guard ([wire.zig:287](../src/protocol/wire.zig)).
Fix: apply the same minimum-size check (`arg_count <= remaining / 4`).

**B5. Response payload length is unchecked.** Severity: Low.
Where: `writeResponse` for `.value` ([wire.zig:562](../src/protocol/wire.zig)) casts
`val.len` to `u32` and never compares against `MAX_PAYLOAD_LENGTH`; only `.event` does.
Impact: a `scan` of 1000 large values produces a response over 16 MiB that every client
rejects, desynchronizing the stream; past 4 GiB the cast is undefined behavior in
ReleaseSmall and the header lies about the length.
Fix: enforce `MAX_PAYLOAD_LENGTH` on every response and return an error instead.

**B6. QUIC gateway gaps.** Severity: Medium (opt-in component, never exercised live).
Where: accept-all validator ([quic_gateway.zig:173](../src/server/quic_gateway.zig)); the
receive buffer grows until `5 + payload_len` bytes arrive with no `MAX_PAYLOAD_LENGTH`
check ([quic_gateway.zig:271](../src/server/quic_gateway.zig)), so a client can declare 4 GiB
and stream data; `processCommand` never calls `isExpired`, so a session authenticated once
keeps its token past `exp` (TCP and WS re-check on every frame).
Fix: cap `payload_len`, bound `recv_buf`, re-check expiry per command, and keep this
component out of production until it has the same live regression tests as TCP/WS.

**B7. Lax WebSocket handshake and framing.** Severity: Low.
Where: [gateway.zig:941](../src/server/gateway.zig) accepts any request containing a
`Sec-WebSocket-Key` header without checking `Upgrade`, `Connection` or
`Sec-WebSocket-Version`; `readWsFrame` ([gateway.zig:778](../src/server/gateway.zig)) ignores
FIN and RSV bits and accepts unmasked client frames.
Impact: non-conformant but not exploitable on its own; fragmentation is simply
unsupported.
Fix: validate the upgrade headers; reject unmasked client frames and reserved bits; close
on fragmented messages.

**B8. Plain HTTP routes and JSON-RPC when auth is disabled.** Severity: Low.
Where: `serveHttp`/`route` and `handleJsonRpc` in [gateway.zig](../src/server/gateway.zig)
call `execProc`, which passes `.enforce(null)` when auth is on (correct, fail closed) and
`.disabled` otherwise. No CORS or security headers; `Captures.param` does no URL decoding.
Impact: with auth disabled every domain route and WS method is callable by anyone who can
reach the port, including write procedures a domain may expose.
Fix: tie B2's "explicit opt-in" flag to this mode; add `Content-Security-Policy` and
`X-Content-Type-Options` headers; document that domain routes must be read-only when the
gateway is public.

### C. Availability

**C1. A non-reading subscriber stalls every publisher on its channel.** Severity: High.
Where: `EventBus.publish` ([bus.zig:231](../src/event/bus.zig)) delivers synchronously on the
caller's thread; `writeExactEvent` on TCP ([tcp.zig:266](../src/server/tcp.zig)) and WS
([gateway.zig:1112](../src/server/gateway.zig)) blocks up to the 2 s send timeout and
swallows the error without closing the connection. Authenticated connections with
subscriptions may idle without a read deadline ([tcp.zig:521](../src/server/tcp.zig)).
Attack: a client authenticates, subscribes to a busy channel, and stops reading. Once the
socket buffer is full, every publish on that channel (every `SET` that emits an event,
every `chat_send`) blocks its worker thread for 2 s, until the token expires (up to an
hour). Ten such clients on ten channels pin ten worker threads continuously; with the
64-thread TCP pool (C2) this is a cheap full outage. The existing regression test covers
non-reading request/response clients, not authenticated subscribers.
Fix: give each connection a bounded outbound queue drained by its own writer (or the
connection thread), drop and close the subscriber when the queue overflows or a send times
out, and never do socket I/O on the publisher's thread.
**Status: fixed (eviction variant).** Event frames are sent with a 500 ms deadline; a
subscriber whose socket cannot take a frame is evicted on the spot: marked closed so every
later publish skips it for free, and its socket shut down (`Stream.shutdown`, which wakes
the parked connection thread on Linux and Windows) so the normal teardown runs. A
publisher therefore stalls at most once, briefly, per stalled subscriber. Counted in
`STATUS` as `event_bus_evictions`; regression test in [tcp.zig](../src/server/tcp.zig)
("stalled subscriber is evicted"). Fan-out still runs on the publisher's thread; a
per-connection writer queue remains a P1 refinement for throughput, not safety.

**C2. Fixed worker pool with no fairness.** Severity: Medium (acknowledged in REVIEW-016).
Where: at most `min(cpu*2, 64)` TCP workers ([tcp.zig:310](../src/server/tcp.zig)); each
connection owns a worker for its lifetime; unauthenticated connections get 30 s. The gateway
is thread-per-connection capped at 256 with the per-IP cap off by default
([config.zig:134](../src/core/config.zig)).
Attack: opening about three TCP connections per second (64 slots / 30 s) keeps every
worker busy; the 1024-deep accept queue then times everyone out. 256 idle WebSocket
connections do the same to the gateway.
Fix: an event-driven backend with AUTH support (the uring/epoll backends exist but lack
it), or per-IP caps on by default plus a pre-auth connection budget separate from the
authenticated one.

**C3. No quotas or rate limits per token or namespace.** Severity: High.
Where: value size is bounded only by the 16 MiB frame; key count, namespace size, event
rate, command rate and connection count per subject are unbounded. `max_wal_size` only
triggers a snapshot.
Attack: one write-scoped end-user token writes 16 MiB values in a loop until the node
is out of memory, then out of disk. Every other tenant goes down with it.
Fix: per-namespace byte and key quotas enforced in `store.set`, a per-connection command
rate limit, and a per-subject connection cap keyed on the token subject.
**Status: partly fixed.** Per-connection command rate limits (`server.max_commands_per_sec`,
`gateway.max_commands_per_sec`; token bucket, `ERR rate limited` over the limit) and a TCP
per-IP connection cap (`server.max_connections_per_ip`, mirroring the gateway's) are
implemented; both default to 0 = off, so turn them on for untrusted clients (section 6.1).
Per-namespace byte/key quotas and a per-subject connection cap remain open (P1).

**C4. CPU amplification through vector operations.** Severity: Medium.
Where: `applyVinsert` only requires `len % 4 == 0` ([vector_ops.zig:133](../src/procedures/vector_ops.zig)),
so a vector may have 4 million dimensions; HNSW insert and search cost scales with
dimension. `vrabitq` ([vrabitq.zig:166](../src/procedures/vrabitq.zig)) allocates a
dim x dim rotation, re-encodes the whole namespace and replicates up to 16 MiB to every
peer; `vreindex` rebuilds the graph. None of these check authority (A1).
Fix: a `MAX_DIM` (4096 is generous), and admin authority for `vrabitq`, `vreindex` and
`vnsdrop`.

**C5. Subscription filters run under the channel lock with no size cap.** Severity: Low.
Where: `filter.matches` is evaluated for every subscriber inside `channel.mutex`
([bus.zig:279](../src/event/bus.zig)); the predicate in
[predicate.zig](../src/core/predicate.zig) accepts any number of `AND` clauses up to the
16 MiB frame.
Attack: one subscriber with thousands of clauses makes every publish on that channel scan
the message thousands of times while holding the lock.
Fix: cap filter bytes and clause count (for example 1 KiB and 16 clauses).

**C6. Synchronous replication on the client write path.** Severity: Medium.
Where: `replicateWrite` holds the cluster mutex and sends to every peer with a 2 s send
timeout each ([node.zig:1006](../src/cluster/node.zig)); a reconnect sets `needs_sync`
and runs the full-state `iterateAll` dump inside the same call ([node.zig:549](../src/cluster/node.zig)).
Impact: a slow or flapping peer adds seconds to every client `SET` and triggers repeated
full-database transfers from the write path.
Fix: hand replication to a per-peer queue and background sender; run anti-entropy off the
client path.

### D. Cluster and replication

**D1. Open gossip plus unauthenticated outbound replication leaks the whole database.**
Severity: Critical when 51821/udp and 6389/tcp are reachable by untrusted hosts; High
otherwise.
Where: `Cluster.start` initializes SWIM without `enableTrust`/`addTrustedOrg`
([node.zig:401](../src/cluster/node.zig)); meshguard admits any peer when
`enforce_trust` is false. `replOutboundHandshake` ([node.zig:337](../src/cluster/node.zig))
proves our identity to the server but never verifies the server's. On any new peer,
`ensurePeersConnectedLocked` probes `proof_prefix_root` and, on mismatch or error, falls
back to `iterateAll` and sends every key and value ([node.zig:544](../src/cluster/node.zig)).
Attack: an attacker generates a key pair, joins gossip with a fake node (SWIM only checks
that the joiner holds its claimed key), and runs a TCP listener that accepts the `W2` or
`WR` preface and answers the root probe with an error. The victim node streams its entire
store to the attacker and keeps forwarding every client write in real time. `org_trust`
does not help: it governs what a peer may write to us, not whom we talk to.
Fix: wire `org_trust` into SWIM (`enableTrust`, `addTrustedOrg`) so only certified nodes
enter the membership table; make the `W2` handshake mutual (server presents and proves its
certificate too) and refuse to sync to an unverified server; drop `WR` outbound entirely
when trust is configured.
**Status: fixed.** With `org_trust` enforced, `Cluster.start` enables SWIM trust with
our org plus every granted org and gossips our certificate, so uncertified nodes never
enter the membership table. Outbound replication speaks the new mutual `W3` handshake
([wire.zig](../src/protocol/wire.zig), [org_trust.zig](../src/cluster/org_trust.zig)): the
server must prove membership in our org or a granted org before the client sends a single
frame, then the client proves itself. Both W3 signatures cover a role label and both
challenges, so a server hello can never be replayed as a client proof (W3 or legacy W2)
and a node cannot be used as a signing oracle by feeding it a chosen challenge. Outbound
data is also scoped
(`Cluster.peerMayReceive`): same-org peers receive everything, other orgs only the
prefixes their static grant or delegated trust-log capability covers, and unauthenticated
links receive nothing. `WR` outbound is still spoken only when this node has no
certificate (the enforcing peer rejects it). Inbound `W2` is still accepted for rolling
upgrades, with a warning; set `org_trust.accept_w2: false` once every peer speaks W3 to
close the plaintext, one-way-authenticated path (its bare `challenge ++ cert` proof is
relay-prone by design).

**D2. Replication runs over plaintext TCP, not WireGuard.** Severity: High.
Where: `PeerConnection.connect` prefers `real_addr` from gossip over the mesh IP
([node.zig:174](../src/cluster/node.zig)); the project documentation describes replication
as encrypted over WireGuard tunnels.
Impact: in every deployment where peers learn each other's real addresses (which is all of
them), replication traffic is readable and injectable on the network path. Combined with
D1, a passive attacker needs only network position.
Fix: route replication over the mesh IP when the tunnel is up and fall back to the real
address only when WG is unavailable; or add TLS/Noise on the replication channel.
**Status: fixed (application-layer encryption).** Every byte after a `W3` handshake travels
in ChaCha20-Poly1305 records ([secure_channel.zig](../src/cluster/secure_channel.zig)) under
per-direction keys derived by X25519 between the two certified node identities and HKDF
over both handshake challenges; nonces are per-direction counters, so records cannot be
replayed or reordered within a session. The route (WireGuard tunnel, Docker bridge, LAN)
no longer matters for confidentiality or integrity. Open-mode (`--cluster-open`, `WR`)
replication remains plaintext by definition.

**D3. Org grants restrict writes but not reads.** Severity: Medium.
Where: `keyAuthorized` ([org_trust.zig:91](../src/cluster/org_trust.zig)) is consulted only
in the inbound frame loop; anti-entropy and the one-shot RPCs `proof_prefix_root` and
`vsearch_local_raw` ([tcp.zig:871](../src/server/tcp.zig)) run with `.trusted` for any
authenticated org.
Impact: a partner org granted `acme:` receives the full database through anti-entropy and
can run vector searches over every namespace.
Fix: filter outbound sync by the destination org's grants; scope `vsearch_local_raw` and
`proof_prefix_root` to granted prefixes.

**D4. `--cluster-open` is an unauthenticated full-access channel on the client port.**
Severity: Medium (deliberate, loudly logged).
Where: [main.zig:162](../src/main.zig) gates it; `handleReplicationConnection` applies
`SET`/`DEL`/vector frames with no checks and allows idle connections forever
([tcp.zig:631](../src/server/tcp.zig)).
Impact: in open mode anyone who can reach 6389 writes anything, creates WORM keys to squat
namespaces permanently, reads vectors, and can hold worker threads indefinitely.
Fix: keep as is but document that open mode is incompatible with any public exposure of
6389; consider a separate replication port so the client port can stay firewalled
differently.

**D5. `trust_grant` and `trust_revoke` accept the org secret key over the wire.**
Severity: Medium.
Where: `parseKeyMaterial` handles `sk=<hex>` ([trust_log.zig:291](../src/procedures/trust_log.zig)).
Impact: an org's root secret travels over plaintext TCP/WS (B1) and sits in request
buffers on the server. The `sig=` path already supports offline signing.
Fix: remove `sk=`; accept only detached signatures.

**D6. Domain-specific parsing in the core replication handler.** Severity: Low.
Where: `handleReplicationConnection` special-cases `note:` keys, base64-decodes and
JSON-parses peer-supplied values ([tcp.zig](../src/server/tcp.zig) around the `.set` arm).
Impact: extra attack surface in the trusted path; the parsers are bounds-safe today.
Fix: move the notification logic to a domain hook.

**D7. Peer-supplied JSON in RPC replies.** Severity: Low.
Where: `parsePeerRootSummary` and `mergeScatterPayload` ([node.zig](../src/cluster/node.zig))
parse up to 16 MiB of JSON from a peer. Handling is defensive; noted for completeness.

### E. Storage, build and operations

**E1. WORM is enforced in memory only; files are checksummed, not authenticated.**
Severity: Medium.
Where: WORM checks live in `setInternalLockedNoWal` and `set`/`delete`
([store.zig:806](../src/storage/store.zig)); the WAL uses CRC32C ([wal.zig](../src/storage/wal.zig))
and the snapshot has a magic and count sanity check ([store.zig:1810](../src/storage/store.zig)).
Impact: anyone with write access to the data directory rewrites "immutable" history
undetected. The append-log, MMR checkpoint and witness machinery under `src/proof/` is the
real tamper-evidence layer and should be presented as such.
Fix: document the boundary; optionally add a keyed MAC or signature over snapshot and WAL
segments.

**E2. The mint secret lives in plaintext config.** Severity: Medium.
Where: `auth.mint_secret_key` ([config.zig:157](../src/core/config.zig)) is read from
`wormdb.json` ([main.zig:238](../src/main.zig)). Whoever reads the file forges tokens for every
namespace.
Fix: load it from a mode-0600 file or environment variable, refuse to start if the config
file is group/world readable, and prefer minting in an external auth service so
Internet-facing nodes never hold the key.

**E3. Production builds disable runtime safety.** Severity: Medium.
Where: the documented production build is `ReleaseSmall` ([CLAUDE.md](../CLAUDE.md),
[build.zig](../build.zig) uses the standard optimize option). In that mode bounds checks,
integer overflow checks and `@intCast` checks are off.
Impact: any latent off-by-one in the wire, WebSocket, predicate or snapshot parsers becomes
silent memory corruption instead of a crash. The parsers read cleanly, but they have not
been fuzzed.
Fix: build Internet-facing nodes with `ReleaseSafe` until the parsers have fuzz coverage;
add a `zig build fuzz` target over `parseCommandPayload`, `readWsFrame`, `predicate.parse`
and the snapshot/WAL readers.

**E4. Container hardening.** Severity: Low.
Where: [Dockerfile](../Dockerfile) runs as root, ships `netcat` and `iproute2`, and the
healthcheck sends a text `PING` that the binary protocol rejects.
Fix: non-root user, read-only root filesystem, a WormWire `STATUS` healthcheck, minimal
base image.

**E5. Attacker-controlled bytes in logs.** Severity: Low.
Where: unauthorized replication keys and seed names are logged verbatim
([tcp.zig](../src/server/tcp.zig) `replication: SET unauthorized for key '{s}'`).
Fix: escape or hex-encode untrusted bytes before logging.

**E6. The 16-shard lock limit silently degrades to no locking.** Severity: Low.
Where: `acquireShard` returns without locking when the limit is hit
([context.zig:190](../src/procedures/context.zig)).
Impact: no built-in exceeds it today, but a domain procedure that does proceeds with no
locks, which under `ReleaseSmall` is a memory-corrupting data race rather than an error.
Fix: return an error or panic in all build modes.

**E7. Cluster identity and certificates.** Severity: Low.
Where: meshguard saves identity keys with 0600 permissions; the node certificate path is
operator-supplied.
Note: good as is; listed so operators know which files to protect alongside `wormdb.json`.

### F. Reference clients

**F1. The browser demo's token policy is an admin policy.** Severity: High for anyone who
copies it.
Where: `chatCapabilities` grants `exec` wildcard ([auth-provider.ts:72](../apps/browser/demo/auth-provider.ts));
`benchmarkCapabilities` grants `all` wildcard ([auth-provider.ts:87](../apps/browser/demo/auth-provider.ts));
tokens are minted for 24 h ([auth-provider.ts:94](../apps/browser/demo/auth-provider.ts)),
which the server rejects at the default `token_max_age_s` of 3600.
Impact: because of A1, every chat user can `scan ""`, `kv_put` any key, `vnsdrop` any
namespace and mint tokens (A2). The demo is the template people will copy.
Fix: grant `exec exact chat_send` and `exec exact chat_history` only, after those
procedures gain scope checks; drop the 24 h TTL to match the server default.
**Status: fixed.** Chat tokens grant exactly `exec chat_send`/`chat_history`, the
procedure-only room grant `exec chat:` (a pseudo-target checked by `chat_send` through
`Ctx.requireExecTarget`; no raw `set` on `chat:*`, which would let a client forge stored
history under another name), `get` on `chat:` for history, `subscribe` on
`chat:`/`presence:` and `publish` on `presence:` only. Chat messages are stored and
published by the server from `chat_send`; the page no longer publishes them itself, and
nothing in the timeline is built from client-published presence events (those remain
self-declared until A3 adds server-stamped provenance). Benchmark tokens grant `get`/`set`
on `bench:` only; TTL is 1 h.

**F2. Client libraries.** Severity: Informational.
The Bun and browser clients keep the token in memory, re-send it on reconnect, and never
persist it; that is correct. `jti` comes from `Math.random()`, which only matters once
revocation (A4) exists.

## 5. What holds up

- SCT verification: signature is checked before any parsing, parsing is bounds-checked,
  `exp`, `iat` skew and max age are enforced, and expiry is re-checked on every TCP and WS
  frame and at event delivery ([auth.zig](../src/server/auth.zig), [tcp.zig:520](../src/server/tcp.zig)).
- A single authorization chokepoint in the executor with deny-by-default for targetless
  commands, per-item checks for `VBULKINSERT`, namespace confinement for bulk keys, and
  universal-admin-only `SAVE`.
- Wire codec: every field is length-prefixed and bounds-checked, trailing bytes are
  rejected, unknown commands are rejected, and `VBULKINSERT` rejects impossible counts before
  allocating.
- Admission budgets and read deadlines from REVIEW-016, backed by the live regression suite
  in [scripts/test-security.ts](../scripts/test-security.ts).
- The `W2` handshake: fresh 32-byte challenge, org signature over the certificate, validity
  window, grant lookup, and proof of possession of the certified node key. Standalone nodes
  refuse legacy `WR` unless `--cluster-open` is passed.
- Event bus lifetime handling: delivery outside locks, retain/release hooks, and
  `tryLock` drops rather than blocking on a busy writer.
- Snapshot loader count sanity, WAL CRC32C and payload cap, and arena-owned entries that
  cannot be double-freed.
- Cluster identity keys written with owner-only permissions.

## 6. Recommendations

### 6.1 Running WormDB as the API today

1. Treat every procedure in section 3 other than `mem_*` as administrative. End-user tokens
   get `get`/`set`/`subscribe` on their own prefixes and `exec` only on procedures that call
   `ctx.requireNamespace` or `ctx.permits` on every key they touch. Audit domain procedures
   to the same standard.
2. Do not grant `publish` to end users. Emit events from procedures only.
3. Put a TLS-terminating proxy in front of the gateway and advertise only `wss://`. Keep
   6389 on a private network reachable by trusted services only.
4. Firewall 51821/udp, 51830/udp and 6389/tcp to known peer addresses, and give every
   node an org certificate (`org_trust.node_cert_path`): that turns on SWIM membership
   trust, the mutual `W3` handshake and encrypted replication. Never run `--cluster-open`
   outside an isolated test network.
5. Set `server.max_connections_per_ip`, `gateway.max_connections_per_ip`,
   `server.max_commands_per_sec` and `gateway.max_commands_per_sec` (all off by default),
   keep `namespace_token_ttl_s` and `token_max_age_s` to minutes (there is no revocation),
   and size `server.max_connections` with the 64-worker ceiling in mind.
6. Keep `auth.mint_secret_key` off Internet-facing nodes; mint in your auth service; make
   `wormdb.json` mode 0600.
7. Build Internet-facing nodes with `-Doptimize=ReleaseSafe` until the parsers are fuzzed.
8. Run as a non-root user with a read-only root filesystem.
9. Alert on `event_bus_drops`, `tcp_connection_queue_depth`, `gateway_connections_active`
   and worker saturation; these are the early signals for C1 and C2.

### 6.2 Remediation order

P0 (blocks safe direct-to-app use) — **all done** (see the Status lines in section 4):
A1 procedure scope checks (`Ctx.requireKey`/`requirePrefix`);
C1 stalled-subscriber eviction with a 500 ms event send deadline;
D1 and D2 SWIM trust from `org_trust`, mutual `W3` handshake, outbound scoping, and an
encrypted replication channel;
C3 per-connection rate limits and a TCP per-IP cap (namespace quotas moved to P1);
B3 pre-auth frame cap and bounded arena retention;
F1 least-privilege demo token policy;
plus A2 (explicit mint authority) because it fell out of A1.

P1:
B1 native TLS or a hard requirement for a proxy; B2 gateway bind address, Origin allowlist
and an explicit flag for auth-disabled public mode; A3 event provenance; A4 revocation;
A5 gate `CLUSTER_PEERS`; C2 an event-driven backend with AUTH or per-IP caps on by
default; C3 remainder: per-namespace byte/key quotas and a per-subject connection cap;
C1 remainder: per-connection writer queues so fan-out leaves the publisher's thread;
C4 `MAX_DIM` (admin gating for `vrabitq`/`vreindex`/`vnsdrop` is covered by A1's range
checks); D3 read-side grants (outbound scoping now exists; inbound reads of proof RPCs are
still org-level); D5 remove `sk=`; B6 QUIC fixes (pre-auth cap and expiry re-check);
E2 secret handling; SWIM admission for delegated orgs that have no static grant entry;
flip `org_trust.accept_w2` to default false once no W2-only peers remain.

P2:
A6, A7, A8, A9, B4, B5, B7, B8, C5, C6, D6, E1 documentation, E3 fuzzing and ReleaseSafe
guidance, E4, E5, E6.

## 7. Not verified and assumptions

- The QUIC gateway was reviewed by reading only; it needs a `-Dquic` build and was also not
  exercised in REVIEW-016.
- meshguard was read only for SWIM trust gating, certificate handling and key storage.
- No fuzzing or live exploitation was done. C2 and the remaining P1 items are
  straightforward to reproduce with the harness in `scripts/test-security.ts` and a fake
  peer. The P0 fixes are covered by unit tests (`zig build test`: scope checks, prefix
  semantics, eviction, socket shutdown wake-up, W3 handshake, secure channel, rate
  limiter) and by the live suite in `scripts/test-security.ts`; the cluster path was
  exercised end to end on a three-node Docker cluster with org certificates.
- External domain packages were out of scope. The domain seam provides no scope
  enforcement, so each domain owns its own authorization.
