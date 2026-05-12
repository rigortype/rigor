# 11. Generating RBS with `rigor sig-gen`

When `rigor check` is happy with your code but `sig/` is still
mostly empty, the analyzer is doing useful inference that
never reaches anyone but itself. `rigor sig-gen` is the
companion command that emits the inferred signatures as RBS
so the rest of the toolchain — Steep cross-checks, IDE
tooltips, downstream consumers reading your gem's `sig/` —
sees what Rigor sees.

This chapter is a walkthrough of the command's UX, the
classification model, the three output modes, and the
`--params` policy trade-off that comes straight out of
[ADR-5](../adr/5-robustness-principle.md)'s asymmetric
"strict on returns, lenient on parameters" rule.

## When to reach for it

- You inherited a Ruby project with zero RBS coverage and
  want a starting point that is more honest than `rbs
  prototype rb`'s syntactic skeleton.
- You added a method, `rigor check` recognises it, and now
  you want the corresponding sig file updated without
  retyping the signature by hand.
- Your existing RBS declares `() -> Numeric` but Rigor
  proves `() -> Integer`. You want the tighter spelling
  applied to `sig/` (after review).

What it is **not**: a replacement for hand-authored RBS
that captures intent the source code does not. If a public
method should accept `_ToStr` because the contract is
"anything that responds to `to_s`" but the current callers
only happen to pass `String`, `sig-gen` will not invent
`_ToStr` for you — clauses 1 and 2 below explain why.

## A first run

Given a `lib/calc.rb`:

```ruby
class Calc
  def add(a, b)
    "sum"
  end

  def greet(name)
    "hi"
  end
end
```

and an empty `sig/`, `rigor sig-gen` prints RBS skeletons:

```
$ rigor sig-gen
# lib/calc.rb
class Calc
  # [new]
  def add: (untyped, untyped) -> String
  # [new]
  def greet: (untyped) -> String
end
```

By default the command writes nothing — it prints the
proposal so you can review it. Pass `--write` to apply the
proposal to `sig/`.

## The three output modes

| Mode | Behaviour |
| --- | --- |
| `--print` (default) | Print RBS to stdout, grouped by source file + class declaration. |
| `--diff` | Show a unified-style diff comparing the existing-declared spelling (if any) against the inferred spelling. Read-only. |
| `--write` | Apply the proposal to `sig/<path>.rbs`. Creates files, inserts new methods into existing class declarations, appends new class blocks to files that don't declare them yet. |

`--write` is the only mode that touches the filesystem. It
operates **only** inside `configuration.signature_paths`
(default `sig/`); anything outside that tree is reported as
`skipped_outside_sig_root` without being written to.

## The classification model

Every method `rigor sig-gen` considers lands in one of five
states:

| Classification | Meaning |
| --- | --- |
| `new-file` | No RBS file declares the receiver class at all. |
| `new-method` | RBS file declares the class but not this method. |
| `tighter-return` | RBS file declares the method, but the inferred return is a strict subtype of the declared return. |
| `equivalent` | The inferred and declared returns are identical (or the inferred return is not a strict subtype). Silently skipped. |
| `skipped` | Disqualified for one of the reasons below. |

The three `sig.skipped.*` reasons are:

- `sig.skipped.complex-shape` — the method has optional, rest,
  keyword, block, or forwarding parameters. The MVP's
  body-typing path only handles required positional
  parameters; complex shapes need a future slice.
- `sig.skipped.untyped-return` — the method body's last
  expression types as `Dynamic[top]`. Emitting `untyped` as
  a tightening would be noise rather than help.
- `sig.skipped.user-authored` — `--overwrite` was not set
  and the method's existing RBS declaration would have to
  be replaced.

The three `sig.generated.*` identifiers
(`sig.generated.new-file` / `new-method` / `tighter-return`)
are emitted as JSON fields under `--format=json` so CI
gating consumers can route them.

## What method shapes the generator covers

Slice-by-slice (each shipped via a CHANGELOG entry — this
list is the current state):

- **Plain instance `def foo`** with required positional
  parameters. Both new-method and tighter-return paths
  apply.
- **Singleton-side `def self.foo`** and
  `class << self; def foo; end`. Rendered as
  `def self.foo: ...`; matched against
  `Reflection.singleton_method_definition` for existing
  RBS.
- **`attr_reader` / `attr_writer` / `attr_accessor`** with
  literal Symbol arguments. The return type is the
  accumulated ivar type from `Scope#class_ivars_for`. The
  generator emits the long-form `def name: () -> T`
  spelling so the writer's merge path applies unchanged;
  existing short-form `attr_reader name: T` declarations
  are recognised as user-authored and never produce a
  duplicate `def` insertion.

Method shapes the generator does **not** cover yet (and
silently skips):

- Optional / rest / keyword / block / forwarding parameters.
- `define_method(:name) { ... }`.
- Methods whose body types as `Dynamic[top]` (the body
  inference cannot prove a useful return type).

These are tracked as ADR-14 follow-ups.

## The `--params` policy and ADR-5

