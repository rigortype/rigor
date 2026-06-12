# ADR-58 — Instance-variable field typing: declaration-sourced nil policy, homogeneous-write reads, ctor definite assignment

Status: **Accepted, 2026-06-12.** WD1 partially implemented (binding-
provenance subset, 2026-06-12; method-return-transit residual queued as
WD1b — see WD1 status). WD2 resolved as already-realized
(2026-06-12 — the flow-insensitive write-union already produces
`join(writes) | nil`; corpus yield ~zero, bounded by untyped-param /
recursive-return Dynamic sources per the WD2 status). WD3 implemented
(2026-06-12 — ctor definite assignment credited through unconditional
same-class calls; closes the ipaddr `@mask_addr` 6-site cluster, see
WD3 status). Archetype:
deliberative. Stakes: high — this governs when `possible-nil-receiver`
may fire on ivar-sourced optionality, the single largest FP class on
idiomatic data-structure Ruby (94 % of possible-nil errors across the
algorithm corpora), and the FP-discipline value binds.

Grounding:
[`docs/notes/20260612-algorithm-corpora-survey.md`](../notes/20260612-algorithm-corpora-survey.md)
(buckets M1/M2/M5: 109 of 116 possible-nil errors are node-field reads;
mechanism confirmed via `type-of`: `attr_accessor` + `@x = nil` ctor seed
→ reads type `Dynamic[top] | nil`, the `nil` fires) and the CRuby-stdlib
survey's deferred C2 cluster
([`20260612-cruby-stdlib-survey.md`](../notes/20260612-cruby-stdlib-survey.md)).

## Context

The class-ivar pre-pass (`ScopeIndexer#build_class_ivar_index`) unions
every `@x = …` write across the class, flow-insensitively. For the most
idiomatic data-structure Ruby —

```ruby
class Node
  attr_accessor :value, :next
  def initialize(value) = (@value = value; @next = nil)
end
current = current.next until current.next.nil?   # traversal
r = @right; b = r.colour                          # rotation under a tree invariant
```

— a field read types `Dynamic[top] | nil` (the ctor's `nil` seed unioned
with the untyped accessor write), and the `nil` constituent fires
`possible-nil-receiver` on every invariant-guarded read flow cannot
prove (rotations, balanced-tree shape, "list has ≥1 element here").
These programs work; the firings frighten them (109 across three
corpora). Yet a node field **genuinely is nil-able** — `leaf.next` IS
nil — so cross-method definite assignment cannot remove the nil, and
*adding* precision (typing reads `Node | nil` instead of
`Dynamic | nil`) would make the FP class worse, not better, unless the
firing policy changes first. The policy is therefore the decision; the
precision mechanisms are sequenced behind it.

Precedent: ADR-57 slice 3 softened destructured optional tuple slots
for exactly this reason — manufactured per-site optionality across a
correlated invariant flow cannot prove frightens working code.

## Decision

> **`possible-nil-receiver` may fire on ivar-sourced optionality only
> when the nil is *flow-live*: assigned or observed on a path that
> reaches the read within the method under analysis** (a local
> `@x = nil` write before the read, a read already narrowed to include
> nil by a failed guard, or an explicit nil comparison establishing
> presence). **Declaration-sourced nil** — the ctor seed / cross-method
> write union arriving via the class-ivar index — is real type
> information (it stays in the displayed type, `Node | nil`) but is
> **not by itself diagnostic fuel**: the working program's invariant is
> assumed, per the robustness principle. A strict profile MAY surface
> the declaration-sourced firings later; the default never does.

The slices, in dependency order:

### WD1 — Slice 1: declaration-sourced nil does not fire (the 109-FP fix)

In the possible-nil diagnostic path, distinguish the provenance of the
receiver's `nil` constituent: ivar-index-sourced (declaration) vs
flow-observed (live). Fire only on live nil. Implementation sketch: the
ivar read path knows when a binding came from the class-ivar index
rather than a method-local write or narrowing; carry that one bit (a
provenance flag on the binding or a fact) to the diagnostic site.
Local writes, parameter nils, and guard-derived nils keep firing
exactly as today. Gate: the 109 algorithm-corpora firings disappear;
Mastodon / haml / kramdown / ruby-lib deltas are zero-or-removals;
self-check clean.

