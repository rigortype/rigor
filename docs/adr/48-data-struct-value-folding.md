# ADR-48 — Struct / Data value folding (member-shape carriers)

Status: **Accepted — `Data.define` slices 1–4 implemented (v0.1.17) plus
bare-local block-form parity; `Struct` follow-up slices 1–4 implemented
(fresh-chain + fold-safe bound-local + setter re-typing).** Two new
type carriers — a **member-class carrier** (`Type::DataClass`) and a
**member-instance carrier** (`Type::DataInstance`) — so that a
`Data.define`-defined value object folds member reads to precise types
(`Point = Data.define(:x, :y); Point.new(1, 2).x` → `Constant[1]`). Shipped
for all three definition forms (constant-assigned, `class X < Data.define(...)`
subclass, bare local), both positional + keyword construction, and the
`[]` / `to_h` / `deconstruct` / `deconstruct_keys` / `members` / `with`
projections. A `DataFolding` dispatch tier reads a cross-file
`Scope#data_member_layouts` side-table the scope indexer populates for the
named forms. **Slice 4 (block-body hardening) landed:** a named class whose
body redefines a member's synthesised reader (`def x`) no longer folds that
member's *read* (it would run the redefined method) — the value accessors
(`[:x]` / `to_h`) still fold because they bypass the reader — gated on a real
`def` node in the project def-node table. **Bare-local block-form parity
landed:** the block form with no resolvable class name (`c = Data.define(:x)
do … end`) now folds too — the block AST is scanned directly for a
member-reader `def`, so a helper-only block folds and a reader-redefining (or
`&proc`) block bails. Folding is
**precision-additive only** — no new diagnostic family, no false-positive
surface (per the project's false-positive-discipline value). Grounded in the
Phase-5 coverage audit
[`docs/notes/20260523-struct-encoding-coverage.md`](../notes/20260523-struct-encoding-coverage.md),
which deferred this as ADR-worthy and named `Data.define` the better
first target.

**`Struct` follow-up — slices 1 + 2 landed (the sound *transient* form).**
The mutable sibling carriers `Type::StructClass` / `Type::StructInstance`
ship, `Struct.new(...)` folds to a `StructClass` member layout, `.new` /
`[]` materialises a `StructInstance`, and a member read off a **fresh**
(chained) instance folds (`Struct.new(:x, :y).new(1, 2).x` → `Constant[1]`,
for the anonymous / constant / subclass / local-class forms, positional +
`keyword_init:`). The mutation-soundness story is resolved by a
**fresh-receiver gate** rather than write-site invalidation: a member read
off a *stored* binding degrades to `Dynamic[top]` (a transient cannot have
been mutated between materialisation and a chained read, so no invalidation
is needed; a stored binding might have, so it is not folded). This touches
no write sites — far lower false-positive risk than enumerating every escape
path — and is precisely the gate the deferred slice 3 relaxes. See
§ "Struct follow-up" below for the full record.

**Struct slice 3 landed (2026-06-15) — fold-safe bound-local member folding.**
A member read off a *stored* local now folds when a conservative whole-body
allow-list scan ([`Inference::StructFoldSafety`](../../lib/rigor/inference/struct_fold_safety.rb))
proves the local is never mutated, aliased, or escaped (`p = Point.new(1, 2);
p.x` → `Constant[1]`); a written / aliased / escaped local stays
`Dynamic[top]`. The scan is an allow-list (every use must be a known-pure read
— a missed case is over-conservative, never unsound), installed once per body
on the scope (`Scope#struct_fold_safe?`) at the top-level and method-body
entry points. See § "Struct follow-up".

**The two demand-gated remnants landed together.** *Bare-local block-form
parity* (`c = Data.define(:x) do … end`): the block has no resolvable class
name for the read-time reader-redefinition guard, but the block AST is in hand
at `Data.define` time, so it is scanned directly — the carrier folds when the
block redefines no member reader, and bails conservatively (a `&proc` block, a
reader-redefining `def <member>`) the way the unresolvable case did before. And
the `Struct` **slice 4** (precise re-typing of a mutated member through a setter
— `s.x = 5; s.x` → the assigned type, the sibling stays precise): a fold-safe
local extended to allow straight-line member setters, whose binding a setter
write-back (`StructFolding.apply_setter_writeback`, at `eval_call`'s post-call
scope) keeps current so the later read folds. A setter inside a loop / block /
lambda, an alias, or an escape keeps the local unfolded (FP-safe). Designed in
[`docs/notes/20260615-struct-folding-slice3-design.md`](../notes/20260615-struct-folding-slice3-design.md).

## Motivation

`Data.define` (Ruby 3.2+) and `Struct.new` are the idiomatic way to write
small immutable/mutable value objects. Rigor sees them constantly — its
own `lib/` defines dozens (`Scope::IndexedKey`, every `Data.define(...)`
in `triage.rb`, `fact_store.rb`, `incremental_session.rb`, …). Today every
one of those instances types as `Dynamic[top]` and every member read
(`record.consumer`, `summary.total`) returns `Dynamic[top]`. That is the
single largest remaining *value-folding* gap now that the shape-carrier
fold tier (Tuple / HashShape / String / Hash) is comprehensive.

The win is precision, not false-positive reduction: a member read that
folds to `Constant[1]` instead of `Dynamic[top]` flows a precise type
downstream, sharpens narrowing, and makes `dump.type` useful on value
objects. There is no diagnostic attached — this ADR adds carriers and
fold handlers, never a rule.

## What exists today

The recognition layer is **already half-built** for the *existence* side
(ADR-24 slice 4a / v0.1.2), and is directly reusable here:

- `Inference::ScopeIndexer#data_define_call?` / `#struct_new_call?`
  recognise a `Data.define(...)` / `Struct.new(...)` call node.
- `#meta_member_names(call_node)` extracts the ordered Symbol member names
  (stripping `Struct.new`'s optional leading String name + trailing
  `keyword_init:` hash via `#struct_new_positionals`).
- `#record_meta_superclass_members(class_node, …)` already registers the
  synthesized reader methods of `class Point < Data.define(:x, :y)` in the
  discovered-methods **existence** table — so `Point.new(1, 2).x` is
  already known to *exist*; this ADR makes its *value* fold.
- `#meta_new_block_body` recognises the `Const = Data.define(:a) do … end`
  block-body idiom (the block defines extra methods on `Const`).

The dispatch/type side is **defensive only**:

- `Inference::Builtins::STRUCT_CATALOG`
  ([`struct_catalog.rb`](../../lib/rigor/inference/builtins/struct_catalog.rb))
  recognises `Struct` as a receiver and blocklists `:[]` / `:hash` /
  `:initialize_copy` against a "hypothetical future `Constant<Struct>`
  carrier". `Data.define` / `Struct.new` are classified `:block_dependent`
  in `data/builtins/ruby_core/struct.yml`, so `ConstantFolding` declines
  and the call resolves through RBS to `Dynamic[top]`.
- The integration fixture
  [`struct_catalog.rb`](../../spec/integration/fixtures/struct_catalog.rb)
  pins the status quo: `Struct.new(:foo, :bar)` → `Struct` (Nominal),
  `Struct.new(:foo).new(1)` → `Dynamic[top]`.

So: member *names* are recognised, member *existence* is registered, but
nothing models a per-instance member **layout** to project a read against.
That layout is the missing carrier.

## Decision

### Two carriers (Data first)

Introduce two carriers, mirroring the `Singleton[C]` (class object) /
instance (value) split, parameterised by the member layout:

1. **`Type::DataClass`** — models the *class object* produced by
   `Data.define(:x, :y)`. Fields:
   - `members` — frozen ordered `Array<Symbol>` of member names.
   - `class_name` — the bound constant name when known (`"Point"`), else
     `nil` for the anonymous-in-flight value before assignment. Display +
     instance-tagging only; **not** part of structural identity beyond the
     field-wise compare (two distinct `Data.define(:x)` results are equal
     as types, which is correct — they are the same *shape*; the engine
     distinguishes the *constants* by their binding, not the carrier).
   - (No `keyword_init` field — `Data` has no such flag. Reserved for the
     Struct follow-up, see below.)

   `DataClass` is what the constant `Point` (or the `class Point < …`
   subclass) carries as its type. Its only folding role is `.new` /
   `.[]` / `.members`.

2. **`Type::DataInstance`** — models a *value* `Point.new(1, 2)`. Fields:
   - `class_name` — the tagging class name (`"Point"`) or `nil`.
   - `members` — frozen ordered `Hash{Symbol => Rigor::Type}` of member
     name → value type. HashShape-shaped, but **closed and total** (every
     declared member is present; `Data` instances have no optional
     members) and **class-tagged** (unlike a bare `HashShape`, which is
     structural).

Both are **immutable, frozen-at-construction, structurally-equal**
carriers built via `Rigor::ValueSemantics` `value_fields` (no hand-written
identity — there is no class-discriminator subtlety like `Constant`'s
Integer-vs-Float case). Both include `Rigor::Type::AcceptanceRouter`.

`Data`'s **frozen instances are why it is the first target**: a
`DataInstance`'s member types can never be invalidated by a later setter
or `[]=` or aliased mutation, so the member map is sound for the
instance's whole lifetime. (This is the soundness hole that defers
`Struct`.)

