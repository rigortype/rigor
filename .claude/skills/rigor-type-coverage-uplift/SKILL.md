---
name: rigor-type-coverage-uplift
description: >-
  Expand Rigor's core/stdlib folding coverage for a named class, module, or method family. Use when
  implementing or auditing `ConstantFolding`, `ShapeDispatch`, or singleton-folding support; not for
  ordinary type inference or user-project annotations.
metadata:
  internal: true
---

# Rigor Type-Coverage Uplift

A contributor workflow for systematically discovering, prioritising, and implementing precision
improvements across Rigor's method-dispatch pipeline. The flow has three phases:

1. **Audit** — enumerate each type's own methods, cross-reference against the existing
   implementation, and produce a machine-readable coverage doc.
2. **Decision** — classify every gap by implementation tier; this document is the
   parallelisation artifact that lets separate agents work on independent tiers.
3. **Implementation** — one tier at a time, apply the per-tier patterns and commit each slice.

---

## Background

Rigor's method-dispatch pipeline resolves `receiver.method(args)` through ordered tiers. For a
given call site, the first tier that returns a non-`nil` type wins. The order is defined by
`dispatch_precise_tiers` in `lib/rigor/inference/method_dispatcher.rb`; read it before relying on
this summary:

```
DataFolding / StructFolding — Data / Struct value objects
meta-introspection          — `Singleton[*].new` and other class-object lifts
ConstantFolding             — scalar constant receivers (String, Integer, Float, bool, nil, Regexp, Symbol)
LiteralStringFolding        — mutable literal-string concatenation
ShapeDispatch               — structural types (Tuple, HashShape, Difference, Size-carrying Nominals)
STDLIB_SINGLETON_FOLDERS    — one folder per stdlib singleton receiver (File, Shellwords, Math, …)
Kernel intrinsics           — Kernel / Object methods (puts, pp, raise, …)
MethodFolding, ReduceFolding, ArrayToHFolding, BlockFolding
RbsDispatch                 — RBS envelope (fallback, always non-nil)
```

A "coverage gap" is any method where the RBS fallback gives a wide type (`String`, `Integer`,
`Array[T]`, …) when a precise `Constant[T]` or `Tuple` or `Refined` type could be returned
because all the relevant arguments are statically known.

The underlying design documents:

- [`docs/adr/3-type-representation.md`](../../../docs/adr/3-type-representation.md)
- [`docs/type-specification/imported-built-in-types.md`](../../../docs/type-specification/imported-built-in-types.md)
- [`docs/adr/5-robustness-principle.md`](../../../docs/adr/5-robustness-principle.md)

---

## Phase 1 — Audit

### 1-a. Enumerate each type's own methods

Use Ruby's reflection API to get only the methods that belong to a specific class or module,
stripping inherited noise:

```ruby
# Instance methods of a class
"".methods - Object.new.methods          # String-specific
0.methods  - Object.new.methods          # Integer-specific (Numeric + Integer)
0.0.methods - Object.new.methods         # Float-specific
true.methods - Object.new.methods        # TrueClass
[].methods  - Object.new.methods         # Array
{}.methods  - Object.new.methods         # Hash
require "set"; Set.new.methods - Object.new.methods   # Set

# Class / module functions (singleton methods)
Math.methods     - Module.methods        # Math module functions
Shellwords.methods - Module.methods      # Shellwords
CGI.methods      - Module.methods        # CGI
URI.methods      - Module.methods        # URI
Regexp.methods   - Class.methods         # Regexp class methods
```

Run this inside `nix … develop --command bundle exec ruby -e '…'` so the environment
matches the project's Ruby 4.0.5.

### 1-b. Cross-reference against the existing implementation

For **instance methods** on scalar types, inspect:

