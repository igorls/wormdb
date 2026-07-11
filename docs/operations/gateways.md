# Gateways

WormDB's primary server port speaks WormWire over TCP. The optional gateway port adds browser-facing access: WormWire over binary WebSocket frames, plain HTTP routes contributed by domain packages, and a JSON-RPC WebSocket dialect whose methods are also domain-contributed. QUIC/WebTransport is available only when the binary is built with `-Dquic=true`.

## Enable The Gateway

From the CLI:

```bash
./zig-out/bin/wormdb --port 6389 --data ./data --gateway-port 6390
```

Or in `wormdb.json`:

```json
{
  "gateway": {
    "enabled": true,
    "port": 6390,
    "public_endpoint": "wss://us-east.example.com"
  }
}
```

The gateway shares the same store, event bus, procedure registry, cluster handle, and vector registry as the TCP server.

## Per-IP Connection Cap

`gateway.max_connections_per_ip` bounds concurrent gateway connections per client IP. The default is **0 = unlimited** — a small default cap would break real deployments, because players behind one NAT (schools, offices) and localhost capacity benches all share a single address ([#89](https://github.com/igorls/wormdb/issues/89)).

```json
{
  "gateway": {
    "enabled": true,
    "port": 6390,
    "max_connections_per_ip": 1024,
    "per_ip_exempt_loopback": true
  }
}
```

- The cap is enforced only when the peer address is resolvable on the accept path; a connection that cannot be attributed to an IP is admitted uncounted, never rejected.
- `per_ip_exempt_loopback` (default `true`) skips the cap for `127.0.0.0/8` and `::1`, so local benches can open hundreds of sockets from one address.
- Each rejection is logged with the peer address and active count, and counted in the `STATUS` field `gateway_per_ip_rejections`.
- The stock `wormdb` binary applies these settings from `wormdb.json` automatically. Embedders starting the gateway themselves apply them with `gateway.setPerIpLimit(cfg.gateway.max_connections_per_ip, cfg.gateway.per_ip_exempt_loopback)` before `gateway.start()`.

## WormWire Over WebSocket

Binary WebSocket frames carry WormWire command and response frames without the raw TCP `WW` preface. Browser clients can use `apps/browser/src/client.ts` and the demo pages under `apps/browser/demo/`.

Authentication is via signed capability tokens (SCT). Configure Ed25519 public keys in `auth.public_keys`; when at least one valid key is loaded and `auth.require_auth` is true, unauthenticated gateway commands are rejected. An empty public-key list leaves gateway auth disabled.

```json
{
  "auth": {
    "public_keys": ["BASE64_ED25519_PUBLIC_KEY"],
    "require_auth": true,
    "token_max_age_s": 3600,
    "mint_secret_key": "BASE64_ED25519_SECRET_KEY",
    "namespace_token_ttl_s": 3600
  }
}
```

The `AUTH` command is connection-level. If it reaches the generic executor, the response is an error because auth must be enforced by the gateway.

`mint_secret_key` is optional. When present and paired with its public key in `auth.public_keys`, `EXEC auth_mint_scoped <namespace> [ttl_s] [subject] [read|write|readwrite]` can mint least-privilege namespace SCTs. Minting requires wildcard admin authority or both `exec auth_mint_scoped` and `exec auth:mint:<namespace>` capability.

Namespace tokens expand to concrete capabilities for `mem:<ns>:`, `vec:mem:<ns>:`, `bq:vec:mem:<ns>:`, `__meta:mem:<ns>:`, `EXEC mem_*`, and `mem:<ns>:` pub/sub channels. Each `mem_*` procedure also checks the namespace argument server-side, so a token for `astrid` cannot call `mem_query raven ...`.

## QUIC / WebTransport

The QUIC gateway is compile-time gated:

```bash
zig build -Dquic=true
```

It requires prebuilt `deps/msquic` and `deps/libwtf`, plus TLS cert/key paths in config:

```json
{
  "gateway": {
    "quic_enabled": true,
    "quic_port": 6393,
    "tls_cert_path": "./cert.pem",
    "tls_key_path": "./key.pem"
  }
}
```

QUIC/WebTransport support depends on the optional `deps/msquic` and `deps/libwtf` artifacts used by the `-Dquic=true` build. The Windows page tracks platform support separately.

## Plain HTTP Routes

Non-WebSocket `GET /api/...` requests on the gateway are routed through the domain route table (`gateway.registerRoutes`). Each route resolves to a compiled `EXEC` procedure — there is no Node or Bun application tier in the serving path. The engine itself ships no HTTP routes; external domain packages contribute them via their manifests at composition time.

A route's HTTP status can be fixed or derived from the response body (e.g. a health endpoint returning 503 while out of sync).

## Frozen Segment Tier

Large static tables can be served from an mmap-backed frozen segment (`.wseg`), mounted at startup via the `segments` config section and looked up by an opaque name the serving domain owns. See [WSEG format](/WSEG_FORMAT) for the file layout. When present, domain procedures read bulk tables from the segment while small aggregate values can still come from the KV overlay.

## JSON-RPC WebSocket Dialect

Text WebSocket frames carry JSON-RPC 2.0 requests dispatched to domain-registered WS methods (`gateway.registerWsMethods`). Responses are streamed as `reqdata` notifications — one per row — and terminated with an `end:true` message. The method set, parameter shapes, and row JSON are defined by the composed domain packages, not the engine.
