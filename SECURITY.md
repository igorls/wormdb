# Security policy

## Reporting a vulnerability

Use [GitHub private vulnerability reporting](https://github.com/igorls/wormdb/security/advisories/new)
when the repository's **Report a vulnerability** form is available. If it is not
available, contact the maintainer through their
[GitHub profile](https://github.com/igorls) to arrange a private channel before
sharing details. Do not put credentials, private data, or exploit details in a
public issue or pull request.

Include the affected commit/version, platform, relevant configuration, minimal
reproduction, expected security property, and observed impact. Use synthetic data
and redact secrets. There is no guaranteed response time or published backport
support matrix; include whether the issue reproduces on current `main`.

## Scope and trust boundaries

WormDB includes the Zig storage engine, WormWire parsers and server backends,
compiled procedures, vector indexes, cluster replication, optional gateways, and
the FFI interface. Reference clients and tooling are also part of this repository.
Report dependency issues here when they have an observable WormDB impact, and
coordinate with the upstream project when appropriate.

Network frames, tokens, gateway requests, replicated records, and imported storage
files can cross trust boundaries. Parsing must bound lengths and allocation,
reject malformed data safely, and avoid memory corruption. Configured
authentication and capability checks must precede the operations they protect.
Replication grants must constrain incoming peers and key prefixes. WORM and
durability guarantees must hold for APIs that promise them.

Operators control local configuration, data files, and compiled procedure code.
WORM is an application storage property, not protection against an administrator
who can replace the binary or modify its files. Built-in procedures remain in
scope: a remotely reachable path through a trusted procedure can still violate a
security boundary.

## Deployment limitations

- When `auth.require_auth` is true, auth-enabled listeners enforce SCT
  authentication independently of verification-key availability. An empty
  `auth.public_keys` list keeps protected commands locked. Global or transport-specific
  opt-outs explicitly disable enforcement. `SAVE` requires universal admin authority.
- Authenticated TCP/WebSocket sessions close at token expiry even when idle.
  Refresh before expiry to keep the session; otherwise reconnect. Event delivery
  checks the current token's expiry and channel grant, including after re-AUTH.
- The synchronous FFI acknowledges WAL-backed writes only after write and sync.
  I/O errors have uncertain outcomes, not rollback guarantees. A direct WAL
  write/sync failure blocks further WAL-backed writes until close/reopen and
  recovery; reconcile recovered state before retrying.
- Raw WormWire TCP does not provide TLS. WebSocket deployments need appropriate
  TLS termination or a secure tunnel. QUIC is an optional, separately configured
  build. Authorization does not provide transport confidentiality.
- Replication can use real peer addresses outside a WireGuard route. Verify the
  route's transport protection; do not infer encryption from cluster membership.
- Use `org_trust` grants for authenticated replication. `--cluster-open`
  explicitly enables unauthenticated replication and belongs only on isolated,
  trusted test networks.
- `examples/local.json` is an unauthenticated loopback development configuration
  with the WebSocket gateway disabled. Do not use it as a production template.
- Procedure helpers differ: `ctx.set()`/`setInt()` bypass the WAL, and `ctx.del()`
  also bypasses the normal WORM check. Procedure authors must choose the durable
  helpers where those guarantees are required. Durable helpers release and
  reacquire locks around storage/replication; they are not a multi-key transaction.

## Assessment expectations

Report authentication or authorization bypasses, cross-namespace access,
memory-safety issues, reachable resource exhaustion, disclosure of secrets, and
violations of promised integrity or durability. Explain the reachable interface,
required configuration and privileges, and practical impact. These deployment
limitations are context for assessment, not blanket exclusions or permission to
ignore a broken configured control. No additional finding classes are excluded.