### The fold pipeline

```
Data.define(:x, :y)        → DataClass{ members: [:x, :y] }
Point = <DataClass>        → constant Point carries DataClass            (existing constant-binding flow)
class Point < <DataClass>  → Singleton[Point] inherits the member layout (via record_meta_superclass_members + a new member-layout side-table)
Point.new(1, 2)            → DataInstance{ class: "Point", members: { x: Constant[1], y: Constant[2] } }
Point.new(x: 1, y: 2)      → DataInstance{ … }  (keyword form mapped by name)
inst.x                     → Constant[1]        (member read projection)
inst[:x] / inst[0]         → Constant[1]
inst.to_h                  → HashShape{ x: Constant[1], y: Constant[2] } (closed)
inst.deconstruct           → Tuple[Constant[1], Constant[2]]
inst.deconstruct_keys(nil) → HashShape{ … }
inst.with(x: 9)            → DataInstance{ members: { x: Constant[9], y: Constant[2] } }
inst.members               → Tuple[Constant[:x], Constant[:y]]
```

Two new dispatch handlers, both registered in
`Inference::MethodDispatcher::ShapeDispatch::RECEIVER_HANDLERS` (the same
table that routes `Type::HashShape => :dispatch_hash_shape`):

- `Type::DataClass => :dispatch_data_class` — handles `:new` (the
  instance-materialisation choke point), `:members`, `:[]` (Data 3.2's
  `Point[1, 2]` alias for `.new`).