**Status, 2026-06-12 — partially implemented (binding-provenance
subset; gate NOT fully met).** Landed the binding-provenance bit exactly
as sketched: a `Scope#declaration_sourced` set of `[kind, name]` refs,
seeded by `seed_instance_ivars` (the class-ivar index entry that carries
a ctor `@x = nil`), dropped by any flow-live `with_ivar`/`with_local`
touch (method-local write or narrowing), intersected at joins, and
propagated to a local across a *pure* ivar-read copy
(`r = @right; r.key`) via `eval_local_write`. `possible-nil-receiver`
consults `scope.declaration_sourced?(:local, …)` and declines.

Measured removals (`--no-cache`, baseline vs new, correct
"possible nil receiver" message count):

| Corpus | before | after | Δ |
| --- | --- | --- | --- |
| algorithms (kanwei `lib/`) | 32 | 5 | −27 |
| ADSR | 13 | 11 | −2 |
| DSAR | 71 | 71 | 0 |
| Ruby (TheAlgorithms) | 0 | 0 | 0 |
| ruby/lib (CRuby stdlib) | 138 | 138 | 0 |
| mastodon `app/models` | 5 | 5 | 0 |
| haml `lib` | 3 | 3 | 0 |
| kramdown `lib` | 8 | 8 | 0 |

