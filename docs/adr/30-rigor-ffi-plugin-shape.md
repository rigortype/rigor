# ADR-30 — `rigor-ffi` plugin shape

Status: **proposed, 2026-05-25.** Records the decision to ship a
core `rigor-ffi` plugin covering the common `ffi` gem machinery
plus a family of per-library sub-plugins (`rigor-rbnacl`,
`rigor-ethon`, `rigor-ffi-rzmq`, `rigor-sassc`), and the
boundary that lets the same core also serve projects targeting
tenderlove's `ffx` gem (a strict FFI subset that transpiles to a
C extension at gem install time).

Grounding survey lives at
[`docs/notes/20260525-ffi-library-survey.md`](../notes/20260525-ffi-library-survey.md)
(five real `ffi` consumers + the four-repo tenderlove addendum).

## Context

Ruby gems that wrap a native library through the
[`ffi`](https://github.com/ffi/ffi) gem present a recurring
opacity wall for Rigor:

- `attach_function :name, [arg_types], ret_type` registers a
  module method at load time. The bound method exists, but its
  RBS-equivalent signature is encoded only as a Ruby array of
  symbols at the call site.
- `FFI::Pointer`, `FFI::MemoryPointer`, `FFI::AutoPointer`,
  `FFI::Struct`, `FFI::Union`, `FFI::Function`, and friends carry
  the cross-boundary data. None of them are first-class types in
  Rigor's vocabulary today.
- The user-facing API of a gem like `ethon` (libcurl), `rbnacl`
  (libsodium), or `sassc-ruby` (libsass) is a Ruby class layer
  built on top of the `attach_function`-bound primitives. Without
  the binding signatures, the high-level methods type as
  `Dynamic[Top]` end-to-end.

The five-library survey + the tenderlove addendum identified the
non-trivial axes:

1. **Binding-style taxonomy.** Literal `attach_function`
   (sassc-ruby, ethon, ffx targets) vs. custom DSL wrapping it
   (rbnacl's `sodium_function` interpolating into `module_eval`)
   vs. bindings declared in a separate gem (ffi-rzmq → ffi-rzmq-core).
2. **Per-library generated surface.** ethon iterates an option
   catalog and `define_method`s each setter; sassc-ruby overrides
   `attach_function` to strip a `sass_` prefix.
3. **typedef'd opaque pointers as nominal types.** sassc-ruby
   declares ten `typedef :pointer, :sass_*_ptr` aliases; treating
   them as distinct `Nominal` types would catch real cross-context
   misuse, but always-nominal risks FP on gems using typedef for
   pure documentation.
4. **The `ffx` target.** ffx exposes the same DSL surface as the
   `ffi` gem but accepts only a 25-symbol primitive type set (no
   callbacks, no struct, no typedef, no enum, no varargs). It
   transpiles to a real C extension at gem install time and
   embeds an `FFI0`-magic-marked metadata blob in each
   trampoline for ZJIT consumption.
5. **The `Fiddle` neighbor.** Ruby stdlib's `Fiddle` is a parallel
   FFI mechanism (used by sqliteffx for out-parameter reads). Its
   binding surface is materially different from the `ffi` gem's.
6. **The "no FFI" negative case.** `childprocess` uses no FFI at
   all — it relies on Ruby's `Process` / `IO`. The plugin must
   activate on detected FFI binding code, not on "looks low-level".

The addendum's headline finding is materially good news: because
ffx's DSL is bit-identical to the `ffi` gem's (and strictly
smaller), a recognizer covering the `ffi` gem covers ffx-targeted
code for free — with the *additional* opportunity of surfacing
ffx-incompatible declarations as static diagnostics before the
gem-install build fails.

The honest demand picture is weaker than the engineering surface
might suggest. sassc-ruby is effectively EOL (libsass deprecated
upstream in 2020); typhoeus / ethon and rbnacl have real but
specialized user bases; ffi-rzmq is niche. None of the four
candidate sub-plugins has the user pull of, say, `rigor-activerecord`.
The implementation case rests instead on **two zero-overhead
properties**:

- Sub-plugins ship in `plugins/` and activate only when the
  matching gem appears in the analysed project's resolved
  dependency set — non-users pay zero analyzer cost.
- Core FFI carrier types (`FFI::Pointer`, `FFI::MemoryPointer`,
  `FFI::Struct`) are referenced by name across the surveyed
  corpus; modeling them in core `rigor-ffi` lifts every project
  that incidentally touches FFI, not just the four worked
  consumers.

This combination — additive coverage with no overhead on
non-users — justifies aggressive implementation despite weak
direct demand (WD9).

## Decision

Ship a **core `rigor-ffi` plugin + per-library sub-plugin
family**, matching the [ADR-12](12-dry-rb-packaging.md) /
[ADR-25](25-plugin-contributed-rbs.md) packaging shape already
proven on the dry-rb and Rails plugin lines. The core covers the
common `ffi` machinery and serves both `ffi`-gem-targeted and
`ffx`-targeted projects unchanged. Per-library sub-plugins
contribute DSL recognizers, option-catalog → setter mappings,
and high-level API RBS refinements.

## Working decisions

### WD1 — Plugin shape: core + per-library sub-plugins

The core `rigor-ffi` plugin owns:

- `extend FFI::Library` recognition (host module becomes the
  binding registry);
- Literal `attach_function` walking with the 25 primitive type
  symbols + `:varargs` + custom-typedef references;
- `callback`, `typedef`, `enum`, `bitmask` recognition;
- `FFI::Struct`, `FFI::Union`, `FFI::ManagedStruct` `layout`
  walking;
- RBS for `FFI::Pointer`, `FFI::MemoryPointer`, `FFI::Buffer`,
  `FFI::AutoPointer`, `FFI::Function`, `FFI::Struct` base;
- The String ↔ `:pointer` / `:string` auto-coercion at call boundary
  (WD7);
- The typedef'd-pointer nominal-type heuristic (WD4);
- The ffx target diagnostic family (WD5) and detection (WD6).

Per-library sub-plugins (`rigor-rbnacl`, `rigor-ethon`,
`rigor-ffi-rzmq`, `rigor-sassc`) own:

- DSL recognizers specific to one gem (`sodium_function`, ethon's
  option-catalog dispatch, sassc-ruby's prefix-strip override);
- High-level API RBS refinements (`SecretBox#encrypt: (String, String) -> String`,
  `Easy#perform: () -> Integer`);
- Cross-gem signature acquisition (ffi-rzmq → ffi-rzmq-core).

**Rejected alternatives.** A monolithic single `rigor-ffi` (every
library's recognizer always loaded) loses the Rails-plugin
packaging discipline already paid for and forces non-users to
carry boot cost. A core-less, every-gem-fully-autonomous shape
disperses common-machinery maintenance and duplicates carrier
RBS.

### WD2 — DSL recognizer placement: extension point in core

The core exposes a `Plugin::FFI::BindingRecognizer` extension
point. Sub-plugins register a recognizer that, given an AST node,
returns zero or more synthesized `attach_function` facts. The
core processes those facts through the same pipeline that handles
literal `attach_function` calls — sub-plugins contribute a
*recognizer*, not a parallel typing pipeline.

Phase 2 (deferred): once [ADR-16](16-macro-expansion.md) Tier C
ships its declarative transform mode, the `sodium_function`
recognizer migrates to a Tier-C manifest declaration. The
extension point stays for shapes that don't fit Tier C cleanly.

**Rejected alternatives.** Core handles only literal
`attach_function`, each sub-plugin walks the AST itself: each
sub-plugin would re-implement the binding-fact emission boilerplate.
Skip the extension point entirely and route all DSL recognition
through ADR-16: forces dependence on Tier C's deferred shape and
couples this ADR's delivery to ADR-16's.

### WD3 — Cross-gem signature acquisition: defer to [ADR-10](10-dependency-source-inference.md)

ffi-rzmq's `attach_function` calls live in the separate
`ffi-rzmq-core` gem. The resolution path is ADR-10's opt-in
dependency-source inference: when a project uses `ffi-rzmq`,
rigor walks `ffi-rzmq-core`'s source under the dependency-source
tier and contributes the `LibZMQ.*` signatures.

**Rejected alternatives.** Plugin-contributed bundled RBS
([ADR-25](25-plugin-contributed-rbs.md)) for `LibZMQ` — preferred
for FP discipline, but requires hand-authoring + per-version
maintenance against `ffi-rzmq-core`. Because ffi-rzmq is the
lowest-demand worked consumer (WD9) and ADR-10 is the long-term
right answer for the general "FFI bindings in a sibling gem"
problem, deferring to ADR-10 is the cheaper path. ADR-25 stays
available as a fallback if ADR-10 progress stalls and ffi-rzmq
support becomes a concrete user ask.

### WD4 — Typedef'd opaque pointers: name-heuristic nominal types

A `typedef :pointer, :alias_name` call contributes a
`Nominal[<plugin>::<AliasName>]` type **iff** `alias_name`
matches the conventional opaque-pointer naming pattern
(`_ptr$` / `_handle$` / `Ptr$` / `Handle$` regex on the alias
symbol). Otherwise the typedef is treated as a transparent alias
for `:pointer`.

The nominal carrier honors the
[robustness principle](../type-specification/robustness-principle.md):

- **Input** — parameters declared as the nominal alias accept
  `Nominal[<alias>] | FFI::Pointer | Integer | nil` (the latter
  two are the wider FFI carriers; `Integer` covers the ffx case
  per WD7).
- **Return** — return types declared as the nominal alias stay
  strict `Nominal[<alias>]`.

A per-project `.rigor.yml` exception list (`rigor_ffi: { nominal_typedef_exceptions: ["log_target_ptr"] }`)
lets a project opt a typedef back to transparent if the heuristic
misfires.

**Rejected alternatives.** Always-nominal: precision-maximal but
risks FP on gems that use typedef purely for documentation.
Opt-in keyword on `typedef` itself: would require modifying the
`ffi` gem's call shape, which is across an API boundary rigor
cannot cross. Pure regex on the alias is brittle but recoverable
through the exception list; a future iteration may layer on
"defined as a return type by at least one `attach_function`" as a
secondary signal.

### WD5 — ffx target: new diagnostic family `ffx.unsupported-*`

When the ffx target is detected (WD6), the core plugin surfaces a
new diagnostic family for binding declarations ffx will refuse to
compile:

- `ffx.unsupported-callback` — `callback :foo, [...], :int`
- `ffx.unsupported-struct` — `class S < FFI::Struct`
- `ffx.unsupported-typedef` — `typedef :pointer, :handle`
- `ffx.unsupported-enum` / `-bitmask` — `enum :state, [...]`
- `ffx.unsupported-varargs` — `attach_function :printf, [:string, :varargs], :int`
- `ffx.unsupported-type` — any type symbol outside the ffx-25
  primitive set (see addendum table).

The diagnostic is **false-positive-free by construction**: every
declaration it surfaces is one ffx would fail to translate at
gem install time. This is the kind of additive,
zero-FP-risk diagnostic the [false-positive
discipline](../type-specification/overview.md#false-positive-discipline)
explicitly invites: it shifts a runtime build failure to a
static lint, with no honest pre-existing usage to break.

Severity defaults to `:error` (ffx will fail to build); a project
that intentionally maintains a dual-target binding file
(declarations gated on `if defined?(FFX)`) can suppress per
declaration via `# rigor:disable ffx.unsupported-*`.

### WD6 — ffx target detection: `extconf.rb` scan first

ffx detection cascades through three sources, top-down:

1. **Project `extconf.rb` scan.** If any `ext/**/extconf.rb`
   contains a literal `FFX.create_makefile` call, the project is
   considered an ffx target. This is a single-file, no-bundler-
   dependency check that handles the canonical sqliteffx pattern.
2. **`Gemfile.lock` dependency scan.** If `ffx` appears as a
   resolved dependency, the project is considered an ffx target.
   Reuses the bundler-parsing path already present for
   `BundleSigDiscovery` (v0.1.5).
3. **Explicit configuration.** `.rigor.yml` may set
   `rigor_ffi: { target: ffx }` to force the detection. Last
   resort, present for environments where neither `extconf.rb`
   nor `Gemfile.lock` is authoritative.

Detection results are cached at the project-context level (cleared
when the relevant input file changes, per ADR-6's cache invalidation
rules).

**Rejected alternatives.** Bundler-first detection: works but
couples to bundler internals for cases where `extconf.rb` already
gives a clean answer. Explicit-only: setup friction outweighs the
zero-FP cost of opportunistic detection.

### WD7 — `:pointer` parameter input set widens universally

A `:pointer`-typed parameter on any `attach_function`-bound
method accepts `FFI::Pointer | FFI::MemoryPointer | FFI::AutoPointer | FFI::Buffer | Integer | String | nil`,
**regardless of target** (ffi gem or ffx).

Rationale: the surveyed corpus shows real-world callers passing
each of these carriers — sqliteffx passes `Integer` (raw address
read via Fiddle), rbnacl passes `String` (binary-encoded buffer),
ethon passes `FFI::AutoPointer` (lifecycle-managed handle),
sassc-ruby passes `FFI::MemoryPointer.from_string` results. The
robustness principle's "lenient on input" line says the parameter
type should be the union of what real callers actually pass; any
runtime rejection (the `ffi` gem refuses raw `Integer`) is a
runtime concern, not a rigor concern.

Return types stay target-dependent: `FFI::Pointer` for the
`ffi`-gem target, `Integer` for the ffx target. Returns are the
"strict on output" side of the asymmetry.

**Rejected alternatives.** Target-dependent input narrowing
(ffi gem: `FFI::Pointer | nil`; ffx: `Integer | nil`): a
dual-target binding file becomes uncheckable; FP on legitimate
cross-carrier code.

### WD8 — Out of scope

The following are deliberately excluded from `rigor-ffi`. Each
has a clean home elsewhere (existing or future).

| Item | Reason |
| --- | --- |
| Use-after-free / double-free / leak diagnostics on FFI handles | Effect-tracking territory, not a type problem. A future `rigor-resource` plugin (or an engine-side effect analysis) is the right home. |
| `FFI::Struct` field-access bounds checking | Array-index flow analysis is engine work, not FFI-specific. |
| Native-side compilation correctness (sassc-ruby's `ext/libsass` build, ffx's generated C) | Rigor analyses Ruby; native build correctness is the gem author's / mkmf's problem. |
| `fisk` / `aarch64` / `JITBuffer` | Pure-Ruby instruction encoders with no FFI binding surface. End-user code never references their symbols. Future `rigor-jit` territory if ever wanted. |
| Hand-written C extensions (`rb_define_method` in `ext/*.c`) | No Ruby-side static handle. Coverage there means parsing `.so`'s — out of scope unless ffx-trampoline `FFI0` blob parsing lands (future, see Open Questions). |
| `Fiddle` | Parallel stdlib FFI mechanism with materially different DSL. Belongs in a sibling `rigor-fiddle` plugin authored separately. |

### WD9 — Implementation justified by zero non-user overhead, not direct demand

Direct user demand for each of the four candidate sub-plugins is
honestly weak. sassc-ruby is effectively EOL (libsass deprecated
upstream 2020); typhoeus / ethon has real but declining HTTP-
client share; rbnacl is specialized to crypto-heavy stacks;
ffi-rzmq is niche. None reaches the user-base scale of the
Rails-tier plugins.

Implementation proceeds anyway because:

- **Per-non-user cost is zero.** Sub-plugins activate only when
  the matching gem appears in the resolved dependency set; a
  project that never `require`s `rbnacl` pays no analyzer cost
  for `rigor-rbnacl`'s recognizers.
- **Core `rigor-ffi` lifts every incidental FFI user.** Modeling
  `FFI::Pointer`, `FFI::MemoryPointer`, `FFI::Struct` in core
  helps any project that ever touches FFI carriers, not just the
  four worked consumers. The core's payoff is broad even if the
  sub-plugin payoff is narrow.
- **Implementation experience is itself an output.** The DSL-
  recognizer extension point (WD2), the typedef-nominal heuristic
  (WD4), and the ffx diagnostic family (WD5/6) are each new shapes
  in the plugin contract. Real worked consumers stress-test them
  before the contract surface stabilises for v0.2.0.

This is the same logic that justifies the dry-rb plugin family at
its current breadth: low individual demand, zero non-user
overhead, broad infrastructure payoff.

### WD10 — Coverage scope + authoring path

Two distinct gem populations exist beyond the four worked
consumers: real-world FFI gems Rigor should also serve, and
internal / private FFI gems an external user might author. This
WD records what each gets from core `rigor-ffi` versus what
needs a sub-plugin, and routes the latter through the
project-wide contribution policy defined in
[ADR-31](31-contribution-and-supply-chain-policy.md).

**Coverage scope of core `rigor-ffi` for a "vanilla" FFI gem.**

For an FFI gem that (a) declares bindings via literal
`attach_function` calls in its own `lib/`, (b) uses primitive
type symbols + `callback` / `typedef` / `enum` / `bitmask`
/ `FFI::Struct`, and (c) wraps the bound methods in a thin Ruby
class layer, the core covers the majority of the typing surface
without any sub-plugin:

| Surface | Core coverage |
| --- | --- |
| `attach_function`-bound method signatures | full (literal walk) |
| FFI carrier types (`Pointer` / `MemoryPointer` / `Struct` / `Function`) | full (RBS in core) |
| Struct field access via `layout` | full (literal walk) |
| Enum value sets and Symbol → integer mapping | full (literal walk) |
| Callback parameter / return types | full (`callback` typedef walk) |
| `typedef`'d opaque pointer aliases | heuristic (WD4); exception list available |
| Thin wrapper class `def` that returns an FFI carrier | full (ordinary inference propagates the carrier) |
| Wrapper class method with semantics **richer** than its FFI primitive's return type (e.g. "this `:pointer` is always a 32-byte signing-key buffer") | not covered — needs sub-plugin RBS refinement |
| Custom DSL wrapping `attach_function` (rbnacl-style `sodium_function`) | not covered — needs WD2 `BindingRecognizer` registration |
| Bindings declared in a sibling gem (ffi-rzmq-core style) | not covered — needs WD3 (ADR-10) or bundled RBS (ADR-25) |
| Option-catalog-driven `define_method` (ethon-style) | not covered — needs ADR-16 Tier B/C recognition |

Concretely: an internal `MyCorp::LibAcme` gem that just declares
`attach_function :acme_open, [:string], :pointer` and wraps it in
`class MyCorp::Acme; def initialize(path); @handle = LibAcme.acme_open(path); end; end`
gets full typing from core alone. The project's `.rigor.yml`
needs only to list the gem under `dependencies:` so the binding
file is in the dependency-source-inference scope (ADR-10).

**Authoring path for the "needs sub-plugin" cases.**

A new SKILL — `rigor-ffi-plugin-author` (placed at
[`.claude/skills/rigor-ffi-plugin-author/SKILL.md`](../../.claude/skills/rigor-ffi-plugin-author/SKILL.md)) —
guides the author through:

1. **Coverage assessment** against the table above. If the gem
   matches the "vanilla" pattern, the SKILL terminates with "no
   plugin needed — declare the dependency and stop." This is
   important: the SKILL should *talk users out of authoring a
   plugin* when core suffices, to keep the plugin ecosystem
   honest.
2. **Authoring path per ADR-31** — author as a third-party
   `rigor-<gem>` gem in the user's own repo (ADR-31 WD4),
   optionally propose for bundling via the WD2 promotion route
   if the gem reaches the WD3 community-recognition threshold.
3. **Scaffold** — references the general
   [`rigor-plugin-author`](../../.claude/skills/rigor-plugin-author/SKILL.md)
   SKILL for the directory layout + spec layout + CHANGELOG
   discipline (the procedural shape is gem-type-agnostic).
4. **FFI-specific bits** — `Plugin::FFI::BindingRecognizer`
   registration (WD2), optional high-level wrapper RBS, demo
   fixture verifying both the binding recognition and the
   wrapper-class typing. **Pin the wrapped gem's version range**
   in the plugin's gemspec; new wrapped-gem versions are tracked
   by updating the plugin in your repo (orphan-plugin risk is the
   plugin author's responsibility per ADR-31 WD4).

The SKILL's procedural FFI-specific content (step 4) is initially
sketched and grows authoritative as slice 1 (core MVP) ships
and slice 2 (sassc-ruby) provides the first concrete reference
implementation.

**Distribution governance: see [ADR-31](31-contribution-and-supply-chain-policy.md).**

The project-wide policy applies — no external PRs into
`plugins/`, third-party plugin authoring is welcomed (WD4),
promotion for bundling happens via issue with `Co-authored-by:`
attribution (WD2), `Subtree merge` of a proven third-party
plugin is reserved as an optional path (WD5). This ADR does not
re-state the policy; the FFI plugin family is one of several
plugin families it governs.

## Implementation slicing

Six slices, sketched. No slice is scheduled by this ADR. Slice
order is engineering-progression-driven (cleanest case first
to validate the core), not demand-weighted.

| Slice | Scope |
| --- | --- |
| 1 | **Core MVP.** `extend FFI::Library` recognition. Literal `attach_function` walking with the 25 primitive type symbols. `ffi_lib`. RBS for `FFI::Pointer`, `FFI::MemoryPointer`, `FFI::AutoPointer`, `FFI::Function`, `FFI::Struct` base. WD7 pointer-parameter widening. No DSL recognizer extension point yet. |
| 2 | **`rigor-sassc` consumer (experience-building).** First real consumer. Validates WD4's typedef-nominal heuristic (sassc-ruby is the cleanest case in the corpus). Exercises `FFI::Struct` `layout` walking (`SassValue` tagged union) + `enum` recognition (`SassOutputStyle`). Acknowledged as low-real-demand (sassc-ruby EOL) — the slice's value is core validation, not user impact. |
| 3 | **`rigor-ethon` consumer.** First contact with ADR-16-flavor work: the option catalog (`Curl::Options.easy_options`) drives `define_method`-generated setters. Likely consumes Tier B trait-inlining for the catalog modules + Tier C heredoc-template for the setter shape. Tests how cleanly ADR-16 covers a real `define_method` farm. |
| 4 | **`rigor-rbnacl` consumer + WD2 extension point.** The `BindingRecognizer` extension point lands here, driven by `sodium_function` recognition (interpolated heredoc — the hardest binding-recovery shape in the corpus). |
| 5 | **WD5+WD6 ffx target.** `extconf.rb` / `Gemfile.lock` detection. Six `ffx.unsupported-*` diagnostics. `sqliteffx` as the verification consumer (every declaration in `sqliteffx.rb` is ffx-compatible; the diagnostic should fire on a constructed counterexample fixture only). |
| 6 | **`rigor-ffi-rzmq` consumer.** Gated on [ADR-10](10-dependency-source-inference.md) dependency-source inference being able to contribute method-level signatures (per-call return-type precision is in ADR-10's future-cycle backlog). Lowest priority — defer until ADR-10 progresses or a concrete user ask appears. |

## Consequences

- **The core handles ffx for free.** Because ffx's DSL is a strict
  subset of the `ffi` gem's, core `rigor-ffi` covers ffx-targeted
  projects without any ffx-specific recognizer. The only ffx-
  specific work is the additive WD5+WD6 diagnostic family.
- **`Plugin::FFI::BindingRecognizer` is the load-bearing
  architectural commitment.** This extension point is the same
  shape problem family as [ADR-13](13-typenode-resolver-plugin.md)'s
  TypeNode resolver chain — a registry of plugin-contributed
  recognizers whose outputs feed a common engine pipeline. Getting
  its surface right matters more than getting any individual
  sub-plugin shipped.
- **Implementation order is engineering-progression-driven.**
  sassc-ruby first because it's the cleanest case, not because
  it's the most-demanded gem. Defenders against the "why are you
  modeling an EOL gem first" critique have WD9 to point at.
- **`rigor-fiddle` is a separate effort.** Fiddle's DSL surface
  differs enough (no `extend FFI::Library`, no `attach_function`;
  uses `Fiddle::Function.new`, `Fiddle::Pointer`, `dlopen`) that
  shared infrastructure would be thin. A sibling plugin authored
  independently is the cleaner shape. Not blocked by this ADR.

## Open questions

- **Parsing the `FFI0` trampoline metadata as a secondary
  signature source.** ffx embeds `(magic | param_count | type_bytes | function_name)`
  in each generated trampoline. For an installed gem whose Ruby
  binding file is hidden (vendor blob, custom wrapper) but whose
  `.so` exists, parsing the trampoline recovers signatures from
  the binary. Out of scope for the initial plugin (requires
  ELF / Mach-O / PE awareness) but the strongest form the
  trampoline metadata's "static-analysis friendliness" can take.
  Worth reconsidering once a concrete consumer needs it.
- **Dual-target gems.** No surveyed gem ships ffi-gem and ffx
  code paths conditionally today. If a real dual-target gem
  appears, WD5's per-declaration suppression must be reviewed for
  ergonomics (likely fine — `# rigor:disable` is the existing
  per-block mechanism).
- **Per-call-site varargs typing in ethon's `easy_setopt`.** The
  `[:pointer, :easy_option, :varargs]` signature dispatches the
  varargs type through an external option catalog. The current
  decision is to model this *in the sub-plugin* (Slice 3) rather
  than the core, on the grounds that varargs-dispatched-by-enum
  is the kind of per-library shape sub-plugins exist for. Watch
  for a second gem with the same pattern that would justify
  promoting the mechanism to core.
- **Diagnostic ID stability for `ffx.unsupported-*`.** The six
  IDs in WD5 are the floor. Adding a seventh (e.g.
  `ffx.unsupported-blocking-call`) post-ship is additive and safe;
  renaming any of the six is a breaking change for projects with
  baselines. Lock the six on first release.
