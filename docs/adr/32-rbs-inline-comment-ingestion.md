# ADR-32 — Inline-RBS comment ingestion as an opt-in plugin

Status: **proposed, 2026-05-25.** Records the decision to consume
the upstream [rbs-inline](https://github.com/soutaro/rbs-inline)
comment vocabulary (`# @rbs name: T`, `#: () -> T`, `# @rbs return:
T`, attribute `#:`, …) by shipping a `rigor-rbs-inline` plugin
that runs the upstream library at env-build time and contributes
the synthesised RBS to the analysis environment. Rigor's core
stays zero-runtime-dependency (ADR-0); the rbs-inline gem becomes
the plugin's responsibility, not the core's.

**Amended 2026-05-25** with WD10 — a `require_magic_comment:`
plugin-config knob (default `true`) that lets a host context
skip the per-file magic-comment gate. The ADR-29 browser
playground sets it to `false` so that any pasted snippet is
analysed as inline-RBS without the user typing
`# rbs_inline: enabled`.

## Context

A Ruby file like

```rb
# @rbs asc_or_desc: :asc | :desc
def ascdesc(asc_or_desc)
  asc_or_desc
end

p ascdesc :desc
p ascdesc :bad
```

types `asc_or_desc` as `Dynamic[Top]` today, and `ascdesc :bad`
raises no diagnostic. The cause is unambiguous: Rigor's pipeline
does not look at `# @rbs` comments. Verified by greppin `lib/`,
`spec/`, and `examples/`; `MethodParameterBinder` reads only the
RBS environment, RBS::Extended `%a{rigor:v1:param:}` annotations,
and ADR-28 protocol contracts.

The downstream machinery is already in place. Re-encoding the
same contract in a `.rbs` file —

```rbs
class AscDesc
  def ascdesc: (:asc | :desc) -> (:asc | :desc)
  def ascdesc2: (:asc | :desc) -> (:asc | :desc)
end
```

— produces the expected behaviour with no engine change:

- `ascdesc :bad` raises `argument type mismatch at parameter
  'asc_or_desc' of 'ascdesc' on AscDesc: expected :asc | :desc,
  got :bad`.
- `annotate` shows the return type of `ascdesc2`'s body as
  `:asc | :desc` — the `case-when` narrowing path and the
  `raise`-arm `Bot` join correctly.

So the missing link is **purely** the path from
rbs-inline-shaped comments to the same RBS env that real `.rbs`
files populate. The Constant[Symbol] singleton lattice, the
parameter-binder substitution, the argument-mismatch diagnostic,
and the case-when narrowing all exist and work.

The upstream `rbs-inline` grammar is substantial (excerpted from
[`references/rbs-inline-wiki/Syntax-guide.md`](../../references/rbs-inline-wiki/Syntax-guide.md)):

- **Method types** in three forms: `#: () -> T`, `# @rbs () -> T`,
  and doc-style `# @rbs name: T` + `# @rbs return: T`.
- **Generics** (`# @rbs generic A`), **mixin generics** (`include
  Foo #[String]`), **`# @rbs inherits`**, **`# @rbs override`**.
- **Block-introduced types** (`# @rbs class ClassMethods` in a
  `class_methods do ... end` block).
- **Attributes** (`attr_reader :name #: String`).
- **Instance variables** (`# @rbs @name: String`).
- **Constants** (`VERSION = ... #: String`).
- **Alias**, **`# @rbs skip`**, **`# @rbs!` raw RBS embedding**,
  **`# @rbs %a{…}` annotations**.
- **Magic comment** `# rbs_inline: enabled` at the top of a file
  is the standard opt-in trigger; `# rbs_inline: disabled` is the
  opt-out.

Re-implementing this grammar inside Rigor would duplicate a
non-trivial upstream effort and risks divergence on every
rbs-inline release. Calling the upstream library — which already
emits well-formed RBS — is the substantially smaller and more
durable engineering choice.

But Rigor's core has a stated zero-runtime-dependency stance
(ADR-0), and `rbs-inline` is a non-trivial gem (it depends on
`prism` and `rbs`, both already required, but introduces its own
versioned surface). Adding it as a core runtime dependency would
contradict ADR-0.

This ADR resolves the tension by adopting the **plugin-as-opt-in
boundary** that ADR-25 already uses for the analogous
"contribute RBS to the env" hook: the inline-RBS reader lives in
a `rigor-rbs-inline` plugin gem, the plugin's gemspec declares
the `rbs-inline` dependency, and a project activates the
behaviour by adding one line to `.rigor.yml`'s `plugins:`.

## Decision

Ship a new bundled plugin **`rigor-rbs-inline`** under
`plugins/rigor-rbs-inline/` that:

1. Declares a runtime dependency on the upstream `rbs-inline`
   gem in its own gemspec (not the `rigortype` gemspec).
2. Honors the upstream **`# rbs_inline: enabled`** magic comment
   as the per-file opt-in trigger — Rigor's inline-RBS reader
   has the same activation rule as upstream rbs-inline. Files
   without the magic comment are processed exactly as today.
3. At env-build time, walks the project's check-target Ruby
   files, invokes `rbs-inline`'s parser API on each magic-comment
   file, and contributes the synthesised RBS to the same
   environment that `signature_paths:`, `bundler:`, and
   `rbs_collection:` populate.

A new optional `Plugin::Manifest` field, **`source_rbs_synthesizer:`**,
exposes the engine-side hook. The plugin sets the field to a
callable that, given a project source file path, returns RBS
source (or `nil` to skip). `Plugin::Loader` records the callable;
`Environment.for_project` invokes it per source file during env
build and merges the resulting RBS streams with the rest of the
signature input.

For the user's example file, after `plugins: [rigor-rbs-inline]`
is set and the `# rbs_inline: enabled` magic comment is added at
the top:

- `ascdesc :bad` raises `argument-type-mismatch` (the same
  diagnostic the real-`.rbs` path produces).
- `ascdesc2`'s `case-when` narrowing makes its return type
  `:asc | :desc` (per the existing flow-analysis path; verified
  in the diagnosis).

## Working decisions

### WD1 — A plugin, not a core feature

Adding `rbs-inline` ingestion to core `rigortype` is rejected.

- ADR-0 commits the analyzer to **zero runtime dependencies
  beyond `prism` / `rbs` / `language_server-protocol`**. Pulling
  `rbs-inline` into the core gemspec would force every Rigor
  installation to install rbs-inline + its dependency closure,
  including projects that use no inline-RBS comments. The
  zero-dep stance is a packaging premise that ADR-27 reinforced
  for distribution; this ADR does not relax it.
- The plugin boundary is the established mechanism for opt-in,
  *additional* RBS contribution (ADR-25 ratified this for static
  bundles; this ADR extends it to synthesised-from-source RBS).
- Activation is one line in `.rigor.yml` — the same UX as
  `plugins: [rigor-activesupport-core-ext]` — so the cost to
  the user is bounded.

Rejected alternative — a Rigor-side re-implementation of the
rbs-inline grammar (Option B in the diagnosis): low up-front
dependency cost, but commits Rigor to following every upstream
rbs-inline syntax change. The upstream grammar has accreted
across rbs-inline 0.x releases and is still moving (the
0.5.0 deprecation entry in the wiki is recent). Grammar drift is
the larger long-term cost.

### WD2 — Honor the upstream `# rbs_inline: enabled` magic comment

The plugin synthesises RBS **only** for files whose first
non-blank lines include `# rbs_inline: enabled`. Files without
the magic comment are passed through untouched.

- Spec alignment with upstream rbs-inline: the same file is
  valid as input to either tool with no source change.
- A project can mix inline-RBS files and plain Ruby files
  freely. A project that has no inline-RBS files at all incurs
  no synthesiser cost beyond the per-file magic-comment scan
  (a cheap top-of-file check).
- The `# rbs_inline: disabled` opt-out is honored identically.

Rejected alternatives:

- **Always-on once the plugin is loaded** — surprises projects
  that activate the plugin for one file but contain other
  `# @rbs`-shaped comments in unrelated contexts (e.g. docs in
  comments). Magic-comment gating keeps the boundary explicit.
- **A separate Rigor-only opt-in comment** (`# rigor:inline-rbs`)
  — divergence from the upstream convention with no offsetting
  benefit. The upstream convention already exists; reuse it.

### WD3 — Use the upstream `rbs-inline` library

The plugin shells out to `rbs-inline`'s parser API in-process
(no subprocess), takes the resulting RBS AST or source text, and
feeds it into `RbsLoader`'s synthetic-source channel.

- The upstream library handles the entire grammar (WD-Context
  bullet list), including the deprecated and ergonomic shapes
  (`# @rbs returns T`, `#::`, doc-style, `# @rbs!`). Reusing it
  means Rigor inherits coverage automatically.
- The library is the canonical source of truth for the grammar
  — upstream syntax changes flow in by version-bumping the
  plugin gem's dependency, not by editing Rigor's parser.
- Subset filtering is **not** done at the boundary in v1. If
  rbs-inline accepts a file, Rigor accepts the synthesised RBS.
  Restricting the supported subset can be added later as a
  configuration knob if a real need emerges.

### WD4 — A new `source_rbs_synthesizer:` manifest field

The engine-side hook is a new optional `Plugin::Manifest` field
holding a callable `(source_file_path) -> rbs_source_string | nil`.

- Distinct from ADR-25's `signature_paths:`. ADR-25 ships
  **static, bundled** RBS that lives inside the plugin gem;
  this ADR synthesises RBS **from the analysed project's own
  source** at env-build time. The two are complementary, not
  alternatives — a plugin can declare both.
- The synthesizer signature is deliberately narrow — one source
  path in, one RBS string out. This keeps the engine free to
  parallelise calls (one Ractor per source file under the
  ADR-15 plan), and lets the plugin be a thin wrapper over
  the upstream library.
- A plugin returning `nil` for a path means "no contribution
  for this file." This is the path the `rigor-rbs-inline`
  plugin takes for every file without the magic comment.
- Future plugins can reuse the same hook for other
  Ruby-source-to-RBS bridges (a speculative `rigor-yard` that
  reads YARD `@param` / `@return` tags; a `rigor-typeprof`
  bridge that runs typeprof on a file and registers its
  inferred RBS). The hook is general; this ADR's plugin is one
  consumer.

Rejected alternative — emit synthesised RBS into a temp
directory and re-use ADR-25's static `signature_paths:` plumbing.
Simpler in pure plumbing terms, but every analyzer run would
regenerate the temp directory; cache invalidation would key off
disk I/O rather than the original source file; LSP incremental
flows would need extra coordination. A direct in-memory hook is
cleaner.

### WD5 — Synthesis is per-file; cache key is the source file

The plugin runs once per source file. The synthesised RBS for
file `F` is a function of `F`'s content alone — it does not see
sibling files. Rigor's per-file cache (ADR-6) is the natural
cache layer: the existing per-file key (path + sha + Rigor
version) extends to "(path, sha, plugin id, plugin version)".

- One slow upstream call per source file. The set of project
  files with the magic comment is bounded by the project's
  size, and rbs-inline is fast (single-pass over Prism's AST,
  no inference).
- Files without the magic comment incur a top-of-file check
  only; no rbs-inline invocation, no synthesis. The common case
  for a project that adopts inline-RBS gradually is "most files
  not annotated, a few are" — the cache is cold for the
  annotated subset only.
- Concurrent synthesis is safe (the plugin is stateless across
  files; rbs-inline's parser is single-call per source).

### WD6 — Fail-soft on synthesis errors

If rbs-inline raises a parse error on a project file, the
plugin returns `nil` (no contribution) and emits a
`source-rbs-synthesis-failed` info diagnostic naming the file
and the upstream error message. Analysis continues — the file
falls back to the no-inline-RBS state (`Dynamic[Top]` for the
affected definitions), matching today's behaviour.

- Loud-on-failure for the user; never silent.
- Bounded blast radius: one broken `# @rbs` comment doesn't
  pull down the rest of the project's analysis.
- Mirrors the ADR-25 conflict-handling policy ("one warning,
  analysis continues") and the broader O7 failure-memo pattern.

### WD7 — Inline-RBS-declared parameter types are honored identically to real `.rbs`

A parameter type declared via `# @rbs name: :asc | :desc`
binds the parameter exactly as `def f: (:asc | :desc) -> ...`
would. The parameter binder makes no distinction; the
diagnostic codes are the same; the robustness-asymmetric
authorship rule (ADR-5) applies at the same boundary.

- Today's RBS path already strict-checks user-declared
  parameter types (verified: `argument type mismatch` fires
  against `:bad` when the parameter is declared `:asc | :desc`).
- The inline-RBS path inherits the same behaviour because the
  synthesised RBS routes through the same `RbsLoader` → env →
  `MethodParameterBinder` pipeline. No new policy.

### WD8 — Additive to the pre-1.0 plugin contract

The new `source_rbs_synthesizer:` manifest field is **optional**.
Existing plugins that do not declare it are unaffected. The
plugin contract (ADR-2) is still pre-1.0; this is the kind of
additive extension WD6 of ADR-25 covers, and it is safe to land
within the v0.1.x line. The contract surface v0.2.0 freezes
should include this field.

### WD9 — Top-level `def` semantics depend on upstream behaviour

The user's diagnostic example uses a top-level `def`. The
upstream rbs-inline wiki documents `def` inside `class` /
`module` explicitly; top-level `def` is not enumerated. The
plugin's behaviour for top-level defs is therefore "whatever
rbs-inline does on a Prism-parsed top-level def" — likely a
generated `Object#…` instance method, but to be verified in
slice 1 against the installed rbs-inline version.

- If upstream rbs-inline does not emit a sensible signature for
  a top-level def, the plugin reports the same condition (the
  file synthesises empty RBS for that def; the existing
  `Dynamic[Top]` fallback applies). This is not the plugin's
  bug to fix.
- A workaround already exists: wrap the def in a class
  (verified working — the experiment in this ADR's diagnosis
  produced `error: argument type mismatch` for the class-wrapped
  variant of the user's example).
- If the upstream behaviour is genuinely unhelpful for
  top-level defs, the plugin's authoring SKILL (deferred) can
  recommend the class-wrapped idiom.

### WD10 — Host-context override: `require_magic_comment:` plugin config

The plugin exposes a single boolean config key,
**`require_magic_comment:`**, defaulting to `true` (which
preserves WD2 verbatim for ordinary `.rigor.yml`-driven
projects). A host context that owns the entire analysis scope
can set it to `false`, in which case every file the
synthesizer sees is treated as if it carried the magic
comment, with no top-of-file check.

The **ADR-29 playground sets this to `false`** so that any
pasted snippet with `# @rbs`-shaped comments is analysed
without the user having to type `# rbs_inline: enabled`. The
playground is a single-buffer, single-request exploration
surface; the multi-file-project friction WD2 mitigates (a
project's other files getting opted in by accident) does not
exist there.

- The escape hatch is **per plugin instance, via plugin
  config**, not a Rigor-wide policy change. A project that
  adopts the plugin in `.rigor.yml` still gets WD2 by default.
- The plugin's `config_schema` declares the key; the user
  supplies it through the existing plugin-config surface on
  `.rigor.yml`'s `plugins:` entry. No new top-level
  configuration axis.
- A future opt-in CLI flag (e.g. a hypothetical
  `--treat-all-as-inline-rbs` for single-file ad-hoc CI use)
  can resolve to setting this plugin config knob, without any
  new mechanism.

Rejected alternative — a global `Rigor::Analysis::Context`
flag set by the playground runner that the plugin reads. The
playground would still need a way to express the intent in
its `.rigor.yml` to keep deployment configuration in one
place. A plugin-config knob is both surfaces.

## Consequences

### Positive

- **The user's exact diagnostic example becomes a one-line
  activation.** Adding `plugins: [rigor-rbs-inline]` plus the
  `# rbs_inline: enabled` magic comment makes `ascdesc :bad`
  raise the same `argument-type-mismatch` the real-`.rbs` path
  produces, and `ascdesc2`'s return type narrows to `:asc | :desc`.
- **Rigor inherits the full rbs-inline grammar for free.**
  Method types, attributes, ivars, constants, `# @rbs!` raw
  RBS embedding, `# @rbs override`, `# @rbs class/module`
  block-as-method bindings — all available through the same
  hook.
- **The hook generalises to other "Ruby-source → RBS"
  plugins.** YARD-tag readers, typeprof bridges, custom
  in-house annotation conventions — each ships as a separate
  plugin without modifying core.
- **No new top-level config axis.** Activation reuses the
  existing `plugins:` list, matching ADR-25's UX.

### Negative

- **One new optional manifest field** on a pre-1.0 contract.
  Additive and low-risk (WD8).
- **The plugin gem adds `rbs-inline` to the user's bundle.**
  A project that adopts inline-RBS pays the dependency cost on
  installation, not at runtime. The core analyzer remains
  zero-dep (WD1).
- **Per-file invocation overhead** on files with the magic
  comment. Mitigated by the per-file cache (WD5) and by the
  scope-gating effect of the magic-comment requirement (WD2)
  — non-annotated files never invoke the synthesiser.
- **Top-level-def behaviour is inherited, not designed (WD9).**
  Acceptable for v1; revisitable if real-world friction
  emerges.

### Carry-over

- **A `rigor-rbs-inline` authoring SKILL is not in this ADR.**
  The plugin's own README + handbook coverage of inline-RBS is
  the v1 user-facing surface; a SKILL can land later if the
  adoption pattern warrants one.
- **LSP incremental flows** are not specifically designed
  around the synthesiser hook in this ADR. The per-file cache
  (WD5) makes the obvious incremental story work, but
  end-to-end LSP integration is queued separately under the
  ADR-19 LSP roadmap.
- **Workspace-wide `# rbs_inline: enabled` activation**
  (matching rbs-inline's CLI `--opt-in` / `--opt-out` modes)
  for ordinary projects remains deferred. The
  `require_magic_comment:` knob added by WD10 is the same
  mechanism scoped to a single plugin instance — a project
  that wants project-wide activation can already set it to
  `false` in its `.rigor.yml`. The deferred work is the
  CLI-side ergonomic surface (a single `rigor check` flag
  rather than a plugin-config entry).

## Implementation slicing (proposed)

### Slice 1 — manifest field + engine hook + plugin skeleton

- `Plugin::Manifest` gains optional `source_rbs_synthesizer:`
  (a callable; frozen at manifest construction).
- `Plugin::Loader` records the callable per plugin id.
- `Environment.for_project` walks check-target source files,
  invokes each registered synthesizer per file, and feeds
  non-nil RBS strings into `RbsLoader` alongside the
  configuration's `signature_paths:`.
- Scaffold `plugins/rigor-rbs-inline/`: gemspec depending on
  `rbs-inline`, plugin class with manifest declaring
  `config_schema` for `require_magic_comment:` (default
  `true`, WD10), a synthesizer callable that consults the
  config knob to decide whether to check the magic comment
  and dispatches to `RBS::Inline::Parser`-or-equivalent.
- Specs: manifest field plumbing, `require_magic_comment:
  true/false` matrix, end-to-end smoke test using the user's
  diagnostic example (the `class AscDesc` variant reproduced
  inline, plus a top-level-def variant to record observed
  upstream behaviour per WD9).

### Slice 2 — failure handling + caching

- Synthesizer error path: emit `source-rbs-synthesis-failed`
  info diagnostic, plugin returns `nil` (WD6).
- Per-file cache key extension to include plugin id + version
  + `require_magic_comment:` value (WD5); cache invalidation
  tests.
- Spec coverage for: magic-comment opt-in/opt-out (WD2),
  empty-synthesis files, parse-error files, mixed inline / no-inline
  projects.

### Slice 3 — `rigor-rbs-inline` plugin polish + docs

- Plugin README documenting the activation flow, the
  `# rbs_inline: enabled` requirement, the known top-level-def
  caveat (WD9), and the diagnostic-example reproduction.
- Update the handbook with one paragraph and a code sample in
  the relevant chapter (likely "Type Sources" or "Authoring
  RBS").
- Cross-reference from ADR-25 (the static-bundle precedent).

## References

- [ADR-0](0-concept.md) — zero-runtime-dependency stance the
  plugin boundary preserves (WD1).
- [ADR-2](2-extension-api.md) — the plugin contract this
  extends with a new optional manifest field (WD8).
- [ADR-5](5-robustness-principle.md) — robustness-asymmetric
  authorship; inline-RBS user-declared parameters are honored
  exactly as the equivalent real-`.rbs` declaration (WD7).
- [ADR-6](6-cache-persistence-backend.md) — per-file cache the
  synthesizer hook extends (WD5).
- [ADR-15](15-ractor-concurrency.md) — per-Ractor isolation
  the synthesizer-callable signature is compatible with.
- [ADR-25](25-plugin-contributed-rbs.md) — static-bundle RBS
  contribution; the precedent for the plugin boundary used
  here.
- [ADR-27](27-tool-distribution-model.md) — Rigor-as-tool
  distribution model; reinforces the zero-runtime-dep stance.
- [ADR-29](29-browser-playground.md) — browser playground;
  the first host context that exercises WD10
  (`require_magic_comment: false`).
- [`references/rbs-inline-wiki/Syntax-guide.md`](../../references/rbs-inline-wiki/Syntax-guide.md)
  — upstream rbs-inline grammar reference.
