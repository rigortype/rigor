# Built-in method typing — boilerplate / pain-point audit — 2026-06-03

## Motivation

Internal-optimisation theme for the next version. This note inventories
the repetition, boilerplate, and hand-maintenance pain points in the
mechanism that assigns types to Ruby built-in methods, so the cleanup
can proceed in ease-of-implementation order without re-deriving the map
each session. Findings only — no behaviour change is proposed here; the
`false-positive discipline` rule means every cleanup below must be a
container-only refactor that leaves folded results bit-for-bit identical
(verified by `make verify`).

## The mechanism in three layers

1. **Catalog-loader layer** — `lib/rigor/inference/builtins/*_catalog.rb`
   (20 files). Each wraps a generated YAML catalogue
   (`data/builtins/ruby_core/<topic>.yml`) in a `MethodCatalog`
   singleton plus a curated mutation blocklist.
2. **Tier-D singleton-folding layer** —
   `lib/rigor/inference/method_dispatcher/*_folding.rb`. One module per
   pure stdlib singleton (CGI, URI, Shellwords, Math, Time, Regexp, Set,
   File) that evaluates the call at inference time on `Constant`
   receivers/arguments.
3. **Dispatch chain** — `lib/rigor/inference/method_dispatcher.rb` wires
   the tiers together in precedence order.

Each layer has accumulated structural repetition. Findings are ordered
by return-on-investment (impact ÷ risk).

## Finding 1 — Tier-D folding modules are a copied skeleton

Eight `*_folding.rb` modules replicate a near-identical shape:

- `dispatch_target?` is the **same one line in 9 places**:
  `receiver.is_a?(Type::Singleton) && receiver.class_name == "X"`
  (`cgi_folding.rb:74`, `uri_folding.rb:51`, `shellwords_folding.rb:81`,
  `math_folding.rb:74`, `time_folding.rb:51`, `regexp_folding.rb:42`,
  `set_folding.rb:43`, `file_folding.rb:110`; plus the `Class` variant in
  `iterator_dispatch.rb:69`).
- The body shape repeats: `module_function`, `try_dispatch(receiver:,
  method_name:, args:)`, method-name `Set` early-return guard, then
  `Type::Combinator.constant_of(Foo.public_send(method_name, str))` with a
  `rescue StandardError → nil` floor. `uri_folding.rb:43-63` and
  `cgi_folding.rb:66-90` are nearly character-for-character identical.

**Pain.** Adding a new pure singleton (Base64, Digest, …) means writing
60–120 lines of boilerplate. Easy to forget the `rescue` floor or
mis-pass the `constant_of` argument.

**Direction.** A single `SingletonFunctionFolder` driven by a
declaration table — `{ "URI" => %i[encode_www_form_component …], "CGI"
=> {…} }` — covering the "single String arg, fold via `public_send`"
case. Keep variant handlers (CGI element escape, Shellwords Tuple
lifting) as per-entry overrides. 8 files → 1 harness + data.

## Finding 2 — The dispatch chain is a hand-written `||` ladder

`method_dispatcher.rb:713-720` (singleton-folding chain) and `:697-704`
(`dispatch_precise_tiers`) repeat the **same `receiver:/method_name:/args:`
keyword triple 15+ times**:

```ruby
FileFolding.try_dispatch(receiver: receiver_type, method_name: method_name, args: arg_types) ||
  ShellwordsFolding.try_dispatch(receiver: receiver_type, method_name: method_name, args: arg_types) ||
  MathFolding.try_dispatch(receiver: ...) || … # 8 entries
```

**Pain.** A new tier means writing the module *and* hand-splicing it
into the ladder. Order is significant (documented in comments) but not
viewable as a list.

**Direction.** `SINGLETON_FOLDERS = [FileFolding, ShellwordsFolding, …]`
driven by `SINGLETON_FOLDERS.lazy.filter_map { |m| m.try_dispatch(**ctx)
}.first`. Order = array order. Requires Finding 3 first.

## Finding 3 — Entry-point names and signatures are not uniform

`try_dispatch` (cgi/uri/file/math/regexp/set/shellwords/kernel/shape)
vs `try_fold` (`constant_folding.rb:135`, `block_folding.rb:72`) vs
`try_forward`/`try_backward` (`method_folding.rb`). Signatures diverge
too: `args:` only / `+ block_type:` / `+ environment:, call_node:,
scope:` (`rbs_dispatch.rb:121` carries
`# rubocop:disable Metrics/ParameterLists`).

**Pain.** This is the root blocker for Finding 2's generic iteration;
the tier interface is implicit.

**Direction.** Unify the pure tiers on `try_dispatch(receiver:,
method_name:, args:)` (alias-migrate). Context-hungry tiers take one
`context:` object, retiring the `ParameterLists` suppression.

