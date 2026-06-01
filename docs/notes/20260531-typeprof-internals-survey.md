# TypeProf internals survey — inference logic + internal type representation

**Date:** 2026-05-31 (verification pass 2026-06-01).
**Subject:** [TypeProf](https://github.com/ruby/typeprof) v0.31.1, vendored read-only at
`references/typeprof/` (pin `19ff60cf`).
**Why:** Deep-dive backing the handbook appendix
[`docs/handbook/appendix-typeprof.md`](../handbook/appendix-typeprof.md). It pins the
appendix's claims — whole-program abstract interpreter, parameter inference from call
sites, literal-widening, diagnostics-as-byproduct — to the actual source so future
appendix edits (and any "should Rigor borrow X" question) rest on verified mechanism, not
folklore.

**Reading order / status.** §1–§8 are the mechanism walkthrough. §9 is the Rigor↔TypeProf
feedback/divergence analysis. §10 is the 2026-06-01 verification pass that resolved the
four items originally left unconfirmed (and corrected one wrong intermediate finding —
narrowing). The two recap tables ("maps back to appendix claims", "resolution status")
sit after §10. **Every claim in this note is now source-confirmed**; the only remaining
caveats are genuine TypeProf limits, not verification gaps (recap at the end of §10's
resolution table).

All `file:line` citations are against the vendored v0.31.1 tree; treat individual line
numbers as ±a few and re-grep before quoting elsewhere. Primary sources: the source
itself + the project's own [`doc/doc.md`](../../references/typeprof/doc/doc.md).
Secondary (design intent / history): Endoh's RubyKaigi talks, listed at the end.

---

## 0. One-paragraph orientation

TypeProf is not a constraint solver and not a textbook Hindley–Milner inferer. It is a
**type-level abstract interpreter implemented as a monotone dataflow graph**. Source code
is lowered to a graph of **vertices** (type sets) connected by **edges** (dataflow) with
**boxes** (computation nodes) sitting on method calls, constant reads, ivar reads, etc.
Types are injected at literals/known points and **propagate along edges until the graph
reaches a fixpoint** (the worklist empties). A method parameter's type is literally "the
union of every actual-argument type that ever flowed into it across all call sites" —
which is why TypeProf needs to *see at least one call site* to infer a parameter. A call
site is any call it can interpret: top-level code, an `__END__` example, a driver script,
or a line in a test. TypeProf has **no notion of a test** — a test is just one more
source of call sites, neither recognised nor privileged as such. This call-site-driven
model is also why its headline product is generated RBS rather than a curated diagnostic
stream. The project's own framing: *"a Ruby interpreter that abstractly executes Ruby
programs at the type level"* ([doc.md:29](../../references/typeprof/doc/doc.md)).

This is the mechanistic backing for the appendix's "whole-program vs local" contrast with
Rigor (per-method inference against a catalog, bounded by inference budgets).

---

## 1. The convergence / worklist mechanism

The whole analysis is a **FIFO worklist to fixpoint**, held on `GlobalEnv`
(`lib/typeprof/core/env.rb`):

```ruby
def add_run(obj)
  unless @run_queue_set.include?(obj)
    @run_queue << obj
    @run_queue_set << obj
  end
end

def run_all
  until @run_queue.empty?
    obj = @run_queue.shift
    @run_queue_set.delete(obj)
    obj.run(self) unless obj.destroyed
  end
end
```

- The queue holds **boxes** (and callsites) to (re)run. `@run_queue_set` dedups so a box
  is queued at most once.
- Fixpoint = `@run_queue` empties. Because the lattice is monotone (types are only added
  during a forward pass; see §below on removal/incremental), this terminates.
- A box gets **(re)enqueued when one of its input vertices changes**. The trigger lives in
  `Vertex#on_type_added` (`graph/vertex.rb:145-166`): adding a new type to a vertex calls
  `on_type_added` on every successor in `@next_vtxs`, and boxes register themselves as
  successors of their inputs (e.g. `MethodCallBox` does `@recv.add_edge(genv, self)` and
  `arg.add_edge(genv, self)` in its constructor, `graph/box.rb:1011-1015`). So "receiver
  gained a new type" ⇒ the call box re-runs ⇒ it may add new edges/types ⇒ downstream
  boxes re-run.

### Vertices are reference-counted type *multisets*

`Vertex` (`graph/vertex.rb:125-208`) does **not** store a flat set of types; it stores
`@types[ty] => Set(source_vars)` — i.e. each type remembers *which upstream sources
contributed it*. `on_type_added` only forward-propagates the genuinely-new types
(`new_added_types`), and `on_type_removed` (`vertex.rb:168-183`) decrements: a type is
removed from the vertex (and propagated as a removal) **only when its last contributing
source is gone**. This reference-counting is what makes **incremental re-analysis**
correct: you can retract one file's contributions without recomputing the world.

`Source` (`vertex.rb:73-123`) is the immutable counterpart — a fixed type set used for
literals and known types. It has no inputs and never re-runs; it only ever *feeds* edges.

### ChangeSet — diff-and-rollback per box run

Each box owns a `ChangeSet` (`graph/change_set.rb`) recording the edges, sub-boxes, and
diagnostics it produced on its **last** run. On re-run, the new run's output is **diffed**
against the recorded set: stale edges/boxes/diagnostics are removed, new ones installed.
This is the unit of incrementality — "edit a file → re-run only the affected boxes, and
roll back exactly what they previously emitted."

### Incremental entry point

`Service#update_rb_file` (`core/service.rb`, ~lines 60-75) drives the edit cycle:
`node.define` / `prev_node.undefine` then `define_all`, then `node.install` /
`prev_node.uninstall` then `run_all`. The `define`/`install` split is two passes: `define`
registers entities (classes, methods, constants) into the global namespace; `install`
materializes the dataflow graph (vertices + boxes) and seeds the worklist.

> Appendix tie-in: this is the v2 "designed for IDE / incremental from the start"
> architecture Endoh describes in the RubyKaigi 2023 "Revisiting TypeProf" talk — the
> reboot existed *because* the original batch design couldn't bolt on incremental IDE
> updates.

---

## 2. What a "Box" is, and the taxonomy

A **Box** = a graph node that **consumes input vertices (via edges), runs domain logic,
and writes to output vertices** (typically a `@ret` vertex). The base `Box#run`
(`graph/box.rb:36-`) wraps `run0` (the per-subclass body) in ChangeSet bookkeeping. The
framing in the appendix ("TypeProf re-interprets callee bodies") is realized here: a
`MethodCallBox` re-running *is* the re-interpretation.

Subclasses (all in `graph/box.rb`), one line each:

| Box | Role |
| --- | --- |
| `MethodCallBox` (1006) | A call site: resolve receiver → find callee(s) → wire args↔params, callee-return→`ret`. The heart; see §3. |
| `MethodDefBox` (669) | A Ruby `def`: holds formal-param vertices, unions all `return` paths into its return vertex, receives actual args from every caller. |
| `MethodDeclBox` (237) | An RBS method declaration: holds the overload set; **type-checks** actual args against declared formals, contributes the declared return type. Does not execute a body. |
| `MethodAliasBox` (974) | `alias`: redirects one method name to another. |
| `ConstReadBox` (53) | Constant reference → resolved value type. |
| `TypeReadBox` (73) | Materializes an RBS type annotation into a propagating vertex. |
| `IVarReadBox` (1263) | `@ivar` read, aggregated **per class** (not per instance — see doc.md:64). |
| `CVarReadBox` (1329) | `@@cvar` read. |
| `GVarReadBox` (1248) | `$gvar` read. |
| `SplatBox` (602) | `*arr` expansion → element vertex. |
| `HashSplatBox` (643) | `**hash` expansion → key/value vertices. |
| `EscapeBox` (568) | `return`/`next` — captures the escaping value, checks against declared return. |
| `MAsgnBox` (1372) | Multiple assignment `a, b = ...` destructuring. |
| `InstanceTypeBox` (1416) | Builds an instance type with type-args (generics instantiation support). |

The "Ruby call passes args / RBS call typechecks args" split (the `MethodDefBox` vs
`MethodDeclBox` duality) is the load-bearing distinction for inference vs checking.

---

## 3. Method-call resolution & inter-procedural flow (the heart)

This is the mechanism the appendix's "infers params from call sites: **yes**" row rests
on. `MethodCallBox` constructor (`box.rb:1006-1018`):

```ruby
def initialize(node, genv, recv, mid, a_args, subclasses)
  super(node)
  @recv = recv
  @recv.add_edge(genv, self)          # re-run when receiver type changes
  @a_args = a_args
  @a_args.each_arg { |arg| arg.add_edge(genv, self) }  # ...or when any arg type changes
  ...
end
```

On `run0` it **resolves the receiver type(s)** to concrete `Type::Instance` / `Singleton`,
walks the **method lookup chain** (prepended modules → own class → included modules →
superclass), and for each resolved callee yields either a `MethodDecl` (RBS) or a
`MethodDef` (Ruby). Then:

- **Ruby def path (inference):** the callee's `MethodDefBox` connects **each actual-argument
  vertex → the corresponding formal-parameter vertex** (`changes.add_edge(genv,
  a_args.positionals[i], f_vtx)`). Because a `Vertex` accumulates a type *multiset* from
  all its in-edges, the parameter's inferred type becomes the **union of the argument
  types from every call site**. The callee's return vertex (union of all `return`/implicit
  paths) is edged back into the call site's `@ret`. **This is whole-program inter-procedural
  flow**: types flow caller→callee (args) and callee→caller (return) by graph edges, with
  no separate summary or constraint set.
