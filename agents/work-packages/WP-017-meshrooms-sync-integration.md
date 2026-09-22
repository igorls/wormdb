# WP-017: Meshrooms synchronous native integration

- Priority: P0
- Status: Review (engine checks passed; native consumer qualification and merge pending)
- Scope: combine the reviewed security changes with the additive synchronous
  FFI/WAL commits, preserve the legacy asynchronous API, and qualify a new native
  artifact for Meshrooms. Do not replace running daemons or publish a release.

The synchronous opener must return only after WAL-backed writes have completed
write and sync, and propagate I/O failures. Preserve snapshot serialization,
authorization and bounded network resources. Correct allocation cleanup in the
new nullable opener without expanding into unrelated FFI changes.

Validation: Zig format check, Windows/Linux engine and FFI unit tests, standalone
build and live security regressions; Meshrooms typecheck, source checks, production
build and full native/process-crash suite with the exact candidate DLL. Retain
the old DLL for incompatible-symbol rejection. Build from clean pinned source,
record provenance and hash/size, and review before updating the consumer lock.
Merge through protected pull requests with current hosted checks green.

Engine candidate validation on Windows and Ubuntu WSL: 303/303 unit tests,
8/8 build steps and 14/14 live security regression groups on each platform.
The independent pre-integration trace confirmed lock compatibility and identified
the nullable-opener allocation cleanup correction included here.