The `--params=POLICY` flag controls how parameter positions
are spelled in the emitted RBS. There are three policies;
two are wired today, one is reserved.

| Policy | Behaviour |
| --- | --- |
| `untyped` (default) | Every parameter is spelled `untyped`. No inference-derived parameter contract is imposed on future callers. The user retains complete authorship over parameter typing. |
| `observed` | Collect argument types from every call site under `--observe=PATH...` (defaults to `spec/` when present), union per parameter position, erase to RBS, emit the union. |
| `observed-strict` | Reserved. Will additionally widen to capability roles (`_ToStr`, `_ToS`, …) once the role catalog ships. Currently rejected with a usage error. |

The default deliberately favours `untyped` because of
[ADR-5](../adr/5-robustness-principle.md)'s clause 2: a
method's parameter contract should be the **most permissive**
shape the body's logic justifies, not the most specific
shape the current callers happen to use. Locking in
`observed` would silently freeze "what the existing specs
happen to pass" as the contract, which is the precision /
adoption trade-off the chapter introduction hinted at.

`--params=observed` is the deliberate opt-in: you are
saying *"the union of what my callers pass today IS the
parameter contract I want."* That is a correctness-
preserving widening — every existing caller still passes —
but it does narrow the contract relative to `untyped`.

## RSpec-aware observations

When you point `--observe` at a `spec/` directory, the
generator recognises three RSpec-shaped binding patterns
and uses them to type receivers that would otherwise
degrade to `Dynamic[top]`:

```ruby
RSpec.describe Calc do
  subject { Calc.new }         # binds :subject → Nominal[Calc]
  let(:other) { Calc.new }     # binds :other   → Nominal[Calc]

  it "..." do
    subject.greet("Alice")     # observed: Calc#greet receives String
    other.greet("Bob")         # observed: same
    described_class.new.add(1, 2)  # observed: Calc#add receives Integer, Integer
  end
end
```

The recogniser handles `RSpec.describe Foo`, bare
`describe Foo` (no `RSpec.` receiver), `subject { … }`,
`subject(:name) { … }`, `let(:name) { … }`, `let!(:name)`,
and `described_class.new(...)`. Same-name `let` bindings
across nested scopes are last-wins; the recogniser does not
re-implement RSpec's full scope rules — the typical
one-spec-file shape is the target.

The recogniser is part of the generator itself; you do not
need to install `rigor-rspec` to benefit from it. If you
already use `rigor-rspec` for diagnostics, the two run side
by side without coordination.

## Safety: what `--write` will and will not do

- **Will** create new `*.rbs` files mirroring `lib/<path>.rb`'s
  layout (basename of `configuration.paths.first` stripped,
  placed under `configuration.signature_paths.first`).
- **Will** insert new method declarations just before a
  class declaration's closing `end` keyword, preserving
  every other byte of the file verbatim.
- **Will** append a new `class Foo … end` block when the
  target file does not declare the class yet.
- **Will not** touch files outside the configured signature
  tree.
- **Will not** replace an existing method declaration
  unless `--overwrite` is set AND the candidate is a
  `tighter-return`. Without `--overwrite`, existing
  declarations are user-authored and the new method is
  silently skipped.
- **Will not** touch `attr_reader` / `attr_writer` /
  `attr_accessor` declarations in existing RBS — those are
  always treated as user-authored.

The recommended workflow is `--diff` first, review, then
`--write` (or `--write --overwrite` if you decided that
the tightening is intentional).

## Putting it together

A typical iteration on a new file:

```sh
# 1. See what Rigor would propose.
rigor sig-gen lib/calc.rb

# 2. Run with the observed-params policy to use spec/ as
#    a parameter-type signal.
rigor sig-gen --params=observed lib/calc.rb

# 3. Compare against the current sig/ tree.
rigor sig-gen --params=observed --diff lib/calc.rb

# 4. Apply.
rigor sig-gen --params=observed --write lib/calc.rb

# 5. Re-run rigor check to confirm no regressions.
rigor check
```

The five steps map to the five ADR-14 slices the command
is built from. If any step shows results you didn't expect,
the diagnostic the analyzer would emit for the same code is
the source of truth — `sig-gen` is a downstream consumer of
inference, not a separate analysis.

## Limits today

- Methods with optional / rest / keyword / block /
  forwarding parameters silently skip
  (`sig.skipped.complex-shape`).
- `define_method` and `Data.define`-specific emission are
  deferred follow-ups (`Data.define`-derived readers come
  through if a method body exists).
- The strict-subtype check uses gradual-mode acceptance
  today; the `:strict` mode reserved on
  `Inference::Acceptance` arrives in a follow-up.
- Round-trip through `RBS::Writer` is not used (it drops
  comments by upstream design); the generator's
  byte-range insertion preserves untouched declarations
  verbatim but cannot preserve comments interleaved
  *inside* a touched declaration's range.

These are the ADR-14 deferred items; the design rationale
is in [`docs/adr/14-rbs-sig-generation.md`](../adr/14-rbs-sig-generation.md).