- **RBS decl path (checking):** `MethodDeclBox#resolve_overloads` matches actual args
  against declared formal types (`match_arguments?`), and on a match edges the **declared**
  return type into the call's `@ret`. Here args are *checked*, not *learned from* — the
  declaration is authoritative.

**Blocks/`yield`:** the block argument is carried as a vertex holding `Type::Proc` values
(`type.rb:196-210`, a Proc wraps the block's code object). Block parameters are wired the
same edge way; `yield` flows the yielded args into the block's params and the block's
result back. The exact fan-out (positional `.zip`, single-arg auto-destructure, return via
escape boxes) is traced in §10c.

**Consequence for the appendix:** an un-annotated parameter only ever called with `String`
infers `(String)`. There is **no robustness widening** — TypeProf reports what flowed.
This is exactly the ADR-5 contrast the "Tests as inference fuel" section draws: Rigor's
`--params=observed` deliberately treats that same observation as a *reviewable suggestion*,
not a contract.

---

## 4. AST → graph construction

`lib/typeprof/core/ast.rb` (+ `ast/*.rb`) lowers Prism AST nodes to graph fragments. Each
`AST::Node` implements `install0(genv)` returning the vertex that represents its value.

- **Literals** (`ast/value.rb`): `IntegerNode#install0` → `Source.new(genv.int_type)`;
  `FloatNode` → `Source.new(genv.float_type)`. **The value is discarded** — `42` becomes
  the `Integer` instance type. The exception is `SymbolNode#install0` →
  `Source.new(Type::Symbol.new(genv, @lit))`, which **keeps the literal symbol**. (See §5.)
- **Local variables:** stored one **vertex per variable per lexical scope** in the
  `LocalEnv` (`@locals[name] => Vertex`). A read returns that vertex; a write edges the RHS
  into it. Not full SSA, but blocks that may mutate an outer var get a fresh vertex spliced
  in (`new_var`/`set_var`) so the closure's effect is modeled.
- **Method call** (`ast/call.rb`): builds `ActualArguments` (positional/keyword/splat/block
  vertices) and emits a `MethodCallBox`; the box's `@ret` is the call's value vertex.
- **`def`** (`ast/method.rb`): registers a `MethodDefBox`; creates one vertex per formal
  param inside the body scope.
- **`if`/branches** (`ast/control.rb`): **TypeProf DOES flow-sensitively narrow.**
  `BranchNode#install0` calls `@cond.narrowings` (a `[then_narrowing, else_narrowing]`
  pair), clones a fresh vertex per modified variable for each arm, and applies the
  narrowing constraint inside the arm via `AST.with_narrowing` before unioning the arm
  results into the `if`'s value. So `if x.is_a?(String)` **does** retype `x` to `String`
  inside the then-arm. See §10a for the full mechanism — this corrects an earlier draft of
  this note that wrongly claimed "no flow narrowing."

---

## 5. Literal & precision policy (verified)

From `doc/doc.md:93-135` ("Abstract values") + the source:

- **Abstracted to the class (value discarded):** instances of classes — `42` → `Integer`,
  `"str"` → `String`, `nil`/`true`/`false` → `NilClass`/`TrueClass`/`FalseClass` instance
  types (`type.rb:99-107` renders these specially in `show`). **No `Constant<1>` analogue.**
  This is the single biggest internal-representation difference from Rigor.
- **Kept concrete:**
  - **Class objects** — `Integer`, `String` constants are `Type::Singleton`, *not*
    abstracted to `Class`, because const refs and class-method dispatch need the identity
    (`doc.md:113-116`).
  - **Symbols** — `:foo` stays `Type::Symbol(:foo)` because the concrete value is needed for
    keyword args, JSON keys, `attr_reader` names, etc. (`doc.md:118-120`). But *dynamic*
    symbols (`:"foo_#{x}"`, `String#to_sym` results) fall back to the `Symbol` instance type.
- **Structure kept (the precision Rigor and TypeProf both have):**
  - `Type::Array` (`type.rb:110-169`) carries an optional `@elems` array of vertices for
    **tuple-like literals** (`[1, "a"]` → `[Integer, String]`) plus a unified
    `@base_type` (`Array[Integer | String]`) for the widened view.
  - `Type::Hash` (`type.rb:171-194`) and `Type::Record` (`type.rb:277-310`) keep
    **per-key field types** for literal-key hashes (`{name: ..., age: ...}`).
- **`untyped`** is the explicit give-up value (`doc.md:122-123`): produced when tracing
  fails; any operation on it yields `untyped`. This is TypeProf's conservatism knob — *"when
  faced with uncertainty, prefer to infer `untyped` rather than emit a wrong diagnostic"*
  (secondary sources, consistent with the doc).

Mapping these onto the appendix's vocabulary table: TypeProf's output column (`1`→`Integer`,
`"foo".upcase`→`String`) is *exactly* what Rigor's RBS erasure produces at the boundary —
the difference is Rigor keeps `Constant`/`Refined`/`IntegerRange` *internally* and only
erases at the edge, whereas TypeProf never had them to begin with.

---

## 6. RBS export (the CLI's main product)

Rendering is `Vertex#show` (`vertex.rb:24-66`) composing `Type#show` (`type.rb`, each
subclass). Notable in `Vertex#show`:

- Iterates the type multiset, **collapses `TrueClass`+`FalseClass` → `bool`**, lifts
  `NilClass` out as a trailing `?` (optional), drops `bot`.
- 0 types → `untyped` (or `nil`/`bot`); 1 → that type (+`?`); many → `(A | B | C)` (+`?`).
- Sorted + uniq'd for determinism.

Method signatures are assembled by `MethodDefBox#show`: join formal-param `show`s as the
parameter list, `-> #{@ret.show}` (or `void` for `initialize`). The recursion guard
(`Fiber[:show_rec]`, `vertex.rb:25-30`) prints `untyped` on cycles — recursive types degrade
to `untyped` rather than loop. **Widening to nominal "happens" simply because the vertices
never held anything narrower** — there is no separate widening pass on output; the
abstraction already occurred at literal-injection time (§5).

---

## 7. RBS *input*

`Service#load_core_rbs` (`core/service.rb`, ~line 10) loads core/stdlib RBS via the `rbs`
gem, converts each decl through `AST.create_rbs_decl`, then `define`/`install`/`run_all`
— i.e. **RBS declarations enter the very same graph** as inferred code, as `MethodDeclBox`
nodes. User `sig/` is supplied on the CLI (`typeprof sig/app.rbs app.rb`,
`doc.md:11-15`). A method entity can carry **both** `decls` (RBS) and `defs` (Ruby); at a
call site `MethodCallBox` consults both — declared types act as authoritative
constraints/return sources, inferred defs contribute learned param/return types. So
hand-written RBS and inference coexist on one method.

> This is the same RBS-as-shared-input point the Steep appendix and the TypeProf appendix's
> coexistence section make: all three tools (Steep, TypeProf, Rigor) read the same `.rbs`.

---

## 8. Diagnostics as a byproduct

Errors are emitted **inside box runs**, not in a separate linter pass — confirming the
appendix's "diagnostics are a side effect vs Rigor's main product" framing:

- Undefined method: in `MethodCallBox` resolution, when no callee is found
  (`changes.add_diagnostic(..., "undefined method: ...")`), with a small per-site error cap.
- Arity / argument mismatch: during arg→param wiring in `MethodDefBox` /
  overload matching in `MethodDeclBox`.
- Wrong return type: `EscapeBox` checks an escaping value against the declared return.

Diagnostics are accumulated in the box's `ChangeSet` and diffed in/out exactly like edges,
so they appear/disappear incrementally with edits. There is **no curation layer / severity
model / false-positive-discipline gate** — the stream is "what abstract interpretation
tripped over," which is why the doc/talks frame TypeProf as *"optimized for understanding
code, not judging it."*

---

## 9. Rigor ↔ TypeProf: feedback vs. fundamental divergence

This section reframes the comparison from Rigor's side: *what could Rigor's design
teach TypeProf*, and *where is Rigor's design so foundationally different that the gap is
not a bug to fix but a consequence of a different bet*. The split matters because the two
are not competitors with the same goal — TypeProf is *understanding code* (infer & emit
RBS, IDE-first, tolerant), Rigor is *judging code* (prove bugs, FP-disciplined, scale
across a whole repo). Every row below is anchored to a mechanism established in §1–§8.

### 9a. Elements Rigor could feed back to TypeProf (portable — no identity loss)

These are precision/ergonomics ideas Rigor proved out that TypeProf could adopt **without
abandoning whole-program type-level execution**. They strengthen TypeProf at what it
already is.

1. **Literal / refinement carriers with output-time widening.**
   TypeProf discards literal values at `install0` (`42`→`Integer`, `value.rb`), yet it
   *already* keeps concrete Symbols (`Type::Symbol(:foo)`) and structural Array `@elems` /
   Record fields (§5). So the "a Type subclass that carries a concrete value" precedent
   exists internally. Rigor's contribution is the *discipline around it*: a `Constant`/
   `Refined`/`IntegerRange` carrier that is kept internally but **erased to nominal RBS at
   the boundary** (Rigor's RBS-erasure contract, §6 is the natural erase point —
   `Vertex#show`). TypeProf could add `IntegerLiteral`/`StringLiteral` purely for hover
   precision and constant-fold builtins, widening in `show`. **Caveat:** the type multiset
   blows up (`42` and `43` are distinct types) — TypeProf's whole-program graph is far more
   blow-up-sensitive than Rigor's budgeted per-method engine, so this *requires* an
   explicit "widen after N literals" strategy that Rigor can largely skip.

2. **An opt-in curated diagnostic layer + severity model.**
   TypeProf's errors are byproducts emitted mid-`run0` (§8) with no curation, no severity
   profile, no suppression grammar. Rigor's `diagnostic-policy` (dotted-identifier taxonomy,
   `severity_profile`, `# rigor:disable`) is a **pure layer over the same signal** — it
   touches no inference internals. TypeProf could ship this as an *optional lint mode*
   without becoming a judge by default (see 9b.2 for why "by default" would break it).

