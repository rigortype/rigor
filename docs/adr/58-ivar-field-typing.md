# ADR-58 — Instance-variable field typing: declaration-sourced nil policy, homogeneous-write reads, ctor definite assignment

Status: **Accepted, 2026-06-12.** Slices not yet implemented. Archetype:
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

### WD3 — Slice 3: ctor definite assignment through same-class calls

The stdlib C2 cluster (ipaddr `@mask_addr`) needs one more step: the
ctor assigns indirectly via a same-class method (`mask!`). A memoised
per-class scan of ctor-reachable same-class calls (depth-capped,
ADR-41-style) marks fields definitely assigned on every ctor path;
those drop the seed nil entirely (it is not merely non-firing — it is
absent). Smallest slice that closes ipaddr's 6 sites + uri/ldap.

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
