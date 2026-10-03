# WP-015: Public launch website and README

## Scope

Refresh the public website and root README around clear positioning, a working
localhost quick start, and links to the public source. Link Meshrooms from the
main site's navigation and footer. Preserve the existing paper/microfiche design.
Runtime changes, new benchmark results, package releases, and historical guide
rewrites are outside this package.

## Acceptance

- The website and README describe the current engine without unqualified size,
  throughput, encryption, or transaction claims.
- A new user can build from source and demonstrate a WORM record with the Bun
  client; the README also includes a working TypeScript example.
- GitHub, documentation, contribution, security, and Meshrooms links are clear.
- Navigation and quick-start controls work on desktop and small screens in both
  themes. The share image matches the updated positioning.

## Validation

- `zig build -Doptimize=ReleaseSmall -Dcrypto-backend=std`
- Exercise SET/GET, WORM overwrite/delete rejection, STATUS, and the exact README
  TypeScript example against a fresh local server using `examples/local.json`.
- Check local assets, HTML anchors, Markdown/source links, JSON-LD, and inline
  JavaScript syntax. Verify the Meshrooms destination.
- Browser review of desktop/mobile layouts, theme switch, section navigation,
  copy feedback, Meshrooms navigation, console errors, and the 1200x630 image.
- `git diff --check`
- All required PR checks must pass before merge. Verify the Pages deployment and
  served content afterward.