3. **Robustness-principle output policy (ADR-5) for parameters.**
   TypeProf emits observed-narrow parameters as-is: a method only ever called with `String`
   becomes `(String)` (§3 — params are the union of actual-arg vertices). Rigor's stance is
   that this observation is a *reviewable suggestion*, not a contract, and it widens toward
   capability roles. TypeProf's RBS output (`MethodDefBox#show`, §6) is the exact place to
   apply a "lenient parameters, strict returns" rewrite — fully compatible with its
   record-what-flowed model.

4. **A public plugin surface for return-type contributions.**
   TypeProf has the *seed* — builtin hooks dispatched via `me.builtin[...]`
   (`box.rb:1037`). Rigor promoted this idea into a first-class plugin API
   (`flow_contribution_for`, return overrides keyed on a literal argument). TypeProf could
   graduate its hardcoded `builtin.rb` dispatch into a registered, third-party-extensible
   API. No conflict with the core model.

5. **Reference-counted incrementality is already shared DNA — Rigor validates the bet.**
   Not a feedback *to* TypeProf so much as a convergent confirmation: TypeProf's
   ref-counted type multisets + ChangeSet diff-rollback (§1) and Rigor's per-file cache
   (ADR-6) independently arrived at "retract one source's contribution without recomputing
   the world." Worth recording that both ecosystems landed here.

