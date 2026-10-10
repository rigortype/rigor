# ADR-121 — Typing calls through Ruby refinements, and `Proc#refined`

Status: **Accepted, 2026-10-09; implemented 2026-10-10; amended 2026-10-11 (WD7, positive
knowledge).** Landed under #1670: the redefined-method decline (#1685), the include expansion (#1684),
gem refine bodies (#1686), the query (#1729), the typed arm (#1747), and for Ruby 4.1's
`Proc#refined` the signature (#1711), refined literals (#1738) and the `BlockAsMethod` field (#1744).
WD7 closes #1796 and #1799. Open: the carry-overs under Consequences, #1669, and gem modules that
gem source inference could make known. The normative rules are in
`docs/internal-spec/inference-engine.md` § "Ruby refinements".

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
refinements). A later activation wins over an earlier one. Activating a module that is already in the
list changes nothing, so the list keeps a module at its first position (`rb_using_refinement` returns
early, CRuby `eval.c`; `using A; using B; using A` still answers B's method). Four sources feed it, in
Ruby's own order:

- lexical `using`, in textual order, outer bodies before inner ones;
- a `refine` block's own module, inside that block;
- a Proc literal (`->{}`, `proc {}`, `lambda {}`) that is the receiver of `Proc#refined`: the
  literal's lexical list, then each `.refined` argument in call order (CRuby duplicates the block's
  cref and then appends). A Proc bound to a local first and refined later (`l = ->{}; l.refined(M)`)
  is not covered, so its body keeps reporting a refined call: a known false positive, accepted until
  the survey corpus shows the shape;
- a block a plugin declares as refined (WD5): the block's lexical list, then the declared modules.

A module's `include`d modules expand ahead of it, so the includer wins (#1671). A non-constant `using`
contributes an *unknown* marker. Check rules and the typer read the same list (#1673). Two lists would
let a call be silenced as refined and typed as unrefined.

### WD2 — The typed arm sits ahead of every other answer

The refined arm runs in `ExpressionTyper#call_result_type_for` directly after `indexed_narrowing_for`,
ahead of `try_literal_send`, `try_local_def_dispatch`, `try_receiver_block_folds`,
`try_overriding_def_dispatch` and `MethodDispatcher.dispatch`. Each of those answers from the method
the refinement replaces: a refined `String#upcase` must not fold, a refined `map` on a Tuple must not
fold per element, a top-level `def` must not bind ahead of a refinement of `Object`, and a plugin
models the class's own method.

Precedence follows `refinements.rdoc` § Method Lookup. Walk the receiver's classes from the most
derived, the singleton class first. At each class, the latest in-effect module that refines the name
for that class wins; otherwise its prepended modules, its own method and its included modules answer
in that order; otherwise move on. A refinement of `C` therefore beats a module prepended to `C`
(probed on Ruby 4.0.5), and a refinement of a module is decided where that module sits. A method
on a more derived class beats a refinement of a less derived one. "Defines the method" is read from
RBS and project `def`s. Core RBS sometimes redeclares an inherited method on a subclass, and the walk
then stops there and declines the refinement: a known imprecision, in the declining direction for
refinements of `Object`, `Kernel`, `Comparable` or `Numeric`. A union receiver is decided per member,
and a `Dynamic` receiver stays `Dynamic`.

### WD3 — What the arm returns

It returns the winning refine-body `def`'s inferred return type, with the call's receiver as `self`. If
that body is not analysable, it returns `Dynamic[top]`. That covers a gem refinement (#1672), whose
bodies are not inferred, and a list that carries the unknown marker while some refinement defines the
name. `super` inside a refine body continues at the next refinement in effect **at the `super` site**,
excluding the current one, and only then at the refined class (`refinements.rdoc` § super). Rigor types
it against the refined class's own method when no other module in the refine body's own in-effect
list refines the name, and as `Dynamic[top]` when one does. Following that chain precisely is
deferred. A refined call skips argument-type and arity checks, because
refine-body parameters bind as an undeclared method's do and have nothing to check against. Inside a
refined Proc, a nested `def` keeps the Proc's refinements, and a `using` raises at runtime, so it adds
nothing to the list.

### WD4 — Direct calls typed, refined indirect calls unknown

The arm types `recv.m`, operators and implicit-self calls. `send`, `public_send` and `&:m` also honour
refinements (CRuby `test/ruby/test_refinement.rb`: `test_send_should_use_refinements`,
`test_public_send_should_use_refinements`, `test_symbol_proc`). When the name they reach is refined in
effect for the receiver, they answer `Dynamic[top]` and skip argument checks; typing them through the
arm is deferred. `respond_to?` and `method` honour refinements too
(`test_respond_to_should_use_refinements`; probed on Ruby 4.0.5), so for a refined name they answer
`Dynamic[top]` and never fold to `false`. Only `methods` ignores refinements and keeps today's answer.

### WD5 — Plugins declare callee-activated refinements

`Plugin::Macro::BlockAsMethod` gains `refinements:` (module names). It also accepts
`self_type: :lexical`, which leaves `self` unbound, so `block.refined(M).call` is expressible as well as
`instance_exec(&block.refined(M))`. One entry carries both halves of activerecord-refined's contract.

### WD6 — Default on

The arm ships without a bleeding-edge flag. Refinements are rare in the survey corpus. The change
removes types Rigor knew to be wrong, but it also adds types where a refined call was fail-soft before
(`:a.shout` becomes `String`), so calls downstream are checked for the first time and new findings are
possible. The release-gate OSS sweep is the check. A `:behaviour` flag would also have to enter the
analysis-cache identity (`lib/rigor/bleeding_edge.rb`), which costs more than the risk.

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
- Negative: `discovered_refinements` already travels in the seed bundle, but refine-body def
  handles do not; a `(module, class, method) → def` table is new state for the warm cache to
  carry. A gem refinement types as `Dynamic[top]` until a plugin or
  RBS can say more.
- Carry-over: plugin-declared refined-call return types (for activerecord-refined's column nodes),
  typed indirect calls, the precise `super` chain, and a Proc refined after binding are open. #1669
  decides the first.

## Relationship to other ADRs

ADR-5 (robustness: `Dynamic` over a wrong answer) is the criterion's root. ADR-16 Tier A owns
`BlockAsMethod`, which WD5 extends. ADR-110's overriding-def dispatch is the precedent for WD2's slot.
ADR-50 WD2 defines the bleeding-edge overlay WD6 declines.

## Amendment (2026-10-11) — WD7: decided from positive knowledge

Three review rounds of #1793 (#1740) each found a refinement Rigor did not see: a `using` of a module
whose bodies live outside the analysed paths, an `alias_method`, `define_method` or `import_methods`
in a refine body, a computed `refine(k)` target, a refining module included from `vendor/`. Every miss
came from one premise: a missing row was read as "refines nothing".

**Criterion: a decline follows from a row, never from the absence of one. A module with no project
declaration is opaque.**

- The refinement table records what the walk could not read, with one wildcard
  (`Scope::DiscoveryIndex::REFINEMENT_WILDCARD`, `"*"`) on two independent axes: a names-wildcard
  `{X => {"*" => [M]}}` (the body may define names the walk cannot spell), a class-unknown row
  `{"*" => {name => [M]}}` (`refine(k)`, `refine(self)`, or a target a project constant write binds),
  and a targets-wildcard `{"*" => {"*" => [M]}}` (a `refine` in a method, or reached through a
  `:refine` literal such as `send(:refine, …)` or `alias_method :r, :refine`). As a module, `"*"` is
  one the walk cannot name: a `refine` in an instance method runs on whatever module extends its
  owner. `alias`, `alias_method`, `define_method` and `attr_*` names in a refine body are recorded. A
  census spec checks that every `refine`-shaped node ends in exactly one outcome.
- A module is opaque when the project does not declare it and it is not a core or stdlib module
  (CRuby ships no refinements), or when a targets-wildcard row lists it or `"*"`. A gem's module is
  opaque even when gem source inference read it, until that inference can show it saw every file
  declaring it.
- Every declared candidate of a `using`'s spelling stays in the list, because which one Ruby's lookup
  finds can depend on load order; undeclared candidates leave, and a spelling with no declared
  candidate enters alone, opaque. An included module the project does not declare enters the list
  unless it is core or stdlib.
- The checks decline every call, whatever the receiver, where an opaque module is in effect.
- The typed arm answers `Dynamic[top]` for every instance-receiver call in the span of an activation
  that puts an opaque module in effect; a class object falls through until singleton-side levels land.
  WD3's rule that the unknown marker answers `Dynamic` only where some refinement defines the name is
  not extended to opaque modules: their rows cannot be read, so every name may be replaced. Wildcard
  rows never yield a winner: a class-unknown row answers `Dynamic` for its names on every instance, a
  names-wildcard row of a level reached before a definer answers `Dynamic`, and so does a winner whose
  module shares its last segment with another listed module.
- A plugin-declared module (WD5) is the plugin's declaration, not code Rigor failed to read: it is
  never opaque, and one nothing declares matches no row, so it silences nothing.

Limits it does not remove: a module reopened in a file outside the analysed paths or under
`exclude:`, a module declared or reopened inside an eval string, and
`TOPLEVEL_BINDING.eval("using N")`, which activates `N` to the end of the file.

Consequence: under a `using` of a gem's module every instance call in the span is unchecked and
`Dynamic` until gem modules can be known, a cost the survey corpus puts at a handful of files.
