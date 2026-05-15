# Appendix — Coming from mypy / Pyright

If your static-typing baseline is Python's mypy or Pyright,
this appendix maps the vocabulary onto Rigor's. The two
ecosystems share more than they look like at first — gradual
typing, a "do not break the runtime" philosophy, separate
type-stub files (`.pyi` / `.rbs`) — but they make different
choices about where annotations live and how aggressive
inference is.

## The five-second pitch

| Question | mypy / Pyright | Rigor |
| --- | --- | --- |
| Where do annotations live? | In source (`def f(x: int) -> str:`) | In `.rbs` files alongside `.rb` |
| Stub format | `.pyi` files | `.rbs` files |
| Default for unannotated code | `Any` everywhere (mypy) / inferred (Pyright) | Inferred precisely or `Dynamic[Top]` |
| Strict mode | `--strict` (mypy) / `strict: true` (Pyright) | `severity_profile: strict` |
| Suppression | `# type: ignore[error-code]` | `# rigor:disable <rule>` |
| Identity of types | Nominal + structural (Protocol) | Nominal + structural facets |
| Narrowing | Flow-sensitive, type guards | Flow-sensitive, predicate methods + RBS::Extended |

The Python / Ruby parallels run deeper than syntax: both
languages were born dynamic, both grew gradual typing
late, both treat type-checking as advisory, and both ship
official syntax for type hints (Python's `typing`, Ruby's
`RBS`). Many of Rigor's design priorities echo the things
mypy got right.

## Type vocabulary mapping

| Python typing | Rigor representation | Notes |
| --- | --- | --- |
| `int` | `Integer` | |
| `float` | `Float` | |
| `bool` | `bool` (`Constant<true> \| Constant<false>`) | |
| `str` | `String` | |
| `bytes` | `String` (with binary encoding) | Ruby has no separate `bytes` type. |
| `None` | `Constant<nil>` | `nil` is Ruby's sole no-value. |
| `Any` | `Dynamic[Top]` | "Stay silent" carrier. |
| `object` | `Object` (or `Top`) | `object` in Python is "any non-None"; Rigor's nearest match is `Top`. |
| `Never` / `NoReturn` | `Bot` | Empty type. |
| `Optional[T]` / `T \| None` | `T?` (i.e., `T \| nil`) | |
| `Union[A, B]` / `A \| B` | `A \| B` | Same display. |
| `Literal[42]` | `Constant<42>` | Direct match. |
| `Literal["foo", "bar"]` | `Constant<"foo"> \| Constant<"bar">` | |
| `Final[T]` | (no analogue) | Rigor does not yet track immutability. |
| `tuple[int, str]` | `Tuple[Integer, String]` | Same per-position model. |
| `list[T]` | `Array[T]` | |
| `dict[K, V]` | `Hash[K, V]` | |
| `set[T]` | `Set[T]` | |
| `TypedDict` | `HashShape{...}` | Closed shape with required / optional keys. |
| `NotRequired[T]` (TypedDict) | optional key in `HashShape` | Covered by Rigor's per-key required/optional flag. |
| `Callable[[int], str]` | `^(Integer) -> String` (RBS proc/block syntax) | |
| `TypeVar('T')` | RBS `[T]` type parameter | |
| `Generic[T]` | RBS `class Foo[T]` | |
| `Protocol` (PEP 544) | RBS `interface _Foo` | Structural typing. |
| `runtime_checkable` Protocol | (no analogue) | Rigor does not run `isinstance` against structural protocols. |
| `Self` (PEP 673) | RBS `self` type | |
| `ClassVar[T]` | `attr_*` on the singleton side / `self.@var` | |
| `Annotated[T, "tag"]` | `RBS::Extended` `%a{...}` annotation | Both attach metadata to a type. |

## Refinement carriers vs Python annotation idioms

Python's typing system has been adding refinement-shaped
features one at a time (`Literal`, `LiteralString`, `TypeIs`,
`Annotated`). Rigor ships a broader catalogue out of the box.