### 9b. Where Rigor diverges fundamentally (NOT portable — different bet)

These are not improvements TypeProf is "missing." They are properties Rigor *bought* by
making a different foundational wager, and TypeProf cannot adopt them without ceasing to be
TypeProf.

1. **Scale: local inference + boundary catalog + budgets vs. whole-program re-interpretation.**
   Rigor infers one method at a time and looks callees up in a *catalog* (core/stdlib/gem
   RBS, plugin contributions), bounded by inference budgets, cached per file. TypeProf's
   inter-procedural flow *is* edges that re-interpret the callee's `MethodDefBox` as a live
   graph node (§3) — there is no method summary, the body re-runs. This is the root of
   TypeProf's "designed for small programs / a prototyping pass" positioning. **The
   load-bearing point:** TypeProf's headline ability to *infer parameter types from call
   sites* is a direct consequence of whole-program edge-wiring. Replacing that with
   local+catalog to gain Rigor's scale would **delete the very feature that defines
   TypeProf**. This is the one divergence that is structurally irreconcilable, not merely
   expensive.

2. **Judging vs. understanding — the false-positive-discipline core.**
   Rigor's top value is "the program works outranks a worst-case static reading; never
   frighten working code." It stays silent unless a bug is *provable*. TypeProf's core is
   "when uncertain, infer `untyped`" (§5, `doc.md:122`) — tolerant, and explicitly *not a
   gate*. Making FP-discipline the **default** posture (vs. the opt-in lint layer of 9a.2)
   is a change of *purpose*, not of mechanism. A TypeProf that gates CI by default is a
   different tool with a different name.

