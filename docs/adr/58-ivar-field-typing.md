# ADR-58 — Instance-variable field typing: declaration-sourced nil policy, homogeneous-write reads, ctor definite assignment

Status: **Accepted, 2026-06-12.** WD1 partially implemented (binding-
provenance subset, 2026-06-12; the method-return-transit residual, WD1b, was
re-adjudicated to demand-gated earned conservatism — see the WD1b
adjudication under WD2). WD2 resolved as already-realized
(2026-06-12 — the flow-insensitive write-union already produces
`join(writes) | nil`; corpus yield ~zero, bounded by untyped-param /
recursive-return Dynamic sources per the WD2 status). WD3 implemented
(2026-06-12 — ctor definite assignment credited through unconditional
same-class calls; closes the ipaddr `@mask_addr` 6-site cluster, see
WD3 status). WD5 implemented
(2026-07-19 — a `MultiWriteNode` ivar target in `initialize` was
recorded into the class-ivar type union but not into `init_writes`, so
the read-before-write nil gate re-injected a spurious `nil` at every
sibling read; `detect_read_before_write` now counts massign targets as
writes, see WD5 status. The `||=`-seeding stretch is
**deferred-with-reason** there). WD2 amended (2026-09-26, #541 — an
`attr_writer` / `attr_accessor` declaration now counts as an untyped
write, see the WD2 amendment). WD2 amended again (2026-10-20, #1154 —
a write from a declared parameter records the declared type, held on
2026-10-21 to parity with a literal write; and 2026-10-21, #1406 — a
declared ivar type wins over the writes). Amendment proposed
2026-10-28 (#2079 / #2170 — another file's and the chain's writes join
existing census entries, coarsely typed; see the amendment before
"Rejected / deferred alternatives"). Archetype:
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

