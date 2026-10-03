# wormdb.dev

The public site for WormDB. Plain static files, zero build step, zero external
requests — fonts are self-hosted in `assets/fonts/`.

## Design: "the paper trail"

The site is styled as a continuous-form line-printer printout — the medium
mainframes used for audit logs precisely because paper is write-once:

- **Greenbar scan bands + sprocket rails** — the page is a sheet of fanfold stock.
- **Three inks**: ribbon black (text), ribbon red (WORM violations, negative
  amounts), ledger green (OK / alive / recorded). Stamp blue for links and
  annotations.
- **Type**: Workbench (dot-matrix display), IBM Plex Sans (body),
  IBM Plex Mono (data). Latin subsets, self-hosted.
- Sections are numbered printout pages (`PAGE 002 · JOB CONTROL`), separated by
  perforation tears. The footer is the `*** END OF JOB ***` trailer page.
- The hero "prints" the WORM-violation demo line by line, like a line printer.
- **Dark mode is the microfiche archive copy** of the same printout: silver
  emulsion on film base, backlit sprocket holes, and the header switches to
  `FICHE ARCHIVE COPY`. It follows the system preference; the `VIEW: PAPER /
  FICHE` nav button overrides it (persisted in `localStorage`).

## Editing

Everything lives in `index.html` (inline CSS/JS). `og.html` is the source for
`og.png` (1200×630) — after editing it, re-render with any browser at that
viewport and replace `og.png`.

Keep the positioning and localhost quick start aligned with the root README.
The navigation and footer link to Meshrooms. Link benchmark source and measured
results with their conditions; avoid fixed performance or binary-size claims
without evidence for the published build. The hero session is illustrative.

After edits, check both themes at desktop and mobile widths, section links,
copy buttons, and the share image. Content and links should remain usable
without JavaScript. The site has no build step.

## Deploy

`.github/workflows/deploy.yml` publishes this directory to GitHub Pages on
every push to `main` that touches `website/`. `CNAME` pins the custom domain
`wormdb.dev` — DNS must point there (A/ALIAS to GitHub Pages, or CNAME
`igorls.github.io` for the apex via your DNS provider's flattening).
