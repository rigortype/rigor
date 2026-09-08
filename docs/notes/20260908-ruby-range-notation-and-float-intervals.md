# Ruby range literals as the interval vocabulary: Integer and Float facts

Date: 2026-09-08. Grounding note for [ADR-109](../adr/109-ruby-native-range-notation.md). Every
fact below was produced on this machine with the Flake's Ruby (4.0.5) or with `exe/rigor` at
`8ff3fe21`; the reproduction commands are in § 8.

## 1. How the `int<min, max>` spelling got in

| Date | Commit | What it said |
| --- | --- | --- |
| 2026-04-27 | `4c678915`, `db0237ba` | ADR-1 records "Importing PHPStan-style integer ranges such as `int<1, 10>`: Rejected for now. Rigor should use its own range notation, such as `Integer[1..10]`, to stay closer to Ruby and RBS naming." The same rule lands in `imported-built-in-types.md` as "PHPStan-style `int<1, 10>` MUST NOT be added as an alias initially." |
| 2026-05-02 | `2ad0d4c6` | `Type::IntegerRange` ships "modelled on PHPStan's `int<min, max>` family"; `describe` prints `int<a, b>`. |
| 2026-06-21 | `3a58eac3` | A docs-contradiction sweep resolves the spec-vs-code disagreement on the code's side: "the implemented `int<min, max>` form is no longer forbidden." ADR-1's row and the `Integer[1..]` row in `rigor-extensions.md` were not touched, so the binding corpus has disagreed with itself since. |

No commit records a decision to override ADR-1; the spelling was a convenience of the first
implementation.

## 2. The round-trip defect of the current spelling

`Type::IntegerRange#describe` prints `int<0, max>` / `int<min, -1>` for half-open ranges, but the
payload grammar (`Builtins::ImportedRefinements::Parser#parse_int_bound`) accepts only signed
integer literals. A user who copies a diagnostic's spelling into a signature gets:

```
sig/foo.rbs:5:3: info: `RBS::Extended` directive payload could not be resolved: "rigor:v1:return: int<0, max>" [dynamic.rbs-extended.unresolved]
```

`int<10, 1>` was worse: `Type::IntegerRange#initialize` raised, the whole Ruby file reported
`internal analyzer error`, and `rigor check` still exited 0 (tracked as a separate fix). The
handbook (`07-rbs-and-extended.md`) and the manual (`16-rbs-extended-annotations.md`) both
presented `int<min, max>` as the input form, so the defect was documented, not hidden.

## 3. Integer facts

| Expression | Result | What it fixes |
| --- | --- | --- |
| `(1..10).inspect`, `(1...10)`, `(1..)`, `(..10)`, `(...10)`, `(nil..nil)` | `1..10`, `1...10`, `1..`, `..10`, `...10`, `nil..nil` | Every bound shape has a Ruby spelling; `Range#inspect` is the display form |
| `(1...10).cover?(10)` | `false` | Exclusive end |
| `(1..10).to_a == (1...11).to_a` | `true` | For Integer, `a...b` and `a..b-1` are the same set (PostgreSQL `int4range` canonicalises the same way) |
| `(1..10) == (1...11)` | `false` | Range *objects* are not equal; the *sets* are. A type is the set |
| `(1..10).cover?(5.5)`, `(1..10) === 5.5` | `true`, `true` | A bare range does not mean "integer"; the class head does |
| `(1..10).cover?(3r)` | `true` | Same: `Rational` is covered. `Integer[R]` says Integer |
| `(5..1).cover?(3)`, `(1...1).cover?(1)` | `false`, `false` | Empty ranges are well-defined in Ruby (and are the empty set) |
| `(0..).cover?(2**64)` | `true` | No integer overflow boundary to model |

## 4. Float facts

The set a Float range denotes is `{x : Float | R.cover?(x)}`. Ruby decides every hard case:

| Expression | Result | Consequence for `Float[R]` |
| --- | --- | --- |
| `(0.0..1.0).cover?(Float::NAN)` | `false` | Any range with a bound excludes NaN |
| `(0.0..).cover?(Float::NAN)` | `false` | Also endless ranges |
| `(nil..nil).cover?(Float::NAN)` | `true` | The unbounded range is the whole `Float`, NaN included; `Float[nil..nil]` normalises to `Float` |
| `(-Float::INFINITY..).cover?(Float::NAN)` | `false` | `Float[-Float::INFINITY..]` is "every non-NaN Float" (`non-nan-float`) |
| `(0.0..).cover?(Float::INFINITY)` | `true` | Endless is closed at +∞ |
| `(0.0..Float::INFINITY).cover?(Float::INFINITY)` | `true` | Same set as `(0.0..)` |
| `(0.0...Float::INFINITY).cover?(Float::INFINITY)` | `false` | `...Float::INFINITY` excludes +∞: "finite" is a Ruby-spellable set |
| `(0.0...Float::INFINITY).cover?(Float::MAX)` | `true` | |
| `(-Float::INFINITY..Float::INFINITY).inspect` | `-Infinity..Infinity` | `Range#inspect` uses `Float#inspect`, which is not Ruby source; the type language spells `Float::INFINITY` |
| `(-0.0..0.0).cover?(0.0)` | `true` | `-0.0` and `0.0` are one point in the order |
| `(0.0...0.0).cover?(0.0)` | `false` | Empty |
| `Float::MIN` | `2.2250738585072014e-308` | Smallest positive *normal* double, and subnormals are smaller. `min` as a bound keyword would mislead; this is PHPStan's `PHP_FLOAT_MIN` trap |
| `0.0.next_float`, `Float::MAX.next_float`, `1.0.prev_float` | `5.0e-324`, `Infinity`, `0.9999999999999999` | Ruby ships the successor function; open bounds canonicalise to closed ones |
| `(1.0...2.0).cover?(1.0..2.0.prev_float)` | `true` | `[a, b)` = `[a, prev_float(b)]` |
| `(0.1..0.2).cover?(0.1)` | `true` | Bounds are doubles, not reals: the literal `0.1` is the same double at annotation and at run time |
| `Float::NAN == Float::NAN`, `Float::NAN.eql?(Float::NAN)`, `[Float::NAN].include?(Float::NAN)` | `false`, `false`, `true` | Value equality on NaN is not reflexive; a `Constant<NaN>` carrier under `ValueSemantics` would be unsound. NaN is never a `Constant` |
| `1 <=> Float::NAN` | `nil` | |

