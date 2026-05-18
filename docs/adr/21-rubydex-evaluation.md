# ADR-21 — Rubydex evaluation (foundation, backend, or tool?)

Status: **proposed (evaluation), 2026-05-19.** Records the
project's stance on Shopify's [`rubydex`][rubydex] across three
candidate roles — implementation foundation, swappable backend,
and supplementary tool — so future "should we just use rubydex?"
questions resolve against a written premise instead of being
re-litigated each cycle. **No core changes are scheduled** by
this ADR; it sets the discipline and the re-evaluation triggers.

[rubydex]: https://github.com/Shopify/rubydex

## Context

[Rubydex][rubydex] is a Shopify-maintained "high-performance
static analysis toolkit for the Ruby language" announced in the
[Rails-at-Scale blog post "One engine, many tools"][post]
(2026-05-12). Stack: a Cargo workspace of three crates plus a
thin Ruby gem (`>= 3.2.0`) that loads a C-ABI dylib via
`ext/rubydex/extconf.rb`. Parser: **Prism** (`ruby-prism 1.9.0`).
RBS parser: the Rust **`ruby-rbs`** crate, not the Ruby `rbs`
gem at runtime. License: MIT. Current version at the time of
writing: **0.2.3 (2026-05-11)** — 11 days after the `v0.2.0`
GA, with high additive churn on the public Ruby API every
release.