> **Corrected 2026-09-26 (#541).** The pre-pass recorded no accessor
> write, so `@next` above read `nil`, not `Dynamic[top] | nil`, until
> the WD2 amendment below; the Grounding line's `type-of` reading is
> wrong in the same way. On the algorithm corpora the `Dynamic[top]`
> came from somewhere else: those node fields are assigned from untyped
> constructor parameters (`def initialize(v, l = nil, r = nil)`), as the
> WD2 status notes. With only `@next = nil` recorded, `if @next` folded
> always-falsey and `@next.value` reported a call on `nil`.

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

**Addendum, 2026-06-13 — WD1 criterion extended to
`argument-type-mismatch` (N2).** The 2026-06-13 app/network corpora
survey
([`docs/notes/20260613-app-network-corpora-survey.md`](../notes/20260613-app-network-corpora-survey.md),
N2 row) found the same declaration-sourced-nil-is-not-fuel gap on a
second diagnostic: a ctor-seeded ivar read as a comparison *argument*
(`@lines = lines` (untyped param) then `while n < @lines` →
`got Dynamic[top]?`; `@length = 0; … while k <= @length` → `got 0?`).
The bare `Dynamic[top]` / `Integer` operand is gradual-consistent with
`Numeric`; the rejecting constituent is the read-site nil a
non-definitely-assigned ivar seed contributes. `argument_type_diagnostic`
now reuses WD1's provenance bit (`Scope#declaration_sourced?(:ivar, …)`)
at the firing decision: when the rejecting argument is a
declaration-sourced ivar read whose type *with the nil constituent
removed* would be accepted (gradual mode), the rule declines. This
changes only the firing decision — the argument's type is unchanged, so
downstream narrowing / joins / other rules are unaffected — and is gated
on provenance exactly as WD1, so flow-live nil (a method-local `@x = nil`
write that drops the mark) and a genuinely-wrong argument type (a
non-nil constituent the parameter still rejects) keep firing. Gate
(`--no-cache`): textbringer `floating_window` loses its 5 `< @lines` /
`> @lines` firings, concurrent-ruby's priority queue loses its 2
`<= @length` firings, all adjudicated declaration-provenance; Mastodon
`app/models` / kramdown `lib` byte-identical; self-check + `check-plugins`
zero new firings; `make verify` + `make bench-perf` clean. The
complementary suppress-on-any-`Dynamic`-union shortcut stays rejected for
the same reason WD1 records — provenance, not carrier shape, is the
stable rule.

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

**Amendment, 2026-09-26 — an attr writer declaration is a write
(#541).** The universe above left out the declaration a class makes
about its own field. `attr_writer :x` and `attr_accessor :x` now
contribute to `@x` exactly what the hand-written untyped setter
`def x=(v) = @x = v` does: `Dynamic[top]`, with the read-before-write
`nil`, the held `&&=` / `op=` merges, and WD1's declaration-sourced mark
following as they follow any write. A writer-only ivar gets an entry.

The criterion is where the evidence sits. A setter call site
(`obj.x = v`) is still declined for the reason above: its receiver's
class has to be resolved, and a misresolved one widens another class's
field. A writer declaration sits
in the class body the pre-pass already walks, names its own ivar, and
states that the field takes values from outside. Without it the
constructor's `@x = nil` was the only write the seed saw, so an injected
callback or flag (`attr_accessor :cb; def initialize = @cb = nil`) read
`nil`: `if @cb` fired `flow.always-truthy-condition`, and `@cb.call`
fired `call.undefined-method` at error level. Both are false positives
on the dependency-injection idiom (bash0C7's report in #541; ADR-5).

Two narrower options were rejected. A mark that declines only the flow
folds leaves the nil-receiver error in place. Contributing only when
every other write is `nil` misses the `@flag = false` flag.

The cost falls on a writer-backed ivar, and a hand-written setter
already paid each part of it:

- **Precision.** An ivar that also has a concrete write reads
  `Dynamic[top] | T`. kramdown's `@children` goes from `[]` to
  `Dynamic[top] | []`.
- **`rigor sig-gen`.** Every method whose return is such an ivar erases
  to `untyped` and is skipped as `sig.skipped.untyped-return`. That
  covers the accessor's own reader and writer, and a sibling
  `def w_value = @w`. `attr_accessor :logger` beside
  `@logger = Logger.new` no longer yields `def logger: () -> Logger`,
  and `@count = 0` no longer yields `def count=: (0) -> 0`. Only an ivar
  assigned from a constructor parameter is still typed, and only under
  `--params=observed`; since #1410 only when nothing else in the class's
  own body in that file writes it.
- **RBS-declared readers.** A writer-only ivar read before any write
  seeds `Dynamic[top] | nil`, so `def x_value = @x` against a declared
  `-> Integer` now reports `def.return-type-mismatch` ("inferred
  `Dynamic[top]?`"). Before, it read `Dynamic[top]` and stayed silent.
  The survey corpus declares almost no RBS, so the gate below could not
  see this. #1406 removes it by seeding from the RBS attr type.

Each closed reading was wrong for a field the class declares writable,
and the false positives removed are on working code with no RBS at all.

Out of scope, unchanged: `attr_reader` alone, a `class << self`
accessor, an includer of a module that declares the writer, another
file's reopening, and a non-literal name list (`attr_writer(*names)`).
Typing the writer from an RBS or inline attribute declaration is #1406;
the #518 safe-navigation workaround stays until #1407. Corpus gate
(`check --no-cache --no-baseline`, base vs change): liquid −1,
textbringer −2, rails −8, kramdown / mastodon / redmine 0, and no
diagnostic added. Every removal is a `flow.always-truthy-condition` on
an accessor-backed ivar (rails `@automatic_reconnect`,
`@ignore_disconnect`; liquid `@strict_variables`; textbringer
`@prefix_arg`).

**Amendment, 2026-10-20 — a write from a declared parameter carries
the declared type (#1154).** The pre-pass typed every rvalue with no
local bindings, so `@x = x` in a constructor recorded `Dynamic[top]`
even where `sig/` declared `initialize: (String x) -> void`, and every
sibling reader of the field was untyped. Such a write now records the
parameter's declared type (`sig/`, `# @rbs`, `#:`), and joins the
class's other writes as any write does: a `reset` storing `nil` makes it
`String?`, and an untyped write keeps `Dynamic[top]` in the union. The
maintainer settled the source on 2026-10-20: the declaration, not a
default value and not observed call sites, because a declared contract
is not a lower bound (ADR-1), so `rigor check` uses it as well as
`rigor sig-gen`. The WD1 mark is unchanged, so a joined `nil` still
does not fire on its own.

The census is flow-free, so the write is credited only where the
parameter cannot have changed: a bare read of the parameter, outside
every block, in a body that never writes that local and hands no code
to `binding` or an eval-family call, under a single typed overload with
no type variable, declared on the class itself (not inherited, not a
module, not a library class). Any other write records what it recorded
before. The binding contract is in `inference-engine.md`
§ "Instance-, class-, and global-variable bindings".

**Amendment, 2026-10-21 — parity with a literal write (#1154).** What
may overwrite a credited ivar unseen is held to the standard literal
writes already meet, not a stricter one. `@x = 1` in `initialize` reads
`1` in every sibling method whatever an unknown object's code does
(`o.extend(M)`, `o.instance_eval(&b)`, `class << o`, a computed
`o.instance_variable_set`, `ReflectiveIvarWrite` leaving it alone), and
a declared-parameter write now does the same. What the class and its
ancestors run still declines the credit: a project ancestor that writes
the ivar or defines its writer, a superclass that is not a core class,
an open-world writer on `self` in an instance body of the class or an
ancestor, a second file writing the same ivar in an instance body of
the same class (a `def` in its class body, in a `Struct.new` /
`Data.define` / `Class.new` constant block or in a `K.class_eval`
block), and a named write from outside
(`o.instance_variable_set(:@x, v)`). An `attr_writer :x` in a reopening
is accepted at parity, as it is for a literal write. A
project-wide decline on any open-world writer was measured first and
credited nothing on any surveyed project (every one holds such a
writer somewhere), so it was dropped. The accepted cost is a false
positive when an unknown-receiver writer stores a value of another
type: a sibling then reports on the declared type, as it reports on a
literal's type today. The decision is recorded in
`approval-queue.d/ivar-seed-literal-write-parity.md`.

**Amendment, 2026-10-21 — a declared ivar type wins (#1406).** The
WD2 amendment's cost on RBS-declared readers is removed at its source.
An ivar the class's RBS declares, as `@x: T` or through a typed
`attr_*` member (in `sig/` or inline), reads that type instead of the
census's join of the writes, so `attr_accessor cb: Proc?` beside
`@cb = nil` reads `Proc?` and `attr_writer x: Integer` no longer reads
`Dynamic[top] | nil`. The maintainer settled this on 2026-10-20 (#1154's
decision, point 3): an explicit declaration wins, and checking the
writes against it is ADR-112 WD5 (#1075). An `untyped` declaration
(rbs-inline's placeholder for a bare attribute) or one with a type
variable is not taken, and an undeclared attribute keeps #541's
`Dynamic[top]`. The declared type serves checking only: `rigor sig-gen`
keeps the census's answer, so it never proposes a declaration back as
an inference. A declaration looser than the code it describes now
surfaces as diagnostics; Rigor's own `sig/` had one
(`Scope#optimistic_locals`, declared `Symbol | Data`).

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

### WD5 — Slice 5: massign ctor targets are init writes (a latent WD2 gap)

WD2's "homogeneous write union" promise silently excluded one write
form. The class-ivar pre-pass has, since N1, decomposed a parallel
assignment (`@m, @n = [], []`) into the accumulator: each
`InstanceVariableTargetNode` records its tuple-position rvalue type, so
the *accumulator* held `@m → Tuple[]`. But `detect_read_before_write` —
the separate walk that populates `init_writes` (the ctor definite-
assignment set gating the read-before-write nil contribution) — only
recognised `InstanceVariableWriteNode` and the compound `@x ||= / &&= /
+=` forms, never a `MultiWriteNode` target. So an ivar written **only**
via massign in `initialize` was absent from `init_writes`; when a
sibling method read it before writing it,
`contribute_read_before_write_nil!` unioned `Constant[nil]` on top of
the recorded type, and the seed reached the read as `Tuple[] | nil`
rather than `Tuple[]`. The declaration-sourced possible-nil mark then
silenced the very diagnostic the concrete type should have surfaced
(`@m.no_such_method` reads a `T | nil` receiver, so the undefined-method
rule declines). The recorded type existed; the nil gate masked it.

The fix is one walk, not the recorder: `detect_read_before_write` now
descends a `MultiWriteNode`'s `value` first (an ivar read on the RHS
stays read-before-write) and then records every ivar target — including
nested `MultiTargetNode` and splat targets — into `seen_writes`, so the
ctor massign credits `init_writes` exactly as a plain `@x = …` write
does. Nothing in the write *universe* changes: an unanalyzable massign
RHS still floors to `Dynamic` (never `nil`, never a guessed nominal) per
N1, and the `guarded` / `falsey_constant?` / read-before-write-nil
disciplines are untouched — the change only stops a spurious nil from
overwriting an already-recorded, already-intended type. FP-safe by
construction (it can only *remove* a nil constituent, the FP-reducing
direction).

**Status, 2026-07-19 — implemented.** Motivated by the mastodon /
redmine / rails-core protection-coverage scout, which flagged untyped
ivar-field reads as a dominant engine gap; the FP-safe, closable part is
this latent massign-seed masking. Measured Tier-1 protection lift
(`coverage --protection`, cache cleared, baseline worktree vs new):
mastodon `app/models` 1837 → 1844 protected dispatch sites
(31.2 % → 31.3 %), redmine `app` 6121 → 6135 (32.2 % → 32.3 %).
Diagnostic gate (`check --no-cache --no-baseline`, baseline vs new):
mail / kramdown / haml / liquid `lib`, mastodon `app/models`, redmine
`app` all **byte-identical** (no new firing, no removed firing on the
surveyed slices — the masked-diagnostic correction is demonstrated on
the synthetic repro; the corpus slices happen not to carry the ctor-
massign-read-cross-method shape, so the win shows as protection-metric
movement without a diagnostic delta). `make verify` + self-check +
`check-plugins` clean; +3 unit specs (cross-method massign read stays a
plain `Tuple`, unanalyzable massign read stays `Dynamic`, nested target
credited). Perf on mastodon `app/models` (cold, 3×): wall flat
(~3.7 s), peak RSS 261 → 254 MB — within noise.

**`||=` seeding — deferred with reason.** The memo idiom
(`@memo ||= []`, `@config ||= {}`) is pervasive, and the pre-pass
deliberately does not seed `Prism::InstanceVariableOrWriteNode` (seeding
`@x ||= v` as `Constant[v]` folds `if @x` always-truthy → FP). The
WD2-shaped `union(v_type, nil)` model was prototyped and run through the
same corpus gate: on all six targets it was **diagnostic byte-identical**
(no new always-truthy / always-falsey / possible-nil firing) **and moved
the protection metric by zero** (mastodon 1844 → 1844, redmine 6135 →
6135 — a `T | nil` seed silences undefined-method the same way the
massign bug did, so it buys no new protected site here). Shipping it
would add a nil-union seeding surface for no measured corpus yield, so
per the WD4 decision rule (ship only if provably clean **and** carrying
adjudicated value) it is deferred. Reopen only if a corpus surfaces a
memo-read shape the `union(v, nil)` seed provably improves without a new
firing.

**Status, 2026-09-23 — implemented (#1175).** The reopen clause
fired on Rigor's own tree: `lib/rigor/effects/unit_scan.rb` writes
`@dispatch_top_level ||= true` and reads `unless @dispatch_top_level` —
a memo-read shape the unseeded `||=` folded to `Constant[false]` and
false-fired `flow.always-truthy-condition`. The pre-pass now seeds all
three compound forms: `||=` contributes `union(v_type, nil)` (skipped
when `v` is a falsey literal, the same "no useful precision" call the
guarded `@x = nil unless @x` skip makes), `&&=` contributes `v_type`
(the write only runs on an already-truthy ivar, so it cannot be the
first thing to give it a value), and `op=` contributes the widened
operator-dispatch result against the accumulated seed (`Constant[0] +
Constant[1]` must not pin the ivar to `Constant[1]`). The `&&=` arm
has one acknowledged boundary: a class whose *only* write to an ivar
is `@x &&= <truthy literal>` gets a purely-truthy seed for an ivar
that is `nil` at runtime forever — degenerate code, and the corpus
gate showed no firing, but the arm is unsound in isolation the same
way the unseeded `||=` was. The same corpus gate was re-run for this
landing; see the PR for the numbers. CI's
Self-check invocations also gained `--fail-on=warning`, matching
`make check` — the warning had printed green on every run since #1071
because the job read the exit code and warnings did not move it.

**Status, 2026-09-24 — widened (#1338).** The `||=` skip now covers
every rvalue with no truthy part, not only a falsey literal.
`@x ||= raise "unset"` stores nothing, yet its `union(bot, nil)`
contribution is `nil`, which bound the ivar in every instance method
of the class; the guard then read as provably raising, and `sig-gen`
declared `-> bot` on a reader whose ivar another class or an
`attr_writer` stores.

**Status, 2026-09-24 — `&&=` boundary closed (#1340).** The `&&=`
arm's boundary above was not harmless: seeded as the rvalue, the
`&&=` bound its own ivar, so `if (@x &&= 1)` could fold always-truthy
and `@x &&= raise "b"` could read `bot` (a direct `@x` read elsewhere
in the class added the read-before-write `nil`, which hid both). An
`&&=` contribution now counts only beside another write of the ivar,
in either source order, and a later `op=` still dispatches on it; an
ivar only `&&=` writes stays unseeded, and the write reads as the
unbound target `Dynamic[top] | v`, which is the statement evaluator's
reading.

**Status, 2026-09-24 — `op=` order closed (#1343).** The `op=` arm
dispatched on the seed as the pre-pass had walked it so far, so its
contribution depended on the order of the class's methods, which Ruby
may call in any order. With `@x = 1`, `@x &&= 1.5` and `@x += 1` in
three methods, the three orders that put the `+=` before the `&&=`
dropped `Float` from the seed and folded `x == 2.5` always-falsey on a
program that reaches it; #1340's read of the held `&&=` covered only
one of them. Every `op=` write is now held like an `&&=` until the walk
has seen the class. An ivar only `op=` writes is seeded from the
widened rvalues first, and that seed counts as a write for `&&=`. The
held writes are then dispatched on the complete seed, once per held
write, which covers every chain one call of each method forms.

Two consequences of dispatching on the complete seed needed handling.
A member the operator cannot take (`nil + 1`, from a `reset` or any
`||=`) made the dispatcher decline the whole union, so every write
fell back to its rvalue. The members it can type are now dispatched
together. A declining member whose class the environment knows lacks
the operator, so its write raises and adds nothing; any other (a
`Dynamic`, a class only source defines) keeps the rvalue it fell back
to before. Joining the rvalue for a `nil` too put an `Integer` no run
can store beside `0.5 | Float | nil`, and a `-> Float?` reader reported
`def.return-type-mismatch`. And distinct tuple literals (`@a += [:s1]`,
`@a += [:s2]`, …) grow the seed by two members per write, so a chain
that would go on from a receiver wider than 40 members floors to
`Dynamic[top]`. That is a cost guard local to the chain, not ADR-41's
unwired `union_size` budget; 40 is the low end of the pathology band
ADR-41's Slice 2a names, and the survey corpus's widest `op=`-written
seed has seven members. The seed then holds what every source order
produced, except the rvalue master fell back to when no other write
stood in the receiver, or when a member that raises made the dispatch
decline. "Raises" is read from the RBS: a source monkey patch of a core
operator, an operator the RBS omits, and the `nil` of an ivar no write
reached yet (`nil ^ true` is `true`), which the seed never modelled,
all read as raising.

ADR-56's `BodyFixpoint` was rejected for the chain: iterated to its
fixed point, a lone counter's `@n += x` re-dispatched on its own
`Dynamic[Integer | …]` result and gained `Dynamic[top]`, and the
widening pass that forces convergence dropped the literal it starts at,
on 51 of 304 `op=`-written ivar seeds in the survey corpus. A lone
write is therefore not applied to its own result: `@a = []; @a += [1]`
still seeds `[] | [1]`, as before, and no rule was seen to fold on it.
The corpus gate (18 targets, plus gitlab's 97 files with an ivar `op=`)
moved no diagnostic; the PR itemises the 39 seeds that change.

### Amendment, 2026-10-28 — cross-file and chain census contributions (#2079, #2170)

**Status: proposed, pending ratification** (`approval-queue.d/lane-2079-cross-file-ivar-census.md`).

The class-ivar census is built per file, keyed by each write's lexical
owner. Two kinds of write that land on `K`'s instances were therefore
missing from `K`'s seed: a write in another file's reopening of `K`
(#2079), and a write in a module `K` includes or prepends or in a
superclass of `K` (#2170). Without them a seed could be narrower than
any value the program stores, which is the opposite of WD1's premise
that the seed is an over-approximation. `class E; def initialize = (@x
= nil); def get = @x.upcase; end` with `class E; def set = (@x = "a");
end` in another file read `@x` as `nil` and reported `upcase` on it,
and `@y = false; other; if @y` folded always-falsey when `other`
lived in another file.

Decision:

- **Widening only, existing entries only.** Each ivar the file's
  census already holds for `K` is joined with those writes. No entry
  is created: an ivar only another file or an ancestor writes keeps
  reading `Dynamic[top]`. A new precise entry would narrow a read
  that is `Dynamic` today, and could add rows.
- **Coarse typing across files.** Another file's write joins as a
  literal's `Constant` (`nil`, booleans, numbers, symbols), a String
  literal as `String`, and `Dynamic[top]` for anything else, an
  `attr_writer` / `attr_accessor` included. A String is mutable, and an
  in-place mutation (`@s << "abc"`) in this file, in another file or in
  an ancestor is not visible where the literal was written, so its
  `Constant` would pin the value too narrowly (review S1). An ancestor's
  value joined from this file's census is widened again by the
  mutations this file observes. The value is recorded flow-free by the
  discovery pre-pass (`[:own_write_type, …]` in the global write
  census), so no other file is typed. An ancestor declared in the
  same file joins its own census entry, typed as the census types it,
  before its read-before-write `nil`.
- **Chain-wide and flow-free.** Every project class and module on
  `K`'s instance resolution chain contributes, whether or not `K`
  ever runs the writing method. A module's own census gains no chain.
  Singleton-side writes, `extend`, the `self.included(base)` hook
  (#1958) and `include(Module.new { … })` (no chain entry) contribute
  nothing.
- **Declaration-sourced.** The joined types are part of the seed, so
  a `nil` they bring is WD1 declaration-sourced and is not fuel for
  `call.possible-nil-receiver`; #2039 keeps the statement-position
  reset from bringing it back unmarked.
- **ADR-46.** Each read files `own_write_type:<owner>#<ivar>`, fired
  when a file's coarse values for the pair move (a type change under
  the same name included), and the chain's class edges.

Accepted losses, under ADR-5: a non-literal write in another file or
an ancestor widens the entry with `Dynamic[top]`, so checks on that
ivar's reads in `K` (`call.undefined-method`, argument types, condition
folds) stop; a write on a path `K` never takes still widens; and a
literal another file writes but never runs at `K`'s read stops a fold;
an all-truthy union (`true` here, `:on` elsewhere) is not folded; a
String literal reads as `String` once another file or an ancestor
writes the ivar, this file's own literal included (`@s = "x"` here and
`@s = "y"` elsewhere drop the `@s == "q"` always-falsey row); a `nil`
written anywhere else (another file, an included module, a
superclass's `initialize`) turns the entry into `T?`, and every method
check on that ivar in `K` goes quiet, as the same-file census already
does (`class Base; def initialize = (@x = nil); end` with `class Sub <
Base; def initialize; super; @x = Integer.sqrt(4); end; def r =
@x.upcase; end` reported `upcase` for Integer and is now quiet, while
Ruby raises; so do `@s = 1` here with `@s = nil` elsewhere and
`@s.upcase`, and `@s = nil` here with `@s = :b` elsewhere and
`@s.even?`); and a write in an `other.instance_eval` block of an
instance method is credited to `K` (#2490). A module's own census takes
no chain (#2487). The coordinator accepted the `nil` and String losses
under ADR-5, pending ratification.

### Amendment, 2026-10-29 — empty seeds are not proof of emptiness (#2499)

**Status: proposed, pending ratification** (`approval-queue.d/lane-2499-accumulator-seeds.md`).

The census seeds an ivar from each write's rvalue, and the same
pre-pass shape seeds class variables, globals and in-source constants.
An empty literal seed (`@s = ""`, `@buf ||= +""`, `$list = []`,
`PREFIX = ""`) pinned the slot to the empty value, so a read in another
method folded `@s.length > 0` always-falsey while a subclass, a mixin,
another file, a memoised accessor's caller or an `attr_reader` caller
filled it (#2491, #2492, #2496, #2497). The per-class mutation census
sees none of those writers.

Decision, shaped by the accumulator idiom rather than a uniform escape
analysis:

- A write whose rvalue is `""`, `+""`, `[]` or `{}`, a `.dup` of one, a
  chained write ending in one (`@a = @b = ""`), or the matching element
  of a multiple assignment (`@a, @b = {}, []`) seeds the slot as
  `String`, `Array[untyped]` or `Hash[untyped, untyped]`
  (`ScopeIndexer::EmptySeed`). `String.new`, `Array.new` and `Hash.new`
  already seed their nominal.
- A non-empty literal keeps its exact type, so modes and config tables
  (`@order = "asc"`, `MODES = %w[a b]`, `@opts = { a: 1 }`) still fold
  and still satisfy a literal-typed RBS parameter.
- Element evidence the census already collects is unchanged: the seed
  joins every other write, and a same-class `<<` still widens the entry
  as before.

Accepted loss: a slot that really stays empty no longer folds `empty?`
or `size > 0` from its seed, a `[].freeze` or `{}.freeze` constant
excepted, since only the bare spellings count.

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