- `lib/rigor/inference/method_dispatcher/constant_folding.rb`
  — `STRING_UNARY`, `STRING_BINARY`, `INTEGER_UNARY`, `FLOAT_UNARY`, `BOOL_UNARY`, `BOOL_BINARY`,
    `NUMERIC_BINARY`, plus the named handlers `try_fold_string_format`,
    `try_fold_string_array_unary` / `_binary`, `invoke_unary`, `invoke_binary`.

For **structural types** (Tuple, HashShape, Size-carrying Nominals), inspect:

- `lib/rigor/inference/method_dispatcher/shape_dispatch.rb`
  — `TUPLE_HANDLERS`, `HASH_SHAPE_HANDLERS`, `SIZE_RETURNING_NOMINALS`, `dispatch_difference`.

For **stdlib module functions**, look for a dedicated `*_folding.rb` sibling registered in
`STDLIB_SINGLETON_FOLDERS` (e.g. `file_folding.rb` for `Singleton["File"]`,
`shellwords_folding.rb` for `Singleton["Shellwords"]`).

For **block-based methods**, inspect:

- `lib/rigor/inference/method_dispatcher/block_folding.rb`

### 1-c. Assign a coverage status to every method

Use the four-symbol legend:

| Symbol | Meaning |
|--------|---------|
| ✅ | Already implemented — `ConstantFolding`, `ShapeDispatch`, `BlockFolding`, or another tier. |
| 🔷 | Another tier is sufficient — e.g. `LiteralStringFolding` for `<<`/`concat`, RBS for a wide but correct return. |
| 🔲 | Gap — a `Constant[T]` / `Tuple` / `Refined` result is achievable and would increase precision. |
| 🚫 | Out of scope — mutating methods, Enumerator-returning stubs, platform-dependent, or non-deterministic. |

### 1-d. Produce the coverage document

Write `docs/notes/<YYYYMMDD>-<type>-method-coverage.md` (or a multi-type file if the scope is
broad). Follow the format of:

- [`docs/notes/20260522-hash-method-coverage.md`](../../../docs/notes/20260522-hash-method-coverage.md)
  — 101 Hash methods, per-method status, per-method note.
- [`docs/notes/20260522-type-method-coverage.md`](../../../docs/notes/20260522-type-method-coverage.md)
  — String / Integer / Float / bool / Array / Tuple / Set.

**Minimum required sections per type:**

1. Source of the enumeration (`"".methods - Object.new.methods`, version stamp).
2. Method table: `| method | status | note |`.
3. Implementation checklist grouped by priority: high (🔴), medium (🟡), low (🟢).
4. Implementation file reference (which source file to edit).

**For stdlib module functions**, split into two separate files:

- **Deterministic** (`Math`, `Shellwords`, `Regexp.escape`, `CGI` escape/unescape, `URI`
  encode/decode) → `…-stdlib-deterministic-module-coverage.md`
  See: [`docs/notes/20260522-stdlib-deterministic-module-coverage.md`](../../../docs/notes/20260522-stdlib-deterministic-module-coverage.md)

- **Non-deterministic / out-of-scope** (`SecureRandom`, `Random`, `FileUtils`, `Marshal`, `GC`,
  `Base64`, `Digest`) → `…-stdlib-nondeterministic-module-coverage.md`
  See: [`docs/notes/20260522-stdlib-nondeterministic-module-coverage.md`](../../../docs/notes/20260522-stdlib-nondeterministic-module-coverage.md)

The split matters: the deterministic doc becomes the implementation backlog; the non-deterministic
doc records the *exclusion rationale* so the question is never re-litigated.

> **Intermediate reports as parallelisation artifacts.** The coverage doc is not mandatory for
> simple single-method additions, but it is invaluable when the scope spans 20+ methods or
> involves multiple implementation tiers. A complete coverage doc lets two agents work
> independently: one handles Tier A (UNARY/BINARY set additions), another handles Tier B (new
> module-function folding). Producing the doc as a first commit before any implementation is the
> recommended approach.

---

## Phase 2 — Decision: classify each gap by implementation tier

