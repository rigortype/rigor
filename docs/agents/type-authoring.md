# Type authoring contract

Read this when a task writes or asserts a type, edits `.rbs`, adds an inline RBS annotation, or
describes a type in a comment, document, or review. It is conditional detail for the standing pointers
in `AGENTS.md`.

## Provenance

A type that Rigor did not produce or check is not written down. Learn it from Rigor —
`rigor type-of`, `rigor annotate`, or `rigor sig-gen --print` — never from surrounding code or an
existing comment.

Types live in `sig/`, in a checked inline `#:` / `# @rbs` annotation, or as inference. When `sig/`
declares the same member, the two must agree: the more precise of two consistent declarations binds, and
a contradiction is a `rbs.contradicting-signature` error. Add an inline annotation only when it says
something the name and code do not: `void` / `bot` intent, a non-nominal refinement such as
`:asc | :desc`, or a parameter contract. Repeating the nominal type Rigor already shows on a method is
noise.

## Comments

In `.rb` files, comments never carry types. YARD tags are typeless and use an em dash after the name:
`@param name — description`, `@raise ExceptionClass — description`, and `@return description`.

A comment explains what the code and signature do not: rationale, a constraint the type system cannot
express, the meaning of `nil`, an ADR or issue, a false-positive bound, or a declined alternative.
It does not restate a name, type, or signature. The gate is `spec/docs/type_shaped_comments_spec.rb`.