| Rigor refinement | Python closest |
| --- | --- |
| `non-empty-string` | (no built-in; PEP 675's `LiteralString` is closest in spirit but different in semantics) |
| `literal-string` | `LiteralString` (PEP 675) — provably built from source-code literals. **Direct match.** |
| `positive-int` | (no built-in; convention is `Annotated[int, Gt(0)]` with third-party validators) |
| `int<min, max>` | (no built-in; same `Annotated[int, Range(...)]` convention) |
| `numeric-string` | (no built-in) |
| `non-empty-array[T]` | (no built-in; some libraries use `tuple[T, *tuple[T, ...]]`) |
| `Constant<42>` | `Literal[42]` |

`LiteralString` is the deepest equivalence — both
Python's `LiteralString` and Rigor's `literal-string` carry the
"this string came from source code, not from runtime input"
fact, and both compose through formatting / interpolation.

## Narrowing — the part that feels familiar

Both checkers are flow-sensitive. The narrowing primitives
have direct analogues:

| Python | Rigor |
| --- | --- |
| `if x:` | `if x` — strips `False` / `None` from truthy edge |
| `if x is None:` | `if x.nil?` |
| `if x is not None:` | `unless x.nil?` |
| `isinstance(x, int)` | `x.is_a?(Integer)` |
| `if isinstance(x, (int, str)):` | `if x.is_a?(Integer) \|\| x.is_a?(String)` |
| `assert isinstance(x, T)` | `# rigor:assert-type` style via plugin OR `T.cast` via `rigor-sorbet` |
| `match x: case ...` (PEP 634) | `case x; in ...` (Ruby's pattern matching) |
| User-defined `TypeGuard[T]` (PEP 647) | `%a{rigor:v1:predicate-if-true: x is T}` directive |
| User-defined `TypeIs[T]` (PEP 742) | Same directive — Rigor's narrowing is symmetric (truthy AND falsey) by default |
| `assert x is not None; x.upper()` | Same idiom: `unless x.nil?; x.upcase; end` |
| `cast(int, x)` | `T.cast(x, Integer)` via `rigor-sorbet`, or RBS-side `param:` directive |

Notable: Python's `TypeGuard` is one-sided (narrows only the
truthy edge), while `TypeIs` (PEP 742, accepted) is two-sided.
Rigor's `predicate-if-true` and `predicate-if-false` directives
are independent and compose — by default declaring
`predicate-if-true: x is T` also narrows the falsey edge to
`x is ~T`, equivalent to `TypeIs`.

## Stubs ↔ RBS

Python's `.pyi` files and Rigor's `.rbs` files play the same
role: declare types for a library that does not ship them
inline.

| Python | Rigor |
| --- | --- |
| `.pyi` stubs | `.rbs` files |
| `typeshed` (community-maintained stubs) | `rbs_collection` + Rigor's bundled stdlib catalogues |
| `mypy_path` config | `signature_paths:` in `.rigor.yml` |
| `py.typed` marker | (no analogue — Rigor checks any file under `paths:`) |
| `from __future__ import annotations` | (no analogue — RBS is always lazy by virtue of file separation) |
| Reveal type: `reveal_type(x)` | `dump_type(x)` (info diagnostic) / `assert_type(x, "...")` |

`reveal_type` and `dump_type` are the same tool with different
names — both emit the inferred type at the call site as a
diagnostic, both are no-ops at runtime in idiomatic test
harnesses, both are the canonical "what does the checker see
here?" probe.

## Severity, suppression, and "strict mode"

| Python (mypy) | Rigor |
| --- | --- |
| `--strict` | `severity_profile: strict` |
| `--strict-optional` | Always-on in Rigor (no separate flag) |
| `--no-implicit-optional` | Always-on in Rigor |
| `--check-untyped-defs` | Always-on in Rigor |
| `--disallow-untyped-defs` | (no analogue — Rigor never demands annotations) |
| `--disallow-any-explicit` | (no analogue) |
| `# type: ignore` | `# rigor:disable all` |
| `# type: ignore[error-code]` | `# rigor:disable <rule>` |
| `# mypy: ignore-errors` (file scope) | `# rigor:disable-file all` |
| `mypy.ini` / `pyproject.toml` | `.rigor.yml` / `.rigor.dist.yml` |

The conceptual gap: mypy's `--disallow-untyped-defs` reflects
its baseline assumption that annotations should exist
everywhere. Rigor never demands annotations — inference is
always the first answer, RBS is the escape hatch. That makes
adoption smoother: there is no "you must annotate this whole
module before mypy is useful" stage.

## Pyright vs Rigor

Pyright (Microsoft's type checker, the engine behind Pylance)
is closer to Rigor in spirit than mypy is — both prioritise
inference depth and pragmatic narrowing over annotation
completeness.

| Pyright | Rigor |
| --- | --- |
| `# pyright: ignore[reportError]` | `# rigor:disable <rule>` |
| `pyright --stats` | (no direct analogue — `rigor check --explain` surfaces gradual fallback decisions) |
| Inferred return types from body | Same — `def` bodies are walked and the inferred return propagates |
| Speculative inference (Pyright is fast) | Rigor's type-objects are immutable shared structures; cache-driven recompute is incremental |
| Strict / basic / off file-level setting | `severity_profile:` is project-wide; per-file via `# rigor:disable-file` |

If you have used Pyright's "infer aggressively, then narrow"
authoring loop, Rigor will feel familiar. The biggest
adjustment is that Rigor's annotations live in `.rbs` files,
not in the `.rb` source.

## "No annotations needed" — true here too

Take a canonical mypy onboarding example:

```python
def classify(n: int) -> Literal["zero", "positive", "negative"]:
    if n == 0:
        return "zero"
    if n > 0:
        return "positive"
    return "negative"

result = classify(7)
# mypy: result: Literal['zero', 'positive', 'negative']
```

The Rigor equivalent — no annotations:

```ruby
def classify(n)
  return :zero     if n.zero?
  return :positive if n.positive?
  :negative
end

result = classify(7)
assert_type(result, "Constant<:zero> | Constant<:positive> | Constant<:negative>")
```

Same precision; one writes the parameter and return
annotation, the other does not.

When you need a sig — for a public library boundary, for
parameter validation, for `def.return-type-mismatch` to fire —
that goes into `sig/<file>.rbs`, not into the `.rb` source.

## Generics

Both ecosystems have generics; Rigor's are RBS's.

| Python | Rigor (via RBS) |
| --- | --- |
| `T = TypeVar('T')` | `[T]` after the method or class name |
| `def first(xs: list[T]) -> T` | `def first: [T] (Array[T]) -> T` |
| `Generic[T]` class | `class Foo[T]` |
| `T = TypeVar('T', bound=Comparable)` | `[T < Comparable]` (RBS bounded type parameters) |
| `ParamSpec` | (no analogue today) |
| `TypeVarTuple` | (no analogue today) |
| `Concatenate[X, P]` | (no analogue today) |

Rigor's generics coverage matches RBS's — it is more
conservative than Python's `typing` ecosystem, but covers the
common cases (collections, methods over generic containers,
class-level type parameters).

## Protocols ↔ RBS interfaces

Python's PEP 544 introduced structural typing via `Protocol`.
Ruby's RBS has had structural `interface _Foo` since its first
release.

```python
class SupportsClose(Protocol):
    def close(self) -> None: ...
```

```rbs
interface _SupportsClose
  def close: () -> void
end
```

A class that defines `close` (with the right signature)
satisfies both. Neither system requires the class to declare
inheritance — the structural match is implicit.

Rigor reads RBS interfaces from `sig/`. When an RBS-declared
parameter is `_SupportsClose`, Rigor checks the call site's
argument structurally, the same way mypy / Pyright check
against a `Protocol`.

## What mypy / Pyright have and Rigor does not

- **Variance annotations on TypeVars.** `TypeVar('T',
  covariant=True)`. Rigor relies on RBS's variance, which is
  fixed per the standard library — there is no user-side
  variance authoring.
- **`Final` / immutability tracking.** Rigor does not yet
  model "this name is never reassigned."
- **`@overload` stacks.** RBS supports method overloads, but
  the dispatch logic in Rigor's analyzer is more conservative
  than mypy's pattern-based overload resolution.
- **Decorator-aware type transformation.** Python's typing
  ecosystem has well-developed support for decorators that
  transform a function's type. Ruby's analogue is less common,
  and Rigor does not yet model `Module#prepend` /
  `define_method` transformations.
- **`async` / `await` types.** Ruby has Fiber and Async, but
  the RBS surface for async types is patchier than Python's
  `Coroutine[T, U, V]`.

## What Rigor has and mypy / Pyright do not

- **Constant folding through method calls.** mypy and Pyright
  both fold literals, but neither folds through arbitrary
  built-in methods. Rigor folds through a catalogued set of
  pure methods on `Numeric`, `String`, `Symbol`, `Array`,
  `Hash`.
- **First-class refinement carriers with narrowing.**
  `non-empty-string`, `positive-int`, `numeric-string`,
  `int<min, max>` — values restricted by predicate, narrowed
  by the corresponding Ruby predicate methods.
- **No-false-positives stance.** mypy will warn about dynamic
  code unless `--no-warn-unused-ignores` or `--ignore-missing-imports`
  is set; Rigor stays silent on `Dynamic[Top]` without
  configuration.
- **Plugin-side return-type variation by argument shape.**
  Pyright's "type alias narrowing" and mypy's overload stacks
  cover some cases; Rigor's plugin contract gives you full
  Ruby code at the dispatch point. The
  [`rigor-lisp-eval`](../../examples/rigor-lisp-eval/) example
  is the canonical demo — `Lisp.eval([:+, 1, 2])` returns
  `Integer`, `Lisp.eval([:<, 1, 2])` returns `bool`.

## A migration vignette

You are porting a mypy-tightened Python module to Ruby. The
original:

```python
def classify_input(s: str) -> Literal["empty", "numeric", "text"]:
    if not s:
        return "empty"
    if s.isdigit():
        return "numeric"
    return "text"

def shout(s: str) -> str:
    assert s, "expected non-empty"
    return s.upper()
```

The Rigor port:

```ruby
# lib/text_utils.rb
def classify_input(s)
  return :empty   if s.empty?
  return :numeric if s.match?(/\A\d+\z/)
  :text
end

def shout(s)
  raise ArgumentError if s.empty?
  s.upcase
end
```

```rbs
# sig/text_utils.rbs
%a{rigor:v1:return: Constant<:empty> | Constant<:numeric> | Constant<:text>}
def classify_input: (String s) -> Symbol

%a{rigor:v1:param: s is non-empty-string}
def shout: (String s) -> non-empty-string
```

You gain: `s.empty?` is a recognised refinement narrower (no
need for `assert s`). `match?(/\A\d+\z/)` does not yet narrow
to `numeric-string` (this is on the v0.1.1 roadmap — see
[`docs/ROADMAP.md`](../ROADMAP.md)), but the eventual
behaviour will mirror `s.isdigit()` narrowing in Pyright.

## What's next

You probably do not need to read the rest of this appendix
section sequentially. Three useful pointers:

- [Chapter 2 — Everyday types](02-everyday-types.md) for the
  carrier zoo if the refinement vocabulary is new.
- [Chapter 3 — Narrowing](03-narrowing.md) for the
  flow-sensitive rules — direct analogues to mypy's narrowing.
- [Chapter 7 — RBS and `RBS::Extended`](07-rbs-and-extended.md)
  for the directive grammar — `predicate-if-true` is Rigor's
  `TypeGuard` / `TypeIs`.

If you want to compare against another tool, the sibling
appendix pages cover [TypeScript](appendix-typescript.md),
[PHPStan](appendix-phpstan.md), and [Steep](appendix-steep.md).