Once the coverage doc exists, walk the 🔲 entries and assign each to exactly one of four tiers.
This is the decision-heavy step; the implementation itself is largely mechanical once the tier
is chosen.

### Tier A — ConstantFolding UNARY / BINARY set additions

**Use when**: the method takes a scalar receiver (`Constant[String]`, `Constant[Integer]`, etc.)
with zero or one additional scalar argument, and `invoke_unary` / `invoke_binary` can evaluate
it by simply calling the method on the unwrapped Ruby value.

`invoke_unary` calls `value.public_send(method_name)` and wraps the result in `Constant[T]`.
`invoke_binary` calls `value.public_send(method_name, other_value)`.

**Required conditions**:

- The method is defined directly on the receiver's Ruby class (not inherited from `Object`).
- The method is non-mutating (no `!`-suffix, no in-place change).
- The return value is a scalar Ruby type (`String`, `Integer`, `Float`, `TrueClass`, `FalseClass`,
  `NilClass`) so it wraps cleanly in `Constant[T]`.
- The method cannot raise on well-typed inputs (or if it can raise, it will raise at inference
  time and return nil from `invoke_unary` / `invoke_binary` — that is acceptable for static
  errors like division-by-zero on literal `0`).

**To add a method**:

1. Add the method name Symbol to the appropriate Set in `constant_folding.rb`:
   `STRING_UNARY`, `STRING_BINARY`, `INTEGER_UNARY`, `FLOAT_UNARY`, `BOOL_UNARY`, `BOOL_BINARY`,
   or `NUMERIC_BINARY`.
2. No other code change is needed — `invoke_unary` / `invoke_binary` pick up the new entry
   automatically.

**Example — `String#chop`** (Tier A):
```ruby
STRING_UNARY = Set[
  :capitalize, :chomp, :chop, # ← add :chop here
  …
].freeze
```

**`NUMERIC_BINARY` is shared by Integer and Float**: adding a Symbol there makes it available to
both. Integer-only operations (`&`, `|`, `^`, `<<`, `>>`) can be added to `NUMERIC_BINARY`
safely — if a Float receiver calls them, `invoke_binary` rescues the `NoMethodError` and returns
`nil`, falling through to the RBS tier. No separate Integer-only binary set is needed.


### Tier B — ShapeDispatch HANDLERS entries

**Use when**: the receiver is a structural type (`Tuple`, `HashShape`, or a `Difference` like
`non-empty-string`) and the precise result depends on the shape, not just the scalar value.

**To add a method**:

1. Add a `method_name: :handler_method_name` entry to `TUPLE_HANDLERS` or `HASH_SHAPE_HANDLERS`
   in `shape_dispatch.rb`.
2. Add the private handler method that receives `(receiver_type, args)` and returns the precise
   type or `nil`.

**Example — `Tuple#last`** (Tier B):
```ruby
TUPLE_HANDLERS = {
  …
  :last => :tuple_last,
}.freeze

def tuple_last(tuple, _method_name, args)
  return nil if args.size > 1
  tuple.elements.last  # Constant[T] element type
end
```

> **Handler signature**: every handler receives `(receiver, method_name, args)` — three positional
> parameters. The dispatch call is `send(handler, receiver, method_name, args)` (see
> `dispatch_tuple` / `dispatch_hash_shape`). A handler written as `def h(tuple, args)` silently
> receives `method_name` in `args` and `args` is bound to `nil`, causing mysterious nil-related
> bugs. Use `_method_name` if you do not need it.

### Tier C — ExpressionTyper / BlockFolding

**Use when**: the method takes a block and the precise return type depends on evaluating the
block's body over element types (e.g. `Array#map`, `Array#select`, `Hash#transform_values`).

These are already handled by `BlockFolding` and the `ExpressionTyper` block-evaluation path.
New block methods fit here by registering in `block_folding.rb`. This tier is complex; reach for
it only when the block return type is genuinely needed for a downstream narrowing.

