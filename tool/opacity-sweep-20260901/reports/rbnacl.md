# rbnacl — opacity attribution (2026-09-01)

## Numbers

| metric | value |
| --- | --- |
| files | 37 (0 parse errors) |
| exprs | 4286 |
| precision | 64.28% (opaque 1531) |
| protection | 57.79% |
| cause_site_counts | inferred_return_untyped 136, none 45, unsupported_syntax 44 |
| tractability | engine_gap 180 |

Tiers: constant 1613, nominal 911, shaped 105, bot 88, refined 38, dynamic_top 1531.

## Attribution split (opaque = 1531)

- Calls 613 (implicit_self 244, dynamic_top 204, precise 165)
- Local reads 488 (def_param 351, assigned_local 137, block_param 0 recorded separately: 0? — bucket absent means 0)
- Ivars: 68 reads + 34 writes opaque; Constants: ConstantRead 74 + ConstantPath 48; Module/Class body mirrors 33.

## Classified cases

1. **Cross-file calls to source-inferred project methods** — `singleton(RbNaCl::Util)#zeros` 36, `#check_length` 12, `#check_string` 7, `#prepend_zeros` 5, `#verify32` 4, `#remove_zeros` 4, `#check_hmac_key` 3, `Argon2#digest` 3 … ≈80 sites — **D**, the headline mechanism, isolated twice over:
   - `check_length` has *no* defaults and returns only `true` (or raises); the same-file implicit call folds to `true` (`rigor type-of lib/rbnacl/util.rb:200:7` → `true`), while all 12 probe-counted opaque sites are cross-file.
   - A minimal 2-file scratch project run through the probe's own discovery-seeded environment reproduces it: `XU.check_it(s, 3)` (bool body), `XKlass#val` (`= 5`), `singleton(XKlass)#sval` (`= 6`) are ALL opaque cross-file.
   - Root, read from the code: `CoverageScan.discovery_seeded_scope` (/Users/megurine/repo/ruby/rigor/lib/rigor/cli/coverage_scan.rb:58) seeds only `discovered_classes` + `param_inferred_types` — there is no cross-file inferred-return table, so a callee's body in another file is invisible and its return answers Dynamic. Rigor's own self-check escapes this via its shipped `sig/`; RBS-less survey targets cannot. Fix direction: a ReturnInferenceCollector seeded like ADR-67's parameter table (a per-method inferred-return summary in the discovery seed) — or lean on the ADR-14 `sig-gen` adoption path, which closes it per-project.
2. **Defaulted parameters kill return propagation even same-file** — `Util.zeros(n = 32)` — **D**, distinct from case 1 and proven in scratch: `MF2.m_expr(n)` (required param, Dynamic arg) folds to String, but `m_default(n = 32)` and a keyword-default `m_kw(n: 32)` answer Dynamic at *every* call form (with arg, without, keyword). String bodies fold fine otherwise (`"\0" * n` → String even with Dynamic `n`; single-overload String#* does not mis-select). Fix direction: infer through optional/keyword defaults by typing the default expression into the parameter's initial type.
3. **libsodium FFI DSL** — implicit-self `sodium_constant` 58, `sodium_function` 44, `sodium_type` 21, `sodium_primitive` 21, `layout` 7, `attach_function` 3 (≈154 sites, the bulk of implicit_self 244) — **E** (own-DSL plugin territory). The DSL (lib/rbnacl/sodium.rb) is gained via `extend Sodium`, and `sodium_function` builds methods with `module_eval <<-RUBY` string eval + FFI `attach_function`; `sodium_constant` does `attach_function` + `const_set(name, public_send(fn_name))` with a `define_singleton_method` lambda fallback. These constructs are also what unsupported_syntax 44 (~20% of causes) names, and the opaque ModuleNode 22 / ClassNode 11 mirror the DSL-heavy class bodies.
4. **DSL-generated native wrappers** — `singleton(RbNaCl::HMAC::*)#auth_hmacsha*` (12), `c_verify32/64`, `singleton(RbNaCl::Random)#random_bytes` (2), generated constants (`KEYBYTES` etc., most of the 122 opaque constant reads) — **B (own native) reached through E**: the methods/constants exist only after the case-3 metaprogramming runs. An rbnacl plugin teaching `sodium_function`/`sodium_constant` semantics would recover them statically (name + arity + `-> bool` are all in the macro call).
5. **A-tainted ivars** — 68 ivar reads (`@key`, `@private_key` …) — writes are param-sourced, so ADR-58 WD1 faithfully types them Dynamic — **A** upstream.
6. **def params** — 351 sites — **A** (CLOSED).
7. **dynamic-receiver cascade** (`bytesize` 51, `==` 21, `[]` 15, `to_s` 13 …) — 204 sites — **C** from cases 1/2/5.

## Native-boundary note

rbnacl never calls C directly from the surveyed tree — everything native is wrapped by its own eval-based DSL, so the native boundary presents as *metaprogramming* (E) rather than missing receivers. The two engine mechanisms isolated here (cross-file inferred returns; defaulted-param defs) are generic Ruby findings that this family merely exposes loudly because it ships no RBS.
