# REVIEW-015: Public launch website and README

- Date: 2026-09-20
- Work package: [WP-015](../work-packages/WP-015-public-launch-site.md)
- Reviewer: Codex
- Outcome: Approved for delivery after required hosted checks

## Change

The README and website now share a source-build and localhost onboarding path.
The copy describes write-once keys, native procedures, vector search, and the
current deployment boundaries. GitHub entry points are prominent, and Meshrooms
is linked from the site's navigation and footer and from the README.

The existing paper/microfiche design is retained. Mobile navigation wraps so
Meshrooms remains visible, code blocks use their available width, small functional
labels are enlarged, and copy controls announce their result. The share image was
regenerated from its HTML source. Unsupported headline benchmark and binary-size
figures were replaced with feature explanations and benchmark-source links.

## Evidence

- Windows with Zig 0.16.0 and Bun 1.4.2: the documented ReleaseSmall/std-crypto
  build passed with the pinned MeshGuard dependency.
- Fresh process-owned localhost server: SET returned OK, GET returned ready,
  overwrite and delete each returned the documented WORM error with exit code 1,
  and STATUS reported one key. The exact README TypeScript snippet printed hello.
  Only the data directory was overridden to isolate validation data.
- HTML IDs/anchors, local assets, changed Markdown and GitHub source links,
  JSON-LD, inline JavaScript syntax, and both Meshrooms links passed checks.
- Browser review covered desktop and 390/320-pixel mobile widths, light/dark
  themes, section navigation, successful copy feedback, and navigation to the
  Meshrooms landing page. No page-level horizontal overflow or browser console
  warnings/errors were observed in the final local checks.
- The updated 1200x630 share image was visually inspected. `git diff --check`
  passed. Impeccable's single detector pass informed the functional text sizing;
  the incumbent printout bands, rails, and page labels remain intentional.

This package changes documentation and static presentation. It does not qualify
cluster operation, container distribution, or production performance. Required
hosted checks and post-merge Pages verification gate publication.
