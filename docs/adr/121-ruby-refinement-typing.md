# ADR-121 — Typing calls through Ruby refinements, and `Proc#refined`

Status: **Accepted, 2026-10-09.** Nothing is implemented yet. The work is tracked by #1670: the query
(#1673), the typed arm (#1664), the include expansion (#1671), gem refine bodies (#1672), the
redefined-method decline (#1663), and, for Ruby 4.1's `Proc#refined`, #1665, #1666 and #1667. The
normative rules land in `docs/internal-spec/inference-engine.md` § "Ruby refinements" with each slice.

Grounding: the design session of 2026-10-09 on #1664 and #1667, probes on master `54da094f0` and
`7baff7b1f` (listed in #1670), CRuby `334b4ffa7f`'s `doc/syntax/refinements.rdoc` and
`test/ruby/test_proc.rb` (`test_refined*`), and [Feature #22097](https://bugs.ruby-lang.org/issues/22097).
ADR-49 archetype: deliberative; stakes: mid (the false-positive envelope of every refined call, plus a
public plugin-manifest field).

## Context

#1120 taught Rigor where a Ruby refinement is in effect, but only to **silence**
`call.undefined-method`. Two gaps remain. First, a call through a refinement is still typed and checked
as the unrefined method: `using M; :a[:b]` with `M` redefining `Symbol#[]` reports an argument mismatch
and types as `String?`. Second, Ruby 4.1's `Proc#refined` brings back block-scoped refinements, and
the library that motivates it (activerecord-refined) activates them in the **callee**
(`block.refined(M)`), where nothing at the block's own site shows it.

The intent is that a correct program using refinements, lexically or through `Proc#refined`, produces
no diagnostic it would not produce without them, and that the type Rigor reports for a refined call is
never the type of the method the refinement replaced.

## Decision

**Criterion: a refinement in effect replaces the method, so its answer replaces the class's answer
entirely. When Rigor cannot read the replacement, the answer is unknown (`Dynamic[top]`). It is never
the replaced method's signature.** The replaced method's RBS describes code that does not run at that
call site, so falling back to it is a confident wrong answer, the failure ADR-5 ranks worst.

### WD1 — One ordered list: in-effect refinements

At every program point Rigor answers one **ordered list** of refining modules (`CONTEXT.md` § in-effect
refinements). A later activation wins over an earlier one. Four sources feed it, in Ruby's own order:

- lexical `using`, in textual order, outer bodies before inner ones;
- a `refine` block's own module, inside that block;
- a block literal that is the receiver of `Proc#refined`: the literal's lexical list, then each
  `.refined` argument in call order (CRuby duplicates the block's cref and then appends);
- a block a plugin declares as refined (WD5): the block's lexical list, then the declared modules.

A module's `include`d modules expand ahead of it, so the includer wins (#1671). A non-constant `using`
contributes an *unknown* marker. Check rules and the typer read the same list (#1673). Two lists would
let a call be silenced as refined and typed as unrefined.

### WD2 — The typed arm sits ahead of dispatch

The refined arm runs in `ExpressionTyper#call_result_type_for`, beside `try_overriding_def_dispatch`
and before `MethodDispatcher.dispatch`. It therefore precedes constant folding, shape dispatch and
plugin contributions: a refined `String#upcase` must not fold, and a plugin models the class's own
method, which the refinement replaces. Precedence follows `refinements.rdoc` § Method Lookup. Walk the
receiver's ancestors from the most derived class. A method defined on a more derived class (or a
singleton method) wins over a refinement of an ancestor. At the first refined ancestor, the latest
in-effect module that refines the name wins. A union receiver is decided per member, and a `Dynamic`
receiver stays `Dynamic`.

### WD3 — What the arm returns

It returns the winning refine-body `def`'s inferred return type, with the call's receiver as `self`. If
that body is not analysable, it returns `Dynamic[top]`. That covers a gem refinement (#1672), whose
bodies are not inferred, and a list that carries the unknown marker while some refinement defines the
name. `super` inside a refine body types against the refined class's own method. Following the next
in-effect refinement is out of scope. A refined call skips argument-type and arity checks, because
refine-body parameters bind as an undeclared method's do and have nothing to check against.

### WD4 — Direct calls only

The arm covers `recv.m`, operators and implicit-self calls. Indirect calls (`send`, `public_send`,
`&:m`, `method`) keep today's typing. Ruby's behaviour there has varied across versions and its
introspection ignores refinements, so modelling it needs its own CRuby check first.

### WD5 — Plugins declare callee-activated refinements

`Plugin::Macro::BlockAsMethod` gains `refinements:` (module names). It also accepts
`self_type: :lexical`, which leaves `self` unbound, so `block.refined(M).call` is expressible as well as
`instance_exec(&block.refined(M))`. One entry carries both halves of activerecord-refined's contract.

### WD6 — Default on

The arm ships without a bleeding-edge flag. Refinements are rare in the survey corpus, and the change
only removes types Rigor knew to be wrong. The release-gate OSS sweep is the check. A `:behaviour` flag
would also have to enter the analysis-cache identity (ADR-50 WD2), which costs more than the risk.

## Rejected and deferred alternatives

| Alternative | Why not |
| --- | --- |
| Fall back to the refined class's RBS when the body is unreadable | Answers with the signature the refinement replaced: the `String?` of the motivating probe. |
| Union the returns of every refinement in effect | Ruby picks one winner by activation order; the union is wider than any execution and still wrong at the edges. |
| Keep refinements silencing-only | Every refined chain (`:t[:c].in?(…)`) is typed against the wrong class from its first link down. |
| A separate `RefinedBlock` macro instead of a `BlockAsMethod` field | activerecord-refined needs `self` binding and refinements on the same call; two entries would have to stay in sync. |
| Infer callee activation from a project method's own `&blk.refined(Const)` body | Inter-procedural and warm-cache sensitive, and it cannot reach gems. Deferred until the survey corpus shows project-local `Proc#refined` DSLs. |
| Gate `Proc#refined`'s signature on `target_ruby >= 4.1` | The default `target_ruby` would report every correct 4.1 call (#1665). |

## Consequences

- Positive: refined calls stop producing argument and undefined-method findings, and their types stop
  propagating the replaced method's return.
- Negative: refine-body defs need a `(module, class, method) → def` table in the seed bundle, which is
  new state for the warm cache to carry. A gem refinement types as `Dynamic[top]` until a plugin or
  RBS can say more.
- Carry-over: plugin-declared refined-call return types (for activerecord-refined's column nodes) and
  indirect calls are open. #1669 decides the former.

## Relationship to other ADRs

ADR-5 (robustness: `Dynamic` over a wrong answer) is the criterion's root. ADR-16 Tier A owns
`BlockAsMethod`, which WD5 extends. ADR-110's overriding-def dispatch is the precedent for WD2's slot.
ADR-50 WD2 is why WD6 avoids a behaviour flag.