3. **Refinement-type *carriers* — not flow narrowing per se (CORRECTED).**
   An earlier draft put "no narrowing" here. That is wrong: TypeProf already does
   flow-sensitive occurrence typing on type-identity predicates (`is_a?`/`nil?`/`case-when`/
   `&&`/`||`; §10a) — it clones per-branch vertices and applies `IsAFilter`/`NilFilter`. The
   genuine divergence is narrower: Rigor narrows **value predicates** (`s.empty?`, `n > 0`)
   into **named refinement carriers** (`non-empty-string`, `positive-int`) drawn from a
   refinement lattice, and threads those carriers through inference and RBS::Extended.
   TypeProf has no refinement-carrier concept — its narrowing filters by class identity and
   nil-ness, not by value-predicate-named subtypes. So this is "portable in principle but a
   large addition" (a new constraint/filter family + carrier lattice), not the structural
   impossibility the earlier draft implied.

4. **Asymmetric authorship (strict returns / lenient params) as an analyzer-wide law.**
   For Rigor this is a pervasive principle (ADR-5) shaping *every* authored type and the
   whole acceptance predicate, not just an output formatter. TypeProf has no notion of
   authorship asymmetry — it records flow symmetrically (args in, returns out, both
   observed). 9a.3 can bolt the *output half* on, but the principle as an internal
   acceptance discipline has no home in a record-what-flowed interpreter.

