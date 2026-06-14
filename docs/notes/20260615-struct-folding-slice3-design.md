# Struct value folding — slice 3 (fold-safe bound locals) + slice 4 (precise mutated-member re-typing) design

2026-06-15. **Slice 3 LANDED 2026-06-15** as designed below
([`Inference::StructFoldSafety`](../../lib/rigor/inference/struct_fold_safety.rb)
+ the `Scope#struct_fold_safe?` field + the top-level / method-body wiring);
this note is kept as its design record and the live spec for the still-deferred
**slice 4** (precise mutated-member re-typing). Slices 1 + 2 landed earlier
(the sound *transient* form). The soundness argument below is what the
implementation realises.

## What landed (slices 1 + 2)

- Carriers `Type::StructClass` / `Type::StructInstance`
  (`lib/rigor/type/struct_{class,instance}.rb`), the mutable siblings of the
  `Data*` carriers. `StructClass` adds a `keyword_init` field.
- Dispatch tier `Inference::MethodDispatcher::StructFolding`
  (`lib/rigor/inference/method_dispatcher/struct_folding.rb`), wired into
  `dispatch_precise_tiers` right after `DataFolding` (before `meta_new`, which
  would otherwise intercept `Singleton[*].new`).
- Side-table `Scope#struct_member_layout` (`{ members:, keyword_init: }`),
  populated by `ScopeIndexer#build_struct_member_layouts` and threaded through
  the `DiscoveryIndex` / project pre-pass exactly like `data_member_layouts`.
- **The soundness gate: `StructFolding#fresh_receiver?`** — a member read
  folds precisely only when `context.call_node.receiver.is_a?(Prism::CallNode)`
  (the transient result of a `.new(...)` / `.with(...)` chain). A read off a
  *stored* binding (a variable / constant read) returns `Dynamic[top]`.

The fresh-receiver gate is sound because a transient instance cannot be
mutated between the statement that materialises it and the chained read in the
*same expression* — there is no intervening statement. It touches no write
sites, so no escape path can be missed (the failure mode that would
manufacture a false positive).

The cost: the common shape `p = Point.new(1, 2); p.x` does **not** fold (the
receiver of `.x` is a `LocalVariableReadNode`, not fresh). Slices 3 + 4 close
that gap.

## Slice 3 — fold member reads off mutation-free bound locals

Goal: `p = Point.new(1, 2); p.x` → `Constant[1]` **when `p` is provably never
mutated, aliased, or escaped** in its scope. Relax `fresh_receiver?` to also
fold a stored-receiver read when the bound local is *fold-safe*.

### The soundness problem (why this is the hard slice)

A `Struct` instance is mutable, and the mutation does **not** rebind the
local, so plain flow re-typing misses it:

```ruby
p = Point.new(1, 2)   # p : StructInstance{x:1, y:2}
p.x = 5               # the setter does NOT rebind p; flow still sees {x:1,...}
p.x                   # naive fold → 1, but runtime is 5 → UNSOUND → a wrong type
```

Worse, aliasing means a mutation through *another* binding invalidates `p`:

```ruby
q = p                 # alias: p and q reference the same object
q.x = 5
p.x                   # naive fold → 1, runtime 5 → UNSOUND
```

And escape means an arbitrary method can mutate it:

```ruby
mutate!(p)            # p escapes; the callee may do p.x = 5
p.x                   # naive fold → 1, possibly wrong → UNSOUND
```

An unsound member map is a **wrong type**, which can manufacture a downstream
false positive (`p.x.zero?` folding to a wrong `true`/`false`, a wrong
`always-truthy`, a wrong `argument-type-mismatch`). That is strictly worse
than not folding. So slice 3 must be sound against **all** of mutation,
aliasing, and escape.

### The fold-safe scan (route b, conservative allow-list)

Do **not** enumerate escape paths and invalidate (route a) — missing one path
is unsound. Instead, prove a local is fold-safe by a conservative
**allow-list** scan: a local is fold-safe iff *every* use of it is on a
short, known-pure allow-list, and **anything else disqualifies it**. Missing a
case in the allow-list makes the scan over-conservative (no fold), never
unsound — the FP-safe direction.

Per method body (or top-level program region), compute the set of fold-safe
struct local names:

> A struct-typed local `n` is **fold-safe** iff every `LocalVariableReadNode`
> with name `n` in the body is the **receiver** of a `CallNode` whose method
> name is in `SAFE` = the fixed Struct read methods
> (`[] dig to_h to_hash to_a values members deconstruct deconstruct_keys
> == != eql? equal? hash inspect to_s size length frozen? each each_pair
> values_at with`) **∪ the member-reader names of `n`'s struct layout**, and
> the call is not a member setter / `[]=` / mutator.

Key points:

