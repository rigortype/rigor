# numo-narray — opacity attribution (2026-09-01)

## Numbers

| metric | value |
| --- | --- |
| files | 2 (narray.rb is just requires; extra.rb is ~everything) |
| exprs | 2324 |
| precision | 43.37% (opaque 1316) — lowest of the native family |
| protection | 37.85% |
| cause_site_counts | unsupported_syntax 163, none 130, inferred_return_untyped 35, explicit_untyped 2 |
| tractability | engine_gap 198, add_rbs 2 |

Tiers: constant 507, nominal 408, shaped 53, bot 39, refined 1, dynamic_top 1316.

## Attribution split (opaque = 1316)

- Calls 500 (dynamic_top 322, implicit_self 101, precise 77)
- Local reads 469 (def_param 200, block_param 44, assigned_local 225); ivars 0
- SplatNode 43, If/Case/Or/Parentheses mirrors ~87, LocalVariableWrite 109.

## Classified cases

1. **Own C-defined API of `Numo::NArray`** — the defining case of this family — **B (own native)**. extra.rb reopens `class Numo::NArray` (so the constant and receiver type resolve precisely — `Numo::NArray`, `singleton(Numo::NArray)`) but every method the C extension defines is invisible: implicit-self `ndim` 26, `shape` 22, `size` 10; named-receiver `Numo::NArray#[]` 18, `singleton#zeros` 8, `#cast` 6, `#array_type` 4, `#asarray` 3, `#flatten` 3, `triu!/tril!/seq/view/swapaxes/reverse` … ≥120 direct sites, seeding most of the 322-site dynamic cascade and the 225 opaque assigned locals. Example: /Users/megurine/repo/ruby/rigor-survey/numo-narray/lib/numo/narray/extra.rb:243 (`ndim != other.ndim`). No RBS exists for numo anywhere.
2. **`Array#*` overload mis-selection under Dynamic argument** — **D**, and a *wrong-precise* answer, not mere opacity. `idx = [true]*ndim` with `ndim` Dynamic types `idx` as **String** (verified: `rigor type-of lib/numo/narray/extra.rb:213:11` → `String`) — overload selection committed to the `(String) -> String` join overload instead of declining to the union/Dynamic. Downstream `idx[axis] = i` then surfaces as `String#[]=` (7 sites, extra.rb:215 etc.), and `yield(self[*idx])` inherits the wrong shape. Sites: extra.rb:213, 279, 389. FP-relevant (a checker consuming `String` here would fire on correct code). Fix direction: overload selection must not pin an overload on a Dynamic-typed argument — join the overload returns or answer Dynamic (relates to the OverloadSelector pass-2 value-pinning fix; this is the remaining Dynamic-argument variant).
3. **Ruby-defined helpers whose bodies are C-call chains** (`check_axis` 6, `concatenate` 5, `split` 4, `reverse` 3 implicit-self sites — these ARE Ruby defs in extra.rb) — **C**: their inferred returns are Dynamic because every leaf touches case-1 methods.
4. **def/block params** — 244 sites — **A** (CLOSED). Param defaults like `axes=[0,1]` still read Dynamic at use sites.
5. **splat-argument call sites** — **F** (the construct behind the outsized unsupported_syntax 163 = 49% of causes). Sampled sites all carry splats: `swapaxes(*axes)` (extra.rb:72 vicinity), `self.class.new(*new_shp).store(self[*src_shp]).reshape(*res_shp)` (extra.rb:861), `self[*idx]` (extra.rb:216); SplatNode is itself 43 of the opaque nodes. numo's API style (shape tuples built as arrays, then splatted) makes this construct unusually dense.
6. **assigned-local reads** — 225 sites — **C** cascade from cases 1/2.
7. **opaque ConstantRead/ConstantPath** (29 total, e.g. `DimensionError`, dtype constants like `Numo::DFloat` where referenced) — **B own-native** (C-defined constants with no Ruby definition).

## Native-boundary note

The purest native target: one giant Ruby file layered over a C class. Receiver naming works (the reopening declares the constant), so the entire miss is method-level: a `numo` RBS sidecar (or plugin) for ~40 C methods would convert case 1 and most of cases 3/6 wholesale. Case 2 is the one genuine engine bug found here.