- `Type::DataInstance => :dispatch_data_instance` — handles the member
  readers (projecting `members[name]`), `:[]`, `:to_h`, `:deconstruct`,
  `:deconstruct_keys`, `:with`, `:members`, `:==`/`:eql?`/`:hash` (fold to
  `Nominal[bool]`/`Nominal[Integer]` — never a `Constant`, equality across
  carriers is not value-decidable here), `:inspect`/`:to_s` →
  `Nominal[String]`.

`Data.define(...)` itself must be recognised *before* the
`:block_dependent` RBS decline. A new precise tier entry (or an extension
of `ConstantFolding`'s receiver dispatch keyed on `Singleton[Data]` +
`:define`) reads the literal Symbol args via the existing
`meta_member_names` logic and produces the `DataClass`. This runs in the
`PRECISE_TIERS` band, above `RbsDispatch`.

Member reads project exactly like `HashShape#hash_dig_step`: a
`DataInstance` read of member `:x` returns `members[:x]` — no optionality
union (Data instances are total), no `Constant[nil]` fallback for a
declared member (a missing member is a runtime `NoMethodError`, out of
scope; an undeclared member read is left to the existing undefined-method
path).

### Degradation contract (the FP-safety boundary)

Folding is **opt-in on a fully-decidable shape** and degrades to today's
behaviour (`Nominal` / `Dynamic[top]`) the moment any premise is
uncertain. Each degradation is a *precision floor*, never a wrong answer:

