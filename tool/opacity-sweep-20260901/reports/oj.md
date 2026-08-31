# oj — opacity attribution (2026-09-01)

## Numbers

| metric | value |
| --- | --- |
| files | 11 (0 parse errors) |
| exprs | 1650 |
| precision | 67.58% (precise 1115 / opaque 535) |
| protection | 57.09% |
| cause_site_counts | unsupported_syntax 15, inferred_return_untyped 79, none 33 |
| tractability | engine_gap 94 |

Tier counts: constant 632, nominal 419, shaped 27, bot 37, dynamic_top 533, top 2.

## Attribution split (opaque = 535)

- Calls 245 (receiver: dynamic_top 115, precise 60, implicit_self 70)
- Local reads 169 (def_param 131, block_param 15, assigned_local 23)
- Ivars 6; rest = structural mirrors (BlockNode 22, EmbeddedStatementsNode 14, If/Unless 15) and misc.

## Classified cases

1. **implicit-self sends to Hash-inherited methods** (`has_key?` 13, `fetch` 6, `store` 3, `key` 4 — ~26 sites in `EasyHash < Hash`, `MimicDumpOption < Hash`) — **D**. Mechanism: dispatch resolves source-defined ancestors but never falls through to the RBS of a builtin superclass. Verified with a scratch discriminator: `{}.has_key?(:a)` folds to `false`; the *identical* literal-arg call inside `class SubHash < Hash` (implicit or explicit self) answers Dynamic; `SubStr < String` + `length` also Dynamic (not generics-specific); user-to-user inherited dispatch (`Derived2 < Base2`) folds precisely. Not argument-driven. Example: /Users/megurine/repo/ruby/rigor-survey/oj/lib/oj/easy_hash.rb:15. Fix direction: extend ancestor-chain method resolution to fall through to the builtin superclass's RBS, binding unbound generic params to untyped — param-independent returns (`has_key?` → bool, `size` → Integer, `length` → Integer) come back precise immediately.
2. **`singleton(JSON)#create_id`** — 15 sites — **B** (external gem). `JSON.create_id` is defined in the json gem's Ruby (`json/common.rb`), which is not scanned and has no RBS loaded (`libraries:` empty); under mimic mode the runtime definition is Oj's own C — both roads are invisible. Example: /Users/megurine/repo/ruby/rigor-survey/oj/lib/oj/json.rb:130.
3. **`Hash[Dynamic, Dynamic]#[]=` / `#[]` / `#fetch`** — 12+3+1 sites — **C**. `@attrs` in state.rb is a Hash whose values include Dynamic writes, so element operations return Dynamic. Example: /Users/megurine/repo/ruby/rigor-survey/oj/lib/oj/state.rb:29.
4. **`Oj::MimicDumpOption#store`** — 4 sites — **D** (same builtin-superclass mechanism as case 1, explicit-self flavor; `store` returns V, which the fallthrough would bind untyped — but today even the dispatch itself fails). /Users/megurine/repo/ruby/rigor-survey/oj/lib/oj/mimic.rb:60.
5. **`singleton(JSON::Ext::Generator::State)#from_state` / `#merge` / `#clear`** — 5 sites — **B** (external **native**: json gem C extension, no Ruby defs anywhere). /Users/megurine/repo/ruby/rigor-survey/oj/lib/oj/json.rb:18.
6. **def-param local reads** — 131 sites — **A** (includes `*args` rest params, e.g. bag.rb:40 `args.empty?`). CLOSED per ADR-67.
7. **block-param reads** — 15 — **A**.
8. **dynamic-receiver method sends** (`[]` 40, `to_sym` 11, `to_s` 11, `each` 6 …) — 115 sites — **C** propagation, overwhelmingly seeded by A (params) and case-2/5 B holes.
9. **`class_eval` reopenings** (mimic.rb: `Date.class_eval do`, `Exception.class_eval do`, etc.) — **F** (the named construct behind most of the 15 unsupported_syntax sites, 11.8% of causes). Defs inside `X.class_eval do … end` lose their class scope, so implicit-self sends inside them (`civil` 2, `year` 2, `month` 2, `day` 2, `start` 2) are unresolvable; beneath that, `Date` RBS would also need the stdlib `date` library (B stacked under F). Example: /Users/megurine/repo/ruby/rigor-survey/oj/lib/oj/mimic.rb:167.
10. **EmbeddedStatementsNode 14 / If-Unless 15** — **G** metric artifacts mirroring inner Dynamic expressions.

## Native-boundary note

Oj's own C-defined API (`Oj.default_options`, `Oj.mimic_JSON`, …) shows up as `singleton(Oj)#default_options=` pairs (2 sites, **B own-native**) — small here only because oj's Ruby shim layer is thin; the JSON::Ext pairs are the external-native twin.