## Finding 4 — Catalog loaders are boilerplate + a 3-site edit

Each `*_catalog.rb` is effectively one statement
(`random_catalog.rb:24`, `set_catalog.rb:22`, …):

```ruby
XXX_CATALOG = MethodCatalog.new(
  path: File.expand_path("../../../../data/builtins/ruby_core/<topic>.yml", __dir__),
  mutating_selectors: { … })
```

- `File.expand_path("../../../../data/builtins/ruby_core/…", __dir__)`
  — the `../../../../` is **copied in 20 files**; a layout change breaks
  all at once.
- A new catalogue is a **3-site hand edit**: the `require_relative` line
  (`constant_folding.rb:4-22`), the `CATALOG_BY_CLASS` row (`:1212-1236`),
  and the loader file itself. The scaffold tool papers over this, but the
  duplication is structural.

**Direction.** (a) Collapse path resolution into
`MethodCatalog.for_topic("set")`, isolating `../../../../` to one place.
(b) Let loaders self-register (`MethodCatalog.register(String, "String",
topic: "string")`) so the require list and `CATALOG_BY_CLASS` merge.

> ⚠️ The `mutating_selectors:` blocklists and their per-selector
> comments (e.g. `set_catalog.rb:38-48`, `random_catalog.rb:30-53`) are
> **genuine design knowledge — not boilerplate**. They record exactly
> which `:leaf` entries the static C classifier mis-attributes and why.
> Preserve them verbatim; only thin the container.

## Finding 5 — Fixture escaping, size caps, and rescue floors re-implemented by hand

Flagged by the `rigor-type-coverage-uplift` skill itself:

- **`assert_type` backslash multi-escaping** — fixtures hand-count
  `'"hello\\\\ world"'`; error-prone on every fold-result assertion.
- **Three-parameter handler convention** — `def h(tuple, args)` silently
  binds `method_name` into `args`.
- **Size caps / `rescue → nil`** re-implemented per folder
  (`shellwords_folding.rb` `SPLIT_LIMIT = 64` mirrors ConstantFolding's
  `STRING_ARRAY_LIFT_LIMIT` by intent but is a separate constant).

**Direction.** Absorb caps + rescue into the Finding 1 harness. Replace
hand-escaped fixture strings with a helper that derives the assert
string from a Ruby value.

## Summary (ROI order)

| # | Pain point | Scale | Risk |
|---|---|---|---|
| 1 | Tier-D folder skeleton (8 modules, `dispatch_target?` ×9) | large | low (pure fns, well-tested) |
| 2 | Hand-written `\|\|` dispatch ladder (triple ×15) | medium | low–med (order is a requirement) |
| 3 | Non-uniform entry names / signatures | medium | med (broad alias migration) |
| 4 | Catalog loader boilerplate + 3-site edit + `../../../../`×20 | medium | low |
| 5 | Fixture escaping / cap / rescue re-implementation | small–med | low |

Biggest lever is folding 1+2+3 together: pure singleton folders behind
one interface, a declaration table, and array-driven dispatch.

## Execution order (ease-of-implementation)

1. **Finding 4** — smallest, safest, no interface change. Path helper +
   self-registration.
2. **Finding 1** — `SingletonFunctionFolder` harness; migrate URI / CGI /
   Shellwords first as the proof, then Math / Regexp / Set / Time / File.
3. **Finding 3** — unify entry-point interface (unblocks 2).
4. **Finding 2** — array-driven dispatch once entry points are uniform.
5. **Finding 5** — fixture-helper + cap/rescue absorption, opportunistic
   alongside 1.

Every step gated by `make verify` (test / lint / check / check-plugins)
with folded results unchanged.

## Progress log (2026-06-03 → 2026-06-04)

- **Finding 4 — DONE (path helper).** Added
  `MethodCatalog.for_topic(topic, mutating_selectors:)` resolving under a
  single `DATA_ROOT`; migrated all 18 instance loaders off the copied
  `File.expand_path("../../../../…", __dir__)`. Blocklists untouched.
  - **Self-registration sub-part — WON'T DO (decision).** Merging the
    `require_relative` list with `CATALOG_BY_CLASS` via load-order
    self-registration is *not* a clean win: `CATALOG_BY_CLASS` is walked
    in declaration order for subclass disambiguation (`DateTime` before
    `Date`, `MatchData`/`Regexp` sharing one catalog), and that order
    does **not** match `require` order. Self-registration would still
    need explicit ordering hints, so it trades one table for another
    plus a load-order coupling. Left as the explicit 3-site edit.
  - **`NumericCatalog` consolidation — DONE.** It was the last per-class
    catalog with its own hand-rolled `safe_for_folding?` / `method_entry`
    / `load_catalog` copy of `MethodCatalog` (it predated the generic
    loader). Replaced with `NUMERIC_CATALOG = MethodCatalog.for_topic(
    "numeric")`; `CATALOG_BY_CLASS` Integer/Float rows repointed. Bang
    gate is a no-op (no foldable numeric bang methods); MethodCatalog's
    alias resolution adds five sound folds (`magnitude`→`abs`,
    `inspect`→`to_s`, …) with no snapshot movement. ractor-readiness
    check now asserts the instance is shareable via the
    `CATALOG_BY_CLASS` deep-freeze.
