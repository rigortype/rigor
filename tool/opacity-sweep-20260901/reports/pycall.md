# pycall — opacity attribution (2026-09-01)

## Numbers

| metric | value |
| --- | --- |
| files | 22 (0 parse errors) |
| exprs | 3103 |
| precision | 62.26% (opaque 1171) |
| protection | 48.93% |
| cause_site_counts | inferred_return_untyped 96, unsupported_syntax 89, none 77, explicit_untyped 1 |
| tractability | engine_gap 185, add_rbs 1 |

Tiers: constant 1138, nominal 678, shaped 55, bot 61, dynamic_top 1171.

## Attribution split (opaque = 1171)

- Calls 463 (dynamic_top 227, implicit_self 124, precise 112)
- Local reads 339 (def_param 215, block_param 41, assigned_local 83); ivars 17
- Constants: ConstantPathNode 68 + ConstantReadNode 24 opaque — unusually high, see case 2.

## Classified cases

1. **attr_reader synthesis** — `PyCall::PyObjectWrapper::SwappedOperationAdapter#obj` 11, `__pyptr__` 26 implicit-self + 13 named-receiver (`attr_reader :__pyptr__` declared in the `PyObjectWrapper` **module**, pyobject_wrapper.rb:5; `attr_reader :obj` pyobject_wrapper.rb:100) — **D**, ~50 sites. Same root verified in the ox scratch discriminator: attr_* reader dispatch answers Dynamic even same-file on the defining class. Fix direction: synthesize attr_* signatures from ivar field types (ADR-58 WD2/WD3); for `@obj = obj` the result is then honestly A-tainted, but `@__pyptr__`'s `PyPtr` contract would surface.
2. **C-defined constants: `LibPython::API`, `LibPython::Helpers`, `PyCall::PyPtr`, `PyType_Type`** — ~92 opaque constant reads — **B (own native)**: defined in ext/pycall/libpython.c / pycall.c; the Ruby tree only ever consumes them. Example: /Users/megurine/repo/ruby/rigor-survey/pycall/lib/pycall.rb:14.
3. **PyCall module functions** (`import_module` 5, `builtins` 4+13 implicit, `len` 2, `init` 4) — **C over B**: Ruby `module_function` defs whose bodies terminate in case-2 constants (`LibPython::Helpers.import_module(name)`, lib/pycall.rb:82). Control run: a scratch `module_function def mfun = 7` folds to `7` at `MF.mfun` — module_function dispatch itself is NOT a gap; the opacity is purely the C body. `builtins` additionally stacks the memoized-ivar-return gap (`@builtins ||=`, case-1 mechanism).
4. **FFI::Struct DSL** — `singleton(PyObjectStruct)#by_ref` 6, `#ptr` 3, `layout` 5, `offset_of` 4, `PyMethodDef#[]=`/`#pointer` 4, struct-field writes `t[:ob_refcnt] = 1` — ~30 direct sites — **E** (framework/plugin territory: the ffi gem has no RBS and its Struct DSL is metaprogramming; this repo already stakes it out via the `rigor-ffi-plugin-author` skill). Example: /Users/megurine/repo/ruby/rigor-survey/pycall/lib/pycall/libpython/pytypeobject_struct.rb:199.
5. **Python-attribute proxying via method_missing** — `obj.__dict__.__pyptr__`, `other.__radd__(...)`, `hasattr?`, `call_object` chains — **F (inherent)**. PyObjectWrapper resolves *Python* attributes at runtime through method_missing (the OPERATOR_METHOD_NAMES table maps Ruby operators to `__add__` etc.); no static story exists for the Python side. Also runtime `define_singleton_method(as) { mod }` in pyimport (import.rb:19). This plus the FFI `.tap`-over-`super` struct initializers are the named constructs behind unsupported_syntax 89 (34% of causes). Example: /Users/megurine/repo/ruby/rigor-survey/pycall/lib/pycall/import.rb:42.
6. **def/block params** — 256 sites — **A** (CLOSED).
7. **dynamic-receiver cascade** — 227 sites — **C**, seeded by cases 1-5.
8. **Protection-lens note** — its top `add_a_type_here` (`[]` 24, `kind_of?` 24, gc_guard.rb) are Dynamic-*receiver* protection holes, not precision holes (`kind_of?` itself types bool via #508); coverage and protection remain different metrics.

## Cross-target addendum (found during rbnacl)

The coverage-lens scope carries no cross-file inferred-return table (coverage_scan.rb:58; 2-file scratch reproduction in the rbnacl report). pycall's cross-file pairs (`singleton(PyCall)#import_module` etc.) would stay opaque under that boundary even if their C leaves were typed; the same-file controls above (module_function fold, attr_reader failure) are unaffected.

## Native-boundary note

pycall is a *double* native boundary: its own C ext (case 2/3) plus the FFI-modeled CPython ABI (case 4) plus the Python object graph itself (case 5). Receiver identity survives (wrapper classes are Ruby), so opacity concentrates in constants and method returns rather than receivers.
