# ADR-29 — Browser playground

Status: **Accepted, 2026-05-23; implemented in v0.1.10–0.1.11.**

Records the decision to build a browser-based Rigor playground — a
text editor that shows real-time diagnostics and `annotate`-style
type comments — and how it should be hosted. Two approaches were
evaluated: a fully in-browser WASM runtime (`ruby.wasm`) and a
server-side API fronted by a static site. The **server-side API** is
the accepted short-term path; a concrete set of gating conditions
(WD6) defines when migration to in-browser WASM becomes viable. The
server-side API + static frontend shipped as the
`plugins/rigor-playground/` plugin and the `rigor playground`
command (local serving, with `rigor-rbs-inline` loaded at
`require_magic_comment: false` per WD4 / ADR-32 WD10); deploying it
to Cloudflare Pages / Fly.io is an ops step, and the ruby.wasm
migration stays gated on WD6.

**Amended 2026-05-25**: WD4 flips the default plugin set from
empty to `rigor-rbs-inline` enabled (per [ADR-32](32-rbs-inline-comment-ingestion.md)
WD10, with `require_magic_comment: false`) so that pasted
snippets carrying `# @rbs`-shaped comments are analysed as
inline-RBS from the first request, with no user-side
configuration.

**Amended 2026-05-29**: per [ADR-34](34-toplevel-unresolved-self-call-default.md)
WD7, the per-request sandbox sets `severity_profile: strict` (or
the equivalent per-rule override) so the new
`call.unresolved-toplevel` rule fires on pasted snippets like
`foo 1`. Inheriting the `balanced` default would map the rule to
`:warning` — surfacing it, but de-emphasising exactly the example
most likely to be the user's first interaction with the
Playground.