Ruby's `Range` has an exclusive **end** and no exclusive **begin**. The set `(c, +∞]`, the truthy
edge of `x > c`, has no Ruby literal; its canonical closed form is `c.next_float..`.

## 5. What actually goes wrong with Floats in Ruby

PHP's motivation for open lower bounds is division by zero and `log(0)`. Ruby's hazards are NaN
and infinity, which closed bounds and `nan?` / `finite?` narrowing address.

| Expression | Result |
| --- | --- |
| `1.0 / 0.0`, `1 / 0.0`, `1.0 / 0` | `Infinity` (no exception) |
| `0.0 / 0.0` | `NaN` |
| `1 / 0` | `ZeroDivisionError` (Integer only) |
| `Float::NAN.to_i`, `Float::INFINITY.to_i`, `Float::NAN.round`, `Float::INFINITY.floor`, `Integer(Float::NAN)`, `Float::NAN.to_r` | `FloatDomainError` |
| `Math.sqrt(-1.0)`, `Math.log(-1.0)`, `Math.acos(2.0)` | `Math::DomainError` |
| `Math.log(0.0)` | `-Infinity` (no exception) |
| `JSON.generate(Float::NAN)`, `JSON.generate([Float::INFINITY])` | `JSON::GeneratorError` |
| `[3.0, Float::NAN, 1.0].sort`, `[Float::NAN, 1.0].max`, `Float::NAN.clamp(0.0, 1.0)` | `ArgumentError: comparison of Float with … failed` |
| `"#{Float::NAN}"` | `"NaN"` (no warning; PHP 8.5 warns here) |

## 6. Core APIs that already take a Range literal as an interval

| Call | Result |
| --- | --- |
| `rand(0.0...1.0)` | a `Float` in `[0.0, 1.0)`; `rand(1.0..2.0)` honours the closed end |
| `Random.rand(1.0..Float::INFINITY)`, `rand(1..)`, `Random.rand(0.0..)` | `Errno::EDOM`: an unbounded interval is rejected at run time |
| `0.5.clamp(0.0..1.0)` | `0.5`; `0.5.clamp(0.0...1.0)` and `5.clamp(1...10)` raise `ArgumentError: cannot clamp with an exclusive range` |
| `case 5 in 1..10` | matches (`Range#===` is `cover?`) |
| `(1..10).step(0.5).first(3)` | `[1.0, 1.5, 2.0]` |

## 7. What the engine already does with Ruby range literals

- `Narrowing#case_equality_integer_range` (`lib/rigor/inference/narrowing.rb` ~L2291) reads a
  `when` range literal, honours `exclude_end?` as `high - 1`, and maps a missing endpoint to the
  carrier's infinity. `spec/rigor/inference/narrowing_spec.rb` L1195–L1225 pins `1..10` → `int<1, 10>`,
  `1...10` → `int<1, 9>`, `(100..)` → `int<100, max>`. End to end, `rigor type-of` on the body of
  `case n when 1...10` reports `int<1, 9>`.
- `ExpressionTyper#type_of_range` carries a literal-endpoint range as `Constant<Range>`
  (`1..10`, `1...10`, `0.0..1.0` all display as their `Range#inspect`); the ADR-3 carrier already
  accepts Float-endpoint ranges.
- `IteratorDispatch` and `BlockFolding` honour `exclude_end?` for `Range#each` / `inject`.
- Not folded today (gaps noted, not part of ADR-109): `n.clamp(1..9)` is `Dynamic[top]` while
  `n.clamp(1, 9)` is `int<1, 9>`; `rand(0.0...1.0)` selects the `Range[Integer] -> Integer?` overload
  and types `Integer?`; `x > 0.0` and `x.nan?` do not narrow (per the spec, deliberately).

## 8. Reproduction

```sh
nix --extra-experimental-features 'nix-command flakes' develop --command ruby -e '
  p (0.0..1.0).cover?(Float::NAN), (nil..nil).cover?(Float::NAN), (-Float::INFINITY..).cover?(Float::NAN)
  p (0.0...Float::INFINITY).cover?(Float::INFINITY), Float::MIN, 0.0.next_float, (1..10).cover?(5.5)
  p (1.0...2.0).cover?(1.0..2.0.prev_float), Float::NAN.eql?(Float::NAN), [Float::NAN].include?(Float::NAN)'
nix --extra-experimental-features 'nix-command flakes' develop --command bundle exec ruby -Ilib -e '
  require "rigor"
  %w[int<1,\ 10> int<0,\ max> Integer[1..10]].each { |s| p [s, Rigor::Builtins::ImportedRefinements.parse(s)&.describe] }'
```

The second command, run at `8ff3fe21`, prints `["int<1, 10>", "int<1, 10>"]`, `["int<0, max>", nil]`,
`["Integer[1..10]", nil]`.
