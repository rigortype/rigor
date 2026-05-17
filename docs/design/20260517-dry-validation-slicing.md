# `rigor-dry-validation` — slicing decision

**Status:** Design note. Authored 2026-05-17 in the
`rigor-dry-types` slice-4 commit. Decides the slice ordering for the
next dry-rb adapter beyond `rigor-dry-types` and `rigor-dry-struct`
(both landed in v0.1.6).

## Scope

[`docs/design/20260509-dry-plugins-roadmap.md`](20260509-dry-plugins-roadmap.md)
§ "dry-validation" describes the gem's three plugin-relevant DSL
surfaces; the user-facing programming shape is one of:

```ruby
class NewUserContract < Dry::Validation::Contract
  params do                       # (1) params { ... } adapter — delegated to dry-schema
    required(:email).filled(:string)
    required(:age).value(:integer)
  end

  rule(:email) do                 # (2) rule { ... } block — no type contribution
    key.failure('has invalid format') unless EMAIL_RE.match?(value)
  end
end

result = contract.call(...)       # (3) Contract#call → Dry::Validation::Result
result.success?                   # narrows Result
result.to_h                       # surfaces the typed params hash
```

The plugin gains user value when Rigor can answer:

- **What is the type of `contract.call(...)`?**
  → `Dry::Validation::Result` regardless of contract shape.
- **What is the typed shape of `result.to_h` on success?**
  → the dry-schema-derived `HashShape`. Requires dry-schema.
- **What params keys exist on a given Contract?**
  → set of `:email` / `:age` / ... from the `params { ... }` block
  (which is a dry-schema in disguise). Requires dry-schema.
- **What does `rule(:email)` do for typing?**
  → nothing; pure business rule.

## Dependency ordering

```
            ┌──── rigor-dry-types  (v0.1.6 — slices 1+2+3+4)
            │
rigor-dry-schema (NOT YET)  ←── consumes :dry_type_aliases
            │
            ↓
rigor-dry-validation (NOT YET)  ←── consumes dry-schema's params shape
```

`rigor-dry-validation` standalone (no dry-schema) can ONLY
contribute the `Contract#call → Result` fact. The rich payload —
typed `result.to_h`, params keys, per-key types — flows from
dry-schema. **Without dry-schema, dry-validation is a one-row RBS
contribution**:

```rbs
module Dry
  module Validation
    class Contract
      def call: (Hash[Symbol, untyped]) -> Result
    end

    class Result
      def success?: () -> bool
      def failure?: () -> bool
      def to_h: () -> Hash[Symbol, untyped]
    end
  end
end
```

That's ten lines of RBS overlay. Not worth a dedicated plugin
slice — fold into a future "dry-rb core RBS bundle" alongside
similar boundaries.

**Decision: slice `rigor-dry-schema` BEFORE `rigor-dry-validation`.**
The validation plugin without schema awareness contributes very
little; with it, the value scales with schema usage in user code.

## `rigor-dry-schema` minimum-viable shape

Per the dry-plugins roadmap § "dry-schema" entry:

```ruby
NewUserSchema = Dry::Schema.Params do
  required(:email).filled(:string)
  required(:age).value(:integer)
end

result = NewUserSchema.call(input)
result.to_h        # => HashShape[{email: String, age: Integer}]
result.errors.to_h # => Hash[Symbol, Array[String]]
```

Plugin contract (proposed):

- Recognise `Foo = Dry::Schema.{Params,JSON,define} { ... }`
  at the project's top level OR as a class-level constant.
- Walk the block body for `required(:key).<predicates>` and
  `optional(:key).<predicates>` calls.
- Map each predicate suffix (`filled(:string)`, `value(:integer)`,
  `value(:date)` …) to the underlying class via the same
  CANONICAL_ALIASES table `rigor-dry-types` uses (`:string` →
  `String`, `:integer` → `Integer`, …). Consume the
  `:dry_type_aliases` fact for any user-authored references
  (`value(Types::Email)` resolves through the cross-plugin
  fact channel).
- Publish a `:dry_schema_table` fact: `{schema_const_fqn =>
  {required: {key => underlying_class}, optional: {...}}}`.
