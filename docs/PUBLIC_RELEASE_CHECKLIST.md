# Public release checklist

Use this checklist against the exact commit and artifacts intended for release.
An open-source preview can document unfinished features; it still needs a clean
disclosure boundary, reproducible onboarding, and accurate claims.

## Before changing visibility

- Resolve the license for every first-party package and include license files.
  Retain dependency licenses and verify the provenance of bundled binaries.
- Scan the proposed source tree **and all remote branches, tags, and PR refs**
  with Gitleaks. Triage every result. A file removed from the default branch can
  still exist in history. Rotate/revoke any real exposed credential before
  publication; rewriting history alone does not invalidate it.
- Review old domain code, commit messages, issues and comments, PR discussions,
  wiki content, releases, Actions logs/artifacts, and Git LFS objects for material
  that was intended to stay private. Automated secret scans do not cover this
  disclosure review.
- Choose whether to publish cleared development history or a fresh source
  snapshot. Preserve a private backup before any authorized history change.
  Review GitHub's [visibility effects](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/managing-repository-settings/setting-repository-visibility).
- Review and adopt a security policy and establish a private reporting channel.
  Enable GitHub private vulnerability reporting when available and verify the
  reporting link from a separate account.
- Require the relevant CI checks on the release commit; review branch rules,
  Actions permissions, fork PR approvals, secret scanning, and push protection.
  Do not give forked pull requests secrets or use `pull_request_target` to execute
  contributor code.

## Build and onboarding

- Resolve the exact MeshGuard submodule commit anonymously; do the same for
  optional QUIC dependencies when shipping that build.
- Build and test Linux and Windows from a fresh checkout with Zig 0.16.0.
  Test the crypto backend actually included in each artifact.
- Install the Bun client with its frozen lockfile and run its tests.
- Follow the README from a clean checkout: start with `examples/local.json`,
  verify the listener is loopback-only, and exercise SET/GET/WORM/STATUS.
  The loopback configuration requires the standalone server to pass
  `server.bind_address` to its listener; verify the built commit contains that wiring.
- Build the documentation. Check commands against the stock executable's
  `--help`; library configuration is not necessarily exposed by the stock CLI.
- Document authentication defaults, plaintext TCP, replication authorization,
  local versus cluster search, procedure durability, and recovery limitations.

## Binary and package releases

- Build the requested tag itself, including on manual workflow dispatch.
- Use supported build runners and test each advertised platform.
- Fail packaging if a promised executable, FFI library, or header is absent.
- Include the project license and applicable dependency notices in every archive
  and publish checksums. Verify the archive after extraction on a clean machine.
- Test Docker build context, runtime libraries, network exposure, and a real
  WormWire health request. Text `PING` is not a WormWire health check.
- Review npm package contents, license, access level, and exports with a dry run
  before explicitly authorizing publication.

## Final decision

Record the source SHA, dependency SHAs, test results, secret-scan scope and result,
remaining limitations, and the owner's disclosure decision. Change visibility
only after the blockers are resolved and the owner authorizes publication.