- **Finding 1 — DONE.** Extracted `MethodDispatcher::SingletonFolding`
  (`receiver?` + `constant_string`); migrated all 9 receiver predicates
  (CGI/URI/Shellwords/Math/Time/Regexp/Set/File + iterator_dispatch's
  `Class` check) and the 4 string-folding `Constant[String]` unwraps onto
  it. Concluded a full declaration-table harness is **over-engineering** —
  the fold bodies (Math numeric, File platform gate, Set constructor,
  Time arity, Shellwords cap) are too varied to table-drive without
  burying domain logic. Extracted only the genuinely-identical gate.
- **Finding 2 — DONE (singleton chain).** `dispatch_stdlib_module_tiers`
  is now `STDLIB_MODULE_FOLDERS.each`-driven (8 folders already shared
  `try_dispatch`, so no Finding 3 dependency for *this* chain). The
  `dispatch_precise_tiers` ladder (697-705) still mixes `try_fold` /
  `try_dispatch` / `try_forward` / block_folding and **does** need
  Finding 3 first — not started.
- **Finding 3 — DONE (full interface-ization).** Every dispatch tier now
  takes a single immutable `CallContext` (`Data.define`) and conforms to
  one interface, `try_dispatch(CallContext) -> Type::t?`:
  - **Slice A** — `CallContext` value object (9 fields: the call quartet
    + block_type/environment/call_node/scope/self_type_override/public_only)
    with a `.build` keyword factory carrying the single
    `Metrics/ParameterLists` disable that retires the per-tier ones.
  - **Slice B1** — precise tiers (ConstantFolding `try_fold`→`try_dispatch`,
    BlockFolding `try_fold`→`try_dispatch`, MethodFolding forward
    `try_forward`→`try_dispatch`, LiteralString/Shape/Kernel + the eight
    singleton folders). `dispatch_precise_tiers` builds the context once
    and drives a single `PRECISE_TIERS` list, absorbing the
    `STDLIB_MODULE_FOLDERS` sub-list from Finding 2.
  - **Slice B2** — context-heavy tiers (RbsDispatch `try_dispatch` —
    ParameterLists disable removed — + `block_param_types`,
    MethodFolding `try_backward`, IteratorDispatch `block_param_types`).
    `dispatch` builds the context once at the top; the two derived RBS
    sites use `CallContext.build`.
  - **Slice B3** — `interface _DispatchTier` + `CallContext` class
    declared in `sig/rigor/inference.rbs` (typed with `Type::t`).
    `make steep-check` green. Declarative only — no forced per-tier
    conformance, matching the engine's partial-signature idiom.
  - Tier entry points are called only from `method_dispatcher.rb` + the
    tier unit specs; specs migrated via a new `cc(...)` support helper
    (Slice B's 102 call sites). Public `dispatch` /
    `expected_block_param_types` keep their keyword signatures (external
    callers unaffected).
  - **Performance: neutral.** Interleaved A/B of `rigor check --no-cache
    lib` (pre-Finding-3 d153403d vs post 4545dc63, 4 pairs) — pre mean
    7.58s, post mean 7.70s (~1.6%), well inside the run-to-run variance
    (6.93–8.40s, ±15%; one pair shows post faster). The per-dispatch
    `CallContext` allocation does not move the needle.
  - **Caught in the full suite, not the unit/inference specs:**
    `ShapeDispatch.dispatch_intersection` re-enters `try_dispatch` once
    per Intersection member; that *intra-tier recursion* still passed the
    old keyword Hash and raised `NoMethodError` post-migration. The
    tier-caller survey excluded `method_dispatcher/` itself, so it was
    missed — only the `intersection_refinement` integration fixture
    exercises the path. **Lesson: when changing a tier-entry signature,
    grep the tier directory itself for recursive self-calls, and always
    run the full `rspec` (not just the unit + `spec/rigor/inference`
    subset) before claiming behaviour-neutral.** Fixed; 5406 examples,
    0 failures.
- **Finding 5 — NOT STARTED.** Fixture-escaping helper + cap/rescue
  absorption.
