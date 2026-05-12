# ADR-14 — RBS signature generation and augmentation from inference

Status: **proposed, 2026-05-12.** Design fixed here so the
`rigor sig-gen` command can land in a future v0.1.x slice
against a stable contract. Implementation queued (no
committed milestone). ADR-12 (dry-rb packaging) still holds
its reserved slot; this ADR is independent of it.

## Context

Rigor today is a one-way pipe: source code (`.rb`) plus
type sources (`sig/*.rbs`, gem RBS, `RBS::Extended`
annotations, plugin contributions) flow IN; diagnostics
flow OUT. The CLI surfaces `rigor type-of FILE:LINE:COL`
and `rigor type-scan PATH` as inspection probes over
`Scope#type_of`, but neither writes anything back to the
repository.

In practice the inference engine knows materially more
than the user has authored:

- For user-defined `def` methods with simple required
  positional parameters, `Inference::ExpressionTyper#infer_user_method_return`
  re-types the method body at the call site and produces
  the most precise carrier the body proves
  ([`lib/rigor/inference/expression_typer.rb:1068`](../../lib/rigor/inference/expression_typer.rb#L1068)).
  This work is currently invisible to anyone other than
  the immediate diagnostic surface.
- Every call site under `lib/` and every spec block under
  `spec/` (or `test/`) is, in effect, an *observation* of
  the parameter types a method actually receives. The
  union of these observations is a correctness-preserving
  upper bound on the parameter contract.
- Many Ruby projects ship no `sig/` at all, or a partial
  `sig/` covering the public API but not internal helpers.
  Authorship friction is the dominant adoption barrier.

[ADR-5](5-robustness-principle.md) Open Question #3 already
flagged the suggestion surface as a deferred design point:

> Should the diagnostic surface report a *suggestion* when a
> user-supplied parameter is nominally typed but every call
> site passes a structural-interface-compatible value? This
> would be a clause-2 advisory rather than an error.

ADR-14 answers that question, broadens it to cover return-
type tightening AND missing-method emission, and lifts the
delivery channel out of the diagnostic stream into a
purpose-built CLI subcommand. The user keeps full control
over what lands on disk.

## Goals

- Let Rigor emit RBS signatures derived from inference so
  users adopt RBS coverage without re-authoring what the
  analyzer already proves.
- Cover three scenarios with one command:
  1. `.rb` file with **no** corresponding RBS file.
  2. RBS file present but **missing methods** that exist
     in the source.
  3. RBS file present, method declared, but inference
     proves a **strictly more precise** return type.
- Use both the **defining file** (body inference) and
  **caller hints** (call sites under `lib/` and `spec/`)
  as type sources, per the user's request.
- Stay observably compliant with ADR-5: strict returns
  by default, lenient parameters by default, user opts in
  to tightening parameters.
- Never silently mutate user-authored RBS that already
  defines a method. Overwrite is an explicit flag, not the
  default mode.

## Non-Goals

- **Not a `rbs prototype` replacement.** `rbs prototype rb`
  emits a purely syntactic skeleton from `def` shapes;
  `rigor sig-gen` emits a semantic skeleton from inferred
  carriers. Users who want syntactic skeletons stay on
  `rbs prototype`; `rigor sig-gen` is the inference-driven
  complement, not its competitor.
- **Not a step of `rigor check`.** Generation never runs
  implicitly. It is invoked explicitly and produces output
  the user reviews before adopting.
- **Not for stdlib / gem RBS.** Only the project's own
  `sig/` tree (and only files under directories the user
  authorises) is writable.
- **Not a runtime type-checking generator.** The output is
  RBS — static. The runtime story is unchanged.
- **Not coupled to the cache contract** for the first
  slice. Generation may opt into the cache for speed once
  the core path is stable; the MVP runs over a fresh
  inference pass.

## Decision

Land a new top-level CLI subcommand `rigor sig-gen` plus a
small generation core under `lib/rigor/sig_gen/` that:

1.  **Inspects sources** under given `PATH...` arguments
    (default `lib/` from configuration) for `def` /
    `define_method` / `attr_*` method shapes the engine
    already discovers via `Inference::ScopeIndexer`.
2.  **Optionally collects caller observations** from a
    second set of paths (default `spec/` if present,
    otherwise empty) so parameter-type *suggestions* can
    be derived from real call sites.
3.  **Compares against existing RBS** loaded through the
    project environment (`Rigor::Environment.for_project`),
    classifying each candidate method into one of four
    states:
    - **`new-file`** — no RBS file declares the receiver
      class at all.
    - **`new-method`** — RBS file declares the class but
      not this method.
    - **`tighter-return`** — RBS file declares the method,
      but the inferred return is a strict subtype of (or
      otherwise more precise than) the RBS-declared return.
    - **`equivalent`** — nothing to do; skip silently.
4.  **Emits RBS text** to stdout by default, or `--write`s
    to the project `sig/` tree following one file per
    source-file convention (`sig/<relative-source-path
    without .rb>.rbs`).
5.  **Honours ADR-5 asymmetrically** at every emission
    site (see § "Robustness principle compliance" below).

The command never modifies `.rb` source files. It only
ever creates or updates `*.rbs` files inside the project's
own `sig/` tree (or whatever directories
`configuration.signature_paths` resolves to).

### Surface

```
Usage: rigor sig-gen [options] [paths]

Modes:
  --print           Write RBS to stdout (default).
  --write           Write RBS to sig/<path>.rbs files.
  --diff            Show a unified diff against existing RBS
                    instead of writing.

Selection:
  --new-files       Emit RBS only for source files with no
                    existing RBS coverage at all.
  --new-methods     Emit RBS only for methods missing from
                    an existing RBS file.
  --tighter-returns Emit RBS only for methods whose inferred
                    return is strictly more precise than the
                    RBS-declared return.
                    (All three flags can be combined; absent
                    means "all three modes".)

Robustness controls:
  --params=POLICY   untyped | observed | observed-strict
                    Default: untyped. See § "Robustness
                    principle compliance".
  --observe=PATH... Directories to scan for call-site
                    observations. Defaults to spec/ when
                    present. Multiple paths allowed.
  --overwrite       Allow tighter-return updates to replace
                    user-authored RBS declarations. Off by
                    default; tighter-return mode emits to
                    stdout / diff only without --overwrite
                    + --write together.

Output:
  --format=FORMAT   text (default) | json (machine-readable
                    classification table).
  --config=PATH     Path to the Rigor configuration file.
```

### Output layout

`--write` follows the established Ruby community convention
(`sig/<path>.rbs` mirroring `lib/<path>.rb`). The first
slice supports one source file → one RBS file; multi-class
files emit one RBS file containing both classes.

`--write` MUST NOT touch files outside
`configuration.signature_paths` (default `sig/`). It MUST
NOT touch files Rigor identifies as gem-supplied or stdlib
RBS even if those happen to live under `sig/`.

### Diagnostic identifiers reserved

A new `sig.*` family reports the generator's per-method
decisions when running with `--explain`-style verbosity (a
future slice). For the MVP these are JSON-output fields,
not diagnostics. The reserved identifiers are:

- `sig.generated.new-file`
- `sig.generated.new-method`
- `sig.generated.tighter-return`
- `sig.skipped.complex-shape` — body inference disqualified
  the method (optional/rest/keyword/block parameters; see
  `user_method_param_shape_simple?`).
- `sig.skipped.user-authored` — `--overwrite` not set and
  the existing RBS declaration is user-authored.
- `sig.skipped.untyped-return` — inferred return is
  `Dynamic[top]`; no useful tightening exists.

`sig.*` is added to the [diagnostic family
hierarchy](../type-specification/diagnostic-policy.md) when
slice 1 lands so plugins cannot collide with it.

## Robustness principle compliance

ADR-5 is the controlling principle. ADR-14 translates each
ADR-5 clause into a concrete generator behaviour.

### Returns — clause 1 (precise)

The generator emits the strictest carrier
`infer_user_method_return` proves. This is *the* clause-1
case: inference picks the precise carrier; erasure to RBS
walks the existing `erase_to_rbs` chain
(`Type::Constant`, `Type::IntegerRange`, `Type::Union`,
`Type::HashShape`, etc.) per ADR-1's lossy-export rule.

Exceptions:

- A `Dynamic[T]` return erases to `untyped` per
  `Type::Dynamic#erase_to_rbs`. The generator records this
  as `sig.skipped.untyped-return` and emits nothing for
  that method (writing `def foo: () -> untyped` would
  obscure rather than help).
- A return that erases to the same RBS spelling as the
  existing RBS-declared return is classified `equivalent`
  and skipped.

### Parameters — clause 2 (permissive)

The generator MUST NOT auto-tighten parameter types beyond
what the user explicitly authorises. The `--params` policy
controls this:

- **`untyped` (default)** — every emitted parameter is
  spelled `untyped`. This is the strictest reading of
  clause 2: no inference-derived parameter contract is
  imposed on future callers. The user retains complete
  authorship.
- **`observed`** — the generator collects argument types
  from every call site under `--observe=PATH...` (default
  `spec/`), unions them per parameter position, erases to
  RBS, and emits the union. This is still ADR-5-clause-2
  compliant: the observed union is *exactly* the
  permissive contract the existing callers prove
  sufficient.
- **`observed-strict`** — same as `observed`, but on top
  of that the generator also widens to known capability
  roles (e.g. observed `String` parameters where all
  callers only consume `.to_s` widen to `_ToStr`). This
  is the maximally clause-2 setting; it requires the
  capability-role catalog (which v0.1.x does not yet
  ship — see § "Open questions"). The flag is reserved
  but inert until that catalog exists.

In all three modes, a method whose *existing* RBS
declares a parameter contract is treated as binding: the
generator MUST NOT widen it, and MUST NOT narrow it
without `--overwrite`. This preserves ADR-5's "RBS
authorship that already exists is respected" boundary.

### What "more precise" means for tighter-return mode

A new return type is "strictly more precise" than the
existing RBS-declared return when:

1. The new type's `erase_to_rbs` is a *different string*
   from the existing declaration's RBS spelling, AND
2. The new type is a subtype of the existing declaration
   under `Inference::Acceptance.accepts(existing, new,
   mode: :strict)`.

The strict-mode acceptance check is the same predicate
the analyzer uses for return-type-mismatch
([`def.return-type-mismatch`](../adr/8-steep-inspired-improvements.md)),
which guarantees the generator never emits a tightening
that the analyzer itself would flag as a soundness
violation against the existing declaration.

## How caller-side observations are collected

For `--params=observed`, the generator runs a second
inference pass over the `--observe` paths and, for every
`Prism::CallNode` whose method name matches a target,
records the `arg_types` (a tuple of `Type::*` carriers).
Resolution uses the same `Inference::ExpressionTyper`
pipeline that powers `rigor check`, so the observation
tier is consistent with the rest of Rigor.

Receiver matching is conservative:

- For instance methods: the receiver type must be a
  `Type::Nominal` whose `class_name` exactly matches the
  target class. Subclass dispatches are NOT credited to
  the parent (ADR-9's class-ordering aware reverse
  lookups are deferred to a later slice).
- For top-level / DSL-block defs: the receiver is
  implicit `self`; only `node.receiver.nil?` call sites
  contribute.
- `define_method`-bound names are treated like `def`s
  with no callable body (the generator skips them in the
  MVP; see slicing).

Observations from RSpec-style spec files use the same
mechanism. There is no RSpec-specific recogniser in the
MVP — the generator only sees them as ordinary call
sites. Future slices may add RSpec-aware recognisers
(e.g. recognising `subject(:foo) { … }` as a definition
or `let(:bar) { … }` as a binding), but the MVP keeps
that surface inside `rigor-rspec` and out of the core
generator.

## Boundary with ADR-1 (RBS round-trip)

The generator is the most aggressive Rigor → RBS export
path. ADR-1 guarantees the export is conservatively
erasing; the generator MUST observe that guarantee:

- Every emitted type goes through `Type#erase_to_rbs`.
- Carriers that have no faithful RBS spelling (e.g.
  precise `HashShape` literals when the export target is
  RBS classic) erase to their nominal envelope.
- Plugin-contributed types route through the plugin's
  `TypeNodeResolver` chain (ADR-13) when an
  `%a{rigor:v1:return: …}` annotation is the most
  precise spelling. The generator MAY emit such
  annotations when the resolver chain proves they round-
  trip; the MVP defers this and emits plain RBS only.

## Boundary with ADR-0 (no Rigor-specific inline DSL)

The generator emits to `*.rbs` files, not to `*.rb`
files, and the RBS it emits is plain RBS (plus optionally
`RBS::Extended` annotations in future slices). Application
code stays Rigor-annotation-free.

## Boundary with ADR-2 / ADR-9 (plugin contract)

The generator runs entirely inside core for the MVP. It
consumes the same `Environment` plugins use as input but
does not invoke the plugin contribution path. Plugins
that already contribute method signatures (e.g.
`rigor-sorbet`, `rigor-activerecord`) are *upstream*
sources of truth: the generator reads their contributions
as part of the existing-RBS comparison, never overwrites
them, and classifies their methods as
`sig.skipped.user-authored` for tighter-return mode.

A future slice MAY expose a plugin hook
(`Plugin::SignatureSuggester` or similar) so plugins can
filter / annotate generator output. ADR-14 does not commit
to that surface today.

## Implementation slicing

The MVP plus four follow-up slices, mirroring the slicing
pattern ADR-13 used. Each slice lands as a separate commit
with its own CHANGELOG `[Unreleased]` entry.

1.  **Slice 1 — MVP (`def` methods, return-only,
    `--print`).** New command `rigor sig-gen` with
    `--print` / `--diff` modes, supporting only the
    return-type tier and only `def` methods that
    `user_method_param_shape_simple?` accepts. Parameter
    policy is hard-coded `untyped` (`--params` flag
    parsed but only `untyped` is wired). Output format
    `text` and `json`. Covers the three classifications
    (`new-file` / `new-method` / `tighter-return`) using
    a fresh inference pass over the input paths. No
    caller-hint collection yet; reserves the flag.
    Integration spec under `spec/rigor/cli/sig_gen_command_spec.rb`.

2.  **Slice 2 — `--write` mode with merge.** Adds the
    `--write` mode. Parses existing RBS files via
    `RBS::Parser`, inserts new method declarations into
    the matching class declaration, leaves all other
    declarations untouched. New `sig/<path>.rbs` files
    are created when needed. `--overwrite` gates
    tighter-return rewrites of user-authored declarations.
    Whitespace / comment preservation uses the upstream
    `RBS::Writer` (lossy on comments — documented;
    rejection criteria in `--diff` mode if the user
    wants comment preservation).

3.  **Slice 3 — `--params=observed`.** Adds the
    second-pass caller observation collector. New
    machinery: `Rigor::SigGen::ObservationCollector`
    walks `--observe` paths, accumulates per-target-method
    `Array[Tuple[Type, ...]]`. Per parameter position the
    aggregator builds the lattice join. ADR-5 clause 2
    compliance: the observation is ALWAYS a *suggestion*;
    `--params=untyped` remains the default; emitted
    parameter types are NEVER widened beyond the join.

4.  **Slice 4 — Additional method shapes.** Extends body-
    inference and emission to:
    - `attr_reader` / `attr_writer` / `attr_accessor`
      (return / parameter from the ivar's accumulated
      type).
    - `define_method` with a literal symbol name and a
      simple block body.
    - Singleton-side `def self.foo` and `class << self`
      methods.
    - `Data.define`-derived readers (already covered by
      core inference; the generator just consumes the
      facts).

5.  **Slice 5 — RSpec-aware observations + handbook.**
    Optional dependency on `rigor-rspec` so that, when
    present, RSpec-block-supplied bindings (`subject`,
    `let`, `described_class.new(...)`) contribute
    cleaner observations than the raw call-site walker
    sees. Handbook chapter covering the generator's UX
    + the ADR-5 trade-offs the `--params` policy
    surfaces.

The MVP is intentionally small. Each subsequent slice has
a clean cut from the previous one; the user can
authorise them independently.

## Working decisions

### WD1 — Why a new top-level command rather than a `rigor check --fix`-style flag?

`rigor check` is the diagnostic surface. Bolting RBS
emission onto it would conflate two responsibilities (read
+ write) on one command and create a permission boundary
inside a single invocation (the read tier always runs;
the write tier needs user authorisation). A separate
command keeps `rigor check` purely diagnostic and makes
the write tier explicit at the CLI shell.

### WD2 — Why default `--params=untyped` rather than `observed`?

ADR-5 clause 2 + the user's instruction: parameter
tightening is the user's choice, not the analyzer's.
Defaulting to `observed` would silently tighten parameters
in every emitted signature on first use. Defaulting to
`untyped` makes adoption painless (the user gets useful
return tightening immediately) and turns parameter
tightening into a deliberate opt-in. The future
`observed-strict` policy is the most precise setting; it
requires capability-role infrastructure that does not
exist yet.

### WD3 — Why a new `sig.*` diagnostic family?

The generator's per-method classification is *meta-
inference*: information about how inference compared
against existing authorship, not about whether the code
under analysis is correct. Reusing `dynamic.*` or
`def.*` would conflate two different telemetry channels.
The `sig.*` family is reserved here and added to the
diagnostic family hierarchy when slice 1 lands.

### WD4 — Why not auto-write on `rigor check`?

Write actions on user-owned files (even in `sig/`) need
explicit authorisation per the project's "executing
actions with care" rule. A separate command gives the
user the seam to review (`--print`, `--diff`) before
authorising the write (`--write`).

### WD5 — Why not extend `rbs prototype`?

`rbs prototype rb` lives upstream and walks `Prism::DefNode`
syntactically; it has no inference engine, no access to
narrowing, no observation collector. Forking it would
either duplicate huge swathes of upstream code or yield
a fork that drifts. Rigor's generator runs *alongside*
`rbs prototype`: users who want a syntactic skeleton use
upstream; users who want an inferred skeleton use Rigor.

### WD6 — Why ADR-14, not ADR-12?

ADR-12 is reserved for dry-rb packaging per the existing
roadmap. ADR-14 takes the next free slot and stays
independent of the packaging discussion.

## Alternatives considered

- **Generator as a `rigor-sig-gen` plugin.** Rejected:
  the generator depends on the core inference pipeline
  (`Inference::ExpressionTyper`, `Scope#evaluate`) more
  directly than the plugin contract exposes today.
  Adding it as a plugin would force a contract widening
  ahead of demonstrated need.
- **`rigor check --emit-rbs`.** Rejected per WD1 +
  WD4: conflates read and write surfaces.
- **Hook into the existing `dynamic.*` diagnostic
  surface** (suggest types via diagnostics, let the user
  copy them out). Rejected: diagnostics are noisy at
  scale, and the suggestion needs to round-trip
  through `RBS::Writer`-shaped output, not a one-line
  message.
- **Build on top of `Steep`'s scaffolding tools.**
  Rejected: introduces a runtime dependency on Steep
  outside the existing `tool/steep/Gemfile` cross-
  checker boundary. AGENTS.md keeps Steep at arm's
  length; the generator stays in-tree.

## Open questions

- **Capability-role catalog.** `--params=observed-strict`
  needs `_ToStr` / `_ToS` / `_ReadableStream` / … as
  authored carriers. The structural-shape spec
  ([`docs/type-specification/structural-interfaces-and-object-shapes.md`](../type-specification/structural-interfaces-and-object-shapes.md))
  reserves the surface; the catalog is not yet
  populated. Until it is, `observed-strict` is inert.
- **Generic methods.** The generator emits
  `def foo: (untyped) -> Integer` for a method whose
  body proves the return is `Integer` regardless of the
  parameter type. If the body's return depends
  algebraically on the parameter type, the generator
  needs a type-parameter introduction step. Deferred
  until the lightweight-HKT exploration (project
  memory) lands a concrete surface.
- **Block parameter signatures.** Today the generator
  rejects any method with a block parameter (`params.block.nil?`
  in `user_method_param_shape_simple?`). A future
  slice could emit `() { (E) -> R } -> …` once the
  inference engine tracks block-yield shapes
  end-to-end.
- **Comment preservation in merge mode.** `RBS::Writer`
  is lossy on comments by upstream design. Slice 2
  preserves untouched declarations verbatim by
  operating on byte ranges where possible, but mixed
  hand-written + generator output in the same class
  declaration loses comments inside the touched
  declaration. The `--diff` review surface flags this.
- **Tapioca-generated RBI under `sorbet/rbi/`.** Out
  of scope — the generator targets RBS under `sig/`,
  not RBI. The `rigor-sorbet` plugin (ADR-11) reads
  RBI; the generator stays in the RBS lane.

## Related ADRs

- [ADR-0: Concept](0-concept.md) — "Application Ruby code
  stays free of Rigor-only annotation syntax." ADR-14
  emits to `*.rbs`, not `*.rb`; the boundary holds.
- [ADR-1: Type Model and RBS Superset Strategy](1-types.md)
  — RBS round-trip is conservatively erasing. ADR-14 is
  the most aggressive Rigor → RBS export site; it observes
  the rule by routing every emission through
  `Type#erase_to_rbs`.
- [ADR-4: Type Inference Engine](4-type-inference-engine.md)
  — the engine that produces the types ADR-14 emits.
- [ADR-5: Robustness Principle](5-robustness-principle.md)
  — controls the asymmetric return-vs-parameter policy
  ADR-14 surfaces at the CLI.
- [ADR-8: Steep-Inspired Improvements](8-steep-inspired-improvements.md)
  — `def.return-type-mismatch` is the soundness predicate
  ADR-14 reuses to decide whether a tightening is safe.
- [ADR-13: TypeNode Resolver Plugin](13-typenode-resolver-plugin.md)
  — plugin-supplied type vocabulary that future slices
  may emit when the resolver chain proves a round-trip.

## Revision history

- 2026-05-12 — initial draft.