Engine type notation is vocabulary, not a type claim. A comment that explains what Rigor infers, rejects or
prints may spell `Dynamic[top]`, `Nominal[Array]` or `Constant[1]`, or quote an RBS example, because the
notation is what the comment is about; the type itself is still learned from Rigor, per § Provenance
(`rigor type-of`, `rigor annotate`). The rule above is about a type attached to a name or signature in the
code (`@param x [String]`, `Hash<Symbol, Integer>` over a method). A sweep that turns the notation into
plain words loses precision: `Array[:multi | Dynamic[top]]` against `Array[Dynamic[top] | Symbol]` became
"the pinned `:multi` joined with untyped, not the erased untyped joined with `Symbol`". The comment audit of
[#2338](https://github.com/rigortype/rigor/pull/2338) reverted that rewrite in twelve files and part of a
thirteenth.

## RBS

Prefer `rigor sig-gen --print` / `--diff` over hand-written or AI-authored RBS. An inference gap is
signal about the engine, so propose the generated output first and hand-edit only after the user has
reviewed that alternative. Correcting existing `.rbs` is fine when the task authorizes it.

### The provenance gate's row classes

`spec/rigor/sig_gen/provenance_spec.rb` classifies every `sig/` declaration against what `rigor sig-gen`
renders, and pins the unmarked residue per file (`SIG_PROVENANCE_RESIDUE`). A row is earned when its return
is what sig-gen generates (`generated`), when the return is equivalent and a parameter or block is typed
(`parameter_intent`), or when it is `void` (`return_intent`). It is residue when sig-gen cannot confirm the
return (`declared_divergent`, `untranslatable_declared`, `unrenderable`, `unmatched_declaration`, and the
rows with no attributed `def`: `synthetic_source`, `inherited_source`, `runtime_defined`, `no_source`),
unless it carries a `# sig-gen gap:` or `# authored:` marker. A declared return that sig-gen would narrow
(`tighter_return`) needs the generated return, or a marker.

`parameter_only` is a fourth state besides earned, residue and `tighter_return`. It holds when sig-gen skips
the method as `sig.skipped.untyped-return`, the declaration states some type, and every overload's return is
the bare `untyped`. "States some type" means: not `(?)`, and at least one positional, optional, rest,
keyword or keyword-rest parameter whose type is not `untyped`, `top` or an optional of either, or a block whose own parameters, or declared
return, are not `untyped`. A block that declares a typed return says what the caller's block must return,
which is authored intent like a parameter. The method's own return is read from the method, never from the
block: `{ (untyped) -> untyped } -> Integer` has a typed method return and is residue.

Typing a method's parameters is what lets sig-gen render its return, and its callers' returns; a declaration
that types the parameters and leaves the return `untyped` makes no claim the gate cannot check, so it does
not count against the file's pin. The row is watched, not waived: the report prints the `parameter_only`
count per file and in total, and `SIG_PROVENANCE_PARAMETER_ONLY` pins it per file, marked and unmarked rows
apart, in both directions. `void`, `bool`, `[untyped, untyped]`, `Array[untyped]`, `untyped?` and a union
with `untyped` state a return and stay residue, as does a declaration that states no type
(`(untyped x) -> untyped`, `(untyped? x) -> untyped`, `(top x) -> untyped`, `(?) -> untyped`, an all-`untyped` block).
A container (`Array[untyped]`, a tuple, a record, a proc) counts as a type. An alias that expands to `untyped` is
not expanded, so it counts as one too.

**The way out is to declare the return.** The row leaves the class when sig-gen can render the return, and
then reads `tighter_return` (the declared `untyped` is looser than the generated type) or, when the body
proves only `nil`, `declared_divergent` residue, because sig-gen declines to propose a bare `nil` over a
declared `untyped`. Either way the author declares the return and the gate confirms it. A return that
depends on the method's own declared return never becomes renderable on its own: the declared `untyped`
makes a recursive call read `untyped`, so sig-gen keeps skipping a self-recursive method, or two
`parameter_only` methods that call each other. Declare it: `(Array[Integer] xs, Integer n) -> Integer` on
`def depth(xs, n); return n if xs.empty?; depth(xs.drop(1), n + 1); end` is confirmed as `parameter_intent`.

**Never add a marker to a `parameter_only` row.** A `# sig-gen gap:` marker records an engine gap with an
allow-listed issue (ADR-14); it is not a way to quiet a row. On a marked row the later `tighter_return` is
silent, so a marker would turn the watched class into a permanent exemption. The gate fails a marked
`parameter_only` row except the two that were marked `unrenderable` rows before the class existed
(`SIG_PROVENANCE_PARAMETER_ONLY_MARKED`, which can only shrink).

**A `tighter_return` over a declared `untyped` takes the proposal.** A bare `untyped` return states nothing for
a marker to record, so the failure message offers no marker for it, only sig-gen's proposed return.

**Each overload's parameter list must fit its `def`** (#3335). For every declaration the gate pairs with a
`def`, every call an overload admits must be one the `def` accepts. Its positional count must fall within the
def's (`*rest` lifts the upper bound). Every keyword it names must be one the def takes, unless the def has
`**rest`. Every keyword the def requires must be required in the overload, and an overload `**rest` needs one in
the def. A declared block needs a def that takes one, yields, asks `block_given?` or calls `super`. An overload
may omit optional positionals, optional keywords or the block, and may make an optional required. `...`
accepts anything past the positionals before it, and `(?)` is exempt. Declarations with no ordinary `def` are
counted as exempt by reason, not compared: `attr_*`, `alias`, `define_method`, a `Data`/`Struct` member, an
inherited or runtime-defined method. The parameter types stay the author's.

Print the report with
`nix develop --command bundle exec ruby -Ilib -Ispec/support -e 'require "sig_provenance_auditor"; SigProvenanceAuditor.report'`.

### Respect a declared `void`

Every Ruby method returns its last expression, so a body almost always *has* a value. An author who
declares `-> void` is saying that the value is not part of the contract and callers must not depend on
it. That is the meaning [`special-types.md` § `void`](../type-specification/special-types.md) binds, and
`static.value-use.void` enforces it. `boolish` is the same kind of promise: only truthiness is
meaningful. `rigor sig-gen` already never proposes over a declared `void` (#836).

Do not hand-tighten either one to the value the implementation happens to return. That covers `sig/`,
review suggestions, and RBS sent upstream to gem_rbs_collection. The test is whether the library
*documents* the value: a doc comment, the README, or the API reference. An implementation detail does
not count. In ruby/gem_rbs_collection#1129, sidekiq's `Client#push` documents "Returns a unique Job ID.
If middleware stops the job, nil will be returned instead", so `String?` was right. `perform_async` and
`Client.enqueue*` document nothing, so their `void` stayed, although their bodies return the same
`push` result.

The shipped `rigor-rbs-contract` skill carries this rule, and the rest of the contract reading behind
it, to adopting projects and gem_rbs_collection contributors
([ADR-131](../adr/131-declarations-are-contracts.md)). Follow it when auditing or contributing RBS.

Outside this repository, the shipped `rigor-type-oracle` skill carries the same provenance rule where
the adopting project has installed it; otherwise treat AI-authored RBS according to that project's
contract.

The normative reasons are [ADR-107](../adr/107-checked-types-and-typeless-comments.md),
[ADR-108](../adr/108-type-provenance-for-agents.md), and
[ADR-14](../adr/14-rbs-sig-generation.md).

## Spelling a refinement

When designing the spelling of a new refinement, and the set it denotes is one a Ruby literal's own
predicate already accepts, spell it with that literal and define it by that predicate:
`Integer[1..10]` and `Float[0.0...1.0]` by `Range#cover?`, not PHPStan's `int<1, 10>`
([ADR-1](../adr/1-types.md), [ADR-109](../adr/109-ruby-native-range-notation.md)).
Before importing a PHPStan, TypeScript or Python spelling, check whether Ruby has a literal for the set
and whether ADR-1's rejected alternatives already ruled on it. The imported `int<min, max>` shipped five
days after ADR-1 rejected it and stood for four months: it could not round-trip (`int<0, max>` printed
but did not parse) or extend to `Float` (`min` reads as `Float::MIN`). When a docs sweep finds the spec
and the code disagreeing, check which side ADR-1 took before siding with the code. A display string a
user may copy into a `%a{rigor:v1:…}` payload must parse back.

## Tighten the gate with the fix

The pattern to copy is the alba maintainer's Steep ratchet
([`03b37e7`](https://github.com/okuramasafumi/alba/commit/03b37e75ee12b9a28e00341143449778bf2241d0),
[`5883637`](https://github.com/okuramasafumi/alba/commit/5883637),
[`bf06036`](https://github.com/okuramasafumi/alba/commit/bf06036)). The `Module#name` thread in
[alba#576](https://github.com/okuramasafumi/alba/pull/576) shows two traps that sit next to it.

- **Remove a downgrade in the commit that makes the code pass it.** alba's Steepfile listed six
  diagnostics at `:information`. `03b37e7` removed `BlockTypeMismatch` and fixed what it exposed; the other
  two commits removed `UnexpectedSuper` and `UnexpectedKeywordArgument` outright, because nothing was left
  to fix. One diagnostic per commit, three left. Do not add a downgrade to land a change, and do not drop
  one without fixing the sites it was hiding.
- **Fix the signature before the call site.** `03b37e7` gave blocks their `[self: …]` types and named each
  proc contract once (`metadata_proc`, `instance_proc?` in place of a bare `Proc?`, `converter` and
  `check`). Only three source lines kept a `# steep:ignore`, each on the one expression the signature
  cannot express, and a type assertion moved to the line that introduces the value.
- **Do not widen a signature to fit the checker.** In alba#576 `_ClassContext#name` stayed `-> String`
  although an anonymous class returns `nil`: the change was signature-only, and `String?` made Steep reject
  `nesting`, which does not narrow a second `name` call (`n = name` would). The maintainer's answer was to
  keep the type honest and change the code. A signature-only scope is a reason to stop and say so, not to
  state a wider type.
- **A core `-> String` with `%a{implicitly-returns-nil}` hides a nil from every checker.** The nil that
  raises in alba is elsewhere: `resource_name` calls `self.class.name.end_with?`, and `self.class` is
  declared `Class`, whose core `name` is `-> String` plus that annotation, so `Alba.serialize(obj) {
  root_key!; … }` raises `NoMethodError` and neither Steep nor Rigor reports it. `RbsDispatch` reads past
  the annotation on purpose ([inference-engine.md](../internal-spec/inference-engine.md), "nil-free for a
  lookup that can miss"). Guard such a call in code and check the producing call sites; do not rely on the
  type.