- Synthesise typed return for `result.to_h` via either the
  ADR-16 substrate (Tier C `HeredocTemplate` with
  `returns_from_arg:` consuming `:dry_schema_table`) or a
  bespoke walker if substrate parameterised returns are out
  of scope at the time.

Slice 1 of `rigor-dry-schema` floor: recognition + fact
publication (no diagnostics yet), mirroring `rigor-dry-types`
slice 1's shape.

## `rigor-dry-validation` slicing — proposed three slices

Once `rigor-dry-schema` provides the underlying shape, the
validation plugin maps cleanly onto the substrate.

### Slice 1 — Contract recognition + Result carrier

- Walk the project for `class X < Dry::Validation::Contract`
  subclasses.
- Synthesise `X#call(Hash[Symbol, untyped]) → Result` (a generic
  `Result`, no schema awareness yet).
- Hand-authored RBS overlay for `Dry::Validation::Result#{success?,
  failure?, to_h}` so the chain `contract.call(...).to_h` resolves
  to `Hash[Symbol, untyped]`.

Floor: every contract call site has a typed `Result` receiver
for downstream method-chain inference.

### Slice 2 — `params { ... }` integration with dry-schema

- Recognise the `params do ... end` block inside a contract body.
- Treat it as a dry-schema declaration (delegate to
  `rigor-dry-schema`'s walker, or duplicate the relevant subset
  if the plugin coupling is a problem).
- Publish a `:dry_validation_params` fact:
  `{contract_const_fqn => HashShape}`.
- Refine `Contract#call`'s return so `result.to_h` typed against
  the per-contract shape rather than `untyped` values.

Floor: `NewUserContract.new.call(email: "x@y", age: 17).to_h`
resolves to `HashShape[{email: String, age: Integer}]`.

### Slice 3 — `json { ... }` adapter parity

The `json { ... }` block has the same shape as `params` but
applies stricter type expectations (no string-to-int coercion).
Apply the same walker; emit the same fact under a different
key (`:dry_validation_json` or shared `:dry_validation_schema`
with a `kind:` discriminator).

Floor: parity with `params`. Demand-driven if no project uses
`json { ... }`.

## ADR amendments needed (if any)

None for the slicing above. dry-validation does NOT need the
`Result[T, E]` carrier amendment that `rigor-dry-monads` does
(see § "Open observation" below) — `Dry::Validation::Result`
is a generic class, not a sum type. Its `#to_h` payload IS the
typed shape, and the `#success?` / `#failure?` predicates
narrow downstream chains via the existing `bool` flow facts.

## Open observation — `rigor-dry-monads` is separately blocked

The roadmap groups `rigor-dry-validation` with `rigor-dry-monads`
because both are next-tier dry-rb plugins. But dry-monads is
blocked on a different axis: it wants per-method return-type
wrapping (`def x; Success(42); end → Result[Integer, untyped]`).
The wrapped `Result[T, E]` / `Maybe[T]` carriers do not exist in
the `Rigor::Type::*` hierarchy today.

Two routes:

- **(a)** Implement `Result[T, E]` / `Maybe[T]` carriers as new
  `Rigor::Type::*` value classes. ADR-3 amendment level work
  (new type kinds, normalization rules, RBS erasure, display
  contract, equality / certainty surfaces).
- **(b)** Express `Result[T, E]` as `Union[T, E]` and `Maybe[T]`
  as `Union[T, NilClass]`. Loses the "tag" disambiguation that
  makes `Success(v)` vs `Failure(e)` precise but might be
  workable as a floor.

Decision: defer dry-monads until at least one of the two routes
becomes concrete. dry-validation can ship without monads — the
dependency goes the other direction (dry-validation uses dry-types
+ dry-schema, not dry-monads).

## Bottom line

**Order of work (queued, demand-driven):**

1. `rigor-dry-schema` slice 1 (recognition + fact publication)
2. `rigor-dry-schema` slice 2+ (per-schema-shape synthesis)
3. `rigor-dry-validation` slice 1 (Contract recognition +
   `Result` carrier)
4. `rigor-dry-validation` slice 2 (params dry-schema integration)
5. `rigor-dry-validation` slice 3 (json adapter parity)
6. `rigor-dry-monads` — only after (a) or (b) resolves the
   `Result` / `Maybe` carrier question

Total: 5-6 small-medium slices. Concrete user demand for any
specific layer would justify pulling it forward.