All deltas are pure removals; **zero new firings** anywhere (every
corpus's total diagnostic count drops by exactly its possible-nil drop).
Adjudicated sample of the 29 removals — all the canonical
direct-copy/seeded-read rotation shape (`r = @right; r.key`,
`node = @next; node.value`), i.e. declaration-sourced.

**Why the gate is not fully met — the dominant firing shape is broader
than the binding sketch.** The binding bit only survives a *direct*
ivar→local copy. The DSAR/ruby-lib bulk (and the algorithms residual 5)
arrive by **method-return transit**: `parent = x.parent`,
`uncle = self.uncle(x)` where the same-class callee has an explicit
`return nil` (RBTree), or array round-trips (`stk.push(self.root); … temp
= stk.pop; temp.value`). Their receiver is still `Dynamic[top] | nil`
whose nil traces to the class-ivar index, but the nil rode a method
return / collection element, not a local binding — so the
binding-attached bit cannot reach it. Probed and confirmed via
`type-of`: DSAR `uncle` reads `Dynamic[top]?`, its nil is `uncle`'s own
`return nil`.

Suppressing those FP-safely needs provenance to ride the **type's nil
constituent** through self-call return adoption (ADR-57) and collection
round-trips, while *not* over-reaching into genuinely foreign library
returns (`ActiveRecord::find_by → T?`, mastodon's 5). That is a larger,
FP-risky change than the binding sketch and the rejected
"any-Dynamic-union" shortcut would swallow the foreign-return nils
wholesale. **Queued as WD1b (nil-constituent provenance through return
adoption)**, gated by the same zero-new-firing protocol; the
binding-provenance subset ships now because it is sound, FP-clean, and
removes the canonical rotation-copy class without touching any other
diagnostic.

### WD2 — Slice 2: homogeneous-write field reads (precision)

With WD1 in force, precision no longer manufactures FPs: when every
recorded write to `@x` across the class is type-compatible, reads
become `join(written types) | nil-if-seeded` instead of
`Dynamic[top] | nil` — `current.next` types `Node | nil`, so traversal
chains (`current.next.value` after a guard) type precisely and
`node = node.next` loops stop draining to Dynamic (algorithm-survey
M1/M2's coverage floor, 35–48 % dyntop on container code).
Attr-writer/unknown writes keep today's Dynamic. Reuses the
dead-transient-nil-write elision already landed (77a4bd0a).

**Status, 2026-06-12 — already realized by the flow-insensitive
write-union; no new code.** The chosen write universe is exactly the one
the slice names — **the recorded direct `@x = expr` writes**
(`build_class_ivar_index`), and the engine *already* delivers WD2's
promised read type from it. The class-ivar index unions every write
rvalue via `Type::Combinator.union` and seeds that union verbatim
(`class_ivars_for` → `seed_instance_ivars`, no widening on the path), so:

- a homogeneous concrete-write field reads its precise type today —
  verified by `type-of`: `@pt = Pt.new` reads `Pt?`; a self-referential
  `@nxt = Node.new` (or `@nxt = r` where `r = @next`) reads `Node?`;
  kanwei `Heap::Node#@left = self` / `@right = self` reads
  `Containers::Heap::Node` (probed in the live index). The self-class /
  forward-declared `.new` resolves because the pre-pass scope is seeded
  with the discovered-class table (`merged_classes`) before the ivar
  walk, and `resolve_constant_name` consults it;
- heterogeneous *concrete* writes keep their precise union, not Dynamic
  (`@v = A.new` / `@v = B.new` reads `A | B | nil`);
- the accessor read then drops the optional under the existing
  return-FP-discipline (`x.nxt` on a `Node` receiver reads `Node`, no
  `nil`), so `current.next.value` after a guard types precisely and a
  clean `node = node.next` loop is `Node`-typed at the seed and re-entry;
- **unknown/untyped writes keep today's Dynamic** exactly as the ADR
  requires — and *that constraint is what bounds the corpus yield.*

**Chosen universe and why no broader one.** A **setter-call-site**
universe (`obj.next = expr` recorded as a write) was investigated and
**declined**: on the algorithm corpora the node fields are written *only*
via untyped params (`def initialize(v, l = nil, r = nil); self.left = l`)
and recursive same-class-method returns (`node.left =
self.insertUtil(node.left, value)`), whose rvalues are themselves
`Dynamic` — so setter sites would add zero precision while widening the
FP surface through receiver-class misresolution. The honest measured
yield of *any* sound homogeneity universe on these corpora is therefore
**~zero on coverage**: kanwei `lib/` stays at `precise_ratio 0.3579`
(64 % dyntop) because its floor is **untyped-param node fields (M3,
explicitly excused as gradual-typing) and recursive-return Dynamic**, not
an ivar-read typing gap WD2 could close. The `Heap::Node` self-write
fields already type `Heap::Node`; the `RubyRBTreeMap::Node` fields are
`Dynamic` precisely because every write source is a param or an
ivar-read rvalue.

**Diagnostic delta: zero (no code change).** Self-check, algorithm
corpora, ruby/lib, Mastodon/haml/kramdown are byte-identical (verified by
construction — the engine behaviour is unchanged). WD1's
declaration-sourced provenance is orthogonal to the carrier and continues
to suppress the rotation-copy firings; WD1's probe fixtures
(`class P; @right = P.new; r = @right; r.key`) pass unchanged and are
themselves the demonstration that the homogeneous `P?` read is already
produced.

**WD1b re-scope, confirmed.** Now that accessor returns drop the nil
(`x.parent` on a `Node` reads `Node`), the dominant DSAR/RBTree residual
does **not** change character under WD2: `uncle = self.uncle(x)` fires on
`Dynamic | nil` where the nil is the same-class callee's *explicit*
`return nil` (flow-live), and the receiver chain `node.parent.parent` is
`Dynamic` from param-sourced `@parent` (M3). Both are WD1b
(nil-constituent provenance through return adoption) / M3 (param
inference) frontiers, not WD2 ivar precision. Typing the ivar read
`Node | nil` would leave these firings intact.

**WD1b adjudication and demand-gating (2026-06-12, main-agent
decision).** The WD1b residual class is re-adjudicated as
**genuine-conservative, not artifact**: the firing nil is the callee's
own explicit `return nil` — a value the method really returns at
runtime (an RBTree node's uncle genuinely can be absent), consumed
unguarded under a tree-shape invariant. That is exactly the
`find_by → T?` shape the WD1 status already ruled must keep firing;
suppressing it would require distinguishing "user same-class callee"
from "foreign library" by origin alone, which is not a soundness-
or invariant-relevant distinction — the two are the same diagnostic.
WD1b therefore moves from "queued" to **demand-gated**: it proceeds
only if a corpus shows a same-class-return shape that is *provably*
invariant-protected in a way flow could credit (at which point the fix
is a narrowing rule, not provenance suppression). The remaining
algorithm-corpora firings stand as earned conservatism.

### WD3 — Slice 3: ctor definite assignment through same-class calls

The stdlib C2 cluster (ipaddr `@mask_addr`) needs one more step: the
ctor assigns indirectly via a same-class method (`mask!`). A memoised
per-class scan of ctor-reachable same-class calls (depth-capped,
ADR-41-style) marks fields definitely assigned on every ctor path;
those drop the seed nil entirely (it is not merely non-firing — it is
absent). Smallest slice that closes ipaddr's 6 sites + uri/ldap.

**Status, 2026-06-12 — implemented.** Extends the 77a4bd0a
dead-transient-nil elision from a top-statement-level post-domination
check into a recursive definite-assignment analysis
(`suffix_definitely_assigns?` over the ctor body suffix, handling
nested `if/else`, `case/when`+`else`, early `return`, and `raise`-
terminated non-completing branches) that may now credit an
**unconditional, statement-level, implicit-`self`/`self.`** same-class
method call as the overwrite. The crediting consults a once-per-program
flat summary `{class => {method => Set<ivars definitely assigned non-nil
on every completing path>}}` (`build_method_assign_effects`), itself
computed by the same suffix analysis and transitively crediting nested
same-class calls under an ADR-41-style hard cap
(`SAME_CLASS_CALL_DEPTH_CAP = 3`) with a per-def cycle guard. Soundness:
conditional calls, calls through a block/loop, calls on a non-`self`
receiver, and unresolved (non-same-class) names contribute nothing — the
seed nil stays. Singleton (`def self.x`) defs are excluded from the
summary; per-class index, so a subclass ctor that does not call `super`
is out of scope as today.

Measured `ruby/lib` delta (`--no-cache`, baseline worktree vs new): the
six predicted ipaddr `@mask_addr` `^` `call.argument-type-mismatch`
firings (`lib/ipaddr.rb` lines 463, 466, 513, 515, 558, 560 — the
`IN4MASK ^ @mask_addr` / `IN6MASK ^ @mask_addr` family) are **removed**,
**zero new** anywhere; total 451 → 445. The residual displayed type at
those reads is now `Dynamic[top] | Integer` (the orthogonal multi-writer
Dynamic chain the ADR noted remains; only the rejecting `nil` is gone,
and `Dynamic` gradually matches `Integer`). uri/ldap `@dn`-style
return-mismatches stay untouched — genuinely param-sourced `Dynamic`,
out of scope as the ADR predicted. Mastodon `app/models`, haml `lib`,
kramdown `lib`, and the four algorithm corpora
(algorithms / ADSR / DSAR / TheAlgorithms) are byte-identical; full
spec suite + self-check + `check-plugins` clean; +7 unit specs (the
indirect-assign / ipaddr-shape / raise-arm wins and the conditional /
block / one-branch / unresolved-call counter-probes).

### WD4 — Gate

Per slice: `make verify` + the three standing corpora + ruby/lib +
algorithm corpora, zero-new / adjudicated-wins (ADR-56 WD4 protocol);
hand-probed discriminating shapes mandatory (traversal loop, rotation
read, a genuine local `@x = nil; @x.foo` that MUST keep firing, a
failed-guard read that MUST keep firing).

## Rejected / deferred alternatives

- **Cross-method ivar definite assignment as the headline fix.**
  Rejected as insufficient — node fields are genuinely nil-able; the
  FP driver is unprovable *use-site* invariants, not assignment gaps.
  Definite assignment survives as WD3 for the genuinely-always-assigned
  cluster.
- **Suppress possible-nil on any `Dynamic`-bearing union.** Considered
  (one-line, kills the same 109 today) but rejected as the criterion:
  it stops being true the moment WD2 lands (`Node | nil` has no Dynamic
  constituent) and would silently weaken genuinely-live nil unions.
  Provenance, not carrier shape, is the stable rule.
- **Strict-mode default for declaration-sourced firings.** Deferred —
  fits ADR-50's bleeding-edge / profile machinery when a user asks.

## Relationship to other ADRs

- **ADR-5 / FP discipline** — the decision criterion is its direct
  application: an invariant the program's tests prove daily outranks
  the worst-case static reading.
- **ADR-57** — slice-3 destructure softening is the precedent; the
  adjudicate-per-class gate protocol carries over.
- **ADR-41** — WD3's ctor-call scan is depth-capped under the standard
  termination rules.
