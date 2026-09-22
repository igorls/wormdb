# REVIEW-017: Meshrooms synchronous native integration

- Date: 2026-09-22
- Package: WP-017
- Outcome: Approved for integration; hosted merge tracked by PR #96.
- Native source candidate: `630f39495afeb2c500eb2dd7c799f7807f9b75a0`.

The synchronous opener and four direct WAL append paths preserve write-plus-sync
before successful acknowledgement. The old asynchronous ABI is unchanged. The
merge changes no security Store/server/auth code relative to `6a53cd0`.
Explicit allocation cleanup corrects the new nullable opener's failure paths.

Windows and Ubuntu WSL each passed 303/303 Zig tests, 8/8 build steps and 14/14
live security groups. A fresh Windows x64 ReleaseFast DLL built from clean pinned
source passed Meshrooms typecheck, 49 source tests, 76 full native/runtime tests
with no skips, and production UI build. Its size is 1,953,792 bytes and SHA-256 is
`72be67a557818090048c669536c464a5bea1171ba79777eba3a08572d1f88aac`.
Every lockfile-required export and the exact artifact hash were checked.

One fresh independent pre-integration investigator and one fresh read-only
candidate reviewer were used. The reviewer found no concrete remaining bypass or
regression and independently passed 303 Zig tests, 44 consumer/native tests,
the real-daemon quota test, native VerifyOnly and diff checks.

Gitleaks' one new match was the public fixed WebSocket handshake nonce in the
live regression test. Its exception is limited to that exact historical
fingerprint; the full fetched-history scan then passed without suppressing other
keys or tests. This records the initial candidate; merge-review changes below
require a newly qualified consumer artifact.

No running daemon, user store, startup registration or release artifact was
replaced. Sync-mode WAL growth, hardware power-loss, sustained load, full
multi-node and optional QUIC qualification remain outside this integration.

## Merge-review follow-up

Hosted review identified silent TCP/WS token expiry and an uncertain WAL sync
failure outcome. A live regression reproduced post-expiry event delivery on the
initial candidate. Token-bounded reads and delivery-time authorization now stop
it; refresh preserves authorized subscriptions and narrower grants take effect.
Token replacement/free and connection teardown synchronize with event delivery.

The synchronous WAL treats a failed write or sync as an uncertain commit, blocks
later WAL-backed writes until recovery, and does not claim rollback. A test-only
post-write sync fault verifies rejection of a contradictory WORM retry and all
other append forms, then reopens and reconciles the original record.

The follow-up reviewer then reproduced a binary-channel representation bypass:
the first CRLF-delimited portion of an event envelope was being re-authorized
instead of the original channel bytes. EventBus now supplies exact structured
channel/message slices to TCP and WebSocket callbacks. The regression uses a
CRLF-containing channel, proves a shorter exact grant receives nothing, and
proves the full exact grant receives the unchanged channel and message.

Windows and Ubuntu WSL passed 304/304 Zig tests, 8/8 build steps and 17/17 live
security groups. Formatting/diff checks passed. Native requalification is
pending before merge.