### 9c. One-line synthesis

TypeProf can move toward Rigor on **precision** (9a.1 literal carriers; refinement-carrier
narrowing per 9b.3 — it already has type-identity occurrence typing, §10a) and **output
manners** (9a.2 diagnostics, 9a.3 robustness, 9a.4 plugins) — all
without surrendering its identity. It **cannot** move toward Rigor on **scale** (9b.1) or
**judgment philosophy** (9b.2) without becoming a different tool, because those are exactly
what Rigor purchased by betting on local-inference-plus-catalog instead of whole-program
type-level execution. The non-portability is *why the two coexist* (the appendix's
side-by-side pattern) rather than one subsuming the other.

---

## 10. Verification pass (2026-06-01) — the four originally-flagged items

Four items were originally flagged as "could not fully confirm." This section resolves
**all four** against the vendored source: narrowing (§10a), parser (§10b), yield fan-out
(§10c), and the line-number audit (§10e). Nothing in §1–§9 above depends on an unverified
claim any more.

> **Correction notice.** An intermediate draft of this §10 (committed earlier the same day)
> stated "CONFIRMED: zero flow-sensitive narrowing." **That was wrong** — a verification
> error caused by a degraded session in which a `grep narrow` returned empty (the command
> had not actually run) and `ast/control.rb` was never read in full. A clean second pass
> (direct full read of `control.rb` + two independent sub-agent traces, all agreeing) shows
> TypeProf v0.31.1 has a **substantial occurrence-typing narrowing subsystem**. The text
> below is the corrected finding. The lesson is recorded honestly because this note is meant
> to be a normative reference: treat a single corrupted-session result as unconfirmed until
> re-verified.

### 10a. Narrowing — CONFIRMED PRESENT (occurrence typing on type-identity predicates)

`ast/control.rb` (737 lines) plus `env/narrowing.rb` and `graph/filter.rb` implement a real
flow-sensitive narrowing pass. `grep -rin "narrow" lib/` returns **94** occurrences.

**The engine** (`AST.with_narrowing`, `control.rb:17-50`): given a `Narrowing` (a
`{var => Constraint}` map), it saves each variable's current vertex, derives a
`narrowed_vtx = original_vtx.new_vertex(...)` then `constraint.narrow(...)` it, sets the
narrowed vertex in the local env, runs the branch body via `yield`, then restores. Instance
variables use a push/pop narrowing stack (`env.rb:403-416`).

**Constraints** (`env/narrowing.rb`): `IsAConstraint`, `NilConstraint`, plus `AndConstraint`
/ `OrConstraint` for composition. **Filters** (`graph/filter.rb`): `IsAFilter` (keep/exclude
by class identity), `NilFilter` (keep/remove `nil`), `BotFilter` (prune unreachable arms).

**Where narrowings come from** (`narrowings` returns a `[then, else]` pair):
- `CallNode#narrowings` (`call.rb:266-305`): `recv.is_a?(Klass)` → `IsAConstraint` on the
  receiver (then = is-a, else = is-not-a); `recv.nil?` → `NilConstraint`; `!e` swaps the
  pair. **Only when the receiver is a local- or instance-variable read** — not an arbitrary
  expression.
- `LocalVariableReadNode#narrowings` / ivar / `it` (`variable.rb:21-24, 71-74, 107-110`):
  bare truthiness `if x` → `NilConstraint(false)` on the then-arm (removes `nil`).
- `AndNode`/`OrNode` (`control.rb:461-467, 506-512`): compose child narrowings via
  `.and`/`.or`, and apply the left operand's narrowing to the right operand at install time
  (`control.rb:446-453, 490-498`).

