# WP-014: Public release preparation

## Scope

Prepare the engine repository for public review: accurate onboarding and support
boundaries, licensing and dependency notices, contribution templates, CI coverage,
and removal of generated artifacts from the source tree. Preserve existing runtime
and release work. Repository visibility, history rewriting, credential rotation,
package publication, and deployment are separate maintainer actions.

## Acceptance

- Build and client instructions match the current implementation.
- License declarations agree with the owner's selected license.
- Contribution guidance and issue/PR templates are present.
- A security reporting policy is reviewed by the owner before adoption.
- Generated caches, screenshots, credentials, and runtime data are excluded.
- CI checks the engine on Linux/Windows and the Bun client.
- Scan current source and all fetched remote history, including PR heads, for
  secrets; keep sensitive evidence outside tracked documentation.
- Record unresolved publication blockers; preparation does not imply production
  qualification or authorization to change visibility.

## Validation

- `zig build test --summary all`
- `zig build -Doptimize=ReleaseSmall`
- `cd apps/bun && bun install --frozen-lockfile && bun test`
- `bun install --frozen-lockfile && bun run docs:build`
- Exercise the documented local configuration with a live server and Bun client.
- Validate workflow/template YAML and changed Markdown links.
- `git diff --check`

Linux CI and an anonymous checkout of the exact release commit remain required
before publication; Windows results alone do not establish Linux support.
