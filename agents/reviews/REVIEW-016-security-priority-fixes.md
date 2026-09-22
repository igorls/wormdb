# REVIEW-016: Priority security fixes

- Date: 2026-09-22
- Package: WP-016 (renumbered during integration to preserve the public-site WP-015)
- Outcome: Approved for integration; undeployed.

The four high-severity security findings and related SAVE authorization gap are
fixed locally. Auth remains enforced with no keys, SAVE requires universal
admin scope, snapshot producers serialize, and TCP/WS connections have global
admission budgets and absolute input deadlines. The shared client port rejects
legacy replication unless explicitly enabled with `--cluster-open`.

Validation passed on both Windows and Ubuntu WSL with Zig 0.16.0:

- `zig build -Dcrypto-backend=std --summary all`: 8/8 steps.
- `zig build test -Dcrypto-backend=std --summary all`: 301/301 tests on each OS.
- `bun run scripts/test-security.ts <binary>`: 14/14 live groups on each OS.
- `bun test` in `apps/bun`: 65/65 tests.
- Changed Zig files pass `zig fmt --check`; working diff passes `git diff --check`.

Snapshot stress includes concurrent manual saves, WAL compaction, deletion and
reload before shutdown. It exposed and resolved the DELETE shard-lock ordering
deadlock. Network tests exercise malicious stalled/trickled inputs, public
command keepalives, token expiry while reading, admission recovery and blocked
sends, alongside valid scoped/admin tokens and idle subscriptions.

Independent read-only investigation and one candidate review were performed.
Confirmed review findings (exact-empty SAVE scope and expiry after read) were
corrected and tested. The parent also reproduced and closed the legacy WR
alternative to client authentication. Existing release-preparation edits remain.

Integration was replayed on main revision `14af562` in a clean worktree. The
already-published bind-address setting was preserved once. All build, unit,
live regression and Bun checks listed above were repeated and passed there.

No deployment, full multi-node rehearsal or optional QUIC runtime was performed.
Linux builds cover the shared authorization code, but standalone epoll/io_uring
listeners were not exercised live. The fixed TCP worker pool still limits valid
long-lived sessions; no fairness guarantee is added. Other 12 WormDB and two
Meshrooms audit findings remain outside this package.
