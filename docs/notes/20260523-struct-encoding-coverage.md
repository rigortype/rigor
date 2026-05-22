# Struct / Encoding coverage audit

Generated 2026-05-23 — the Phase 5 artifact of the post-`c9a535a`
`rigor-type-coverage-uplift` line. Phase 5 was scoped as "the remaining
low-priority carriers". The audit's conclusion for both types is a
**decision**, not a dispatch slice: one is deferred as an ADR-worthy
feature, the other is recommended for permanent exclusion.

---

## 1. Struct — deferred (needs a struct-shape carrier; ADR-worthy)

### Current state

`Struct.new(*members)` returns a fresh anonymous subclass. `STRUCT_CATALOG`
is defensive (see `struct_catalog.rb`): it recognises `Struct` as a receiver
class, classifies `Struct.new` `:block_dependent` (the optional class-body
block), and blocklists `:[]` / `:hash` / `:initialize_copy` against a
"hypothetical future `Constant<Struct>` carrier".

`spec/integration/fixtures/struct_catalog.rb` fixes the status quo:

```ruby
klass = Struct.new(:foo, :bar)   # => Nominal[Struct]
inst  = Struct.new(:foo).new(1)  # => Dynamic[top]
```

`inst.foo` cannot fold because nothing models the per-subclass member layout.

### Why this is not a coverage-uplift slice

Precise Struct member access (`Point = Struct.new(:x, :y); p = Point.new(1, 2);
p.x  # Constant[1]`) needs **two new carriers**, not a dispatch-tier entry:

1. A **struct-class carrier** — an anonymous `Struct` subclass parameterised by
   its ordered member-name list (and `keyword_init:` flag).
2. A **struct-instance carrier** — member-name → value-type, essentially a
   `HashShape` with a class tag, so `.x` / `.x=` / `[]` / `to_h` / `deconstruct`
   project precisely.

That is a genuine feature with real design surface, none of which the
coverage-uplift corpus has decided:

- the `Struct.new` class-body block (`do … end`) may define extra methods —
  the carrier must degrade gracefully when it does;
- `keyword_init: true` structs, positional structs, and the Ruby 3.2 hybrid;
- subclass-of-a-struct (`class Point3D < Point`);
- the immutable sibling **`Data.define`** (Ruby 3.2+) — arguably a better first
  target than `Struct` because `Data` instances are frozen, so the carrier
  soundness story is simpler.

### Recommendation

Treat Struct / Data value folding as a **dedicated feature with its own ADR**
(carrier zoo addition + the `Struct.new` / `Data.define` block-degradation
contract), not an autonomous coverage slice. The `HashShape` carrier is the
obvious structural prior art. No implementation is authorised by this audit.

---

## 2. Encoding — recommended for permanent exclusion

### Current state

`ENCODING_CATALOG` is defensive in the same shape as `STRUCT_CATALOG`:
`Encoding` is a recognised receiver, the RBS tier answers `Nominal[Encoding]`,
and the registry-walking singletons (`Encoding.find` / `.list` / `.aliases` /
`.name_list`) plus the mutating setters (`default_external=` /
`default_internal=`) are blocklisted as process-registry-dependent.

### Why a carrier would not pay for itself

A `Constant[Encoding]` carrier could only fold a vanishingly small surface:

- `Encoding::UTF_8.name` → `Constant["UTF-8"]`, `.dummy?` → `Constant[false]`,
  `.ascii_compatible?` → `Constant[true]`.

Real programs do not perform static computation on `Encoding` objects — the
type is used as an opaque tag passed to `String#encode` / `#force_encoding`.
The blocklisted registry methods (the only ones with interesting return values)
stay blocklisted because their answer depends on the analyzer process. The
precision gain over the existing `Nominal[Encoding]` answer is negligible, and
every new `SCALAR_CLASSES` member widens the carrier zoo (Ractor shareability,
`describe`, `erase_to_rbs`, the `==` / `hash` contract) for no user benefit.

### Recommendation

**Do not add an `Encoding` constant carrier.** The current
`Nominal[Encoding]` answer is correct and sufficient; `ENCODING_CATALOG`'s
defensive blocklist already covers the unsound paths. This is a deliberate
permanent exclusion, recorded so the question is not re-litigated.

---

## 3. Phase 5 outcome

| 型 | 判断 | 理由 |
|----|------|------|
| Struct / Data | 延期（ADR 化推奨） | struct-shape キャリア 2 種が前提。実機能であり coverage スライスではない。 |
| Encoding | 恒久的に対象外 | キャリア新設のコストに見合う精度向上がない。`Nominal[Encoding]` で十分。 |

Phases 1–4 of the coverage-uplift line landed as dispatch / carrier slices;
Phase 5 closes the line by recording that the two remaining candidates are a
deferred feature and a permanent exclusion respectively.
