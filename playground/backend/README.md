# playground/backend — Rigor playground backend

The Rack/Puma backend behind the browser playground (frontend
lives at [`../frontend/`](../frontend/)). A thin layer around
the existing `Rigor::CLI` commands; each HTTP request writes
its source body to a per-request `Tempfile` and runs
`rigor check` / `rigor annotate` / `rigor type-of` against it
in-process. No subprocess, no shell.

ADR references:

- [ADR-29](../../docs/adr/29-browser-playground.md) — the
  overall playground design and the slice 1 contract.
- [ADR-32](../../docs/adr/32-rbs-inline-comment-ingestion.md)
  — the inline-RBS plugin the playground pre-loads.

## Endpoints

| Method | Path | Purpose |
| --- | --- | --- |
| `POST` | `/check` | `rigor check --format=json` against the supplied source. Returns `{ success, error_count, diagnostics }`. Diagnostic `path:` fields are rewritten to the virtual label `<playground>` so the tmpfile path never leaks to the client. |
| `POST` | `/annotate` | `rigor annotate` against the supplied source. Returns `{ annotated }` — the source with `#=> dump_type: <type>` suffix comments. |
| `POST` | `/annotate-lines` | Same analysis as `/annotate` but reshaped: returns `{ annotations: { "1": "...", ... } }` keyed by 1-based line number, for clients that want to render inlay-hint-style overlays without re-parsing the comment grammar. |
| `POST` | `/type-of` | `rigor type-of --format=json FILE:LINE:COL`. Body: `{ source, line, column }`. Returns the JSON shape `rigor type-of` emits, or 422 when the position has no resolvable type. |
| `GET` | `/` | Serves the static frontend's `index.html`. |
| `OPTIONS` | (any) | CORS preflight — `Access-Control-Allow-Origin: *` per ADR-29 WD1. |

Every JSON endpoint enforces a 64 KB source-body cap (ADR-29
WD4); oversized requests return `413`.

## Pre-loaded plugins

Per the [ADR-29 WD4 amendment (2026-05-25)](../../docs/adr/29-browser-playground.md#wd4--backend-sandbox-and-request-isolation),
the backend's [`.rigor.yml`](./.rigor.yml) pre-loads
`rigor-rbs-inline` with `require_magic_comment: false`
([ADR-32 WD10](../../docs/adr/32-rbs-inline-comment-ingestion.md#wd10--host-context-override-require_magic_comment-plugin-config)).
Any pasted snippet carrying `# @rbs name: T`-shaped comments
is analysed as inline-RBS from the first request — users do
not need to type `# rbs_inline: enabled`.

## Local development

```sh
cd playground/backend
bundle install              # one-time
bundle exec puma -C puma.rb  # serves on http://localhost:9292
```

Then in another terminal:

```sh
curl -X POST http://localhost:9292/check \
  -H 'content-type: application/json' \
  -d '{"source":"class AscDesc\n  # @rbs asc_or_desc: :asc | :desc\n  def ascdesc(asc_or_desc); asc_or_desc; end\nend\nAscDesc.new.ascdesc(:bad)\n"}'
```

Expected response (formatted for readability):

```json
{
  "success": false,
  "error_count": 1,
  "diagnostics": [
    {
      "path": "<playground>",
      "line": 5,
      "column": 21,
      "severity": "error",
      "rule": "call.argument-type-mismatch",
      "source_family": "builtin",
      "message": "argument type mismatch at parameter `asc_or_desc' of `ascdesc' on AscDesc: expected :asc | :desc, got :bad"
    }
  ]
}
```

## Spec suite

```sh
cd playground/backend
bundle exec rspec spec/
```

The specs run against an in-process `Playground::App` via
`Rack::Test::Methods`; no Puma boot needed. They are
deliberately separate from the main Rigor spec suite (the
backend has its own Gemfile / lockfile) and are NOT part of
`make verify` at the project root.

## Deployment (deferred)

ADR-29 WD5 commits the backend to Fly.io free-tier as the
production deployment target. The actual `fly.toml` +
`Dockerfile` artefacts are deferred to a follow-up — the
slice 1 Rack-app contract this directory delivers is
deployable to any process supervisor that can `bundle exec
puma -C puma.rb`. See ADR-29 § "Implementation slices" for
the deferred deploy work.

## License

[MPL-2.0](../../LICENSE), same as the parent project.
