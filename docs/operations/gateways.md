# Gateways & Light-API

WormDB's primary server port speaks WormWire over TCP. The optional gateway port adds browser-facing access: WormWire over binary WebSocket frames, plain HTTP Light-API routes, and a cc32d9-compatible JSON-RPC WebSocket dialect. QUIC/WebTransport is available only when the binary is built with `-Dquic=true`.

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

## WormWire Over WebSocket

Binary WebSocket frames carry WormWire command and response frames without the raw TCP `WW` preface. Browser clients can use `apps/browser/src/client.ts` and the demo pages under `apps/browser/demo/`.

Authentication is via signed capability tokens (SCT). Configure Ed25519 public keys in `auth.public_keys`; when at least one valid key is loaded and `auth.require_auth` is true, unauthenticated gateway commands are rejected. An empty public-key list leaves gateway auth disabled.

```json
{
  "auth": {
    "public_keys": ["BASE64_ED25519_PUBLIC_KEY"],
    "require_auth": true,
    "token_max_age_s": 3600
  }
}
```

The `AUTH` command is connection-level. If it reaches the generic executor, the response is an error because auth must be enforced by the gateway.

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

## Plain HTTP Light-API

Non-WebSocket `GET /api/...` requests on the gateway are routed directly to compiled `lightapi_*` procedures. There is no Node or Bun application tier in the serving path.

| Route | Procedure |
| ----- | --------- |
| `/api/balances/<chain>/<account>` | `lightapi_balances` |
| `/api/account/<chain>/<account>` | `lightapi_account` |
| `/api/accinfo/<chain>/<account>` | `lightapi_accinfo` |
| `/api/tokenbalance/<chain>/<account>/<contract>/<symbol>` | `lightapi_tokenbalance` |
| `/api/usercount/<chain>` | `lightapi_get uc:<chain>` |
| `/api/holdercount/<chain>/<contract>/<symbol>` | `lightapi_holdercount` |
| `/api/networks` | `lightapi_networks` |
| `/api/codehash/<sha256>` | `lightapi_codehash` |
| `/api/key/<pubkey>` | `lightapi_key` |
| `/api/topholders/<chain>/<contract>/<symbol>/<n>` | `lightapi_topholders` |
| `/api/topram/<chain>/<n>` | `lightapi_topram` |
| `/api/topstake/<chain>/<n>` | `lightapi_topstake` |
| `/api/rexbalance/<chain>/<account>` | `lightapi_rexbalance` |
| `/api/rexraw/<chain>` | `lightapi_get rexraw:<chain>` |
| `/api/sync/<chain>` | `lightapi_sync` |
| `/api/status` | `lightapi_status` |

`/api/status` returns HTTP 503 when the body starts with `OUT_OF_SYNC`.

## Frozen Segment Tier

Large Light-API tables can be served from an mmap-backed frozen segment:

```bash
./zig-out/bin/wormdb --gateway-port 6390 --lightapi-segment ./lightapi.wseg
```

`lightapi_segment` can also be set in `wormdb.json`. When present, account and balance procedures read bulk tables from the segment while small aggregate values can still come from the KV overlay. Network metadata under `lightapi.networks` is seeded into KV at startup.

## JSON-RPC WebSocket Dialect

Text WebSocket frames support a cc32d9-style JSON-RPC 2.0 dialect. Supported methods include:

| Method | Purpose |
| ------ | ------- |
| `get_networks` | Stream configured networks |
| `get_balances` | Stream balances for up to 100 accounts |
| `get_token_holders` | Stream token holder rows |
| `get_accounts_from_keys` | Stream account permission rows for public keys |

Responses are streamed as `reqdata` notifications and terminated with an `end:true` message.