1. **Block body present** (`Data.define(:x) do … end` /
   `class Point < Data.define(:x); def m; end; end`) — the block may
   define extra methods, redefine a reader, or add constants. **As shipped
   (slice 4):** for the **named forms** (`class Point < Data.define(...)` and
   `Const = Data.define(...) do … end`) the member layout still folds — the
   block typically only adds helper methods, and `.x` / `to_h` / `[]` keep
   their precision. The one read refused is a member whose synthesised reader
   the body *redefines* with a real `def x`: that read would run the
   redefined method, not return the member, so folding it would be unsound.
   Both named forms register the override as a `def` node under the class
   name, so an entry in the project def-node table (`Scope#user_def_for`) is
   the discriminator — the synthesised reader has no def node. The value
   accessors `[]` / `to_h` / `deconstruct` bypass the reader and stay
   foldable, so the gate is on the bare member read only. The **bare-local**
   block form (`c = Data.define(:x) do … end`) has no resolvable class name,
   so its block defs cannot be looked up in the def-node table — but the
   block AST is in hand at `Data.define` time, so the guard is applied
   against it directly (`fold_define_block` /
   `MemberShapeProjection.block_redefines_member_reader?`): the whole carrier
   folds when the body redefines no member reader, and bails conservatively
   for a reader-redefining `def <member>` or a `&proc` block (no scannable
   body). Validated against Rigor's own `lib` (dense with the
   block-and-subclass form): no self-check regression.
2. **Non-literal / non-Symbol members** (`Data.define(*names)`,
   `Data.define(dynamic_expr)`) — member set unknown → no carrier
   (`Nominal[Data]` / current behaviour).
3. **`.new` arity / key mismatch** — positional count ≠ member count, or a
   keyword key ∉ members, or mixed positional+keyword → **do not fold the
   instance** (a real `ArgumentError` at runtime; our job is to never
   emit a *wrong* member map). Degrade to `Nominal`.
4. **Non-foldable argument types** — a member arg that is itself
   `Dynamic[top]` is stored as `Dynamic[top]` in the member map (the
   instance still folds *structurally*; the member read returns
   `Dynamic[top]`, which is correct and still better than the whole
   instance being dynamic, because *sibling* members stay precise).
5. **Re-opening the class** (`Point = Data.define(...); Point.class_eval …`
   or a later `class Point; def m; end; end`) — out of scope; the member
   *readers* remain valid (Data readers are frozen-synthesised and cannot
   be removed), so member-value folding is unaffected; added methods
   resolve through the user-method path.

6. **Empty container literal as a member argument** (`R.new([], {})`) — a
   member holds a *reference* to the container the constructor was handed,
   so its emptiness is a fact about that argument at the instant of
   construction, not a property of the value object: the caller keeps its
   own alias, and "construct empty, then fill" (`r = R.new([], []);
   xs.each { |x| r.items << x }`) is the dominant Ruby shape. An empty
   `Tuple` / closed empty `HashShape` is therefore recorded **widened** to
   its bare nominal (`Array[untyped]` / `Hash[untyped, untyped]`), through
   the same helpers `MutationWidening` uses to retract a mutated local's
   literal shape. Non-empty literals are untouched: their element evidence
   survives an append, and their reads never fold to `nil`.

Points 1–5 only ever *narrow* a type from `Dynamic[top]` to a proven
member type and degrade to the status quo on any uncertainty, so they add
no false-positive surface. Point 6 is where that reasoning turned out to
have a hole, and is written from the FP it cost: the emptiness pin was the
one member fact whose reads fold to `nil`, and `nil` is the receiver type
`call.undefined-method` fires on. Issue #293 reported it on correct code —
a factory returning `Struct.new(:items, :errors).new([], [])` filled by
`<<` on the next line, whose consumer's `.items.first.local` was reported
undefined. Emptiness aside, the tier stays a pure precision uplift.

### Severity / diagnostic posture

**None.** This ADR adds no rule, no diagnostic identifier, no severity
mapping. It is a pure precision uplift to the inference engine's dispatch
tier. (Contrast ADR-47, which *does* add a rule and therefore carries a
WD4 corpus FP gate; this ADR carries no such gate because it cannot
fire.) The one place a *future* diagnostic could attach — `.new` arity
mismatch as an `arg.*` error — is explicitly **out of scope** here and
would be its own ADR slice with its own FP envelope, exactly as ADR-24
slice 4 split undefined-method from arity.

## Carrier-zoo checklist