### Tier D — New singleton-folding module (module function dispatch)

**Use when**: the receiver is a module or class constant (e.g. `Math`, `CGI`, `Regexp`) called
as a singleton, and the folding logic cannot be expressed as a simple UNARY/BINARY set entry.

**Receiver identification**: at dispatch time, `Math` in `Math.sqrt(4.0)` resolves to a
`Type::Singleton` object. Guard with:
```ruby
SingletonFolding.receiver?(receiver, "Math")
```

**Pattern to follow**: `ShellwordsFolding` is the canonical reference
(`lib/rigor/inference/method_dispatcher/shellwords_folding.rb`). Structure:

```ruby
module MathFolding
  MATH_UNARY_METHODS  = Set[:sqrt, :exp, :log, :log2, :log10, :sin, :cos, :tan, …].freeze
  MATH_BINARY_METHODS = Set[:atan2, :hypot, :ldexp, :log, …].freeze

  module_function

  def try_dispatch(context)
    method_name = context.method_name
    return nil unless SingletonFolding.receiver?(context.receiver, "Math")
    return nil unless MATH_UNARY_METHODS.include?(method_name) ||
                      MATH_BINARY_METHODS.include?(method_name)
    fold_math(method_name, context.args)
  end

  def fold_math(method_name, args)
    # validate arg count and types, then:
    #   Math.public_send(method_name, *unwrapped_args)
    # wrap result in Constant[T] or Tuple
  end
end
```

**To wire a new Tier D module**:

1. Create `lib/rigor/inference/method_dispatcher/<name>_folding.rb` exposing `try_dispatch(context)`.
2. Add `require_relative "method_dispatcher/<name>_folding"` in `method_dispatcher.rb`.
3. Register it in `STDLIB_SINGLETON_FOLDERS` as `"<ClassName>" => <Name>Folding`. The table is
   consulted only for `Singleton` receivers, so no ordering decision is needed.

---

## Phase 3 — Implementation patterns and common pitfalls

### Stdlib module fixture: must use a project-directory fixture

The test harness selects the RBS environment based on fixture layout:

- **Flat `spec/integration/fixtures/<name>.rb`** → `Environment.default` (RBS core only; no
  stdlib libraries). Shellwords, Math, CGI, URI, Digest, etc. are **not** in RBS core and will
  not be found.
- **Directory `spec/integration/fixtures/<name>/demo.rb`** → `Environment.for_project` (loads
  `DEFAULT_LIBRARIES`, which includes `shellwords`, `uri`, `json`, `digest`, and others).

**Rule**: any fixture that exercises a stdlib module not in RBS core MUST be a directory fixture.
Using a flat fixture causes all type lookups to return `Dynamic[top]`, making every test pass
vacuously.

`DEFAULT_LIBRARIES` includes (as of Ruby 4.0.5):
`shellwords`, `benchmark`, `base64`, `did_you_mean`, `pathname`, `json`, `yaml`, `fileutils`,
`uri`, `digest`, `securerandom`, `logger`, `tempfile`, `tmpdir`, `open-uri`, …

### assert_type backslash escaping

`assert_type(expected_string, expr)` calls `expr_type.describe(:short)` which calls
`value.inspect` on `Constant` values. `inspect` doubles backslashes.

`describe(:short)` returns **only** `value.inspect` — the bare `"..."` form with no wrapper.
`%(Constant["hello.world"])` as the first argument to `assert_type` is always wrong; it checks
against `Constant["hello.world"]` (a string that starts with the letter C) which will never
match `describe(:short)`.

When an expected string contains backslashes, use single-quoted literals and count carefully:

