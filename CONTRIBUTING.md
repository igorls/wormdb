# Contributing to WormDB

Use [GitHub issues](https://github.com/igorls/wormdb/issues) for reproducible bugs
and focused proposals. Discuss protocol, persistence-format, or public API changes
before implementing them. Keep reports and pull requests free of credentials,
private datasets, and deployment details. Follow the [security policy](SECURITY.md)
for private vulnerability reports; do not post exploit details in public issues.

## Development setup

Use Zig **0.16.0**, Git, and Bun for the TypeScript clients and documentation.

```sh
git clone https://github.com/igorls/wormdb.git
cd wormdb
git submodule update --init deps/meshguard
zig build -Dcrypto-backend=std
zig build test -Dcrypto-backend=std
```

Linux is the primary server platform. Windows supports the standalone server with
the threadpool backend. The default Linux build links libsodium; the explicit
`std` crypto backend above avoids that dependency. QUIC is optional and requires
the separate MsQuic/libwtf build. See [build.zig](build.zig) and
[Windows support](docs/WINDOWS.md).

## Validation

Run the checks relevant to your change and include their results in the PR:

```sh
zig fmt --check src/path/to/changed.zig
zig build test
zig build -Doptimize=ReleaseSmall
```

For the Bun client:

```sh
cd apps/bun
bun install --frozen-lockfile
bun test
```

For documentation, from the repository root:

```sh
bun install --frozen-lockfile
bun run docs:build
```

Use integration checks for changes to networking, persistence, authentication, or
replication. State which operating systems, backends, and configurations you
actually exercised. A passing unit suite does not establish crash recovery,
cluster convergence, or production readiness.

## Pull requests

First-party contributions are licensed under [MIT](LICENSE). Preserve applicable
third-party copyright and license notices.

- Keep changes focused and preserve unrelated work.
- Describe the problem, resulting behavior, tests, and remaining limitations.
- Use Conventional Commit titles, for example `fix(storage): preserve WAL errors`.
- Reference the issue; include `Fixes #123` only when the change resolves it.
- Do not commit generated docs, benchmark data, private keys, runtime databases,
  or machine-specific configuration.

Platform shims belong in `src/core/compat.zig`. Changes to compiled procedures must
follow the [procedure guide](.agent/skills/wormdb-procedures/SKILL.md), especially
locking, WORM checks, and the distinction between durable and snapshot-only writes.
Agent work packages use the [repository workflow](agents/README.md).

## Secret scanning

CI uses Gitleaks 8.30.1 with the default detectors, an exact public test-fixture
exception, and one historical fingerprint for a retired browser-demo key. The
exceptions are documented in `.gitleaks.toml` and `.gitleaksignore`. To check Git
history locally:

```sh
gitleaks git . --log-opts="--all" --redact --no-banner
```

This checks the refs available in your clone. A publication review must also
fetch remote branches, tags, and pull-request refs. Never add a baseline or broad
exception merely to hide a real historical credential.