Rubydex's positioning is explicit and load-bearing: it is **not**
a type checker. The blog post enumerates type-aware analysis as
future work ("**Type-aware analysis**: consume type annotations
(Sorbet sigs, RBS) to improve method reference accuracy through
type inference"). The README and `docs/architecture.md` describe
two stages — **Discovery** (capture every `Definition` literally
written) and **Resolution** (group `Definition`s into
`Declaration`s, compute FQNs, resolve constant references,
linearise ancestors). The Ruby surface is `Rubydex::Graph` with
`#index_workspace` / `#index_all` / `#resolve` / `#diagnostics`
/ `#[fqn]` / `#search` / `#resolve_constant(name, nesting)`
plus `Declaration` / `Definition` / `Signature` / `Mixin` /
`Reference` / `Location` value objects.

What rubydex tracks vs. what it does not:

| Surface | Status |
| --- | --- |
| Classes / modules / constants / methods / ivars / cvars / globals — declarations grouped from definitions | tracked |
| `include` / `prepend` / `extend` mixin chains; ancestor linearisation | tracked |
| Constant references with location data; per-FQN reverse lookup | tracked |
| RBS files as declaration sources (location, comments, deprecation, parameter *shape*) | tracked |
| Require-path resolution (`#resolve_require_path`, `#require_paths`) | tracked |
| Method types from RBS (return types, parameter types) | **not exposed** — `MethodDefinition#signatures` returns parameter *shape* only |
| Method references with high precision | **partial** (blog: "method references with limitations" — requires type inference) |
| Type inference, control flow, narrowing, expression-type queries | **explicit non-goals today** |
| Linter rule catalogue, refactoring engine, code-generation | **explicit non-goals today** |

Adoption in the Shopify Ruby tooling stack — as of 2026-05-19:

- **Tapioca**: on `main`. `tapioca.gemspec` declares
  `rubydex >= 0.1.0.beta10`; `lib/tapioca/static/symbol_loader.rb`
  calls `Rubydex::Graph#index_all` / `#resolve` directly. The
  blog post claims gem RBI generation went from ~6 min to ~20 s.
- **Ruby LSP**: **in-flight**. [PR #4103 "Migrate to Rubydex and
  remove old indexer"][ruby-lsp-pr] is open with ~30 satellite
  PRs/issues. Live `Gemfile.lock` on `ruby-lsp` `main` does not
  depend on rubydex. The blog post's framing of this as done is
  forward-looking; treat as "merged-RSN", not "shipped".
- **Packwerk**: prototype. [PR #447][packwerk-pr] "Replace core
  parsing/resolution engine with Rubydex" is open.
- **Spoom**: exploratory, paused per the blog post.

The question this ADR addresses, in three parts:

1. **Foundation** — Could Rigor's implementation be re-platformed
   on top of rubydex? Specifically: does it make sense to delete
   Rigor's environment / class-registry / project-source-discovery
   pre-passes and re-implement them as queries against a rubydex
   `Graph`?
2. **Backend** — Can Rigor's existing implementation and a
   rubydex-backed implementation coexist behind a stable
   internal seam, so the choice becomes a runtime/configuration
   decision rather than a fork?
3. **Tool** — Independently of (1) and (2), are there discrete
   rubydex capabilities (constant cross-references, workspace
   symbol search, require-path resolution) worth consuming from
   `rigor lsp` or specific CLI subcommands without re-platforming?

A fourth question hovers above the three: how much of rubydex's
scope **overlaps** with what Rigor already implements, and what
does that overlap imply about long-term direction?

[post]: https://railsatscale.com/2026-05-12-one-engine-many-tools/
[ruby-lsp-pr]: https://github.com/Shopify/ruby-lsp/pull/4103
[packwerk-pr]: https://github.com/Shopify/packwerk/pull/447

## Decision

The three questions decide differently:

| # | Question | Decision | When to revisit |
|---|---|---|---|
| 1 | Foundation (replace Rigor's core) | **Reject.** Rubydex's scope ends below Rigor's primary mission. | Only if rubydex ships a type-inference engine usable as a substrate without re-implementing carrier / narrowing / dispatcher (see triggers). |
| 2 | Backend (swappable index source) | **Defer, with explicit triggers.** Not actioned in v0.1.x or v0.2.x. | When the trigger conditions below fire — chiefly: rubydex reaches 1.0 with stable API; rubydex exposes RBS *method types* not just parameter shape; Ractor shareability is documented. |
| 3 | Tool (LSP cross-file features) | **Conditional accept, queued.** Adopt under `examples/rigor-lsp-rubydex/` as an *opt-in* LSP capability provider for `textDocument/definition` / `textDocument/references` / `workspace/symbol`. Does not modify the analyzer's primary path. | When LSP roadmap commits to one of these capabilities. |

The strategic frame, recorded once so the rest of the document
doesn't have to keep restating it: **Rubydex is the universal
indexer Rigor *should consume from, not become*.** Rigor's
differentiated value is the type lattice (ADR-1), the inference
engine (ADR-4), and the RBS-superset annotation grammar
(`RBS::Extended`). Rubydex's differentiated value is a
Rust-backed declaration graph that Tapioca / Ruby LSP / Packwerk
can share. The two projects answer different questions, and the
healthier composition direction is "Rigor's RBS-method-type
translator reads from a rubydex `Graph`," not "Rigor becomes a
rubydex consumer that drops its own engine."

## Rationale

### Track 1 — Reject foundation replacement

Rubydex explicitly disclaims the surface area that Rigor's
inference engine implements. From the blog post and
`docs/architecture.md`:

> *Rubydex has no concept of types and performs no inference …
> Tracking method references with high accuracy depends on
> inferring the type of the receiver, which is currently not
> supported.*

Mapped against Rigor's `lib/rigor/inference/` subtree, the
non-overlap is exhaustive:

- [`expression_typer.rb`](../../lib/rigor/inference/expression_typer.rb) —
  the per-Prism-node type computer. **Not in scope for rubydex.**
- [`narrowing.rb`](../../lib/rigor/inference/narrowing.rb) and
  [`acceptance.rb`](../../lib/rigor/inference/acceptance.rb) —
  edge-aware narrowing per
  [`docs/type-specification/control-flow-analysis.md`](../type-specification/control-flow-analysis.md).
  **Not in scope for rubydex.**
- [`method_dispatcher/`](../../lib/rigor/inference/method_dispatcher) —
  the tiered dispatcher (RBS → in-source → plugin → dependency-source
  inference per ADR-2 / ADR-9 / ADR-10). **Not in scope for
  rubydex.**
- [`rbs_type_translator.rb`](../../lib/rigor/inference/rbs_type_translator.rb) —
  translates RBS method types into internal carriers. Rubydex's
  `MethodDefinition#signatures` returns parameter *shape* only;
  it cannot replace this translator. **Not replaceable.**
- [`hkt_*`](../../lib/rigor/inference/) — the
  ADR-20 lightweight-HKT substrate. **Not in scope for rubydex.**
- [`synthetic_method_*.rb`](../../lib/rigor/inference/) — the
  ADR-16 macro-expansion substrate. **Not in scope for rubydex.**
- [`project_patched_*.rb`](../../lib/rigor/inference/) — the
  ADR-17 monkey-patch pre-evaluation registry. **Not in scope
  for rubydex.**
- [`closure_escape_analyzer.rb`](../../lib/rigor/inference/closure_escape_analyzer.rb) —
  closure-escape / capture analysis. **Not in scope for rubydex.**

None of these can be expressed as queries against a rubydex
`Graph` because the graph stores only what rubydex's two
stages produce: declarations and resolved references. The
inference engine is the analyser, and a wholesale replacement
means "reimplement Rigor's analyser inside rubydex" — which is
the inverse direction the blog post itself anticipates ("Type
checkers like Sorbet would benefit massively from the same
foundation, eventually being able to consume Rubydex").

A theoretically interesting alternative — "merge Rigor's
inference engine **upstream into rubydex** so the unified tool
is both indexer and type checker" — is also rejected. Rigor's
type model (ADR-1, ADR-3, ADR-20) is built around RBS as the
canonical contract; rubydex parses RBS via a Rust crate that
exposes only declarations. Closing the gap requires either
re-implementing Rigor's type carrier zoo in Rust or extending
rubydex's FFI surface to expose typed signatures end-to-end.
Neither is a project Rigor can drive from outside Shopify's
roadmap, and both lose the benefit of Rigor's existing
implementation discipline. **Status review trigger:** if
rubydex's "future plans" ships a type-inference layer that
covers the spec corpus's value lattice, this ADR re-opens.

### Track 2 — Defer backend swap

The narrower question — "could Rigor's environment / declaration
layer be re-implemented as a thin adapter over `Rubydex::Graph`,
with the analyzer staying intact?" — is more interesting and
more defensible. The overlap is real:

| Rigor surface | Rubydex equivalent | Overlap |
| --- | --- | --- |
| [`lib/rigor/analysis/project_scan.rb`](../../lib/rigor/analysis/project_scan.rb) + `Runner#expand_paths` | `Graph#index_workspace` / `#index_all` | **Strong** — both walk directories, apply exclusions, list `.rb` files. |
| [`lib/rigor/environment/rbs_loader.rb`](../../lib/rigor/environment/rbs_loader.rb), [`bundle_sig_discovery.rb`](../../lib/rigor/environment/bundle_sig_discovery.rb), [`lockfile_resolver.rb`](../../lib/rigor/environment/lockfile_resolver.rb) | `Graph#add_workspace_dependency_paths` + `Graph#add_core_rbs_definition_paths` | **Strong** — both walk Bundler-locked gem trees + stdlib RBS. Rubydex additionally indexes core/stdlib RBS via `Gem.path` search for the `rbs` gem. |
| [`lib/rigor/environment/class_registry.rb`](../../lib/rigor/environment/class_registry.rb) + [`reflection.rb`](../../lib/rigor/environment/reflection.rb) | `Graph#declarations` + `Declaration#ancestors` / `#descendants` / `#members` | **Strong** — both give "what classes exist + ancestor chains". |
| [`lib/rigor/inference/scope_indexer.rb`](../../lib/rigor/inference/scope_indexer.rb) `#build_declaration_artifacts` | `Graph` discovery stage | **Partial** — Rigor also produces per-node scope snapshots (locals, `# TYPE:` overrides, declared types) that rubydex does not. The classes-and-methods half overlaps. |
| `ExpressionTyper#resolve_constant_name` ([`expression_typer.rb:395`](../../lib/rigor/inference/expression_typer.rb:395)) | `Graph#resolve_constant(name, nesting)` | **Strong on the resolution algorithm**, weak on the precedence rules Rigor adds (in-source > RBS, with `# TYPE:` override). |
| [`lib/rigor/cache/`](../../lib/rigor/cache/) (RBS environment, constant table, ancestor table — all Marshalled, content-addressed) | Rubydex's in-memory graph (process-local, rebuilt per session) | **Inverted shapes.** Rigor caches across processes (per ADR-6); rubydex assumes per-session indexing is fast enough that no on-disk cache is needed. |

Five reasons the swap is deferred, not actioned:

1. **The RBS surface doesn't reach far enough.** Rubydex parses
   `.rbs` files but exposes only declaration metadata
   (location, comments, deprecation) and parameter *shape*
   (`MethodDefinition#signatures` returns names / kinds /
   locations, **not types**). Rigor's
   [`rbs_type_translator.rb`](../../lib/rigor/inference/rbs_type_translator.rb)
   needs *typed* method definitions — return types, parameter
   types, variance — which today the Ruby `rbs` gem provides via
   `RBS::Environment#method_definitions`. Backend-swapping the
   declaration layer would still leave Rigor reading every
   `.rbs` file a second time through the `rbs` gem to recover
   types rubydex doesn't expose. That double-parse undoes the
   performance argument that motivates the swap.

2. **The Ractor shareability story is unverified.** ADR-15
   commits Rigor to a Ractor-based concurrency model. Rubydex's
   `Graph` is an opaque-handle object backed by a Rust dylib
   loaded through `extconf.rb`; the Ruby-level wrappers
   (`Declaration`, `Definition`, `Location`) are normal mutable
   Ruby objects with no documented shareability guarantees.
   Until rubydex documents Ractor compatibility, adopting it as
   a backend forces Rigor's concurrency design into a wait
   state.

3. **The native-build footprint contradicts Rigor's pure-Ruby
   stance.** Rigor today ships no C / Rust extensions (gemspec
   has no `extensions` field; `Makefile` has no native build
   steps). Adopting rubydex changes that — Rigor's gem would
   pull in a transitive native dependency. Rubydex ships
   precompiled binaries for `x86_64-linux` / `x86_64-darwin` /
   `arm64-darwin` / `aarch64-linux` / `x64-mingw-ucrt`, which
   covers most users, but the source-build fallback requires
   `cargo` with `rust 1.89+`. Rigor's `flake.nix` already
   pulls Rust via `mkRuby` (Ruby 4.0.4 needs it), so the
   in-flake build path works; the worry is non-Nix users on
   platforms rubydex hasn't precompiled for, and the
   Ruby-version-precompile matrix (per-minor `.so` files under
   `lib/rubydex/<ruby_minor>/`) where Rigor's **Ruby 4.0**
   requirement may outrun rubydex's precompile coverage for
   months.

4. **API instability at v0.2.x.** Rubydex's recent release
   notes show the public Ruby surface gains methods every
   release ("Expose X in the Ruby API" recurs across v0.2.1 /
   v0.2.2 / v0.2.3). There is no `CHANGELOG.md` in the repo;
   release notes live on GitHub. The architecture doc warns
   that even iteration order of returned collections is not
   stable across server restarts. Tapioca, which depends on
   rubydex today, absorbs that churn cost because Tapioca's
   release coordinator is in the same org. Rigor isn't, and
   would be tracking upstream changes asynchronously.

5. **Rigor's cache architecture isn't pulled by the same
   forces.** ADR-6 keys Rigor's caches by content hashes of
   the underlying RBS / source files; cached artifacts include
   `rbs_constant_table`, `rbs_instance_definitions`,
   `rbs_class_ancestor_table`, `rbs_known_class_names`. Rubydex's
   model is "re-index every session, in parallel, fast enough
   that no cache is needed". The two models are coherent
   independently but argue past each other: Rigor's cache wins
   on cold start of repeated runs (`rigor check` in CI on the
   same SHA); rubydex's parallelism wins on a single warm run
   over a large corpus. Replacing Rigor's cache layer with
   rubydex's session-rebuild model is a *separate* design
   question — see "Open questions".

The combined verdict: the backend swap is **plausible** but the
trigger conditions are not met. Re-evaluation is gated on:

| Trigger | What changes |
| --- | --- |
| Rubydex reaches `1.0.0` with a published API stability promise | Removes (4). |
| Rubydex exposes typed method definitions (return type / parameter types from RBS) via the Ruby API | Removes (1). |
| Rubydex documents Ractor shareability of `Graph` / `Declaration` / `Definition` | Removes (2). |
| Rubydex ships precompiled binaries for the Ruby version Rigor requires | Removes (3) for non-Nix users. |
| Rigor profiles `rigor check` on a 50k+ LOC project and identifies declaration / class-registry work as the dominant cost (>30% of wall time) | Makes the swap *worth* the integration cost. |

If three or more of these trigger together, this ADR is
re-opened with the swap design fleshed out behind a `backend:`
configuration axis (`backend: rigor` (default) vs.
`backend: rubydex`).

### Track 3 — Conditional accept as a supplementary tool

Two LSP surfaces Rigor does not currently implement are exactly
the shape rubydex was built for:

- **`textDocument/definition`** — "jump to where this constant /
  class is declared". Rubydex's `Graph#[fqn]` returns the
  `Declaration`, which carries every contributing `Definition`'s
  location. Constant references are tracked completely.
- **`textDocument/references`** — "find every place this
  constant is used". Rubydex's `Graph#constant_references`
  returns the typed reverse index.
- **`workspace/symbol`** — fuzzy global symbol search.
  `Graph#search(query)` is precisely this.

[Today's LSP](../../lib/rigor/language_server/server.rb#L97)
implements hover / completion / signatureHelp / documentSymbol
/ foldingRange / selectionRange (per ADR-19 / Slice 6) — all
**per-file** queries. The three above are unimplemented and
require a cross-file declaration index that Rigor's
[`ScopeIndexer`](../../lib/rigor/inference/scope_indexer.rb)
does not build (the per-node scope snapshot is throwaway state,
not a persistent index).

The path of least friction is **an optional LSP capability
provider** that loads rubydex if the user has it installed,
exposes the three handlers above, and defers everything else to
Rigor's native LSP implementation. Concretely:

- New optional dependency: rubydex is **not** added to
  `rigortype.gemspec`. Users who want the three capabilities
  add `gem "rubydex"` to their own Gemfile, and Rigor's LSP
  detects its presence at load time (`begin; require "rubydex";
  rescue LoadError; end`) and registers the corresponding
  handlers only if loaded.
- New module: `lib/rigor/language_server/rubydex_provider.rb`
  encapsulates the optional integration. The file does not
  exist today; this ADR is the design pre-commitment.
- Boundary: the rubydex `Graph` is built once per LSP session
  (matching `ProjectContext`'s lifetime), invalidated on
  `workspace/didChangeWatchedFiles`. Per-file changes use the
  buffer table; rubydex sees committed-to-disk content only,
  same as Tapioca's consumption pattern.
- Diagnostic: a `language_server.rubydex.unavailable` notice
  fires once at startup if the user requested the capability
  but rubydex isn't loaded.

This is **not** the same as Track 2 (backend swap):

- It does not change the analyser's primary path.
- It does not require Rigor to read RBS through rubydex.
- It does not pull rubydex into Rigor's runtime dependency
  graph.
- It does not enter the Ractor concurrency design's blast
  radius (the LSP runs on the main thread; rubydex sits beside,
  not inside, the analyser's worker pool).

A second, smaller use-case: **`rigor check <path>` dependency-
graph file selection.** Today `rigor check lib/foo.rb` analyses
exactly one file. A natural extension is "analyse `foo.rb` and
everything it transitively requires". Rubydex's
`Graph#resolve_require_path(path, load_paths)` does the per-call
resolution; it does **not** ship a graph walk. Building a real
transitive-requires query would be a thin Ruby loop on top.
**Verdict:** queue this until concrete user demand surfaces.
The capability would be neat; today it's speculative.

A third option floated in the user prompt — **using rubydex's
constant cross-references for diagnostic placement** (e.g., "this
constant is referenced in 17 places; the narrowed type holds at
line N") — sits in the same conditional-accept bucket. It
unblocks features Rigor doesn't have today, doesn't compete with
the inference engine, and shouldn't block on Track 2's triggers.

## Overlap matrix

For quick reference (referenced by Track 2's "deferred" verdict
and by the open questions below):

| Rigor capability | Rubydex coverage | Verdict |
| --- | --- | --- |
| Project file discovery | full | overlap; not worth swap on its own |
| Bundle / Gemfile-locked gem discovery | full | overlap; not worth swap on its own |
| Core / stdlib RBS path discovery | full (independent of bundle) | overlap; Rigor's [`bundle_sig_discovery.rb`](../../lib/rigor/environment/bundle_sig_discovery.rb) is more configurable |
| RBS class / module / method *declaration* extraction | full | overlap |
| RBS method *type* extraction (return types, parameter types, variance) | **none** | Rigor must keep its own RBS parsing for types |
| In-source class / module discovery | full (declarations) | overlap |
| In-source method body inference (return-type computation) | none | Rigor exclusive |
| Constant lookup (Ruby-precedence-respecting) | full | overlap; Rigor adds in-source > RBS precedence + `# TYPE:` override |
| Constant cross-references (find-references on a constant) | full | **Rigor exclusive gap that rubydex fills** |
| Ancestor chain / linearisation | full | overlap |
| Mixin (`include` / `prepend` / `extend`) tracking | full | overlap |
| Local variable type tracking / closure capture | none | Rigor exclusive |
| Control-flow narrowing | none | Rigor exclusive |
| Method dispatch resolution (typed) | none | Rigor exclusive |
| Synthetic-method substrate (ADR-16) | none | Rigor exclusive |
| Monkey-patch pre-eval (ADR-17) | none | Rigor exclusive |
| Lightweight HKT (ADR-20) | none | Rigor exclusive |
| Sorbet sig ingestion (ADR-11) | none | Rigor exclusive (plugin) |
| Cross-plugin fact store (ADR-9) | none | Rigor exclusive |
| Dependency-source inference (ADR-10) | none | Rigor exclusive |
| Sig-gen (ADR-14) | none | Rigor exclusive |
| Persistent on-disk cache (ADR-6) | none (session-rebuilds) | Rigor exclusive |
| LSP `textDocument/hover` (typed) | partial (declaration-only; no inferred type) | Rigor exclusive on the typed half |
| LSP `textDocument/definition` (constants) | full | **Rigor gap** |
| LSP `textDocument/references` (constants) | full | **Rigor gap** |
| LSP `workspace/symbol` | full | **Rigor gap** |
| MCP server for AI agents | full (separate Rust binary) | orthogonal to Rigor's mission |

Reading the table: rubydex covers the **lower half of the
stack** (declaration discovery, name resolution, cross-file
constant references) — the "what exists" layer. Rigor covers
the **upper half** (typed inference, narrowing, dispatch,
plugin-extended semantics) — the "what is the type of this
expression" layer. The overlap is exactly the boundary between
the two halves; both projects implement that boundary
independently, and the per-project cost of crossing it is
non-trivial.

## Alternatives considered

| Candidate | Status | Reason |
| --- | --- | --- |
| Rewrite Rigor on top of rubydex (delete `lib/rigor/environment/` + `lib/rigor/analysis/project_scan.rb` and re-implement as `Graph` queries) | Rejected | Bears the full cost of (1)–(5) under Track 2; gains a non-trivial speed-up on the declaration-discovery layer that is not Rigor's hot path according to current profile data. |
| Vendor rubydex's `Graph` data model in Ruby (re-implement in pure Ruby for the API shape, drop the Rust backend) | Rejected | Duplicates effort the upstream owns; reimports the API instability risk without the performance upside; produces a half-feature that's both behind upstream and behind Rigor's own code. |
| Add rubydex as a hard runtime dependency of `rigortype` | Rejected | Pulls a native dependency on every Rigor install for features only a subset of users want; expands the supported-platform matrix Rigor commits to. |
| Propose upstream changes to rubydex to expose RBS method types | Queued (informational) | Worth proposing if Track 2's triggers cluster around (1). Rigor's contribution would be a Rust-side patch to `ruby-rbs` integration, not a small Ruby PR — substantial scope. |
| Fork rubydex and add typed RBS extraction | Rejected | Forking a Rust workspace owned by Shopify creates a maintenance burden Rigor cannot reasonably carry. |
| Adopt rubydex's MCP server pattern for Rigor's own AI integration | Out of scope | Rigor has no current AI-agent integration mandate. If one emerges, see the [`rigor-plugin-author`](../../.codex/skills/rigor-plugin-author/SKILL.md) discipline. |

## Working decisions

### WD1 — Why "evaluation" status, not "rejected" or "accepted"?

The three sub-decisions land differently (reject / defer / conditional accept). A single
status would either oversimplify (label all three "rejected" and lose Track 3's
conditional accept) or overcommit (label "accepted" when the foundation question
is decisively no). Per ADR style precedent (ADR-13 covers two related features
with one status; this ADR covers three with one status), the umbrella status
records the meta-decision: **the question is settled, here's the shape**.

### WD2 — Why mention the strategic frame at all?

The user prompt asked "is rubydex worth replacing Rigor's implementation with?"
The answer "no, but…" is not complete without naming **why** the projects
shouldn't collapse into one. The strategic frame in § Decision — "Rubydex is
the universal indexer Rigor should consume from, not become" — is the
durable claim. Without it, every future "should we just use rubydex?"
conversation re-derives the same conclusion from first principles. With it,
the conversation starts at the table and updates per trigger.

### WD3 — Why is Track 3 not actioned now?

Two reasons: (a) ADR-19 committed the LSP to a bundled-in-`rigortype` shape;
adding rubydex as an *optional* sidecar respects that shape. (b) The three
unimplemented LSP capabilities (`definition`, `references`, `workspace/symbol`)
aren't on the v0.1.x roadmap. When the LSP roadmap commits to one of them,
the rubydex provider lands as a parallel implementation slice; until then,
designing the provider in advance is premature.

### WD4 — Why no PoC commit alongside this ADR?

Per the project's typical ADR flow (ADR-11 / ADR-13 / ADR-15 / ADR-16 / ADR-17
/ ADR-18 / ADR-20 are all proposed-status ADRs that pre-date implementation),
implementation slicing follows ADR acceptance. The proposed status is the
work product here; the PoC would commit Rigor to integration work the triggers
say isn't justified yet.

### WD5 — Why isn't this a `Plugin::Base` extension?

Track 3 — the only track that actions integration — is an LSP capability
provider, not an analyser plugin. Plugins per ADR-2 contribute to inference;
the rubydex provider contributes to *editor surfaces*. The naming convention
follows ADR-19's family prefix; if the provider extracts to its own gem under
the v0.x trigger conditions, the gem name `rigor-lsp-rubydex` matches the
existing `rigor-*` pattern.

### WD6 — Does this ADR commit Rigor to Ruby 3.2 compatibility regression?

No. Rubydex requires `>= 3.2.0`; Rigor requires `>= 4.0.0`. The min versions
align at the floor (4.0 ≥ 3.2). The concern flagged under Track 2's reason (3)
is *precompiled binary coverage for Ruby 4.0*, not version-range compatibility.
Rubydex's loader does `require "rubydex/#{ruby_version}/rubydex"`; until
rubydex ships a `lib/rubydex/4.0/rubydex.so`, Ruby 4.0 users hit the Cargo
fallback. This is a friction point for non-Nix users, not a deal-breaker.

### WD7 — What if rubydex itself adds type inference?

The blog post lists this as future work. If it lands and the type-inference
layer:

- targets the same value lattice Rigor's spec corpus authors (`docs/type-specification/`),
- exposes a Ractor-shareable API,
- handles the RBS / RBS::Inline / RBS::Extended trinity,

then Track 1's reject decision re-opens. The likelihood of all three landing
without forcing breaking compromises on Rigor's spec is low — Rigor's spec
makes design choices rubydex isn't bound by (the asymmetric robustness
principle per ADR-5, trinary certainty, the `Dynamic[T]` algebra). The
realistic forecast: rubydex adds type inference scoped to the Shopify-internal
toolchain's needs (Tapioca-shaped, Sorbet-compatible), and Rigor's spec
extensions stay outside that scope. In which case Track 1's verdict holds.

## Open questions

- **RBS double-parse cost.** If Track 2 ever fires, does Rigor's
  `RbsLoader` + rubydex's RBS indexing both reading the same `.rbs` files
  produce a measurable wall-time tax, or is the cost lost in the noise?
  Worth a benchmark slice before any backend-swap implementation.

- **Cache invalidation interaction.** Rigor's ADR-6 cache keys artifacts by
  content hashes of upstream files. If a future rubydex provider also caches
  (in-memory only today, but plausibly on-disk in v0.x), do the two caches
  invalidate in lockstep, or does one stale entry cause silent divergence?
  Design needed if Track 3's provider grows beyond LSP read-only paths.

- **Cross-plugin fact-store composition with rubydex facts.** ADR-9's cross-
  plugin fact store lets plugins publish typed facts other plugins consume.
  If rubydex declarations become a fact channel (e.g., `:rubydex_declarations`),
  do existing plugins compose against them, or does the fact contract need
  widening?

- **Tapioca-style RBI consumption alignment.** [ADR-11 § "Slice 4 — RBI
  directory walker"](11-sorbet-input-adapter.md) reads `sorbet/rbi/**/*.rbi`
  via Rigor's own walker. If `rigor-sorbet` ever loads rubydex, can the
  RBI walk delegate to rubydex's `index_all([rbi_path])` and consume the
  resulting graph instead? Probably yes; defer until `rigor-sorbet`'s
  slice 4 implementer raises it.

- **Constant reference contributions to flow facts.** Rubydex tracks constant
  references "completely". If a user assigns `FOO = X.bar; ...; FOO.baz`,
  rubydex's reference index would surface the second use site. Rigor's
  narrowing already handles this via local-variable type carry; the question
  is whether the two analyses can disagree, and if so, which wins. Per the
  RBS-wins precedent (ADR-1, ADR-11 WD3), Rigor wins on type-bearing claims;
  rubydex wins on location-bearing claims. The disagreement boundary should
  stay clean.

- **Should `rigor sig-gen` (ADR-14) consume rubydex's Graph?** If Track 2
  fires, sig-gen's "find every method in this project" pre-pass becomes a
  `Graph#declarations` query. Until then, sig-gen has its own walker; the
  switch is mechanical when justified.

- **What's the Rigor analogue of rubydex's `Diagnostic{rule, message,
  location}`?** Rigor's diagnostic taxonomy (per
  [`docs/type-specification/diagnostic-policy.md`](../type-specification/diagnostic-policy.md))
  is richer (per-rule severity profiles, suppression markers, plugin
  provenance). If Track 3's LSP provider surfaces rubydex's integrity-
  failure diagnostics to the editor, the prefix family is
  `language_server.rubydex.*` (per ADR-2 § "Plugin Diagnostic Provenance").

## Re-evaluation triggers

This ADR is reviewed when:

| Trigger | Re-evaluate toward |
| --- | --- |
| Rubydex reaches `1.0.0` with a published API stability promise | Lower the bar on Track 2. |
| Rubydex exposes typed RBS method definitions (return type, parameter types) via the Ruby API | Track 2 backend swap becomes net-positive on RBS cost. |
| Rubydex documents Ractor shareability of `Graph` / `Declaration` / `Definition` | Removes the ADR-15 blocker on Track 2. |
| Ruby LSP's [PR #4103](https://github.com/Shopify/ruby-lsp/pull/4103) lands and stays landed across two minor LSP releases | Confirms the API is stable in practice; lowers (4). |
| Rubydex ships a `lib/rubydex/4.0/rubydex.so` precompiled binary | Removes friction for non-Nix Rigor users. |
| Rigor's LSP roadmap commits to `textDocument/definition` / `textDocument/references` / `workspace/symbol` | Action Track 3. |
| Rubydex ships a type-inference engine that targets the spec lattice (ADR-1) | Re-open Track 1. |
| A user-side benchmark shows Rigor's declaration / class-registry work exceeds 30% of `rigor check` wall time on a real project | Action Track 2. |

The expectation is **no trigger will fire in v0.1.x**. The
realistic horizon for Track 3 action is v0.2.x — coupled to
ADR-19's "trigger conditions for re-evaluation". The horizon for
Track 2 is v0.3.x or beyond.

## Consequences

**Positive**

- Rigor's design is no longer ambiguous about whether to adopt
  rubydex. Future "should we just use rubydex?" conversations
  resolve against this ADR.
- The strategic frame ("indexer vs. inference engine") is
  written down once. It bounds the discussion in future ADRs
  about LSP capabilities, cross-plugin facts, sig-gen scope, etc.
- The Track 3 path keeps the door open to picking up rubydex's
  best-in-class constant-reference indexing for LSP features
  without committing to backend replatforming.

**Negative / cost**

- The decision is partly contingent on upstream's roadmap. If
  rubydex ships a type-inference engine ahead of Rigor's
  expectation, Track 1 reopens — and Rigor will be operating
  on an older premise until that's noticed.
- No PoC means the integration friction estimates under Track 2
  are theoretical. A future implementer might find a real
  blocker the ADR didn't anticipate.

**Neutral**

- Adds a new diagnostic family prefix `language_server.rubydex.*`
  reserved for Track 3, even though no diagnostics emit today.
- Adds `examples/rigor-lsp-rubydex/` to the reserved-but-empty
  directory list. When Track 3 actions, the
  [`rigor-plugin-author`](../../.codex/skills/rigor-plugin-author/SKILL.md)
  SKILL covers the scaffold; this ADR doesn't pre-author the code.

## Revision history

- 2026-05-19 — initial proposal. Triggered by user request to
  evaluate whether `Shopify/rubydex` should replace Rigor's
  implementation foundation, become a swappable backend, serve
  as a supplementary tool, or be deferred. Resolution: tri-fold
  decision (reject foundation, defer backend, conditional-accept
  tool) plus written re-evaluation triggers.
