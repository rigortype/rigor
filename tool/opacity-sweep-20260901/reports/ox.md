# ox — opacity attribution (2026-09-01)

## Numbers

| metric | value |
| --- | --- |
| files | 15 (0 parse errors) |
| exprs | 1752 |
| precision | 54.57% (opaque 796) |
| protection | 32.13% |
| cause_site_counts | inferred_return_untyped 110, none 129, unsupported_syntax 25 |
| tractability | engine_gap 135 |

Tiers: constant 548, nominal 293, shaped 68, bot 47, dynamic_top 792, top 4.

## Attribution split (opaque = 796)

- Local reads 294 (def_param 101, block_param 56, assigned_local 137 — the assigned_local mass is `match = nodes.select …` chains downstream of case 1)
- Calls 290 (dynamic_top 211, implicit_self 37, precise 42); ivars 2
- Structural mirrors: BlockNode 43, IfNode 38, OrNode 17, LocalVariableWriteNode 50.

## Classified cases

1. **ivar-backed method/accessor returns** — the dominant root. Covers implicit-self `nodes` (24 sites), `Ox::Element#attributes` (8), `Ox::Element|Ox::Instruct#value` (3), `Ox::Element#name` (3, an `alias name value` over the inherited `attr_accessor :value`), plus the `value` sends on Dynamic receivers (4) — **D**. Mechanism, verified by scratch discriminators: a plain same-file `def xs; @xs = [] if @xs.nil?; @xs; end` types its final ivar read as `Array[Dynamic] | []` (`rigor type-of` on ox's own element.rb:52:7 shows exactly that), yet every call site of `xs` answers Dynamic — with and without `method_missing` in the class (method_missing is innocent; a literal-return sibling `def plain = 'lit'` folds precisely at its call site). `attr_accessor` readers fail identically even directly on the defining class in the same file. So inferred returns sourced from instance-variable reads do not propagate to call sites. Examples: /Users/megurine/repo/ruby/rigor-survey/ox/lib/ox/element.rb:220 (`nodes.each`), /Users/megurine/repo/ruby/rigor-survey/ox/lib/ox/element.rb:322. Fix direction: ADR-58's pending lanes (WD2/WD3) — let the per-class ivar field type feed method return inference and synthesize attr_* reader/writer signatures from it; this single fix would drain most of ox's 211-site dynamic-receiver cascade.
2. **dynamic-receiver cascade** (`[]` 49, `==` 22, `each` 18, `select` 16, `size` 12 …) — 211 sites — **C**, overwhelmingly seeded by case 1 (`nodes` → Dynamic → `.select` → `match` → …) plus A params.
3. **assigned-local reads** — 137 sites — **C** (same cascade landing in locals: `match`, `found` in `alocate`/`locate`).
4. **def/block params** — 157 sites — **A** (CLOSED, ADR-67). Includes `Ox::Element#alocate` (4 sites) whose return is the param-tainted `found`.
5. **`Hash[Dynamic,Dynamic]?#[]` / `#has_key?`** — 7 sites — mixed: element access is **C** (value type Dynamic regardless); `has_key?` on the optional receiver is a small **D** (bool derivable from the Hash arm; nil-union receiver dispatch declines). /Users/megurine/repo/ruby/rigor-survey/ox/lib/ox/hasattrs.rb:48.
6. **unsupported_syntax** — 25 sites (9.5% of causes) — **F**. Sampled construct: reflective ivar access with computed names — `args.each { |k, v| instance_variable_set(k, v) }` (/Users/megurine/repo/ruby/rigor-survey/ox/lib/ox/bag.rb:18) and `instance_variable_get(at_m)` with an interpolated symbol; the cause attaches to the enclosing `each`. Ox::Bag is a deliberately reflective grab-bag class — inherent, not an engine target.
7. **If/Or/EmbeddedStatements mirrors** — ~62 sites — **G**.

## Cross-target addendum (found during rbnacl)

The coverage-lens scope seeds no cross-file inferred-return table (coverage_scan.rb:58, verified with a 2-file scratch project — see the rbnacl report). Case-1 sites whose *definition* lives in another file (`attributes` in hasattrs.rb consumed from element.rb; `value` in node.rb) sit behind BOTH that boundary and the same-file ivar/attr gap proven above — fixing only one will not clear them.

## Native-boundary note

Ox's C core (`Ox.parse`, `Ox.sax_parse`, `Ox.dump`) barely surfaces because lib/ only builds the node model in Ruby; the one hit is `singleton(Ox)#sax_parse` (1 site, **B own-native**, xmlrpc_adapter.rb:29). The real story in ox is pure-Ruby: ivar-backed accessors.