Every new `Rigor::Type::*` carrier must satisfy the full contract in
[`docs/internal-spec/internal-type-api.md`](../internal-spec/internal-type-api.md).
For each of `DataClass` and `DataInstance`:

- [ ] **Core class** `lib/rigor/type/data_class.rb` /
  `lib/rigor/type/data_instance.rb` — `include Rigor::ValueSemantics`
  + `value_fields`; `include Rigor::Type::AcceptanceRouter`; `freeze` at
  end of `initialize` (and `freeze` the member collection).
- [ ] **Meta surface** — `describe(verbosity)` (`Point(x: 1, y: 2)` /
  `Point` for the class), `erase_to_rbs` (`Point` nominal for both —
  conservative; the instance's structural members are *not* RBS-
  expressible as a class instance, so erase to the nominal class name, or
  `untyped` for the anonymous case), `normalize` (idempotent; `self` —
  these are already canonical), `traverse(&block)` (yield each member
  value type; `DataClass` is a leaf, no-op), structural `==`/`eql?`/`hash`
  (via `value_fields`).
- [ ] **Capability predicates** — all `Trinary.no` except: `DataInstance`
  answers `record`? Decide in implementation — a `Data` instance is
  *like* a record but class-tagged; lean `Trinary.no` for `record` (which
  means the structural-record family) and rely on `class_object` /
  nominal capability for "is an object". `DataClass#class_object` →
  `Trinary.yes`.
- [ ] **Refinement projections** — empty arrays (no constant-witness
  contribution) except `finite_values` if both carriers are fully
  constant — defer; return empty for slice 1.
- [ ] **Relational queries** — `subtype_of` / `accepts` routed through
  `AcceptanceRouter` → `Inference::Acceptance`; add the acceptance rules
  (a `DataInstance` is acceptable where its `Nominal[class]` is; member-
  wise depth is a follow-up).
- [ ] **Structural queries** — `members` (the structured member shape),
  `has_method(name)` (`Trinary.yes` for a declared reader on
  `DataInstance`), `method(name, scope:)`. `key_type`/`value_type`/
  `tuple_arity` → not-applicable sentinel.
- [ ] **Combinator factory** — `Rigor::Type::Combinator.data_class_of(
  members:, class_name: nil)` + `.data_instance_of(members:,
  class_name: nil)`; production code constructs only through these.
- [ ] **Central require** — `require_relative` in `lib/rigor/type.rb`,
  ordered after the structural carriers (Tuple, HashShape).
- [ ] **RBS surface** — add both classes to `sig/rigor/type.rbs`,
  including the `type t` union alias and the `Combinator` factory
  signatures.
- [ ] **Public-API drift snapshot** — add the new `Combinator` factory
  methods to `PublicApiDriftSnapshots::COMBINATOR_SINGLETON` in
  `spec/rigor/public_api_drift_spec.rb`.
- [ ] **Per-carrier spec** — `spec/rigor/type/data_class_spec.rb` /
  `data_instance_spec.rb` (identity, describe, erase, accepts, members).
- [ ] **Dispatch wiring** — `RECEIVER_HANDLERS` + the two handler methods
  in `ShapeDispatch`; the `Data.define` recogniser in the precise tier.
- [ ] **Integration fixtures + snapshots** —
  `spec/integration/fixtures/data_define*.rb` (+ `.yml` snapshots);
  update the existing `struct_catalog` fixture only when the Struct
  follow-up lands.
- [ ] **Ractor shareability** — frozen immutable carriers; no
  `Ractor.make_shareable` needed beyond `freeze` (the member collections
  are frozen).
- [ ] **CHANGELOG** — `[Unreleased]` entry at landing (release-style).

## Slice plan

1. **Slice 1 — `DataClass` carrier + `Data.define` recognition.**
   The carrier, the factory, the precise-tier recogniser producing
   `DataClass` from a literal-Symbol `Data.define`, and `.new` arity
   handling that returns `Nominal[Data]` (no instance carrier yet) — i.e.
   the class half lands first and `Data.define(...)` stops being
   `Dynamic[top]`. Carrier-zoo checklist for `DataClass`.