**Consumers:**
- `BranchNode#install0` (if/unless, `control.rb:70-124`): per-arm vertex cloning +
  `with_narrowing`; arms then `BotFilter`-pruned and joined.
- `CaseNode`/`WhenNode` (`control.rb:254-395`): **pivot narrowing** — `case x; when Konst`
  narrows `x` inside the clause via `IsAFilter` (only for `ConstantReadNode` conditions with
  a `static_ret`, and only when the pivot is a local variable); the `else` clause applies the
  negated exclusion filters.
- `LoopNode` (while/until, `control.rb:159-162`): truthiness `NilFilter` on a bare-variable
  condition.

**What this means for the Rigor comparison (the important correction):** TypeProf is NOT
"no narrowing." It has occurrence typing on **type-identity predicates** (`is_a?`, `nil?`,
class-match in `case/when`, `&&`/`||` propagation). What it lacks relative to Rigor is
**refinement-type carriers** — narrowing a *value predicate* (`s.empty?`, `n > 0`) into a
**named refinement type** (`non-empty-string`, `positive-int`). Rigor's distinctive surface
is the refinement lattice, not "having narrowing at all." The appendix wording must reflect
this subtler line (fixed in the appendix alongside this note).

Known limits (honest): predicate narrowing requires the receiver/subject to be a bare
variable read; `case/in` pattern matching (`CaseMatchNode`, `control.rb:397-425`) installs
patterns and unions clause results but shows **no pivot narrowing**; refinement-style value
predicates are not modeled.

### 10b. Parser — CONFIRMED: Prism ≥ 1.4.0, Ruby ≥ 3.3

`ast.rb` parses via `Prism.parse(src)` (`ast.rb:~4`) and `AST.create_node` dispatches on
Prism node-type symbols — `:if_node`/`:unless_node` → `IfNode`/`UnlessNode`,
`:and_node`/`:or_node` → `AndNode`/`OrNode`, `:case_node` → `CaseNode`,
`:case_match_node` → `CaseMatchNode`, `:while_node`/`:until_node` → `WhileNode`/`UntilNode`
(`ast.rb:85-92`). Gemspec: `required_ruby_version >= 3.3`, `add_runtime_dependency "prism",
">= 1.4.0"` and `"rbs", ">= 3.6.0"` (`typeprof.gemspec:17, 31`).

### 10c. yield / block param fan-out — CONFIRMED

A block passed at a call site is parsed in `ast/call.rb`: block formal params become
`blk_f_args` (one vertex each) plus a `blk_f_ary_arg` array vertex, wrapped as
`Block.new(self, blk_f_ary_arg, blk_f_args, block_body.lenv.next_boxes)` and carried as
`Source.new(Type::Proc.new(genv, block))` (`call.rb:191`). The `Block` class lives at
`env/method.rb:254-280`.

Fan-out (`Block#accept_args`, `env/method.rb:265-273`), driven by `builtin.rb` `proc_call`
(`builtin.rb:28-29`) with `a_args.positionals`:

```ruby
def accept_args(genv, changes, caller_positionals)
  if caller_positionals.size == 1 && @f_args.size >= 2
    changes.add_edge(genv, caller_positionals[0], @f_ary_arg)   # yield [x,y] → |a,b| auto-destructure
  else
    caller_positionals.zip(@f_args) do |a_arg, f_arg|           # yield x,y → |a,b| : a<-x, b<-y
      changes.add_edge(genv, a_arg, f_arg) if f_arg
    end
  end
end
```

So: positional 1-to-1 `.zip` in the normal case; a **single yielded arg into a ≥2-param
block auto-destructures** through `@f_ary_arg` (which is wired to each `@f_args[i]` via a
`SplatBox` at block-install time). Excess yielded args are dropped (the `if f_arg` guard);
no explicit arity-mismatch diagnostic on this path. Block return flows back via
`Block#add_ret` (`env/method.rb:275-279`), edging each block-body escape box's return
(`box.a_ret`) into the `yield` expression's `ret` vertex.

### 10d. Diagnostic note

The block fan-out and narrowing findings do not change §8: diagnostics remain a byproduct of
box runs.

### 10e. Line-number audit — CONFIRMED accurate

Spot-check of the citations in §1-§8 against the source: all within ±a few lines, most
exact. `env.rb` `add_run` 176 / `run_all` 183-194 ✓; `vertex.rb` `on_type_added` 145-166 ✓,
`BasicVertex#show` 24-66 ✓; `box.rb` `MethodCallBox` 1006 / `run0` 1024-1083 / ctor edges
1010-1015 ✓, `MethodDefBox` 669 ✓, `MethodDeclBox` 237 ✓; `type.rb` `Type::Symbol` 229-244
✓, `Type::Array` 110-169 ✓; `value.rb` `IntegerNode#install0` → `Source.new(genv.int_type)`
(~66) ✓, `SymbolNode#install0` keeps the literal symbol (~98) ✓.