**Re-evaluated 2026-06-14**: the Option-A blockers below were
assessed on 2026-05-23; the `ruby.wasm` ecosystem has since moved.
`ruby/ruby.wasm` now publishes Ruby 4.0 builds (the
`@ruby/4.0-wasm-wasi` package), and `rbwasm`'s from-source build
links a bundle's gem C extensions — so the `prism`/`rbs` blocker is
now a *build-and-verify* task, not a missing-upstream one. WD6 is
revised with per-condition status; **WD8** records the concrete
`rbwasm` build pipeline and **WD9** the in-browser transport, both
implemented as the `plugins/rigor-playground/wasm/` scaffolding.
Crucially, the [try.ruby-lang.org](https://try.ruby-lang.org/playground/)
hosting model (the wasm module served as a *static asset*)
sidesteps blocker 4 entirely: the ~1 MB cap is a Cloudflare
*Workers* script limit, not a Pages / static-CDN one — a 15 MB+
wasm is just a cached file there, exactly as try.ruby ships it.
This re-evaluation does **not** flip the production default: Option
B remains the deployed backend until WD6 conditions ② and ③ are
verified green. It moves the open work from "wait for upstream" to
"run the gating `rbwasm` build spike."

## Context

A publicly accessible playground lets users try Rigor against an
arbitrary snippet without installing anything. The target experience
is a Monaco- or CodeMirror-style editor on the left; on the right
(or inline as type comments) the output of `rigor annotate` and the
diagnostic stream from `rigor check --format json`, updating on each
keystroke or debounce tick.

The hosting goal is **Cloudflare Workers / Pages**: a static frontend
with no origin server to operate, zero per-request infrastructure
cost, and global low-latency delivery. That goal makes the runtime
choice load-bearing — whether the Rigor engine runs in the user's
browser (WASM) or on a backend service determines whether the fully-static target is achievable.

### Option A — Full `ruby.wasm` (in-browser WASM)

`ruby.wasm` embeds a Ruby interpreter compiled to WebAssembly. The
frontend page ships the Ruby runtime + all gem sources + Rigor's YAML
data catalogs, and the analysis runs entirely in the browser — no
network round-trip per keystroke, no backend to operate.

**Blockers at the time of this ADR (2026-05-23):**

1. **No Ruby 4.0 WASM build.** `ruby.wasm` ships production builds for
   the Ruby 3.x line. Rigor's gemspec pins `required_ruby_version =
   [">= 4.0.0", "< 4.1"]` (ADR-27 WD7 — Rigor stays latest-Ruby-only
   because `ruby/rbs` tracks the latest Ruby and ADR-15's Ractor model
   requires recent-runtime features). Relaxing this pin conflicts with
   the rationale behind WD7 and is therefore not a viable workaround.
   A Ruby 4.0 WASM target does not yet exist; when it ships it will
   likely arrive as an experimental build before becoming production-
   grade.

2. **C-extension dependencies.** Both `prism` (the parser Rigor
   depends on) and `rbs` (the type environment layer) carry C
   extensions. These are absent from the standard `ruby.wasm` runtime
   bundle. Building them for WASM requires Emscripten toolchains and
   patch work not currently maintained by either upstream project
   specifically for the `ruby.wasm` target. This is an engineering
   project in its own right, not a configuration choice.

3. **`flock` in the cache layer.** `lib/rigor/cache/store.rb` acquires
   advisory locks with `File::LOCK_EX` (`flock(2)`) to guard atomic
   cache writes (ADR-6). `flock` is not supported in the WASM sandbox
   (WASI/Emscripten virtual filesystems do not implement POSIX file
   locking). A playground can stub the cache to no-op, but this
   requires a dedicated code path or a build-time abstraction layer.

4. **Cloudflare Workers bundle size.** The ruby.wasm runtime binary
   is approximately 15 MB; adding gem sources and Rigor's 740 KB of
   YAML builtin catalogs pushes the total well above the 1 MB Worker
   script limit (the paid plan raises the WASM module limit to 25 MB,
   but the overall bundle — script + WASM + assets — remains a tight
   fit and is not a free-tier option).

5. **Ractor (ADR-15).** The fork-based worker pool that shipped in
   v0.1.8 is disabled in WASM; a playground analyzing a single snippet
   does not need concurrency, so this is addressable with a
   single-threaded execution path, but it adds a conditional code path
   to maintain.

**Long-term upside.** Option A remains the ideal end state: zero
per-request server cost, no latency from a network round-trip, and no
backend to operate or secure. The blockers are all time-bounded — Ruby
4.0 WASM will eventually ship; `prism` already has a JavaScript WASM
build (used by web-based editors) and an official Ruby WASM build is a
natural follow-on; Cloudflare's bundle limit is less relevant once the
ruby.wasm team ships a more compact runtime. WD6 records the gating
conditions.

### Option B — Server-side API + static frontend

The frontend is a static HTML/JS page (Cloudflare Pages) containing
the editor and rendering logic. Analysis requests are sent to a small
HTTP API that shells out to `rigor check --format json` and `rigor
annotate`, returning JSON. The backend is deployed on a separate
hosting service (Fly.io, Railway, or similar) and kept isolated from
the static frontend.

**Advantages:**
- Works today with the existing CLI and its JSON output contract.
- No changes to the Rigor engine — the API is a thin shim over the
  same binary users run locally.
- The frontend on Cloudflare Pages is fully static; only the API
  server runs compute.
- Per-request isolation is trivially enforced: each request writes a
  `Tempfile`, runs analysis, and discards it.

**Challenges:**
- Not fully static — a small API server must be operated.
- Network round-trip latency per analysis request (acceptable for a
  debounce-driven playground; target < 500 ms for a 100-line snippet
  on a warmed server).
- Requires security hardening: input size caps, request timeouts,
  rate limiting, and sandboxing to prevent malicious input from
  affecting the host.

### Option C — Cloudflare Workers as proxy

A Cloudflare Worker could accept the request and forward it to a
backend. This adds an indirection layer without eliminating the
backend. It is not evaluated further; if a backend is necessary,
routing it through a Worker adds complexity with no structural
benefit. (Workers could eventually host a WASM build — Option A
via Workers — but that inherits Option A's blockers.)

## Decision

**Adopt Option B (server-side API + static frontend) as the short-term
implementation.** Option A is the long-term target; WD6 defines the
three conditions that must all hold before migration is warranted.

The playground exposes three endpoints wrapping existing CLI commands:

| Endpoint | CLI equivalent | Response |
| --- | --- | --- |
| `POST /check` | `rigor check --format json` | JSON diagnostic array |
| `POST /annotate` | `rigor annotate` | annotated source text |
| `POST /annotate-lines` | `rigor annotate` (reshape) | `{ line_number → type }` map |
| `POST /type-of` | `rigor type-of` | type string for a position |

The frontend is a static Cloudflare Pages site. The backend is a
minimal Rack application running inside the same `rigortype` Ruby
process on Fly.io (or equivalent), with one worker per Puma thread.

## Working decisions

### WD1 — Frontend on Cloudflare Pages; backend as a separate service

The static frontend (HTML + JS + editor bundle) is deployed to
Cloudflare Pages. No server-side rendering, no Worker compute for the
frontend itself.

The API backend is a separate deployment (Fly.io free tier or
Railway). It runs Ruby 4.0 + `rigortype` + a thin Rack/Puma layer.
CORS headers on the backend allow cross-origin requests from the Pages
domain.

The frontend and backend are co-located in
`plugins/rigor-playground/` — `frontend/` for the static assets
and the gem root for the Rack/Puma backend. They are deployed
independently; the frontend's `RIGOR_API_URL` is injected at build
time as an environment variable.

### WD2 — API contract

All endpoints accept `application/json` with UTF-8 source in the
request body. All responses are `application/json`.

**`POST /check`**

Request:
```json
{ "source": "...", "config": {} }
```

Response (mirrors `rigor check --format json` → `Result#to_h`):
```json
{
  "diagnostics": [
    {
      "path": "<playground>",
      "line": 3,
      "column": 5,
      "rule": "call.undefined-method",
      "message": "...",
      "severity": "error"
    }
  ],
  "error_count": 1,
  "success": false
}
```

**`POST /annotate`**

Request: `{ "source": "..." }`
Response: `{ "annotated": "# annotated source with type comments..." }`

**`POST /annotate-lines`** (amendment 2026-05-25)

Same input as `/annotate`. Returns the same analysis
reshaped for clients (the slice-3 frontend's "Show types"
toggle) that want to render type annotations as inlay-hint-
style overlays without reparsing the comment grammar:

Request: `{ "source": "..." }`
Response: `{ "annotations": { "1": "String", "5": ":asc | :desc" } }`

The map is keyed by 1-based line number (JSON object keys
are strings); the value is the inferred type's short
description. `/annotate-lines` invokes `rigor annotate
--format json`, which emits this map straight from the
engine's line-type data — no `#=>`-comment text is rendered
or reparsed (the earlier string-parsing approach broke
silently when the comment spelling changed). Lines without
an annotation are absent from the map.

**`POST /type-of`**

Request: `{ "source": "...", "line": 5, "column": 12 }`
Response: `{ "type": "String" }`

The `config` field in `/check` is initially ignored; it is reserved
for a future slice that exposes a subset of `.rigor.yml` options (e.g.
`severity_profile:`) to the playground UI.

### WD3 — Editor: CodeMirror 6

CodeMirror 6 is the frontend editor, not Monaco. Both support Ruby
syntax highlighting; CodeMirror 6 is chosen because:

- **Bundle size.** A minimal CodeMirror 6 bundle with Ruby language
  support is ~100 KB gzipped. Monaco's full bundle is ~2 MB gzipped;
  its Ruby support requires a community package, and its language
  server integration expects a Worker-based language server process
  (unnecessary here — diagnostics come from the Rigor API).
- **Embeddability.** CodeMirror 6 is designed as a library, making it
  straightforward to add squiggly-underline decorations driven by the
  `/check` response and inline type-comment annotations from
  `/annotate`.
- **No build-time compilation needed for the editor itself.** Monaco
  requires a separate copy of `monaco-editor` in the asset pipeline;
  CodeMirror 6 packages integrate cleanly with standard bundlers (or
  CDN imports for a no-bundler setup).

Diagnostics from `/check` are rendered as CodeMirror lint markers
(red underlines + hover tooltips). Type annotations from `/annotate`
are rendered as a diff-style "ghost text" overlay toggled by a button.

### WD4 — Backend sandbox and request isolation

Each HTTP request is handled in isolation:

1. Source code is written to a `Tempfile` (`/tmp/rigor-playground-*.rb`)
   created at request start and deleted in an `ensure` block.
2. `Rigor::Analysis::Runner` (or equivalent entry point) is invoked
   directly in-process against that file — no shell exec, so no
   injection risk from the path.
3. The persistent on-disk cache (ADR-6) is **disabled** for the
   playground backend. Each request builds its RBS environment from
   scratch. This avoids cross-request cache poisoning and removes the
   `flock` dependency; the latency cost (RBS environment boot ~100 ms)
   is acceptable for a web playground.
4. A hard 10-second timeout per request terminates runaway inference
   (a deliberately adversarial snippet could trigger expensive recursion).
5. Input is capped at **64 KB** of source text. The UI enforces this
   client-side; the backend enforces it server-side with a 413 response.

The backend loads **`rigor-rbs-inline`** by default (per
[ADR-32](32-rbs-inline-comment-ingestion.md) WD10) so that a
pasted snippet carrying `# @rbs`-shaped comments is analysed as
inline-RBS the moment the page loads — no plugin configuration
to discover, no `# rbs_inline: enabled` magic comment to type.
The plugin's `require_magic_comment:` config key is set to
`false` for the same reason: the playground is a single-buffer
exploration surface, so the multi-file-project friction WD2 of
ADR-32 mitigates does not exist.

The playground's `.rigor.yml` (embedded in the backend) is a
fixed minimal config:

```yaml
plugins:
  - id: rigor-rbs-inline
    config:
      require_magic_comment: false
severity_profile: strict
```

No other plugins are loaded by default. A future slice may
expose a plugin-picker UI for the user to toggle additional
plugins per request; ADR-29 v1 keeps the surface narrow.

### WD5 — Backend deployment: Fly.io free-tier (single machine)

The backend is deployed as a single Fly.io Machine (shared-CPU-1x,
256 MB RAM). A single Puma worker with 2 threads is sufficient for the
expected playground traffic. The Fly.io free allowance covers this
configuration without cost.

If traffic warrants scaling, Fly.io autoscaling or a move to a
different host is straightforward — the backend is a plain Rack app
with no stateful coupling to the host. The backend deployment manifest
(`plugins/rigor-playground/fly.toml`) is committed to the repository.

Rate limiting (50 requests/minute per IP) is enforced at the Fly.io
proxy layer via `fly.toml` `http_service.rate_limiting`. A global
concurrency limit of 4 in-flight requests prevents a burst from
monopolizing the single machine's CPU during the RBS environment boot.

### WD6 — ruby.wasm migration gate (three conditions; status 2026-06-14)

Migration from Option B to Option A (fully in-browser WASM) requires
**all three** of the following conditions to hold simultaneously. The
status line under each records the 2026-06-14 re-evaluation.

1. **An official Ruby 4.0 WASM build is production-grade.** "Production-
   grade" means: published under `ruby/ruby.wasm`, passing the upstream
   test suite, and available from a CDN or as a stable npm package. An
   experimental or nightly build does not satisfy this condition.
   - **Status: MET in practice.** `ruby/ruby.wasm` ships Ruby 4.0
     builds (`ruby-4.0.0` artifacts; the `@ruby/4.0-wasm-wasi` npm
     package). The one caveat is wording: `ruby.wasm` publishes under
     dated *pre-release* tags by convention rather than a "stable"
     release — but these are the same builds `try.ruby-lang.org` ships
     in production, so the spirit (not nightly/experimental,
     CDN-installable) holds.

2. **`prism` and `rbs` WASM packages are available.** Both gems must
   ship official WASM builds (either bundled in the ruby.wasm runtime
   or as separately loadable `.wasm` modules), passing their own test
   suites under the WASM target.
   - **Status: MET — full build green 2026-06-14.** `prism` is CRuby's
     own parser and ships inside the interpreter wasm. The WD8 `rbwasm`
     from-source build compiles and statically links `prism`, `rbs`,
     **and** `psych` against wasi-sdk-24.0 with zero linker errors,
     producing a 69.9 MB `rigor-playground.wasm`. The initial spike hit
     one wiring gap — `psych`'s `-lyaml` did not reach the final static
     link even though `libyaml.a` was built and `--with-libyaml-dir`
     passed — fixed by a confined build patch
     ([`wasm/build_patches/libyaml_link.rb`](../../plugins/rigor-playground/wasm/build_patches/libyaml_link.rb))
     that forces `libyaml.a` onto the crossruby XLDFLAGS the way
     `ruby_wasm` already does for wasi-vfs. The C-extension risk this
     condition was about is fully cleared; what remains is WD6 ③
     (runtime correctness under the sandbox).

3. **Rigor's own test suite passes under WASM.** A CI job running
   `make test` inside the ruby.wasm runtime (stubbing `flock` and the
   fork-based worker pool) must pass without test count regressions.
   This gate catches engine code that silently assumes POSIX semantics
   absent from the WASM sandbox.
   - **Status: MET for the playground — runtime verified 2026-06-14.**
     The adapter runs end-to-end in the `@ruby/wasm-wasi` VM and emits
     **diagnostics byte-identical to the Rack backend** (the
     `nil.upcase` undefined-method *and* the `rigor-rbs-inline`
     argument-type-mismatch), confirmed headlessly by `rake smoke`
     ([`wasm/smoke.mjs`](../../plugins/rigor-playground/wasm/smoke.mjs),
     which replicates the browser `DefaultRubyVM` WASI). Four
     wasm-runtime integration fixes were needed and are in place:
     (a) `gem "js"` in the bundle — `DefaultRubyVM` requires it to
     instantiate; (b) `require "rubygems"` in the adapter — ruby.wasm
     runs rubygems-disabled, and without it RBS's loader silently builds
     an **empty** type universe (0 classes → nothing flagged); now 334+
     classes load; (c) `require "/bundle/setup"` (ruby_wasm's load-path
     setup) not `bundler/setup` (which hits the disabled rubygems path);
     (d) a writable working dir — WASI mounts the packed gem/config tree
     read-only, so the adapter stages `/work` (the browser VM's in-memory
     `/`; an explicit preopen under Node) for the cwd-relative cache +
     per-request buffer. The `flock`/fork concerns held as predicted
     (shimmed / self-degrading). A full `make test` under wasm remains a
     larger, separate exercise, but the playground's runtime correctness
     is established.

Until all three conditions hold, the server-side API (Option B) is the
production backend. The next concrete step is no longer "wait for
upstream" — it is to run the WD8 `rbwasm` build and resolve condition
② (then ③).

### WD7 — `rigor annotate` output in the playground

`rigor annotate` today emits source text with type comments appended as
`# :: Type` annotations (one per expression line). The playground
renders this as a toggleable "annotated view" — clicking "Show types"
replaces the editor content with the annotated source; clicking "Edit"
restores the original. The annotated view is read-only; attempting to
edit it switches back to edit mode automatically.

A future slice may render the type annotations as CodeMirror inlay
hints (inline after the expression, styled as ghost text) rather than
replacing the editor content — this is deferred until the CodeMirror
inlay hint API stabilises in the ecosystem and the playground has
real-user feedback on whether the toggle UX is sufficient.

### WD8 — `rbwasm` build pipeline (added 2026-06-14)

The in-browser build lives in
[`plugins/rigor-playground/wasm/`](../../plugins/rigor-playground/wasm/)
and is produced by `rbwasm` (the `ruby_wasm` gem) over a dedicated
`Gemfile` containing the `rigortype` path gem, `rigor-rbs-inline`, and
`rbs-inline` — the playground's exact runtime set. Because `rbs` carries
a C extension, the build uses `rbwasm`'s **from-source** path
(`--build-options`/wasi-sdk), which compiles and statically links
`prism` and `rbs` into a single `.wasm`. This is the load-bearing
property that distinguishes the build from a prebuilt + pure-ruby-gem
pack: it is the only route that satisfies WD6 ②.

Packing decisions:

- **Catalog + signature data ride along with the path gem.** The
  `rigortype` gemspec already lists `data/builtins/**/*.yml` and
  `sig/**/*.rbs` in `spec.files`, so `rbwasm` packs them into the gem's
  VFS tree alongside `lib/`; the engine's `__dir__`-relative reads
  resolve unchanged. (The build doc records an explicit `--dir` fallback
  in case a `ruby_wasm` version packs only `require_paths`.)
- **The cache is off, so `flock` is never reached.** The in-VM adapter
  invokes `rigor check --format=json --no-cache` (WD4 already mandates a
  cacheless playground), which removes the single POSIX-locking
  dependency without touching engine code.
- **Config travels as a packed `.rigor.yml`.** A copy of the
  playground config (loads `rigor-rbs-inline`, `severity_profile:
  strict`) is mapped into the VFS at the adapter's working directory so
  `Rigor::CLI.start`'s normal cwd discovery finds it — the same config
  surface the Rack backend relies on.
- **Contract fidelity by construction.** The adapter calls
  `Rigor::CLI.start(argv, out:, err:)` against `StringIO` buffers,
  byte-for-byte the same invocation as the backend's `run_cli`
  ([`app.rb`](../../plugins/rigor-playground/lib/rigor/playground/app.rb)).
  The WD2 JSON shapes are therefore identical between transports; only
  the bytes' origin (network vs in-VM) differs.

**Known v1 cost — per-call RBS env rebuild.** The CLI rebuilds the RBS
environment on every invocation, and with the disk cache off there is no
cross-call reuse. In wasm that boot is seconds, not the backend's
~100 ms. The optimisation is a persistent `Runner` that builds the env
once at page load and re-runs `run_source` per keystroke (the
`ProjectContext` env-once pattern used by the mutation harness); it is
deliberately out of the v1 scaffolding because it must re-derive the
CLI's plugin/config wiring without the CLI, and shipping a faithful
slow path first keeps the contract honest. Tracked as the WD8 perf
follow-up.

### WD9 — in-browser transport (added 2026-06-14)

The wasm frontend reuses the CodeMirror 6 editor, lint markers, type
overlay, and the WD2 JSON shapes verbatim; only the transport changes.
Where the backend page calls `fetch("/check", …)`, the wasm page sets
the request on a JS global and calls `vm.eval` against the adapter,
which reads it and returns the same JSON string. To keep the working
backend page (`frontend/index.html`) untouched, the wasm variant is a
**separate self-contained static page**
([`wasm/index.html`](../../plugins/rigor-playground/wasm/)) — the two
deployments (Pages-over-backend vs fully-static-wasm) stay independent,
matching WD1's independent-deploy stance. `vm.eval` runs Ruby
synchronously on the main thread; offloading analysis to a Web Worker
(so a slow keystroke does not block typing) is the WD9 responsiveness
follow-up, paired with WD8's persistent-env work.

### WD10 — deployment: docs-site sub-path, CI-built wasm on R2 (added 2026-06-14)

The playground ships at `https://rigor.typedduck.fail/playground/`, a
sub-path of the existing documentation site (Astro + Starlight on
Cloudflare Workers Static Assets, with `rigor` vendored as the
`upstream/rigor` submodule). Two facts of that site shape the design:

1. **The site CI is Node-only** (it never builds Ruby and deliberately
   avoids the heavy `references/*` submodules), so the wasm cannot be
   built there — it must arrive as a pre-built artifact.
2. **Cloudflare Workers Static Assets cap a single file at 25 MiB.** A
   from-source Ruby 4.0 wasm with the full stdlib + `data/builtins`
   plausibly exceeds that, so the binary is not a static asset.

Decision (chosen 2026-06-14):

- **The wasm is built in `rigor`'s own CI** (it has the toolchain
  context) on release / manual dispatch, and **published to Cloudflare
  R2** — keeping the multi-MB binary out of both the per-deploy Astro
  asset bundle and git history, and sidestepping the 25 MiB asset cap.
  The build is **version-pinned**: the wasm is produced from the same
  `rigor` commit the site's submodule points at, so the playground's
  behaviour matches the synced docs.
