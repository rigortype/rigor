# rigor-playground

Browser-based Rigor playground — a local Rack/Puma server that
serves the CodeMirror 6 frontend and exposes the `/check`,
`/annotate-lines`, and `/type-of` JSON endpoints.

Implements [ADR-29](../../docs/adr/29-browser-playground.md).

## Usage

```sh
gem install rigor-playground
rigor playground            # opens http://localhost:9393
rigor playground --port=4000
rigor playground --no-open  # start server without opening browser
```

## Deployment (Fly.io)

See [`fly.toml`](fly.toml) and [`Dockerfile`](Dockerfile). The
build context must be the rigor repo root:

```sh
docker build -f plugins/rigor-playground/Dockerfile -t rigor-playground .
```

Or from the repo root:

```sh
fly deploy --remote-only --dockerfile plugins/rigor-playground/Dockerfile
```

## Frontend (Cloudflare Pages)

See [`frontend/README.md`](frontend/README.md).

## License

MPL-2.0 — same as the parent `rigortype` gem.
