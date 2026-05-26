# plugins/rigor-playground/frontend — Rigor playground frontend

The static frontend for the browser playground (backend lives
at [`../`](../), i.e. `plugins/rigor-playground/`). A single
`index.html` that imports [CodeMirror 6](https://codemirror.net/)
from [esm.sh](https://esm.sh/) at runtime, applies design-system
styling, and talks to the backend over `/check`,
`/annotate-lines`, and eventually `/type-of` (slice 4,
demand-driven).

ADR references:

- [ADR-29](../../../docs/adr/29-browser-playground.md) — the
  overall playground design.
- [ADR-32](../../../docs/adr/32-rbs-inline-comment-ingestion.md)
  — the inline-RBS plugin the backend pre-loads, showcased
  in the seeded SAMPLE.

## What it does

- CodeMirror 6 editor with Ruby syntax highlighting + the
  lint gutter.
- A 600 ms debounced `POST /check` after each keystroke,
  rendering returned diagnostics as wavy underlines and an
  expandable list panel.
- A "Show types" / "Hide types" toggle that overlays
  per-expression type annotations via `POST /annotate-lines`.
- Dark / light / auto theme switching.

## Local development

The backend at [`../`](../) serves the frontend on the same
origin (`Rigor::Playground::App` falls back to serving
`index.html` on `GET /`). So:

```sh
cd plugins/rigor-playground
bundle install              # one-time
bundle exec puma -C puma.rb  # serves on http://localhost:9292
```

Then open `http://localhost:9292` in a browser.

For frontend-only iteration (no backend), any static file
server works (`python3 -m http.server`, `npx serve .`,
`miniserve`, etc.), but `POST /check` will fail until the
backend is wired up via one of the deployment options below.

## Cloudflare Pages deployment (ADR-29 WD1)

The directory is deploy-ready for Cloudflare Pages: drag-and-
drop it into the dashboard or use Wrangler:

```sh
cd plugins/rigor-playground/frontend
npx wrangler pages deploy . --project-name=rigor-playground
```

`_headers` ships a security-header baseline (CSP, XFO,
Referrer-Policy). `_redirects` documents the same-origin /
cross-origin choice — same-origin via custom-domain routing
is the recommended path.

### Routing the backend

The frontend posts to relative URLs (`const API = ""` in
`index.html`), so the same origin must serve both frontend
and backend in production. Choose one:

| Path | How |
| --- | --- |
| **Same-origin (recommended)** | Set up a custom domain on the Pages project; configure a Cloudflare Rule (Workers / Load Balancer / Page Rules) routing `/check`, `/annotate*`, `/type-of` to the Fly.io app's host. The frontend stays unchanged. |
| **Cross-origin** | Frontend on `<app>.pages.dev`, backend on `<app>.fly.dev`. Change the `API` constant in `index.html` to the absolute backend URL (e.g. read from a `<meta name="rigor-api" content="...">` tag injected at build time). The backend already serves the necessary CORS preflight (see `lib/rigor/playground/app.rb`'s `CORS_HEADERS`). |

## License

[MPL-2.0](../../../LICENSE), same as the parent project.
