# Namespace-Scoped Auth Tokens

This note finalizes the namespace-scoped authentication model for `mem_*`
procedures and related raw KV/vector/pubsub access. It is the design input for
the implementation work tracked by issue #4.

## Goals

- Allow BentoKit and other embedded clients to mint least-privilege tokens for a
  single memory namespace.
- Keep the existing Signed Capability Token (SCT) binary format in
  `src/server/auth.zig`.
- Enforce namespace scope at every client-facing path that can read, write, or
  subscribe to namespace data.
- Preserve existing deployments: auth-disabled listeners and unrestricted admin
  tokens continue to work.

## Token Format And Storage

WormDB continues to use SCTs:

```text
SCT = payload || ed25519_signature
payload = iat || exp || subject || jti || capabilities
capability = op || match_type || pattern
```

Tokens are signed and stateless. The server does not store issued namespace
tokens by default; it verifies signatures against configured Ed25519 public keys
and checks expiration on every authenticated connection. The `jti` remains the
stable identifier used for revocation.

Revoked token IDs are stored in WormDB as durable keys:

```text
auth:revoked:<jti> -> {"exp": <unix_seconds>, "reason": "...", "revoked_at": <ms>}
```

The auth verifier must reject a token whose `jti` has a live revocation record.
Expired revocation records may be compacted by a future maintenance procedure.

## Master Key Model

There are two authority levels:

- **Admin token:** an SCT with `Operation.all` + `MatchType.wildcard`, or an SCT
  with `Operation.exec` + exact `auth_mint_scoped` and `auth_revoke`
  capabilities plus a namespace mint capability.
- **Namespace token:** an SCT generated for one namespace with only the expanded
  capabilities listed below.

The server-side mint procedure is enabled only when a signing secret is present
in config. If no signing secret is configured, `auth_mint_scoped` returns a clear
`auth mint not configured` error and operators can continue minting SCTs offline.

The signing public key corresponding to the mint secret must also be present in
the verifier public-key set so minted tokens are accepted by gateways.

## Mint API

Procedure:

```text
EXEC auth_mint_scoped <namespace> [ttl_s] [subject] [mode]
```

Arguments:

- `namespace`: memory namespace, validated with the same rules as `mem_init`.
- `ttl_s`: optional token lifetime in seconds. Defaults to the configured
  namespace-token TTL and must not exceed `auth.token_max_age_s` when non-zero.
- `subject`: optional token subject. Defaults to `mem:<namespace>`.
- `mode`: optional capability bundle: `read`, `write`, or `readwrite`. Defaults
  to `readwrite`.

Return:

```json
{"token":"<base64-sct>","subject":"...","namespace":"...","exp":123,"jti":456}
```

Authorization to mint:

- The caller must already be authenticated.
- The caller must either have wildcard admin capability or be permitted to
  execute `auth_mint_scoped` and mint the target namespace.
- Namespace mint permission is represented as `Operation.exec` with prefix
  pattern `auth:mint:<namespace>` or wildcard admin capability.

## Namespace Capability Expansion

The mint procedure expands a namespace into concrete SCT capabilities rather than
embedding app-specific policy in the token parser.

For namespace `astrid`, read mode grants:

```text
get       prefix "mem:astrid:"
get       prefix "vec:mem:astrid:"
get       prefix "bq:vec:mem:astrid:"
exec      prefix "mem_"
subscribe prefix "mem:astrid:"
```

Write mode grants:

```text
set       prefix "mem:astrid:"
set       prefix "vec:mem:astrid:"
set       prefix "bq:vec:mem:astrid:"
delete    prefix "mem:astrid:"
delete    prefix "vec:mem:astrid:"
delete    prefix "bq:vec:mem:astrid:"
publish   prefix "mem:astrid:"
exec      prefix "mem_"
```

`readwrite` is the union of both sets.

The `exec prefix "mem_"` capability only permits entry into memory procedures.
Each `mem_*` procedure must still authorize the namespace argument through the
procedure context before it reads or writes data. This second check is required
because command-level auth sees only the procedure name, not the namespace
argument.

## Enforcement Scope

Client-facing enforcement applies to:

- Raw KV commands: `GET`, `SET`, `DEL`.
- Raw vector commands: `VINSERT`, `VDELETE`, `VBULKINSERT`, `VRABITQ_INSTALL`.
- Pub/sub commands: `SUB`, `UNSUB`, and `PUBLISH`.
- Stored procedures: at command level for `EXEC`, then inside namespace-aware
  procedures for their namespace arguments.

Public commands remain public: `STATUS`, `CLUSTER_STATUS`, `CLUSTER_PEERS`,
`SAVE`, and `AUTH`.

Cluster replication, recovery, and internal maintenance callers use
`AuthContext.trusted` and do not require SCTs.

## Procedure Context Changes

Implementation issue #4 should extend procedure context from identity-only to
auth-aware:

```zig
ctx.identity() ?[]const u8
ctx.permits(op: auth.Operation, target: []const u8) bool
ctx.requireNamespace(ns: []const u8, access: .read | .write) !void
```

`requireNamespace` expands the namespace to the same concrete targets used by
minting and returns `error.PermissionDenied` on mismatch. `mem_*` procedures call
it before touching store, vector registry, or event bus state.

## Expiry, Rotation, And Revocation

- Tokens always carry `iat`, `exp`, and `jti`.
- Namespace tokens should be short-lived by default. A deployment default of one
  hour is recommended; operators may choose lower or higher values within
  `auth.token_max_age_s`.
- Rotation is key-set based: add the new public key, start minting with the new
  secret, wait for old tokens to expire, then remove the old public key.
- `EXEC auth_revoke <jti> [reason]` writes `auth:revoked:<jti>` and takes effect
  for new AUTH attempts immediately. Active connections are checked for token
  expiration today; issue #4 should also check revocation at the same point.

## Migration

Existing auth-disabled listeners keep their current behavior. Existing SCTs with
wildcard capabilities remain valid and are treated as admin tokens.

The migration path is additive:

1. Configure verifier public keys as today.
2. Optionally configure the server mint signing secret.
3. Deploy `auth_mint_scoped` and procedure-context namespace checks.
4. Move clients from wildcard/admin SCTs to namespace tokens.
5. Keep wildcard SCTs only for operators and trusted control-plane services.

## Issue #4 Checklist

- Add config for optional mint signing secret and namespace-token default TTL.
- Add `auth_mint_scoped` and `auth_revoke` procedures.
- Thread `TokenState` or a permit callback into `procedures.context.Ctx`.
- Add `ctx.permits` and `ctx.requireNamespace`.
- Gate every `mem_*` procedure by namespace and access mode.
- Check revocation during AUTH and during active-connection token refresh checks.
- Add tests for scope match, scope mismatch, mint with admin token, mint without
  admin token, revocation, and wildcard-token migration behavior.