| `assert_type` argument | String it checks against |
|------------------------|--------------------------|
| `'"hello\\\\ world"'` | `"hello\\ world"` (two chars: `\` + ` `) |
| `'"hello\\ world"'`   | `"hello\ world"` (one char: `\ `) — **wrong** |

Rule of thumb: to assert a string whose `inspect` has N visible backslashes, write 2N backslashes
inside a single-quoted Ruby string literal as the first argument to `assert_type`.

**Regexp results require extra attention** because the chain has three steps:
`Regexp.escape` introduces one backslash per escaped meta-character → `inspect` doubles each →
the single-quoted source must double again:

```ruby
Regexp.escape("a.b")            # value: "a\.b"   — 1 backslash
# describe(:short) = "a\\.b"   — 2 backslashes (inspect doubled)
assert_type('"a\\\\.b"',   …)  # ✓  4 source backslashes → 2 actual → matches
assert_type('"a\\.b"',    …)   # ✗  2 source backslashes → 1 actual → mismatch
```

For a value with multiple escaped characters (`Regexp.escape("[a-z]")` has three backslashes):
```ruby
assert_type('"\\\\[a\\\\-z\\\\]"', Regexp.escape("[a-z]"))  # ✓ 4 per group = 12 total
```

When in doubt, read the `got:` field from an assert_type mismatch error — it shows the
`actual.inspect` value. The content between the outermost `\"` delimiters in `got:` is
exactly what belongs between the `'"` and `"'` of the correct single-quoted argument.

### Safe error handling in fold methods

A fold method that can raise at inference time should rescue and return `nil` to defer to the
RBS tier:

```ruby
def fold_split(args)
  # … validate args …
  Shellwords.split(arg.value)
rescue ArgumentError
  nil  # unmatched quotes — let RBS return Array[String]
end
```

Never let fold methods propagate exceptions to the inference engine.

### Size safety caps

When a fold returns a `Tuple` of potentially unbounded size (e.g. `Shellwords.split` on a long
command), cap the result:

```ruby
SPLIT_LIMIT = 64
tokens = Shellwords.split(arg.value)
return nil if tokens.size > SPLIT_LIMIT
```

`STRING_ARRAY_LIFT_LIMIT` in `ConstantFolding` uses the same pattern; keep the convention
consistent.

---

## Measuring precision impact

Use `rigor coverage --format json` to get a before/after machine-readable precision score.
Run once before implementation begins and again after each slice to confirm the uplift is real:

```sh
# Before implementing the slice:
nix develop --command \
  bundle exec exe/rigor coverage --format json \
  spec/integration/fixtures/<name>/demo.rb > /tmp/before.json

# After implementing:
nix develop --command \
  bundle exec exe/rigor coverage --format json \
  spec/integration/fixtures/<name>/demo.rb > /tmp/after.json

# Compare:
ruby -r json -e '
  b = JSON.parse(File.read("/tmp/before.json"))["summary"]
  a = JSON.parse(File.read("/tmp/after.json"))["summary"]
  puts "precise_ratio: #{(b["precise_ratio"]*100).round(2)}% → #{(a["precise_ratio"]*100).round(2)}%"
  puts "dynamic_opaque: #{b["dynamic_opaque_count"]} → #{a["dynamic_opaque_count"]}"
'
```

For a broader signal (impact on all of `lib/`):

```sh
nix develop --command \
  bundle exec exe/rigor coverage lib
```

`make coverage` enforces the precision floor set by its `--threshold` in the `Makefile` — any
slice that regresses precision below it fails CI.

---

## Verification

After every implementation slice:

```sh
nix develop --command make verify-changed
```

`make verify-changed` is the local gate; the full gate (tests, lint, `check`, `check-plugins`) is CI
on the Draft PR. CI's self-check runs `rigor check lib` — Rigor's self-check must stay clean.

If the self-check surfaces new diagnostics in `lib/`, the cause is almost always:
- a method added to a UNARY/BINARY set that Rigor itself uses — check that the Rigor codebase
  is not calling the method on a non-literal receiver that now resolves differently; or
- a blocklist entry missing for a method the catalog classifies as `:leaf` but is actually
  mutating.

---

## Coverage doc maintenance

After implementing a 🔲 item:

1. Update the corresponding `docs/notes/…-coverage.md` — change the symbol from 🔲 to ✅.
2. Commit the doc update in the same commit as the implementation (or as an immediate follow-up),
   so the doc stays in sync as the living record.

---

## Quick checklist

Before declaring a coverage-uplift slice done:

- [ ] Coverage doc produced (or an existing one updated) with ✅/🔷/🔲/🚫 per method.
- [ ] Each 🔲 entry assigned to Tier A / B / C / D.
- [ ] Tier A additions: Symbol added to the correct UNARY/BINARY Set; no other code change needed.
- [ ] Tier B additions: `HANDLERS` entry + private handler method in `shape_dispatch.rb`.
- [ ] Tier D additions: new `*_folding.rb` file following the `ShellwordsFolding` pattern;
      `require_relative` added to `method_dispatcher.rb`; registered in `STDLIB_SINGLETON_FOLDERS`.
- [ ] Unit spec for each new method / module in `spec/rigor/inference/method_dispatcher/`.
- [ ] Integration fixture in `spec/integration/fixtures/<name>/demo.rb` (directory form for
      stdlib modules; flat form for core types). **Create together with the describe block
      below** — a fixture file with no spec wiring is dead code and will never catch regressions.
- [ ] Integration describe block in `spec/integration/type_construction_spec.rb`.
- [ ] Precision snapshots updated: `UPDATE_SNAPSHOTS=1 bundle exec rspec spec/integration/precision_snapshot_spec.rb`.
      Run this whenever you add or modify a fixture — the golden files in `spec/integration/snapshots/`
      must reflect the new precise types or the CI snapshot gate will fail.
- [ ] `make verify-changed` clean locally; CI green on the Draft PR (it runs `make coverage` too).
- [ ] Changelog fragment under `changelog.d/<section>/` (user-visible description of the new folds).
- [ ] Implemented 🔲 entries updated to ✅ in the coverage doc.

---

## Example: end-to-end Shellwords implementation

The [`ShellwordsFolding`](../../../lib/rigor/inference/method_dispatcher/shellwords_folding.rb)
module is the canonical worked example of Tier D (new singleton-folding module):

1. **Coverage doc** produced:
   [`docs/notes/20260522-stdlib-deterministic-module-coverage.md`](../../../docs/notes/20260522-stdlib-deterministic-module-coverage.md)
   — §2 Shellwords lists escape/shellescape, split/shellsplit/shellwords, join/shelljoin as 🔲
     with receiver identification notes and fixture considerations.

2. **Module file**:
   `lib/rigor/inference/method_dispatcher/shellwords_folding.rb`  
   — `try_dispatch(context)` guards with `SingletonFolding.receiver?(receiver, "Shellwords")`.
   — `fold_escape`, `fold_split`, `fold_join` each validate argument count and type before
     calling the real `Shellwords` method and wrapping the result.

3. **Registered** in `STDLIB_SINGLETON_FOLDERS` in `method_dispatcher.rb`.

4. **Unit spec**:
   `spec/rigor/inference/method_dispatcher/shellwords_folding_spec.rb`  
   — 27 examples covering each method, its aliases, non-constant inputs, arity guards, and a
     split → join round-trip.

5. **Integration fixture** (directory form, for `Environment.for_project`):
   `spec/integration/fixtures/shellwords_folding/demo.rb`  
   — `assert_type` calls demonstrating all three method groups and the fallback-to-RBS behaviour
     for non-constant inputs.

6. **Integration spec** wired in `type_construction_spec.rb`.

7. **Coverage doc updated**: Shellwords section in
   [`docs/notes/20260522-stdlib-deterministic-module-coverage.md`](../../../docs/notes/20260522-stdlib-deterministic-module-coverage.md)
   changed to ✅.

The whole slice — doc, implementation, unit spec, integration fixture, spec wiring, changelog —
was one commit.
