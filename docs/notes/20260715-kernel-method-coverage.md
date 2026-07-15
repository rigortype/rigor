# Kernel method coverage audit

2026-07-15. Enumerated inside the Flake on Ruby 4.0.5:

- `Kernel.private_instance_methods(false)` — 70 methods (the module-function surface every
  implicit-self call reaches).
- `Kernel.public_instance_methods(false)` — 43 methods (the Object protocol Kernel contributes).
- `Kernel.methods - Module.methods` — 60 singletons; every entry mirrors a private instance
  method (`module_function` twins), so the table below covers them — no separate section.

Cross-referenced against the `KernelDispatch` precise tier
(`lib/rigor/inference/method_dispatcher/kernel_dispatch.rb`), the static-refinement override
table (`Rigor::Builtins::StaticReturnRefinements`), `MutationWidening::PURE_SELF_RETURNERS`
(ADR-76), and the RBS fallback (probed with `dump_type` on a scratch fixture, `--no-cache`).

## Legend

| Symbol | Meaning |
|--------|---------|
| ✅ | Already implemented in a precise tier. |
| 🔷 | Another tier is sufficient (RBS envelope is already exact, or the flow engine owns it). |
| 🔲 | Gap — a precise `Constant[T]` / `Tuple` / passthrough result is achievable. |
| 🚫 | Out of scope — non-deterministic, effectful, or environment-dependent; RBS-wide is correct. |

## 1. Private instance methods (70) — the module-function surface

### Conversion / constructor functions

| Method | Status | Tier | Note |
|--------|--------|------|------|
| `Array` | ✅ | KernelDispatch | Shape fold: `Array(nil)→Array[bot]`, Tuple/Array/Union/scalar distribution. |
| `Integer` | ✅ | KernelDispatch | Constant fold incl. base (`Integer("ff",16)→255`) + `decimal-int-string` refinement path. |
| `Float` | ✅ | KernelDispatch | Constant fold, rescue-guarded. |
| `Rational` | ✅ | KernelDispatch | Numeric-constant fold with Ruby normalisation. |
| `Complex` | ✅ | KernelDispatch | Numeric-constant fold, 1- and 2-arg forms. |
| `String` | 🔲→✅ | KernelDispatch (this session) | `String(v)` on a value-pinned scalar Constant folds to `Constant[String]` (`String(42)→"42"`); rescue-guarded, declines otherwise. |
| `Hash` | 🔲→✅ (partial) | KernelDispatch (this session) | Trivially-sound slice only: `Hash(hash_shape)` passthrough, `Hash(nil)` / `Hash([])` (empty Tuple) → empty `HashShape`. `to_hash`-protocol args deferred (not decidable from types alone). |
| `Pathname` | 🔷 | RBS | Returns `Pathname`; no value-level carrier for Pathname constants worth adding here (MethodFolding owns Pathname instance folds). |

### Output / formatting

| Method | Status | Tier | Note |
|--------|--------|------|------|
| `p` | 🔲→✅ | KernelDispatch (this session) | Identity typing: 1 arg → the arg type verbatim (precision-preserving, Dynamic in → Dynamic out); 2+ args → `Tuple` of the arg types; 0 args → decline (RBS `nil` already exact). Declines on splat/forwarded args, explicit foreign receivers, and user redefinitions. |
| `pp` | 🔲→✅ | KernelDispatch (this session) | Same identity typing as `p`. |
| `format` | 🔲→✅ | LiteralStringFolding (this session) | All-args-value-pinned exact fold layered into the existing `fold_format` lift (that tier runs ahead of KernelDispatch and already owned the call): `format("%d", 1)→Constant["1"]`, rescue-guarded (bad directive ⇒ decline back to the `literal-string` lift), `STRING_FOLD_BYTE_LIMIT`-capped. The `String#%` fold only covered the binary-operator spelling. |
| `sprintf` | 🔲→✅ | LiteralStringFolding (this session) | Alias of `format`; same fold. |
| `puts` | 🔷 | RBS | `-> nil` already exact. |
| `print` | 🔷 | RBS | `-> nil` already exact. |
| `printf` | 🔷 | RBS | `-> nil` (IO write is the point; return exact). |
| `putc` | 🔷 | RBS | Returns its argument per RBS overloads; effectful, precision gain negligible. |
| `warn` | 🔷 | RBS | `-> nil` already exact. |
| `display` | 🔷 | RBS | (public) `-> nil`. |

### Control flow / blocks — owned by the flow engine, not dispatch

| Method | Status | Note |
|--------|--------|------|
| `loop` | 🔷 | Control-flow. The flow engine evaluates the block body (`eval_loop`, ADR-56 slice B); the break-value channel types the expression. |
| `catch` / `throw` | 🔷 | Non-local control flow. `throw` diverges (`bot`); `catch`'s value channel is not a dispatch fold — any uplift belongs in the flow engine. |
| `lambda` / `proc` | 🔷 | Return `Proc`; block-parameter binding and block-body typing are owned by `BlockParameterBinder` / `ExpressionTyper`, not a Kernel fold. |
| `block_given?` / `iterator?` | 🔷 | RBS `bool` exact; no static block-presence fact is tracked to sharpen it. |
| `raise` / `fail` | 🔷 | Diverge (`bot`); the flow engine already treats raise edges as terminating. |
| `exit` / `exit!` / `abort` | 🔷 | Diverge (`bot`) per RBS. |
| `at_exit` | 🚫 | Effectful registration; RBS `Proc` fine. |

### Non-deterministic / effectful / environment-dependent (RBS-wide is CORRECT)