- **The frontend (`index.html`) is served as a static asset** under the
  site's `public/playground/`, copied from the submodule by a dedicated
  sync step (mirroring `sync-rigor-docs`). It is a full-bleed app, so it
  sits *outside* the Starlight doc chrome; a Starlight page links to it.
- **The page fetches the wasm from R2 by a configurable URL** (the page
  defaults to a same-origin relative path for local `rake serve`; the
  site sync step overrides it to the R2 URL via a `<meta>` tag). The
  transport indirection means the page is agnostic to whether the binary
  is an asset or R2-hosted. `WebAssembly.compileStreaming` requires
  HTTPS (Cloudflare provides it); a cross-origin R2 URL needs CORS on
  the bucket; the content-hashed wasm is served `immutable`.

Rejected: building in the site CI (no Ruby toolchain, would balloon
deploy time); committing the binary to either repo (large git blobs,
re-uploaded every deploy); a routing Worker to proxy R2 same-origin (the
site is assets-only with no `main` Worker — an R2 custom domain or
public URL is simpler than introducing Worker script logic).

## Implementation slices

No slice is scheduled by this ADR. The playground is a new parallel
track that does not block the `0.2.x` evaluation line.

| Slice | Scope |
| --- | --- |
| 1 | `plugins/rigor-playground/` — Rack application, `/check` endpoint, `Tempfile`-per-request isolation, 10 s timeout, 64 KB cap, fixed `.rigor.yml` (loads `rigor-rbs-inline` with `require_magic_comment: false` per WD4 / ADR-32 WD10). Deployed to Fly.io. Slice 1 is gated on ADR-32 slice 1 (the `source_rbs_synthesizer:` manifest field and the `rigor-rbs-inline` plugin existing). |
| 2 | `plugins/rigor-playground/frontend/` — CodeMirror 6, debounced `/check` calls, lint markers, Cloudflare Pages deploy config. |
| 3 | `/annotate` endpoint + frontend toggle view. |
| 4 | `/type-of` endpoint + frontend hover integration. |
| 5 | ruby.wasm migration (WD8/WD9/WD10). **Scaffolding + green build landed 2026-06-14** under `plugins/rigor-playground/wasm/` — `rbwasm` Gemfile + build task, in-VM CLI adapter, packed `.rigor.yml`, static wasm frontend. **`rake build` now succeeds**: `prism` + `rbs` + `psych` link under wasi-sdk-24.0 (WD6 ② MET, via the `libyaml_link` build patch), producing a **~70 MB** `rigor-playground.wasm` — which, being ≫ 25 MiB, confirms the WD10 R2 hosting path. **Runtime verified (WD6 ③)**: `rake smoke` runs the adapter in a browser-representative VM and reproduces the backend's diagnostics byte-for-byte (after four wasm integration fixes — `gem "js"`, `require "rubygems"`, `/bundle/setup`, writable `/work`). Remaining before shipping: R2 bucket + secrets, and the docs-site sync wiring. |
