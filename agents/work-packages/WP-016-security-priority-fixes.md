# WP-016: Priority security fixes

- Priority: P0
- Status: Review (validated locally; see REVIEW-016; pending integration)
- Scope: reviewed auth fail-open, SAVE authorization, snapshot concurrency,
  TCP idle-worker exhaustion, and unbounded gateway connection threads.

Enforce auth independently of key availability; require existing universal SCT
admin authority for SAVE; serialize all snapshot producers before copying data;
bound accepted connections and incomplete network input on Windows and Linux.
Preserve explicit auth opt-outs, signed tokens, pub/sub, authenticated replication,
and existing release-preparation changes.

Validation: `zig build test -Dcrypto-backend=std --summary all`,
`zig build -Dcrypto-backend=std`, and live regression checks against the resulting
binary on Windows and Linux. Include hostile stalled/fragmented input,
capacity recovery, legitimate signed reads/writes/subscriptions, and concurrent
snapshot/reload with WAL compaction. Review the candidate independently before
recording completion. No deployment or external publication is included.