| Method | Status | Note |
|--------|--------|------|
| `rand` / `srand` | 🚫 | Non-deterministic by definition; folding would be wrong. |
| `gets` / `readline` / `readlines` / `select` / `open` / `` ` `` (backtick) | 🚫 | IO; runtime-dependent. (`Kernel#select`'s RBS is the known `-> Array[String]` hazard — ADR-57 WD3 measured it non-reproducing.) |
| `system` / `exec` / `spawn` / `fork` / `syscall` | 🚫 | Process effects; results depend on the host. |
| `sleep` | 🚫 | Effectful; return value (elapsed seconds) is runtime-dependent. |
| `binding` | 🚫 | RBS `Binding` exact; the value itself is context-dependent. |
| `caller` / `caller_locations` | 🚫 | Call-stack-dependent. |
| `eval` / `load` / `require` / `require_relative` / `gem` / `gem_original_require` / `autoload` / `autoload?` | 🚫 | Code-loading effects; `require` → `bool` is already exact where it matters. |
| `test` | 🚫 | Filesystem probe. |
| `trap` / `set_trace_func` / `trace_var` / `untrace_var` | 🚫 | VM-hook registration. |
| `global_variables` / `local_variables` / `instance_variables_to_inspect` | 🚫 | Reflection over runtime state. |
| `respond_to_missing?` / `initialize_clone` / `initialize_copy` / `initialize_dup` | 🚫 | Protocol hooks, not call-site foldable. |

### Introspection with exact-enough RBS

| Method | Status | Note |
|--------|--------|------|
| `__method__` / `__callee__` | 🔷 | `Symbol?`; a per-def-body constant fold is possible but the consumer demand is nil — deferred. |
| `__dir__` | 🔷 | Already tightened to `non-empty-string?` by the `StaticReturnRefinements` tier. |

## 2. Public instance methods (43) — the Object protocol

Handled by existing engine surfaces; listed by group rather than per-row where uniform.

| Method(s) | Status | Note |
|-----------|--------|------|
| `itself` / `dup` / `clone` / `freeze` | ✅ | ADR-76 pure self-returners: shape carriers preserved, facts kept. |
| `frozen?` | 🔷 | RBS `bool`. A `Constant`-receiver fold is possible but frozen-ness is not tracked on carriers — skipped (not free; task rule). |
| `nil?` / `is_a?` / `kind_of?` / `instance_of?` / `===` / `!~` / `<=>` / `eql?` | 🔷/✅ | Predicate narrowing is owned by the flow engine (`Narrowing`); `nil?`/`is_a?` narrow edges today. |
| `class` / `singleton_class` | ✅ | Meta-introspection tier (`try_meta_introspection`). |
| `to_s` / `inspect` / `hash` | 🔷/✅ | `ConstantFolding` folds these on scalar constant receivers via the per-class catalogs; wide receivers correctly fall to RBS. |
| `tap` / `then` / `yield_self` | 🔷 | Block-typed by `BlockFolding` / block evaluation. |
| `send` / `public_send` / `__send__` | 🔷 | Fold only on value-pinned literal method names (ADR-78 `REFLECTIVE_SEND_METHODS` guard). |
| `method` / `public_method` / `singleton_method` / `methods` / `public_methods` / `private_methods` / `protected_methods` / `singleton_methods` / `instance_variables` | 🚫 | Runtime reflection; RBS-wide correct. |
| `instance_variable_get` / `instance_variable_set` / `instance_variable_defined?` / `remove_instance_variable` | 🚫 | Dynamic ivar access; ADR-58 owns the static ivar story. |
| `define_singleton_method` / `extend` | 🚫 | Metaprogramming effects. |
| `enum_for` / `to_enum` | 🚫 | Enumerator-returning stubs. |
| `object_id` | 🚫 | Runtime identity. |

## 3. Implementation checklist

- 🔴 High (this session): `p` / `pp` identity typing and the `String()` constant fold land in
  `KernelDispatch` (the existing Kernel precise tier — no new tier file needed); the `format` /
  `sprintf` exact fold lands in `LiteralStringFolding#fold_format` (that tier sits ahead of
  KernelDispatch and already owned the format spelling — the exact fold is a strict refinement
  inside its existing firing envelope).
- 🟡 Medium (this session, trivially-sound slice): `Hash()` HashShape passthrough +
  empty-collapse. Deferred: `to_hash`-protocol arguments.
- 🟢 Low / deferred: `__method__` per-body constant; `catch` value-channel typing (flow
  engine); `URI()` (lives with `URIFolding`'s `Singleton["URI"]` receiver, and the toplevel
  `URI(...)` spelling resolves through Kernel — deferred pending demand); `frozen?` trivia.

Guard shared by every new fold (FP envelope): decline when the call has an explicit non-`self`
receiver (Kernel's surface is private — such a call is a user method), when the receiver class
(or the toplevel) has a discovered user redefinition of the name, or when the argument list
contains a splat / forwarding node (arity not statically known).

## 4. Implementation file reference

- `lib/rigor/inference/method_dispatcher/kernel_dispatch.rb` — `p` / `pp` identity, `String()`,
  `Hash()` (+ the shared `kernel_owned_call?` / splat-arity guards).
- `lib/rigor/inference/method_dispatcher/literal_string_folding.rb` — the `format` / `sprintf`
  exact constant fold (`fold_format_constant`).
- Unit specs: `spec/rigor/inference/method_dispatcher/kernel_dispatch_spec.rb`,
  `spec/rigor/inference/method_dispatcher/literal_string_folding_spec.rb`.
- Integration fixture: `spec/integration/fixtures/kernel_functions.rb` (flat — Kernel is RBS
  core; no stdlib library load needed).