- **Every read must be a safe-receiver read.** A read in any other position —
  a call *argument* (`foo(n)`), an alias RHS (`m = n`), a container element
  (`[n]`, `{k: n}`), a bare value / return, a block capture — is not a
  safe-receiver read, so the local is disqualified. This subsumes
  escape **and** aliasing without enumerating them: every escape/alias is
  *some* non-receiver occurrence of `n`. Implementation: walk the body once,
  count total `LocalVariableReadNode(n)` and count safe-receiver reads; equal
  ⇒ every read was a safe receiver. (A setter `n.x = v` has the receiver read
  counted but not safe ⇒ inequality ⇒ disqualified, automatically.)
- **An unknown method call disqualifies.** `n.some_user_method` could mutate
  via an internal `self.x = …`, so only the `SAFE` allow-list is folded; an
  unknown name is treated as potentially-mutating. This is why the scan must
  be **layout-aware** — it needs `n`'s member-reader names to tell a member
  read (`n.x`, safe) from an unknown method (`n.frobnicate`, unsafe). Correlate
  `n → members` by detecting the materialising assignment (`n = <Struct.new
  chain>` syntactically, or `n = Const.new(...)` resolved via the layout
  side-table). A local assigned a struct in one branch and a non-struct in
  another, or reassigned, is conservatively disqualified.
- **Blocks are fine** as long as the walk descends into them: a `n` use inside
  a block (`n.each { … n … }`) is checked on its own; `n.each` itself is a safe
  receiver read.

### Where to hook it

Two viable shapes, pick by what reads cleanest against the codebase at
implementation time:

1. **Per-region side-table** (mirror `struct_member_layouts`): the scope
   indexer computes a `struct_fold_safe_locals` set per method body and the
   fold consults it via the scope. `fresh_receiver?` becomes
   `fresh OR (stored-local AND scope.struct_fold_safe?(local_name))`.
   Threading a *per-body* (not per-project) set through the scope is the new
   surface — study how method-body pre-scans are currently threaded
   (`build_user_method_body_scope` inherits `discovery` whole; a per-body
   table needs to be computed at body entry).
2. **Degrade-on-bind, inverted**: by default keep the `StructInstance` in the
   binding (as today), and at the fold site consult the scan. (The bound
   carrier is already retained — slice 2 does not degrade on bind.)

Either way the scan result is the same boolean per local.

## Slice 4 — precise mutated-member re-typing (route a, the narrow safe case)

Once slice 3 folds fold-safe locals, slice 4 *extends* fold-safety to locals
that are mutated **only through a direct setter on the same syntactic
binding** (no aliasing, no escape, no `[]=` with a dynamic key):

```ruby
p = Point.new(1, 2)
p.x = 5               # rebind member :x to the RHS type (5) on p's binding
p.x                   # → 5  (sound: the setter's effect flowed back)
p.y                   # → 2  (sibling stays precise)
```

This is the route-(a) flow-sensitive invalidation, but applied **only** to the
narrow, decidable case the slice-3 scan already proves safe (no alias / no
escape). The setter `p.x = v` re-binds `p` to a `StructInstance` with member
`:x` replaced by `v`'s type (the setter already returns `v` — slice 2 — so
this is the binding-side effect). The choke point is
`MutationWidening.widen_after_call` (`eval_call`'s post-scope); the prior art
is ADR-56 slice C receiver-content write-back (`content_writeback_block_captures`
/ `loop_content_writeback`), which already flows a mutation's effect back into
a continuation binding. Aliasing/escape are excluded by construction because
the slice-3 scan disqualifies any local that is aliased or escapes.

## Gate (both slices)

Precision-additive (no diagnostic), but the soundness bar is hard:

- Hand-probe the discriminating shapes that distinguish sound from unsound:
  `p.x = 5; p.x` (slice 4 → 5; slice 3 alone must NOT fold a mutated local),
  `q = p; q.x = 5; p.x` (alias → must NOT fold), `mutate!(p); p.x` (escape →
  must NOT fold), `p.x` with no mutation anywhere (→ folds).
- `make verify` — Rigor's own `lib` + the bundled corpora byte-identical
  besides the intended precision gains.
- A `rigor-survey` corpus diff (a mistyped bound-struct receiver is exactly the
  kind of external-code FP the self-check cannot expose) before trusting the
  bound-local fold.

## Prior art / pointers

- `lib/rigor/inference/method_dispatcher/struct_folding.rb` — the slice-1/2 tier
  and `fresh_receiver?` gate to relax.
- `ScopeIndexer#widen_member_for_observed_mutators` — class-ivar
  Tuple→Array / HashShape→Hash widening on observed mutator names (route-a
  prior art).
- ADR-56 slice C (`content_writeback_block_captures`, `loop_content_writeback`,
  `MutationWidening::CONTENT_ADDERS`) — receiver-content mutation flowing back
  into a continuation binding (the slice-4 write-back shape).
- `DataFolding` — the immutable sibling, which folds bound reads
  unconditionally (Data is frozen, so it has no fold-safe scan).