2. **Slice 2 — `DataInstance` carrier + member-read folding.**
   `.new` materialises a `DataInstance` (positional + keyword arg → member
   map); the instance-dispatch handler projects member reads, `[]`,
   `to_h`, `deconstruct`, `deconstruct_keys`, `members`, `with`. The
   headline win. Carrier-zoo checklist for `DataInstance`.
3. **Slice 3 — the `class Point < Data.define(:x, :y)` subclass idiom.**
   Thread the member layout from the `DataClass` superclass onto the named
   subclass so `Point.new(...)` folds (the common real-world form; the
   existence side already exists via `record_meta_superclass_members`).
   This is the integration-heavy slice (a class → member-layout
   side-table read at the `.new` choke point).
4. **Slice 4 — block-body degradation hardening (LANDED).** The
   reader-redefinition guard for the named forms (§ degradation 1): a member
   whose reader the class body redefines no longer folds on read, gated on a
   real `def` node via `Scope#user_def_for`. Settled the open-set-vs-bail
   choice against Rigor's own `lib` (the densest block-and-subclass corpus):
   the named forms fold with the guard; the bare-local block form stays
   conservatively unfolded (no resolvable class name to consult the guard,
   no corpus demand). Bare-local block-form parity is a demand-gated remnant.

Slices 1–2 are the value; 3 is what makes it pay off on real code (most
`Data` value objects are defined via the subclass form to attach methods);
4 is the false-positive guard that keeps the subclass form sound when the
body redefines a reader.

## Struct follow-up (slices 1–4 landed)

The class carrier is nearly identical to `DataClass` (it adds a
`keyword_init: bool` field, parsing the trailing `keyword_init:` option the
existing `struct_new_positionals` already strips), but the **instance carrier
is mutable**: `Struct` has `x=` setters and `[]=`, so a `StructInstance`'s
member map can be invalidated by a later write or by aliasing + external
mutation. The 2026-06-15 implementation resolves this in two ways the
original deferral left open:

**Carrier decision — dedicated `StructClass` / `StructInstance` carriers**
(not a `kind:` discriminator on the `Data*` carriers). The mutability gate,
the acceptance projection, and `receiver_descriptor` all pattern-match
cleanly on the carrier type, and `keyword_init` diverges the class carrier;
the `Data*` carriers stay structurally and behaviourally immutable.

**Soundness — a fresh-receiver gate, not write-site invalidation (route b,
sharpened).** The ADR named two routes: (a) flow-sensitive invalidation on
every observed setter / `[]=` / escape (prior art
`ScopeIndexer#widen_member_for_observed_mutators`), or (b) fold reads only
where no mutation can reach them. Route (a) requires *enumerating every
escape path* — a call argument, an alias assignment, a container store, a
block capture — and **missing one is unsound, which manufactures a
false positive** (the project's cardinal sin). Route (b) is realised at its
soundest extreme: a `StructInstance` member read folds **only when its
receiver node is a fresh `.new(...)` / `.with(...)` call** — a transient that
provably cannot have been mutated between materialisation and the chained
read. A read off a *stored* binding degrades to `Dynamic[top]`. This touches
**no write sites**, so no escape path can be missed; the cost is that bound
instances (the common `p = Point.new(1, 2); p.x` shape) do not yet fold.
Member *setters* (`s.x = v`) return the assigned value type (modelling the
setter's own return, sound regardless of mutation state, and avoiding a
fall-through undefined-method on an unregistered writer).

**Slice plan (Struct):** slice 1 = the `StructClass` carrier + `Struct.new`
recognition; slice 2 = the `StructInstance` carrier + fresh-chain member
folding + the side-table (`Scope#struct_member_layout`) for the
constant/subclass forms. Both landed together (the side-table is needed for
the common constant form, and completes the materialisation foundation).
**Slice 3 landed (2026-06-15):** the fresh-receiver gate now also folds a
member read off a *mutation-free bound local*, proven by a conservative
fold-safe scan ([`Inference::StructFoldSafety`](../../lib/rigor/inference/struct_fold_safety.rb)
— a local folds only when every use is a member read / known-pure projection;
any setter, index-write, alias, escape, or unknown-method call disqualifies
it). Soundness rests on a counting identity: a local is fold-safe iff every
`LocalVariableReadNode(n)` is the receiver of a pure-read call
(`total_reads == pure_receiver_reads`), which catches every mutation / escape
/ alias without enumerating escape paths (the allow-list keeps a missed case
over-conservative, never unsound). The set is computed once per local-variable
scope (respecting `def` / `class` / `module` boundaries; blocks share locals)
and installed on the scope (`Scope#struct_fold_safe?`) at the top-level
(`ScopeIndexer`) and method-body (`build_method_entry_scope` /
`build_user_method_body_scope`) entry points — measured perf-neutral on the
self-check. **Slice 4 landed:** the fold-safe scan is relaxed to also admit a
local whose only mutations are **straight-line member setters** (`s.x = v`):
the setter's assigned type is written back into the local's `StructInstance`
binding at `eval_call`'s post-call scope (`StructFolding.apply_setter_writeback`,
mirroring `MutationWidening.widen_after_call`), so a later `s.x` folds to the
assigned value and a sibling `s.y` stays precise. The write-back is sound only
because the scan still disqualifies any alias, escape, `[]=`, or setter inside a
loop / block / lambda (where a single static pass cannot model the per-iteration
effect) — a straight-line conditional is fine, its branch scopes join. Designed
in
[`docs/notes/20260615-struct-folding-slice3-design.md`](../notes/20260615-struct-folding-slice3-design.md).

