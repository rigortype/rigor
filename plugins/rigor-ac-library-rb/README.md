# rigor-ac-library-rb

## What it is

An RBS bundle for [ac-library-rb](https://github.com/universato/ac-library-rb), the Ruby port of the AtCoder
Library (ACL). It declares the gem's `AcLibraryRb` namespace: `Segtree`, `LazySegtree`, `FenwickTree`, `DSU`,
`PriorityQueue`, `Deque`, `ModInt`, `MaxFlow`, `MinCostFlow`, `SCC`, `TwoSAT`, `Convolution`, the math and string
functions (`crt`, `inv_mod`, `pow_mod`, `floor_sum`, `convolution`, `suffix_array`, `lcp_array`, `z_algorithm`),
the class aliases (`UnionFind`, `SegTree`, `LazySegTree`, `HeapQueue`, `TwoSat`), and the core extensions
(`Integer#divisors`, `#to_modint`, `Array#to_fenwick_tree`, the private `ModInt()` on `Object`, …), plus the
`ModInt` overloads of `Integer#+`, `#-`, `#*` and `#/` that `ModInt#coerce` makes true (`1 + m` is a `ModInt`). It
emits no diagnostic of its own.

## Why it exists

ac-library-rb ships no RBS, and inference cannot write it: the containers are generic over values the caller picks
(a segment tree's monoid, a queue's elements), and their methods read parameters nothing inside the gem
constrains. `rigor sig-gen` over the gem's `lib_lock/` types 91 methods and leaves 95 untyped. Without
signatures, every call into the gem reads `Dynamic[top]`, so a typo in a method name and a wrong argument count
both pass silently.

## How it works

The manifest's `signature_paths: ["sig"]` adds `sig/ac_library_rb/*.rbs` to the RBS environment. Indices, sizes
and graph structure are precise (`DSU#groups` is `Array[Array[Integer]]`, `MaxFlow#min_cut` is `Array[bool]`,
`MinCostFlow#flow` is `[Integer, Integer]`). The containers are generic — `Segtree[S]`, `LazySegtree[S, F]`,
`PriorityQueue[T]`, `Deque[T]` — and `FenwickTree`'s values are `untyped`, since it starts from `0` and adds
whatever the caller adds (`Integer`, `Float` or `ModInt`).

Rigor does not bind a class's type parameters from constructor arguments, so `Segtree.new([1, 2], 0) { … }` reads
as a raw `Segtree` and `prod` as `Dynamic[top]`; a literal `0` is never taken as the element type.

```yaml
# .rigor.yml
plugins:
  - rigor-ac-library-rb
```

## Scope and limits

- The signatures cover the gem as installed (`lib_lock/`, under `AcLibraryRb`). Code that pastes ACL's top-level
  `lib/` sources into a submission defines its own classes and does not need the plugin.
- The gem is loaded per file (`require "ac-library-rb/segtree"`) or whole (`require "ac-library-rb/all"`), and the
  math functions are reached through `include AcLibraryRb`. The signatures cannot include the module into
  `Object` for you: `Object` including a module whose classes inherit from `Object` is a recursive ancestry RBS
  rejects. Rigor reports a top-level `include` itself as `call.unresolved-toplevel`
  ([#1383](https://github.com/rigortype/rigor/issues/1383)).
- The core extensions are declared whether or not the file that defines them is loaded. `ac-library-rb/modint`
  loads the `ModInt` conversions; `Integer#divisors`, `#each_divisor` and the `Array` conversions need
  `ac-library-rb/core_ext/all` (or `core_ext/integer`), and calling them without it passes the check and raises
  `NoMethodError` at runtime.
- `PriorityQueue.new`, `.max`, `.min`, `.[]`, `Array#to_priority_queue` and `Deque.[]` answer an `untyped` element
  type: bound from a literal array it would be the literals the array starts with, and a later `pop` would read as
  one of them.
- `MaxFlow#flow`, `MinCostFlow#flow` and `#slope` answer `Integer` for an `Integer` limit or none, and
  `Integer | Float` for a `Float` limit, which comes back as the flow when the capacities do not bound it.
- `ModInt#**` returns `ModInt | Integer`: it answers `0` when the modulus is 1.
- `ModInt.mod` is `Integer`; before `ModInt.set_mod` it is `nil`, and every other `ModInt` operation raises then.