---

## How this maps back to the appendix claims

| Appendix claim | Verified mechanism |
| --- | --- |
| "whole-program abstract interpreter" | worklist-to-fixpoint dataflow graph; inter-proc by edges (§1, §3) |
| "infers params from call sites: yes" | actual-arg vertex → formal-param vertex edges; param = union of all callers (§3) |
| "re-interprets callee bodies" (vs Rigor's catalog lookup) | `MethodDefBox` re-runs as a graph node; no summary cache (§2, §3) |
| "literal precision: widened to nominal" | `42`→`Integer` at `install0`; no `Constant` (§5) |
| "no refinement *carriers*" (CORRECTED — TypeProf HAS occurrence-typing narrowing) | TypeProf narrows on `is_a?`/`nil?`/`!`/`case-when`/`&&`/`\|\|` (§10a); what it lacks vs Rigor is *refinement-type carriers* (value-predicate → named type like `non-empty-string`), not flow narrowing per se |
| "RBS is the output product" | `Vertex#show` / `MethodDefBox#show` render RBS; errors are byproduct (§6, §8) |
| "call sites fuel param inference (a test is just one kind of call site — TypeProf has no notion of 'test')" | params only get types if some call site supplies args; tests are an ordinary call-site source, not specially recognised (§3) |
| Incremental / IDE-first (v2) | ChangeSet diff-rollback + ref-counted vertices + `update_rb_file` (§1) |

No appendix claim was contradicted by the source. Two refinements worth folding in if the
appendix is ever expanded: (a) **Symbols are kept as literal values** (a small precision
TypeProf *does* have that the appendix's table doesn't mention), and (b) the v2 design is
explicitly **incremental/IDE-first**, not just "a batch prototype generator" — the CLI is
one front-end over an LSP-shaped core.

---

## Resolution status of the originally-flagged items

All four items first flagged as "could not fully confirm" are now resolved against the
source in §10. Summary (full detail + citations there):

| Originally flagged | Status | Where |
| --- | --- | --- |
| Narrowing — does v0.31.1 have any? | **RESOLVED: present.** Full occurrence-typing subsystem (`env/narrowing.rb`, `graph/filter.rb`, per-branch vertex cloning). An earlier draft wrongly said "zero." | §10a |
| Parser backend | **RESOLVED: Prism ≥ 1.4.0, Ruby ≥ 3.3** (from gemspec). | §10b |
| Block/`yield` param fan-out | **RESOLVED.** Positional `.zip`; single-arg→multi-param auto-destructure; return via escape boxes. | §10c |
| Line-number drift | **RESOLVED.** All §1–§8 citations within ±a few lines (most exact). | §10e |

Remaining *genuine* limits (not verification gaps — these are TypeProf behaviours):
predicate narrowing requires the receiver/subject to be a bare variable read; `case/in`
pattern matching does not narrow the pivot; refinement-style value predicates are not
modeled (§10a). The dynamic-symbol fallback to the `Symbol` instance type is noted in §5.

---

## Sources

Primary (vendored, authoritative for v0.31.1):
- `references/typeprof/lib/typeprof/core/{env,service,builtin,type}.rb`
- `references/typeprof/lib/typeprof/core/graph/{vertex,box,change_set}.rb`
- `references/typeprof/lib/typeprof/core/ast/*.rb`
- [`references/typeprof/doc/doc.md`](../../references/typeprof/doc/doc.md) — "What is TypeProf" + "Abstract values"

Secondary (design intent / history — corroborating, not authoritative):
- [GitHub: ruby/typeprof](https://github.com/ruby/typeprof) — "experimental type-level Ruby interpreter"
- Yusuke Endoh (Mame), [Revisiting TypeProf — IDE support as a primary feature, RubyKaigi 2023](https://rubykaigi.org/2023/presentations/mametter.html) — the v2/incremental reboot
- Yusuke Endoh, [TypeProf for IDE, RubyKaigi Takeout 2021](https://rubykaigi.org/2021-takeout/presentations/mametter.html)
- Yusuke Endoh, [Good first issues of TypeProf, RubyKaigi 2024](https://speakerdeck.com/mame/good-first-issues-of-typeprof) — Source/Vertex/Box architecture slides
- [Ruby News: TypeProf — Abductive Reasoning for Abstract Interpretation](https://ruby.news/2021/08/23/TypeProf-Abductive-Reasoning-for-Abstract-Interpretation.html)