**Slice 5 landed ([#525](https://github.com/rigortype/rigor/issues/525)) — the
in-body member read.** Slices 1–4 all decide foldability from the receiver
NODE, so a member read written with no receiver at all — the ordinary body of a
`Struct.new(:text) do def shout; text.upcase; end end` method — had nothing to
decide from and degraded to `Dynamic[top]`, taking its method's whole return
with it. The caller knows the answer, so it passes it down: `try_user_method_inference`
judges the receiver EXPRESSION — a recognised MATERIALISATION (`Point.new(…)`,
`Point[…]`, a `.with(…)` copy of a struct that did not define its own `with`), a
fold-safe local, or `self` inheriting the current body's grant — and
`build_user_method_body_scope` records the result as the
`:self` sentinel in the body scope's fold-safe set — collision-free, since `self`
is a keyword and no Ruby local can carry that name, so no new `Scope` field is
needed. `foldable_receiver?` gains a matching arm for a `nil` / `self` receiver,
tied to the exact carrier the grant was issued for.

The materialisation test is deliberately narrower than slice 2's
`fresh_receiver?`, which accepts ANY chained call. "Chained" stops meaning
"fresh" as soon as a method can hand back its own receiver, and a self-returning
fluent builder is ordinary Ruby: `Line.new("a").with_text("z").shout` over
`def with_text(v) = (self.text = v; self)` would otherwise grant `shout` a member
map two statements stale and fold `"A"` where the runtime value is `"Z"`. The
grant path therefore recognises only the shapes the folding layer itself
materialises. (Slice 2's own reading of `fresh_receiver?` is untouched here and
has the same latent gap for a direct member read through such a builder — tracked
as [issue #595](https://github.com/rigortype/rigor/issues/595).)

Two conditions beyond the caller's evidence: the carrier must be a
`StructInstance`, and the body's every use of `self` must be a pure read
(`StructFoldSafety.self_fold_safe_body?`). A member setter on self, a bare
`self` that escapes, and a self-call that is neither a member reader nor a fixed
pure read all refuse. The last is what makes the grant closed under the calls the
body makes: `def shout; reset!; text.upcase; end` over a sibling
`def reset!; self.text = ""; end` has no setter of its own, so a guard that only
looked for direct setters would fold `text` to the construction value while the
runtime read is `""`. Unrecognised self-calls are instead resolved against the
receiver's own class and asked the same question, so a body that merely DELEGATES
(`def outer; shout; end`) can keep the grant while one that reaches a writer at
any depth loses it.

That resolution is bounded, and every bound fails CLOSED — it refuses the grant,
never issues one. A mutual-call cycle refuses rather than recursing; a name that
resolves to nothing (`puts`, `raise`, an RBS-only ancestor's method) refuses,
since the answer must be backed by a body actually examined; `super` refuses,
because the resolver walks own-class defs only; and the walk is capped at
**4 hops**, so a delegation chain longer than that refuses even when every body
in it is pure. Delegation therefore keeps the grant *within the cap*, not
unconditionally — the cost of the cap is precision on a deep chain, never a wrong
fold.

**The grant is part of the ADR-84 return-memo key.** It is a third
call-site-varying dimension: the same `(def_node, receiver, arg_types)` returns a
folded member type from a foldable call site and `Dynamic[top]` from a
non-foldable one. Verified by removing the key element — the first call site to
run then answers for both, and in the foldable-first order that serves the folded
value for a read off a local nothing proved current, a wrong type rather than
mere imprecision. It is read off the built body scope rather than threaded
separately, so the key cannot drift from the scope that produced the result.

## Rejected / deferred alternatives

- **Reuse `HashShape` for the instance, tagged with a class name.**
  Rejected: `HashShape` is *structural* (two shapes with the same pairs
  are equal and interchangeable). A `Data` instance is *nominal* — `Point`
  and `Line` with the same member names are different types, `is_a?`
  narrows on the class, and `to_h` vs the instance are distinct. A
  class-tag bolted onto `HashShape` would fork every `HashShape` handler
  on "is this tagged?". A dedicated carrier is cleaner and keeps
  `HashShape`'s structural contract intact. (The instance carrier *erases*
  to `HashShape` for `to_h`, which is the right direction.)
- **Improve the RBS for `Struct.new` / `Data.define` to return
  `Nominal[Struct]` instead of `untyped`.** This is a strictly smaller,
  orthogonal fix (it removes the `Dynamic[top]` but gives no member
  precision). Worth doing regardless, but it is not value folding and does
  not need this ADR. Folded here only as the slice-1 floor for the
  no-carrier degradation paths.
- **A `Constant<Struct>` whole-instance constant carrier** (the shape the
  defensive `STRUCT_CATALOG` blocklist guards against). Rejected: a
  constant carrier would try to fold *behaviour* (calling real `Struct`
  methods on a synthesised instance), which re-introduces the
  process-dependence and mutation hazards the catalog blocklist exists to
  prevent. The member-shape carrier folds *member layout*, not behaviour —
  it never instantiates a real object.
- **Folding `Struct` in the same slice.** Rejected/deferred per §
  "Struct follow-up" — the mutation-soundness story is genuinely harder
  and the audit explicitly names `Data` the better first target.

## Consequences

- **Precision:** `Data` value objects (pervasive in Rigor's own `lib` and
  in idiomatic modern Ruby) fold member reads to precise types instead of
  `Dynamic[top]`. Downstream narrowing and `dump.type` improve.
- **No FP surface:** folding is additive and degrades to the status quo on
  any uncertainty; no new diagnostic, no corpus gate required.
- **Carrier-zoo cost:** two new carriers (`DataClass`, `DataInstance`)
  widen the zoo — the `describe` / `erase_to_rbs` / equality / acceptance
  / Ractor-shareability surface each must satisfy. Justified by the
  pervasiveness of `Data`/`Struct` value objects, unlike the `Encoding`
  carrier the same audit rejected as not paying for itself.
- **Self-check:** Rigor's own `lib` is a dense corpus of the
  `Data.define` + subclass form, so `make check` is a live regression
  guard — any unsound member fold would surface as a self-check change.

## Related

- [`docs/notes/20260523-struct-encoding-coverage.md`](../notes/20260523-struct-encoding-coverage.md)
  — the Phase-5 coverage audit that deferred this as ADR-worthy and named
  `Data` first; also the permanent `Encoding`-exclusion decision.
- [ADR-3](3-type-representation.md) — type-object representation + the
  open questions on carrier shape this ADR instantiates for a new carrier.
- [ADR-24](24-self-method-call-resolution.md) — slice 4a's
  `record_meta_superclass_members` registers the member *existence* this
  ADR makes *value-folding*.
- [`docs/internal-spec/internal-type-api.md`](../internal-spec/internal-type-api.md)
  — the carrier contract the checklist above enumerates.
- [`docs/type-specification/structural-interfaces-and-object-shapes.md`](../type-specification/structural-interfaces-and-object-shapes.md)
  — the member-shape schema the `members` structural query populates.
