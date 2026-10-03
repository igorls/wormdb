# REVIEW-014: Public release preparation

- Date: 2026-09-21
- Work package: [WP-014](../work-packages/WP-014-public-release-preparation.md)
- Reviewer: Codex
- Outcome: Approved for source publication preparation
- Delivery: [PR #94](https://github.com/igorls/wormdb/pull/94)

## Scope and decisions

The owner approved MIT for first-party code, the exact security policy, and
publication of the existing repository and history. The changes add contribution
guidance, accurate first-run instructions, dependency notices, native Linux and
Windows CI, and secret scanning. Existing runtime and binary-release work is
outside this package.

## Validation evidence

The integrated candidate at `95ef912` passed 298 Zig tests, the ReleaseSmall
build, 65 Bun tests, and the documentation build. A live standalone check verified
the process-owned loopback listener, SET/GET, WORM overwrite/delete rejection,
STATUS, and data retention after forced restart through WAL recovery. Workflow
and issue-form YAML, changed local Markdown links, and `git diff --check` passed.

[Hosted CI](https://github.com/igorls/wormdb/actions/runs/35549390491) passed the
Linux and Windows test/build jobs and Bun tests. The
[hosted secret scan](https://github.com/igorls/wormdb/actions/runs/35549390558)
passed. The separate pre-publication scan covered the source tree and fetched
remote branches, tags, and PR heads with the two documented, narrow fixture/demo
exceptions. Sensitive scan evidence stays outside tracked documentation.

The review follow-up aligns the Bun lockfile's workspace name with the existing
package manifest. Gitleaks 8.30.1 automatically reads the root `.gitleaks.toml`;
the hosted command uses that policy. The final PR commit must retain all four
passing required checks before merge.

## Publication boundary

Dependabot alerts and a main-branch rule requiring Linux, Windows, Bun, and
Gitleaks checks are enabled. Administrator override remains available; no second
reviewer is required. Workflow tokens default to read-only.

After changing visibility, enable private vulnerability reporting, verify secret
scanning and push protection, require workflow approval for outside contributors,
and verify an anonymous checkout. Binary, container, and npm publication require
their own validation and authorization. This review does not certify production
readiness or every historical guide.
