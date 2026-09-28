# ADR-119 — Certainty on discovery facts, candidate-set reads over the resolution chain

Status: **Proposed, 2026-09-28.** Awaiting the maintainer's acceptance. Nothing behaviour-changing has
landed. Landed already, byte-identical and independent of this decision: #1551 (the layered
def-nesting lookup) and #1563 (the `module_function` readings behind one helper,
`lib/rigor/inference/module_function_state.rb`). The gates landed in #1566
(`spec/rigor/declaration_facts/`, described in `docs/internal-spec/inference-engine.md` § "Declaration-fact
gates"); until this ADR is accepted they record what the code does today. The resolution chain this ADR
builds on is #1578 (Draft, not yet landed), an amendment of ADR-24 that fixes #1567, #1568 and #1571 and
leaves #1570 at master's answer (§ The chain); #1572 tracks the external-definer typing read it defers,
#1573 a repeated `extend`'s position. **Citation baseline:** `file:line` cites are at `origin/master`
`4f4e4934f` unless a `#1578` branch path is named (`72cfcb820`); SI is
`lib/rigor/inference/scope_indexer.rb`.

Grounding: the design-review rounds on #1531 and #1507 (2026-09-28), the adversarial critiques they
answered, the five reviews of this ADR's drafts on #1562, the chain implementer's measurements (a
linearisation from the real tables against Ruby, an 8,000-program fuzz, a mixin census over Mastodon,
Redmine, GitLab, Rails and Rigor), and the probes reproduced in Context, all re-run for this draft under
`rigor check --no-cache` and Ruby 4.0.5. ADR-49 archetype: deliberative; stakes: high.

**Scope.** Three decisions were one draft and are now three documents, each the smallest that holds:
the **resolution chain** (an ADR-24 amendment, carried by the chain PR #1578, pending) owns Ruby's
linearisation and its
dependency contract; **this ADR** owns the gates, certainty on facts, and candidate-set reads over that
chain; a **follow-up ADR** owns concern hooks instantiated per includer. § The chain states only what
this ADR relies on.

## Context

ADR-116 WD5 moved `ScopeIndexer`'s table walkers onto one declaration walk, each port required to be
byte-identical to the walker it replaced, with a named *variant* wherever the walkers disagreed
(`docs/adr/116-hot-file-restructuring.md:160–184`). Four tables were ported (#1517, #1522, #1527). A
contract for the next four walkers went through three adversarial review rounds on #1531 and did not
converge; the ports were paused. The reviews and this ADR's probes attribute that to five failure
modes, each of which the Decision addresses by mechanism rather than by another list.

1. **Enumeration in prose never converges.** Every list was incomplete in the next round: the quirk
   list (H1), the "four versus twenty walkers" pause scope, then the context computers outside
   `ScopeIndexer` — sig-gen's own `module_function` rule (`lib/rigor/sig_gen/generator.rb:667–690`),
   `Effects::DefinitionContext` (`lib/rigor/effects/definition_context.rb:34`), `Effects::Visibility`,
   which names no declaration node (`lib/rigor/effects/visibility.rb:7–40`), `Plugin::NodeContext`
   (`lib/rigor/plugin/node_context.rb:22`), `SyntheticMethodScanner#build_hierarchy`
   (`lib/rigor/inference/synthetic_method_scanner.rb:369`), the ActiveRecord `ModelDiscoverer`, and the
   evaluator's own class entry (`lib/rigor/inference/statement_evaluator.rb:2699, 2719, 5178`). Under
   WD6's rules i–iv, measured at `19a9c054c`, 47 methods in `scope_indexer.rb` and 64 other files compute
   declaration context. On the read side it holds four times over: `Scope` exposes every table raw
   (`lib/rigor/scope.rb:41–75`) and 36 files outside the table owners read them; six consumers walk
   ancestry through the `Scope` readers (`lib/rigor/analysis/check_rules.rb:1137, 1518, 2524, 3787`;
   `lib/rigor/analysis/check_rules/source_arity.rb:98–121`;
   `lib/rigor/inference/last_line/implicit_self.rb:69, 83, 101`; `lib/rigor/reflection/constant_ancestors.rb`;
   `lib/rigor/inference/method_dispatcher/singleton_mixin_dispatch.rb`;
   `lib/rigor/inference/expression_typer.rb:2067`); four more loop over the raw tables on purpose, to
   avoid recording ADR-46 edges (`rbs_dispatch.rb:856–861, 890`;
   `lib/rigor/inference/macro_block_self_type.rb:130, 157`; `scope.rb:1317` `singleton_extends_of`, which
   `narrowing.rb:3160` walks; `project_chain_covered?`,
   `lib/rigor/analysis/check_rules/shadowed_rescue_collector.rb:234`); and the seed paths copy explicit
   member lists (`lib/rigor/analysis/runner.rb:2016`, `worker_session.rb:344`,
   `lib/rigor/inference/parameter_inference_collector.rb:258`,
   `lib/rigor/protection/discovery_seed.rb:97–108`, `lib/rigor/cli/coverage_mutation.rb:135`,
   `lib/rigor/sig_gen/observation_collector.rb:92`) or read short keys
   (`lib/rigor/analysis/incremental_session.rb:872, 941, 969`).
2. **Variants were found by reading code and diffing walker against walk**, so they grew as
   O(walkers × categories): `RULE_VARIANTS` went from none to four rules in three slices
   (`lib/rigor/inference/declaration_walk/traversal.rb:89–94`) and the draft needed six more. They
   protect behaviour no corpus exercises — #1527's control switched each variant to the walk's rule and
   found no divergence in 67,137 files — and a shadow sweep over a corpus that lacks a construct passes
   without checking anything (S1). `RIGOR_SHADOW_RULE_WALK` is set by no workflow or Makefile target.
3. **One semantic question had several implementations and no reference.** `module_function`'s
   definee was computed four ways — a sibling-statement toggle, a prescan that stamps a `kind` on
   deferred-range rows, an orderless self-extend, and sig-gen's direct-statement toggle — until #1563
   moved the readings behind one helper (`module_function_state.rb:45–198`), byte-identical, so the four
   semantics still stand (SI:4884–4915, 4580–4587, 6096–6109; `generator.rb:667–690`) and the visibility
   walker still ignores the call (SI:6190–6330). Ruby's answer is run-dependent (a bare call inside `if`,
   `each {}`, `tap {}`, a called lambda or a called `def self.setup` takes effect; a bare visibility call
   resets it; `def self.x` gets no instance copy; the named form snapshots the earlier `def`). **Method
   resolution order has the same problem**: two walks are breadth-first (`scope.rb:1358–1376`,
   `enqueue_ancestors` at `:1593`, which drops names that resolve to no project class at `:1586–1600`;
   `check_rules.rb:3748–3763`), `SourceArity` walks by superclass level with its own agreement rule and
   eight hedges (`source_arity.rb:98–126, 138, 148, 173–177, 234, 238, 268, 275, 291`), and none is Ruby's
   order. Three false positives on master need no uncertainty at all: breadth-first reaches `Base#foo`
   before a module's `M#foo` (#1567, on the instance side, on the singleton side through `extend A` where
   `A` includes `M`, and for a constant `M::X` against `Base::X`); a public method in a prepended module is
   ignored, an error-level firing (#1568); an `include` of a module already in the superclass chain, a
   no-op in Ruby, changes the answer (#1570).
4. **Byte-identity was demanded against walkers that are wrong or deliberately over-approximate.**
   The extends walker over-approximates on purpose, in the ADR-5-safe direction (SI:5869–5874).
   #1518–#1520 are rules wrong in several walkers at once. #1550 is a false positive on correct Ruby
   (the named form resolves the *later* `def`; the reading now lives at SI:4951–4956 over
   `ModuleFunctionState.each_singleton_copy`). `def.override-visibility-reduced` fires on a private
   override of `Helpers2#fmt2` after `if true; module_function; end` (`check_rules.rb:3710–3720`).
5. **The justification shifted** from speed to C2 without a criterion for landing a port. The speed
   case was measured and found absent (`docs/adr/116-hot-file-restructuring.md:175` still calls the
   merge "the wall lever").

Seven findings bound the design. **(a)** The typed pre-passes call `scope.type_of` under the project
seed and the plugin registry (SI:1714, 1756, 1775, 2111, 2231, 2996; SI:974, 1023), so they are not pure
per file. **(b)** A direction per table or per read is ill-posed: visibility is read to fire and silenced
by `nil`, constants are read both ways (`scope.rb:136–155`), and on an ancestor walk keeping a `possible`
edge shadows a further ancestor while dropping it exposes one. **(c)** A candidate set over a
breadth-first walk is not sound either (`bfsvis`, `idemvis2`: a certain nearest definer, a wrong order).
**(d) Some edges have no position that is a fact**: an `include` inside a method takes effect when the
method is called (`methinc`); an `included do` edge is recorded on the concern but Ruby applies it to the
includer, and a `prepend` there lands ahead of the includer (`hookpre`; GitLab's `CacheMarkdownField`
prepends inside both `included do` and `class_methods do`); two files reopening one class order their
includes by load order (`xfile`); and **an include the chain skips as already present becomes positioned
by a later reopening** — `C < Base; include M` and then `class Base; include M; end` gives Ruby
`[C, M, Base, M]`, while a single linearisation gives `[C, Base, M]` (`retro_super2`; also `retro_mod3`,
where a module is reopened to include another, and `supposs_type2`, a `possible` superclass include).
`SourceArity` declines on the first three today; the fourth is silent on master only because the
breadth-first walk happens to reach `M` first, and the shape fires when it does not (`chain_equiv`).
**(e) Some edges are not recorded, only marked**: `send(:include, M)`, the receiver form `C.include(M)`
and GitLab's `prepend_mod_with` add nothing to the mixin tables (`MIXIN_CALL_NAMES` holds `include` and
`prepend`, SI:5600); each stamps `ENVELOPE_DYNAMIC_MARK` on the class (the constant-receiver branch at
SI:6457–6463 marks any surface-rewriting call, `SURFACE_MIXIN_HELPER` at SI:6437–6439 names the helpers,
and `spec/rigor/inference/included_module_dispatch_spec.rb:261` pins the mark for `Klass.include(M)`).
Three readers decline on a marked class today — `SourceArity` (`dynamic_surface?`), which is why
`send_inc`, `recv_inc` and `pmw_on` are silent; the RBS-ancestor typing arms (`rbs_dispatch.rb:621, 656,
739–749`, answering `Dynamic[top]`, pinned at `included_module_dispatch_spec.rb:264–273, 279`); and
`program_may_answer?` and `mixin_may_answer?` (`check_rules.rb:2507–2511, 2523–2532`) — and every other
read types through it
(`pmw_type` fires `undefined method 'upcase' for 1`). **(f) The chain sees only project classes**, so
"absent means `NoMethodError`" is false: with `include M if X` and `M#to_s(fmt)`, `Object#to_s` answers
when `X` is unset, yet `call.wrong-arity` fires (`absent_arity`); `include M; include Enumerable` fires an
error-level `undefined method 'first' for 1` although `Enumerable#to_a` answers (`gemmod3`, #1572).
**(g)** A single-valued table has no union (last-write-wins, SI:4939–4945) and scalar consumers deref the
value (`runner.rb:590–616`).

## Decision

**Criterion.** A discovery producer is judged by a relation Ruby can witness, never by identity to a
predecessor: a fact is *certain* (it holds whenever the file's top level executes) or *possible*. A read
answers only when its answer is the same under every world it must consider — every assignment of the
`possible` facts it depends on, both sides of a relevant skipped include — and depends on no edge whose
position is unknown; a marked entry keeps exactly master's declines and adds none. Otherwise it answers
*unknown*, which every consumer treats as silence (ADR-5). Unknown is carried only by an internal API
whose value type separates it from *absent*; every existing reader keeps its return shape and answers
from one Ruby-order chain. All reads are defined over that chain. A behaviour change lands under WD7's second
lane; a behaviour-preserving change under its first.

### The chain this ADR builds on (ADR-24 amendment, carried by #1578, pending)

This ADR relies on the following contract and states no more of it; the binding text is ADR-24's
amendment, which WD1 of that ADR (`docs/adr/24-self-method-call-resolution.md:121`) already frames as
"enclosing class + ancestors, cross-file".

- **The tables suffice; no discovery-data change is needed.** `discovered_prepends` is its own table and
  both tables keep statement order (SI:5829, 7354), so includes are `includes_of − prepends_of`
  (`scope.rb:1287–1288`). A linearisation from the real tables under CRuby's `include_modules_at` rules
  matched Ruby on 13 of 14 single-body `lin.rb` cases, #1570's shape among them (the reader still returns
  master's answer there, since its tables coincide with a reopened body's; see the skip bullet), "the
  superclass prepended it",
  retroactive includes into a module and a module's own prepends; the miss is `include M; prepend M`
  (`[M, C, M]` against `[M, C]`, same first definer). An 8,000-program fuzz against real dispatch matched
  whenever a body lists its prepends before its includes; arbitrary interleaving differed in about 0.2 % of
  cases, only where one body includes and prepends the same module. The census (14,558 includes, 216
  prepends) found no such body and three `class << self; prepend`. The chain processes a body's prepends
  before its includes, which never invents a super method after `C`. **The fuzz never reopens a body**;
  a body reopened after a subclass has linearised (`retro_super2`, `retro_mod3`) is not matched by a single
  linearisation, and is covered by the skip-worlds rule below, not by new data.
- **API.** `Scope::ResolutionChain` (`lib/rigor/scope/resolution_chain.rb` on #1578) is internal: nothing
  joins the public `Scope` surface that `spec/rigor/public_api_drift_spec.rb:8–10` pins as the ADR-2 plugin
  API, and `sig/rigor/scope.rbs` is unchanged. A chain is a frozen list of entries, the index where each
  superclass level starts, and a truncated flag (budget 100). A **project
  entry** is a name and a side. An **external entry** is the name as written, its candidate list and
  whether it was reached through a superclass edge, placed at its Ruby position. Linearisations are memoised per node.
  A prepend is skipped only when the class has already prepended the module; an include is skipped when
  the module is present anywhere in the chain, and if it sits between the insertion point and the
  superclass boundary the insertion point moves to it. The singleton side is the metaclass, then the
  superclass metaclass chain, with `extend` and `class << self; include` under the include rule.
- **Skipped includes are two worlds.** An include the chain skips because the module is already present
  is recorded as a fork **when the skipped module's closure defines the queried name**, whether the skip
  happens in the class's own body or inside an included module's closure (`retro_mod3`): the read
  evaluates the chain under every subset of the relevant skips (the internal Unknown-capable read of
  ADR-119 WD2 answers only when every subset gives the same first definer). An **existing reader**, which
  exposes no Unknown, returns **master's answer where the worlds disagree** (`ResolutionChain::MasterOrder`:
  the breadth-first definer, the depth-first external groups, master's arity levels). **The rule the chain
  PR must follow:** an existing reader returns master's answer whenever the first definer is not the same
  across every subset of the relevant skips; the simplest implementable form, and the one required here, is
  master's answer whenever the chain carries **two or more relevant skips**, and the chain's answer only
  for zero or one. Two worlds — every skip made and every skip skipped — are not enough: with `Base`
  including `N` and `A` (`A` including `Deep#foo`), `C < Base` including `D#foo` and then `A`, and `N` later
  reopened to include `D`, Ruby prints `"d"`, master is silent, and the two-world chain (#1578 at
  `72cfcb820`) reports `undefined method 'upcase' for 1`, because a mix of skips puts a third definer
  first — as its own ADR-24 text admits (`docs/adr/24-…md:576–577` on the branch). "No firing master
  lacks" holds only under this rule. Its cost is small: on GitLab relevant skips reach two for a name on
  Project (6 names), Group (5) and User (5) and one elsewhere, so those names fall back to master's answer;
  on Mastodon 42 of 4,379 chains are contested and, under two worlds, no reader fell back. The reopened-body
  shapes (`retro_super2`, `retro_mod3`, `supposs_type2`), where master's walk happens to be right, stay
  silent. The price is that #1570, an existing false positive whose tables are identical to
  `retro_super2`'s, keeps master's answer in the existing readers; it is fixed by PR C at the `:arity`
  decision point of `SourceArity`, where the disagreement yields `Unknown` and silence, with no new data.
  Relevant skips count
  toward WD2's cap of four together with the relevant `possible` edges. Measured separately on GitLab:
  relevant skips alone reach 5 for one name, so the cap trips on three classes
  (`Gitlab::Graphql::Aggregations::SecurityOrchestrationPolicies::…` on `edit_path` among them); Project
  has 6 names with relevant skips (at most 2 each), Group and User 5 each (2 each, `run_after_commit` and
  its siblings), on top of Project's up to 3 relevant edges. The joint per-name figure is not yet
  measured; the bound 3 + 2 = 5 means the cap can also trip on at most those 6 Project names if their
  edges and skips coincide, and the chain PR measures it. No new data is needed.
- **Marked entries keep exactly master's declines and add none.** A chain entry whose class carries
  `ENVELOPE_DYNAMIC_MARK` — set by `send`, by the receiver form `C.include(M)` and by helpers such as
  `prepend_mod_with` (SI:6437–6439, 6457–6463) — declines today in `SourceArity` (`dynamic_surface?`), in
  the RBS-ancestor typing arms (`rbs_dispatch.rb:621, 656, 739–749`) and in `program_may_answer?` and
  `mixin_may_answer?` (`check_rules.rb:2507–2511, 2523–2532`), and nowhere else. The chain PR preserves
  every `ENVELOPE_DYNAMIC_MARK` / `dynamic_surface?`-style check it touches, with a spec that pins each one it
  moves, and introduces no new decline on the mark. Typing through marked entries is therefore a known
  remainder (WD2), not a rule: on GitLab 1,730 entities carry the mark, among them ApplicationController,
  Project, Group, User, Issue, MergeRequest and Ci::Build, so 4,041 of 18,164 classes and 41–51 % of
  (class, name) pairs resolve at or beyond a marked entry; on Mastodon 4.7–7.6 % (RoutingHelper, Setting).
  Making those reads unknown would turn that share of the project's types `Dynamic`.
- **Every existing reader changes its walk, not its shape** (#1578): `user_def_through_ancestors` and
  `singleton_def_through_ancestors` (which now also reaches an extended module's includes, #1567's
  singleton shape); `discovered_method_through_ancestors?` and `external_ancestor_name_candidates`; the
  rule-side walk `each_project_ancestor` (`check_rules.rb:3748`) that `nearest_ancestor_method_def`
  (`:3897`) and the override lints ride, plus a new prepend-region check in the visibility rule (#1568);
  `SourceArity`'s levels, with every hedge kept; `Reflection.ancestor_constant_scopes` and the constant-path
  walk (#1571); and `ExpressionTyper#related_to_owner?`. All walk the chain in Ruby order and keep their
  current return shape — `node | nil`, a `[node, owner]` pair, a Boolean. Only *which* definer they
  return changes, so every caller and every wrapper keeps working unchanged: the presence tests (`check_rules.rb:931`,
  `rbs_dispatch.rb:758`, `lib/rigor/inference/method_dispatcher/struct_materialization.rb:147`,
  `error_info.rb:174`, `expression_typer.rb:1638, 1665, 2127`, `project_method_ownership.rb:126–131`,
  `active_model_serializers.rb:166, 242`), the wrappers that return a reader's result under another name
  (`expression_typer.rb:2379, 2483, 2498`; `published_constant_guard.rb:143–163`;
  `SingletonObjectConstant.def_node_for`; `VoidTailSummary#discovered_def`; `resolve_self_callee_def`)
  and their dereferences far from the reader (`expression_typer.rb:2283, 2366, 2413, 3684`,
  `void_tail_summary.rb:175`, `statement_evaluator.rb:437`, `method_dispatcher.rb:311`,
  `struct_materialization.rb:91–93`), many under `rescue StandardError`. No reader exposes Unknown. This
  fixes #1567 on both sides (`C.foo` through `extend A`, `A` including `M`, prints `"M"` in Ruby and fires
  `undefined method 'upcase' for 1` on master), #1568 and #1571 (the constant analog, `M::X` against
  `Base::X`, the same firing) at every call site at once; #1570 is left at master's answer where the worlds
  disagree (above); and the walks converge on one implementation. The corpus diagnostics and sig-gen
  diffs of #1578 are identical to
  master's.
  **Plugins keep the same API and get the corrected order**: rule blocks receive `scope`
  (`lib/rigor/plugin/base.rb:613`); `docs/internal-spec/inference-engine.md:654` binds `user_def_for` to
  "`Prism::DefNode` or `nil`" and `:661` binds `user_def_through_ancestors` to its pair; both hold, so this
  is a bug fix under ADR-2, not a contract change.
- **Three name-resolution flavours**: `:methods` via `known_user_class?`, `:constants` via
  `Reflection.known_project_namespace?`, `:arity` via `SourceArity`'s `project_class?`, which expands
  #986's ambiguous names.
- **Dependency contract (ADR-46).** A lookup records class edges for the root and for every project
  entry it passes over, not for the one that answers — today's breadth-first contract in Ruby order.
  A whole-chain read records every entry. Walkers that read raw tables so as to record nothing
  (`rbs_dispatch.rb:856–861, 890`; `macro_block_self_type.rb:130, 157`; `singleton_extends_of`,
  `project_chain_covered?`) keep their own walks and are allowlisted with that reason.
- **The chain PR (#1578) migrates no call site.** It changes the walk inside the readers above and nothing
  at their callers. The Unknown-capable read is ADR-119's, internal, and used only by the firing sites
  ADR-119's PR C and later migrate (WD2). External entries are transparent to the readers, which many
  callers use as existence probes; the typing-only read that answers "the definer is external" is #1572,
  a follow-up of the chain PR.
- **Detection spec — the walker allowlist** (`spec/rigor/scope/ancestry_walker_detection_spec.rb` on
  #1578). It flags a method that reads two or more of the eight edge readers (`includes_of`,
  `prepends_of`, `superclass_of` and their siblings), reads one inside a loop — a block, `while`, `until`
  or `for` body, directly or through a local — calls a same-file method that reads one inside a loop, or
  recurses; a flagged method is either allowlisted with a reason or fails. Existence compositions over one
  class and name (`ProjectMethodOwnership.source_defines?`, `project_method_ownership.rb:123–132`;
  `instance_self_answers?`, `expression_typer.rb:1634–1641`) and a reader inside a loop over call targets
  (`closure_escape_analyzer.rb:118`) are allowlisted as unions used only to withhold, not exempted by the
  rule. The spec fails on a stale allowlist entry. On master it flags 29 methods; on #1578, 14,
  all allowlisted with a reason. Eleven are unions or universals used only to withhold:
  `method_defined_on_known_subclass?`, `mixin_may_answer?`, `self_undefined_method_diagnostics` (the
  closedness gate), `project_chain_covered?`, `ancestry_step_leaves_project?`,
  `external_gem_reached_through_ancestry?`, `LastLine::ImplicitSelf`'s `class_side?`, `instance_side?`
  and `rbs_ancestry?`, `source_ancestors_reach?` and `Scope#singleton_extends_of`. Three are bridge walks
  that interleave RBS-declared edges and plugin allow-lists the tables do not carry —
  `macro_block_self_type#singleton_extends_reach?`, `rbs_dispatch#allowed_rbs_complete_extended_module`
  and `rbs_dispatch#each_source_ancestor_candidate` — deferred to the work beside #1572 (the two `extend`
  bridges already follow Ruby's singleton order for what they see; the RBS-complete ancestor bridge is
  #1572's reorder).
- **Gates.** The chain PR fixes #1567 on both sides, #1568 and #1571, refs #1570 with an explanatory
  comment, and lands under **all of WD7 lane 2, (a)–(f)**: read-level witness fixtures (`Method#owner`,
  `Module#ancestors`) for the readers it changes — `p1567_sing`, `pconst`, `retro_super2`, `retro_mod3`,
  `supposs_type2` and the third-definer probe above — the corpus diagnostics and sig-gen diffs adjudicated
  in the PR, no byte-identity claim, the allocation sweep, a `SourceArity` A/B against master (the oracle
  flag is still to be added, Migration 3), and a report of the count of reads whose answer changed to
  `Dynamic` (WD7(f)). It carries no `possible` edge, so the WD7(f) census of `possible` reads, the
  `chain_equiv`/`pmw_type`/`xfile` fixtures and the joint cap measurement belong to PR C's list, not to it.

This ADR agrees with that design. What #1578 leaves open: #1570 (master's answer where the worlds
disagree, until PR C),
#1572 (an external definer ahead of a project one), #1573 (a repeated `extend`'s position), and the two
table gaps — include and prepend of one module in one body, and `class << self; prepend`. Where this ADR
needs more than the tables hold — the position of hook-driven and in-method edges, the order of a
multi-file class's edges, and edges that are only marked — it declines, or keeps master's answer, rather
than adding data (WD2).

### WD1 — Storage: today's tables keep today's meaning; `possible` lives beside them

- Every existing member keeps exactly its current contents and semantics, the **union**
  (`certain ∪ possible`). Existing readers, raw reads and scalar derefs (`runner.rb:590–616`,
  `rbs_dispatch.rb:871`) keep their meaning.
- A set-valued member that admits `possible` facts has a `possible_*` sibling of the same shape (for
  `discovered_methods`, `name → kind` maps with `:both`, `scope.rb:986–992`, the relation is per pair). A
  single-valued member that admits them keeps its slot and today's fold and has a `contested_*` sibling:
  the keys whose value depends on a `possible` fact, including keys whose only definer is `possible`.
  Slots never hold a new wrapper (`METHOD_KIND_BOTH`, `discovery_index.rb:132`; the header-nesting
  alternatives, `:147–149`).
- **Where the position-unknown mark lives.** The three mixin members (`discovered_includes`,
  `discovered_prepends`, `discovered_extends`) carry a third sibling, `position_unknown_*`, of the same
  shape as `possible_*` and a subset of it: the edges recorded outside a class body (inside a method, a
  block including `included do` and `class_eval`) and every `class << self; prepend`. The mixin walk that
  records the edge (`write_mixin_targets`, SI:5829; the extends walker, SI:5879–5933) writes it, from the
  same context that decides `possible` (WD3): an edge under control flow inside a body is `possible` only;
  an edge outside a body is `possible` and `position_unknown`. The fold unions it per class as it unions
  the member (`accumulate_*_lists`, SI:7307–7325), the bundle carries it beside the member (ADR-85 WD2),
  and every copy path moves the triple (member, `possible_*`, `position_unknown_*`) under the pairing rule
  below, `DiscoveryIndex#with` raising on a partial triple. It admits with its member in PR C.
- Siblings **always exist** for admitting members. `DiscoveryIndex#with` (`discovery_index.rb:55`) is
  overridden to accept a member and its siblings only **together** (a pair, or the mixin triple): passing
  one without the others raises. The copy paths iterate one declaration of pairs (ADR-116 C1) and drop a
  pair only when **both**
  are empty — today's `reject { … empty? }` at `discovery_seed.rb:108` drops members one at a time and
  would strand a non-empty sibling. Each copy path has a round-trip spec on a fixture index whose
  siblings are non-empty *and* one whose siblings are empty.
- Marshal-clean, plain frozen data.
- **Admission precondition.** A member may admit `possible` facts only once (i) every copy path passes its
  round-trip specs and (ii), for a single-valued member, every read the census records for it outside the
  table owners — a read or copy of the whole table, or its def-index slot name as a key, a constant or a
  variable — consults `contested_*` or goes through a `Scope` reader. The census reporting (ii) is
  `spec/rigor/declaration_facts/admission_census_spec.rb` (#1566): per member it records the files outside
  the table owners that read the whole table or copy it — a call or Symbol naming it, a slot key such as
  `[:def_sources]` in any argument position, a keyword or hash key — and, apart from them, the files that
  read or copy every member at once (`with(**seed)`, `to_h` or `deconstruct` on an index, iterating its
  members, a computed name). A new raw read or copy path must be recorded in `admission_census.yml`;
  `RIGOR_REGENERATE_GATES=1` rewrites it. The owners are `scope.rb`, `scope/discovery_index.rb`,
  `scope_indexer.rb` and `runner/project_pre_passes.rb`. That file is the slot-reader migration list,
  distinct from the chain's walker allowlist.

### WD2 — Candidate-set reads over the chain

A read that answers a question about a member — definer, visibility, arity, type, or which ancestor —
is defined over the chain (`ResolutionChain`):

- **Worlds.** The **relevant** `possible` edges of a read are those whose closure defines the queried
  name or shares a module with the chain. The read computes the chain under every assignment of the
  relevant edges (held or not), and under both sides of every relevant skipped include on the path (§ The
  chain), takes each chain's first definer, and collects the **candidate set**, with *absent* as a member
  when some world has none. It answers when every candidate gives the same answer to the question asked,
  and *unknown* (`Unknown`, which a typing site maps to `Dynamic` and a lint to silence) otherwise. More
  than four relevant edges and skips together answers unknown. On GitLab, Project
  and Group reach 8 and 10 `possible` edges (Avatarable's and CacheMarkdownField's hooks); with the
  shares-a-module clause (Avatarable's hook `include Gitlab::Utils::StrongMemoize` duplicates
  `project.rb:29` and `group.rb:16`, so it is relevant to every name) Project reaches at most 3 relevant
  edges for any name, with 82 names at two or more, and Group 105 names at two; with relevant skips
  added (§ The chain) the bound is 5 on six Project names, so the cap can trip there as it does on the
  three classes where skips alone exceed four, and the chain PR measures the joint figure. Mastodon and
  Redmine have no owner above four even before relevance.
- **The internal API.** `Rigor::Inference::DefinerResolution.resolve(scope, class_name, method_name,
  side, question:)` is the candidate-set read. It is not a `Scope` method, so the public surface
  `public_api_drift_spec.rb:8–10` pins is unchanged. It returns `Known(answer)` — the answer keyed by the
  question: a `[node, owner]` pair for `:definer`, a visibility for `:visibility`, an envelope for
  `:arity`, so candidates that agree on the answer but differ in node are still `Known` —, `Unknown`, or
  `Absent`. A result is consumed only by an exhaustive `case/in` in the same method, with an arm for each
  of `Known`, `Unknown` and `Absent` and **no `else` or `in _` arm** that could fold `Unknown` into a firing
  arm; it is never stored, returned or truth-tested (`Absent` and `Unknown` are both truthy). PR C adds the
  spec that enforces this syntactically for every call site. Only ADR-119's behaviour PRs (C and later)
  migrate a firing site to it, each under WD7 lane 2 with a fixture; every other site reads through the
  existing readers.
- **Position-unknown edges.** A `possible` edge produced **outside a class body** — inside a method
  (`methinc`), inside a block including `included do` and `class_eval` (`hookpre`) — and a
  `class << self; prepend` have no position in the chain; the `position_unknown_*` sibling (WD1) carries
  them. A read answers unknown when the closure of a position-unknown edge defines the queried name.
- **Multi-file classes.** A class declared in two or more files (`class_sources` holds two or more
  paths) has **unordered mixin edges**: the merge keeps the edges and drops the file (`(mods + …).uniq`
  at SI:7308, 7316, 7325), so their relative order is load order. A read declines only when **two or more
  of those edges' closures define the queried name** (`xfile`) — which also declines where `require` fixes
  the order, safely — and answers otherwise. Measured: 169 GitLab pairs (0.04 %); Mastodon has two
  multi-file classes, neither with mixin edges. No file-per-edge record is needed, but the signal must
  reach the default path: `discovered_class_sources` is built by the pre-pass on every run
  (`record_class_sources`, SI:4008; the accumulator, SI:7455) and carried in every bundle
  (`class_source_names`, SI:7332ff), yet seeded onto the scope only under dependency recording
  (`runner.rb:2089–2091`, `scope.rb:1765–1767`) and dropped by the protection seed
  (`discovery_seed.rb:87–89`), because its only reader recorded ADR-46 edges. It is seeded on every run
  and carried by the protection seed — a lane-1 change under every lane-1 gate, the allocation sweep among
  them, that adds one reference to an already-built Hash of one Set of paths per class. It is
  behaviour-preserving in-repo: the table's `Scope` readers (`scope.rb:1770`, SI:3111) sit behind
  `DependencyRecorder.active?`, and `read_site` does nothing without an accumulator. Two leftovers:
  `discovered_class_sources` is on the pinned public surface and third-party plugins now see it populated
  on every run (a table they could already read under `--incremental`; no signature changes), and the
  comments at `scope.rb:1765–1767`, SI:107 and `discovery_seed.rb:87–89`, which say it is seeded only
  under recording, are updated in the same PR. Letting the rule apply only under `--incremental` is
  rejected: plain `check` and `--incremental` would answer differently for the same project.
- **Marked entries.** A chain entry carrying the dynamic mark keeps exactly master's declines (§ The
  chain: `SourceArity`, the RBS-ancestor typing arms, `program_may_answer?`, `mixin_may_answer?`) and
  adds none; every other read
  answers through it as on master, the remainder § The chain measures.
- **The absent candidate.** *Absent* is dropped only when **no RBS Rigor loads — the project `sig/`,
  plugin-synthesised RBS, and the RBS of every external entry in the chain — declares a method of that
  name for the receiver's RBS ancestors, `Object` included, and none of them declares `method_missing` or
  `respond_to_missing?`** (project entries by source, external entries by RBS: `ActiveRecord::Base`,
  `Delegator`). An external entry RBS does not know counts as defining the name, and the read is unknown.
  Otherwise the external definer is a candidate, with its RBS signature as its answer (`absent_arity`:
  `Object#to_s` disagrees with `M#to_s(fmt)`, unknown; `gemmod3`: `Enumerable#to_a` is the first definer,
  #1572). For relationship lints (`def.override-visibility-reduced`, `def.method-visibility-mismatch`)
  *absent* always counts.
- **The `SourceArity` differential.** `SourceArity` as it stands at `4f4e4934f` — its level rule and its
  hedges: `externals` (`source_arity.rb:173–177`), `load_order_dependent?` (`:138`),
  `object_extension_may_shadow?` (`:148`), `dynamic_surface?` (`:234`), `project_patched?` (`:238`),
  `public_at?` (`:268`), `chain_free_of_hooks?` (`:275`), `subclasses_agree?` (`:291`) — is kept as an
  oracle behind a flag. Over the WD5 fixtures and the lane-2 corpus — the survey checkouts
  `docs/agents/measurement.md` names, Mastodon, Redmine and GitLab among them, run with
  `check --no-cache` before and after the change — the set of `call.wrong-arity`
  firings after a change must be a subset of the oracle's; a firing outside that set is allowed only for
  a mechanism the PR names and the fixture witnesses.
- **Conditional definers.** A `def` inside control flow, a method body, or a block **other than the
  immediately-evaluated meta-new blocks Rigor already treats as class bodies** — the constant-write forms
  `K = Class.new`/`Module.new`/`Struct.new`/`Data.define do … end` (`meta_new_block_split`, SI:3764;
  `meta_new_constant_rvalue?`, SI:8390) and the bare-factory blocks the walk recognises
  (`AnonymousMetaClass.block_form_receiver`, `lib/rigor/inference/anonymous_meta_class.rb:42`), whose
  bodies Ruby evaluates as a class body whenever the factory call runs, so their certainty is that of the
  enclosing statement (`K ||= Class.new { … }` runs only while `K` is unset and is `possible`) — is a
  `possible` definer: its slot in `discovered_def_nodes`/`singleton_def_nodes`, its visibility and its
  **parameter envelope** (`discovered_parameter_envelopes`, read by `SourceArity` at
  `source_arity.rb:123–126, 224–225` through `Scope#parameter_envelopes_of`, `scope.rb:1810`) are
  contested (`conddefm`: master fires, Ruby returns `"b1"` when `X` is unset). `class_methods`,
  `included`, `prepended`, `helpers` and `class_eval` blocks stay `possible` until the follow-up ADR
  positions them.
- **Existence reads.** A boolean read used positively (`discovered_method?` at `check_rules.rb:952`,
  `known_user_class?`, `published_constant?`) answers over the union, withholding by construction. A
  presence test on a reader's result (`closure_escape_analyzer.rb:118` and the sites in § The chain)
  answers over the union in Ruby order, as the reader does; a negated or compared boolean read
  (`singleton_context_def?`, `check_rules.rb:3633–3636`) becomes a candidate-set read when PR C migrates
  it.
- **ADR-46 recording.** A candidate-set read records class edges as the chain does in **every** world it
  evaluates — each assignment, both sides of a relevant skipped include — and for every class whose
  closure it tests for a position-unknown edge, a multi-file class or a relevant skip, so a warm run
  re-checks the
  consumer when a def is added to a hook-included module or a reopened body. This is a superset of
  today's recording.
- Cost: with no relevant `possible` edge and no relevant skipped include the set is a singleton and the
  read costs one memoised chain plus one membership test per edge; the constant tables admit no `possible`
  facts in this ADR.

### WD3 — What is certain

A fact is `certain` when its statement executes whenever the file's top level executes: reachable
through `class`, `module` and `class << self` bodies alone, with no enclosing control flow, block,
method body, `rescue`/`else`/`ensure` clause or `BEGIN`/`END`; the meta-new blocks named in WD2 count as
bodies. Everything else is `possible`, and a `possible` **edge** outside a class body is also
position-unknown (WD2). A reopening whose `class` keyword sits inside a conditional makes its statements
`possible` however many other definitions exist (`condclass`). An unconditional `include` in a
`class << self` body is a `certain` singleton-side edge (SI:5877, 5933). **The extends fold stays in
this ADR**: both sites (SI:377, 7474) copy with `||=` (SI:6129–6141); a copy through a `possible` extend
edge — `extend X if …`, `class << self; include X if …` — marks the key contested. **Deferred to a
follow-up ADR**: hook facts instantiated per includer (PHPStan's trait model,
<https://phpstan.org/blog/how-phpstan-analyses-traits>). Today every walker treats `included do` and
`class_methods do` as ordinary calls under the concern's own owner (SI:2756, 2763, 2771, 2919–2926,
5773–5800); `SyntheticMethodScanner` replays `included do` macro calls only
(`synthetic_method_scanner.rb:326–362`); `ModelDiscoverer` recognises a concern by its `included do`
block (`plugins/rigor-activerecord/lib/rigor/plugin/activerecord/model_discoverer.rb:549–550, 573`). The
follow-up owns the precedence rules probed on ActiveSupport 8.1.3 (`extend X; include M` resolves to
`M::ClassMethods`, the reverse to `X`; `prepend M` beats the includer's own `def self.build`; `include M, N`
applies right to left; a `def self.x` in `included do` is the includer's singleton method), the
incremental closure (`runner.rb:626–630`; `incremental_session.rb:868–876`), the ADR-89 signature
(SI:6935) and the fold's missing def-source rows (`dependency_recorder.rb:283`). Until then the hook
edges are position-unknown and reads through them decline, as `SourceArity`'s level rule declines
`hookpre` today.

### WD4 — Classification of every `DiscoveryIndex` member, with structural checks

`DiscoveryIndex::MEMBER_CLASSES` (`discovery_index.rb:73–131`, landed by #1566) puts each `Data.define`
member (`discovery_index.rb:13–53`; 39 today) in exactly one of five classes with a one-line reason, and
`spec/rigor/declaration_facts/member_classes_spec.rb` fails on a member that is unclassified or classified
twice and checks each class's shape on a two-file fixture project. A table added to the index must be
classified in the same change. The classes and their shape checks, as landed:

| Class | Members | Shape check | Reference |
| --- | --- | --- | --- |
| `:set_valued` (may admit `possible_*`) | `discovered_classes`, `discovered_methods` (`name → kind`, relation per pair), `discovered_refinements`, `discovered_global_write_census`, `discovered_includes`, `discovered_prepends`, `discovered_extends`, `discovered_class_sources`, `discovered_deferred_ranges` (rows; `kind`/`owner` from `ModuleFunctionState`), `constant_sources`, `constant_writers`, `constant_shadowers`, `published_constant_names`, `local_constant_names`, `published_constant_alias_names`, `published_constant_ivars` | collections of names or rows; where the member admits `possible`, its sibling exists and every sibling entry is in the member | Ruby witness |
| `:single_valued` (may admit `contested_*`) | `discovered_def_nodes`, `discovered_singleton_def_nodes`, `discovered_def_sources`, `discovered_singleton_def_sources`, `discovered_method_visibilities`, `discovered_parameter_envelopes` (a join to `OPAQUE`), `discovered_superclasses`, `discovered_header_nestings`, `data_member_layouts`, `struct_member_layouts` | a slot kind recorded per member, no certainty wrapper; where the member admits `contested_*`, the sibling exists and its keys ⊆ member keys | Ruby witness (`source_location` for def identity) |
| `:typed` | `declared_types`, `class_ivars`, `class_cvars`, `program_globals`, `program_global_seeds`, `in_source_constants`, `param_inferred_types` | every leaf is a `Rigor::Type` value; the witness checks the table admits the class of the value Ruby holds | The type lattice |
| `:syntactic` | `discovered_def_nestings`, `patched_line_readers`, `clears_last_status`, `defines_case_equality`, `implicit_self_evidence` | the same value from the file's parse alone (the ADR-53 shadow harness stays for these) | The parse |
| `:run_state` | `run_generation` | an opaque token only the runner's seed supplies; absent from every bundle | None |

The siblings WD1 adds (`possible_*`, `contested_*`) join `MEMBER_CLASSES` as a sixth class when the first
one lands: a `possible_*` sibling has its member's shape and `⊆ member`; a `contested_*` sibling is a Set
of the member's keys; a sibling exists iff its member admits `possible`. Deferred ranges, def sources and
parameter envelopes are not syntactic: the range rows carry the `module_function` definee
(SI:4580–4587), the def sources come from the definee walk in `accumulate_project_index` (SI:7518–7545)
and feed the ADR-17/#735 suppression (`scope.rb:1045, 1094, 1111, 1127, 1143`), and the envelopes are
what the arity check reads.

### WD5 — The witness, at two levels

- **Table level** (landed by #1566: `spec/support/declaration_witness.rb`, fixtures under
  `spec/integration/fixtures/declaration_witness/`, `witness_spec.rb`). A fixture runs under the suite's
  Ruby with a time limit and records `Module.nesting` at each line that runs, each module's methods by side
  and visibility with their `source_location`, its mixins, its superclass, and the class of each class
  variable's value; the witness compares them with the index the runner seeds and `ScopeIndexer.index`
  builds for the file. A set-valued table must satisfy `certain ⊆ runtime ⊆ certain ∪ possible`, a
  single-valued one must agree wherever it answers, def identity is compared by `source_location` line, and
  a typed table must admit the class Ruby holds. Since no `possible_*` table exists yet, every entry reads
  as `certain` except the self-extend edge Ruby does not show and what the extends fold derives from it. A
  fixture that reproduces a filed bug stays `pending`, with its issue, beside a pin of today's exact
  violations. The relation is stated against the per-file index because `finalize_def_index` deliberately
  subtracts plain cross-file defs (SI:7480, ADR-17).
- **Read level** (to be added; #1578 carries read-level fixtures for its readers). For each fixture
  variant, `Module#ancestors`, `Method#owner` and the resolved method's visibility and arity are compared
  with `ResolutionChain` and the candidate-set reads: a read answers the variant's value or unknown, never
  a different value. This is the only witness for the chain, the
  skip-worlds rule, the extends fold and the position-unknown rule, whose tables are correct while the
  reads are wrong. The `SourceArity` differential of WD2 is asserted here and over the lane-2 corpus.
- A fixture must fail on `master` before its fix. **Limit:** one run witnesses one execution;
  "every world" is approximated by fixture variants that take each branch, and a fabricated `certain`
  fact is caught only where a variant's run lacks it. The fuzzer stays local until its load rate on the
  constructs that matter (2–7 %) exceeds 50 %.

### WD6 — The producer tripwire

`spec/rigor/declaration_facts/producers_spec.rb` (landed by #1566) parses every Ruby file under `lib/`
and `plugins/*/lib/` with Prism and lists each method, or class or module body, that (i) references a
declaration node class (`ClassNode`, `ModuleNode`, `SingletonClassNode`) or its `Prism::Visitor` hook,
(ii) names a node-type symbol, (iii) names a visibility or mixin keyword as a symbol, or (iv) reads a
constant, in any covered file, built from one of those (`CLASS_BODY_NODES`, SI:4082;
`IVAR_BARRIER_NODES`); or (v) is reachable, through same-file calls in bodies and default arguments, from
`ScopeIndexer.index` (SI:102), `.accumulate_project_index` (SI:7518), `.finalize_def_index` (SI:7465), a
multi-file entry point (`.discovered_*_for_paths`, `.discovered_project_index_incremental`,
`.scan_summary_for_paths`) or any method another covered file calls as `ScopeIndexer.x`, and writes into a
table parameter; or (vi) includes `DeclarationWalk::Collector` or subclasses a class that does. Rule (v) is
what marks the four bug sites rules i–iv miss — `record_module_function_names` (SI:4951),
`record_singleton_def_node` (SI:4939), `fold_extends_into_singleton_tables` (SI:6129) and
`apply_alias_def_nodes`; `finalize_def_index` is a root because it holds the ADR-17 subtraction and the
project-fold call site (SI:7474). Today `producers.yml` holds 371 entries in 69 files. A new producer must
be recorded there with a reason;
`RIGOR_REGENERATE_GATES=1` adds it as `TODO`, which the spec rejects until it is justified; the entries
marked `grandfathered` are a closed list, pinned by count and digest. **What remains**, as the spec's
header states: a computer that dispatches on `node.class.name` or other strings, on `Prism::Node#type`
through a variable, through `Prism.const_get`, by duck typing (`respond_to?(:superclass)`), or on a keyword
spelled as a String is not found; the list freezes the set and certifies nothing about how an entry
computes its context.

### WD7 — Landing rules

Two lanes. Neither lane's list is sufficient: the review loop of `docs/agents/contribution-flow.md`
applies to every PR, and no listed gate may be skipped or replaced by a claim.

- **Lane 1 — behaviour-preserving changes** (refactors, ports onto `DeclarationWalk`, performance and
  allocation work, deleting a `RULE_VARIANTS` entry the walk's rule reproduces): byte-identical corpus
  diagnostics, byte-identical corpus `rigor sig-gen` output, the shadow harness wherever a table is
  rebuilt, the per-merge allocation sweep. A port may not change a fact.
- **Lane 2 — behaviour changes** to declaration facts or to how a read answers, in a `ScopeIndexer`
  walker, a `DeclarationWalk` collector, `ModuleFunctionState`, the fold, `ResolutionChain`, sig-gen,
  Effects, a plugin discoverer or a `Scope` reader, and deleting a `RULE_VARIANTS` entry whose variant was
  a bug. Necessary, not sufficient: (a) a reproduced bug's WD5 fixture fails before and passes after;
  (b) the corpus diagnostics diff **and** the corpus sig-gen diff, every changed line adjudicated under
  the false-positive rule (`visibility_excludes?` hides visibility changes from diagnostics,
  `generator.rb:732–741, 906–907`); (c) neither byte-identity to a predecessor nor a variant is claimed;
  (d) the per-merge allocation sweep runs and its answer is in the PR; (e) for any change that can add a
  `call.wrong-arity` firing, the `SourceArity` differential; (f) a change that can widen a read to
  `Dynamic` reports, over the lane-2 corpus, the change in the (class, name) census of reads answering
  `Dynamic` taken from `rigor check --no-cache`'s own scopes (an instrumented run, since `rigor coverage`
  seeds from `DiscoverySeed.discovery_tables`, `lib/rigor/cli/coverage_scan.rb:60`, which drops extends,
  header nestings and class sources and so does not see what `check` sees), with `rigor coverage`'s
  `dynamic_specific`/`dynamic_top` tier counts (`lib/rigor/cli/coverage_command.rb:38–39`; the target's
  `.rigor/cache` cleared before each arm, `:139`) as a secondary figure with that gap stated,
  because the diagnostics diff cannot show a precision loss that only removes firings; `rigor type-of` is
  not usable for this, since it reads every cross-file declaration as `Dynamic[top]`
  (`docs/agents/measurement.md:60–64`). **The chain PR lands under this lane**, before
  this ADR's acceptance, as ADR-24's amendment.

### What each part removes, and what remains

| Failure mode | Removed by | Remains |
| --- | --- | --- |
| 1 Prose enumeration | WD4 (members `Data.define`-derived, shape-checked; landed); WD6 (producers parsed; landed); WD1 (copy paths paired and round-trip-tested; slot readers censused, landed); the chain's detection spec (ancestry walkers parsed, one chain the reference; the internal API's `case/in` discipline checked syntactically) | Grandfathered producers, walkers and slot readers converge as bugs are filed; the patterns are themselves stated lists |
| 2 Variants by reading; vacuous sweeps | WD1 + WD7(c): no variants; a disagreement is a fixture or nothing; WD5 at both levels | Unknown constructs are found by users; one run witnesses one execution |
| 3 Several implementations of one question | `module_function`: one helper (#1563, landed); resolution order: one chain inside every existing reader (ADR-24 amendment) | The helper preserves four semantics until PRs B–C; the allowlisted union walks stay by design; concern hooks wait for the follow-up ADR |
| 4 Byte-identity to wrong legacy | WD1 + WD2 + WD7: over-approximation is legal only as `possible`; no read answers from it, from an edge without a position, or from one side of a relevant skipped include; a marked entry keeps master's declines | A fabricated `certain` fact no fixture covers stays until reported; typing through marked entries (`C.include(M)`, `prepend_mod_with`, `send`) stays as on master, 41–51 % of GitLab's pairs |
| 5 Shifting justification | WD7: two lanes with fixed, necessary gates | Triage decides what counts as reproduced |

## Migration

**Before acceptance.**

1. **#1551 (merged, lane 1).** The layered def-nesting lookup (SI:350–355).
2. **#1563 (merged, lane 1).** The `module_function` readings behind one helper
   (`module_function_state.rb`); shadow-checked on the corpus.
3. **The gates (#1566, merged, lane 1).** `member_classes_spec.rb`, `producers_spec.rb`,
   `admission_census_spec.rb` and `witness_spec.rb` under `spec/rigor/declaration_facts/`, recording
   today's behaviour. Still to add under the same lane: WD1's `with` pairing and round-trip specs, WD5's
   read-level witness, pending fixtures for #1518, #1519, #1520, #1550, #1570, #1572, #1573 and the probes
   named in Context, and the `SourceArity` oracle flag.
4. **#1548 (bug fix).** Key the seeded deferred-ranges reuse (SI:313–315) on content digest plus parse
   version, or drop it (`runner.rb:1985–1994`; SI:7109; `discovery_seed.rb:97–108`).
5. **Declaration-driven copy paths (lane 1).** Pairs, dropped only when both are empty. In the same lane,
   `discovered_class_sources` is seeded on every run and carried by the protection seed (WD2,
   Multi-file classes), with the allocation sweep as its gate.
6. **The chain PR (#1578, pending; lane 2, ADR-24 amendment).** § The chain, the two-or-more-skips
   fallback rule and the dynamic mark included; changes the walk inside every existing reader and migrates
   no call site; fixes #1567 on both sides, #1568 and #1571, refs #1570. **It carries** all of WD7 lane 2
   (a)–(f): read-level witness fixtures for its readers (`p1567_sing`, `pconst`, `retro_super2`,
   `retro_mod3`, `supposs_type2`, the third-definer probe, `pmw_on`), adjudicated corpus and sig-gen diffs,
   the allocation sweep, the `SourceArity` A/B against master, a `Dynamic`-count report, the walker
   allowlist spec and a spec pinning each preserved mark check. **It does not carry** what needs a
   `possible` edge — PR C's list. Every existing reader keeps its return shape; every entry is `certain`
   until PR C admits the mixin members.

**After acceptance — under WD7 lane 2.**

| PR | Change | Expected corpus diff | Expected sig-gen diff | False-positive check |
| --- | --- | --- | --- | --- |
| A — #1550 | The named form snapshots the last receiverless `def` before the call | Zero (rare) | The singleton keeps the earlier body's type | Fixture asserts `P9.a == 1` |
| B — reset, receiverless-only, privatisation | A bare visibility call ends the toggle; `def self.x` gets no instance copy; `attr_reader` private, no singleton copy; `define_method` both; a `certain` module function's instance copy recorded private (SI:6190–6330); sig-gen bypasses `visibility_excludes?` for module functions | Zero on existence; `Helpers#fmt` stops firing | Module functions after a reset stop rendering as singletons; omitted ones appear | Probes P1–P13, `vis.rb` |
| C — candidate-set reads and the first `possible` facts | The internal API of WD2 over the chain, with position-unknown edges, marked entries, the absent rule, the `SourceArity` differential and conditional definers; the firing sites it migrates, each with a fixture: return inference (`expression_typer.rb:2283`, where Unknown types `Dynamic`), **the `:arity` question at `SourceArity`'s decision point (`source_arity.rb:98–121`, where `absent_arity` and #1570 fire today and Unknown means silence)**, the override super-method lint (`check_rules.rb:3770–3807`), the visibility mismatch (`check_rules.rb:2648–2649`) and `singleton_context_def?` (`:3633–3636`). Its own gates beyond (a)–(f): the WD7(f) `possible`-read census, the `chain_equiv`, `pmw_type` and `xfile` fixtures, the joint cap measurement, the `case/in` spec, and the mixin triple's admission. Then, once WD1's precondition holds for **every member this PR writes into** — `discovered_includes`, `discovered_prepends`, `discovered_extends`, `discovered_methods`, `discovered_def_nodes`, `discovered_singleton_def_nodes`, `discovered_method_visibilities`, `discovered_parameter_envelopes`, `discovered_deferred_ranges` — conditional mixin edges, conditional `def`s and a bare `module_function` inside control flow, a block or a singleton-method body become `possible` | Silences `Helpers2#fmt2`, `bfsvis`, `idemvis2`, `expose`, `extend`, `sclass`, `condclass`, `conddef`, `conddefm`, `absent_arity`, #1570 (`redund`), `onload_body` and `ifdef_inc`; keeps `methinc`, `hookpre`, `xfile`, `sclpre`, `supposs1`, `send_inc` and `recv_inc` silent; `gemmod3` waits for #1572; may silence checks that resolved through a possible-only definer | A notice on `possible` module functions; `possible` edges render nothing (RBS has no conditional form) | Every fixture at both witness levels; the differential; a candidate-set read never answers a value a variant contradicts |
| D — hook facts per includer | Deferred to the follow-up ADR | — | — | — |

Precision estimate (`edges.rb`): about 13 of 940 mixin calls in Mastodon's `app`, 6 of 85 in
`app/lib`, sit outside unconditional bodies; Redmine has 17 `send(:include)` and 6 mixin calls inside
methods. Precision does not collapse, and the relevance rule keeps GitLab's core models answering.

## Relationship to other ADRs

- **[ADR-24](24-self-method-call-resolution.md) — amended by the chain PR.** It owns implicit-self
  resolution and its order (`:98–100`, WD1 at `:121`); #1578 (pending) carries § The chain's contract as
  its amendment; the breadth-first walks inside `user_def_through_ancestors` (`scope.rb:1358`) and
  `each_project_ancestor` (`check_rules.rb:3748`) are replaced by the chain, with `MasterOrder` answering
  where the worlds disagree under the two-or-more-skips rule. The amendment's #1570 text is to say what
  this ADR says: fixed by PR C at the arity decision point, with no new data. This ADR's reads
  are defined over that chain and add certainty on top.
- **[ADR-116](116-hot-file-restructuring.md) WD5 — partially superseded.** Byte-identity and the variant
  rule (`:160–184`) are retired for behaviour changes; its guardrails remain lane 1. The four ported
  collectors stay; `RULE_VARIANTS` entries are deleted under the lane their case belongs to. #1531 closes
  as superseded; the README row drops "WD5 in progress". C1 is what WD1 applies to the copy paths.
- **[ADR-53](53-scope-discovery-index-separation.md)** — the shadow harness narrows to WD4's syntactic
  members and lane 1; the "generic-visitor rewrite: Deferred" row (`:233`) is marked superseded.
- **[ADR-85](85-seed-bundles-and-lazy-def-node-handles.md) WD2 — amended.** Bundles carry the pairs; the
  next `IncrementalSnapshot::SCHEMA` bump (`lib/rigor/cache/incremental_snapshot.rb:148`, currently 30)
  covers them; `docs/internal-spec/cache.md` documents them.
- **[ADR-46](46-incremental-dependency-graph.md)** — preserved by the chain's dependency contract and
  WD2's every-world recording; the gaps the follow-up must close are recorded in WD3.
- **[ADR-17](17-monkey-patch-pre-evaluation.md)** — the fold's subtraction (SI:7480) is a consumer policy
  the WD5 relation is stated around.
- **[ADR-15](15-ractor-concurrency.md)** — plain frozen data; the chain memo is per index.
  **[ADR-5](5-robustness-principle.md)** — unknown-is-silence at every read.
  **[ADR-38](38-additional-initializers.md)** — the typed pre-pass's registry read is why the typed
  members are outside WD1.
- **[ADR-2](2-extension-api.md) — unchanged.** Plugins keep the same readers with the same shapes
  (`docs/internal-spec/inference-engine.md:654` for `user_def_for`, `:661` for the pair-returning walk)
  and receive the corrected order as a bug fix; `Scope::ResolutionChain` and `DefinerResolution` are
  internal, not public `Scope` methods, so `public_api_drift_spec.rb:8–10` and `sig/rigor/scope.rbs` are
  unchanged. Exposing either to plugins
  needs its own ADR-2 amendment.
- **`rigor sig-gen` output is a gated artifact** in both lanes; ADR-89 WD1 is not changed by this ADR.
- **Follow-up ADR (to be numbered): hook facts per includer.**

## Rejected / deferred alternatives

| Candidate | Status | Reason |
| --- | --- | --- |
| A per-file declaration-fact IR (round 1) | Rejected | Typed pre-passes are not pure per file (SI:1714–2996); the ivar pass (SI:397–412) does not fit rows; the default path loads no snapshot (`runner.rb:1558–1563`). |
| Ruby as the judge of every disagreement | Rejected | Several Ruby answers per text (Context 3); deliberate over-approximation (SI:5869–5874); Zeitwerk fixtures raise; five members have no runtime counterpart. Ruby is WD5's *witness*. |
| One approximation policy per table; direction per reader; direction per call site | Rejected (drafts 1–2) | Visibility, constants and ancestry are read both ways; on a walk neither direction is safe; labels were self-declared. |
| Candidate sets over the breadth-first walks (draft 3) | Rejected | Not Ruby's order (`bfsvis`, `idemvis2`, #1567, #1568). |
| Candidate sets over a chain, counting only edges with a position (draft 4) | Rejected | In-method includes, hook edges and cross-file load order have no position; `SourceArity` declines there and draft 4 fired (`methinc`, `hookpre`, `xfile`). Position-unknown edges decline (WD2). |
| A single linearisation for a skipped include (draft 5) | Rejected | A body reopened after a subclass linearised, or a `possible` superclass include, positions the module differently (`retro_super2`, `retro_mod3`, `supposs_type2`); the fuzz never reopened a body. Two worlds per skipped include. |
| "Through `send`" as a position-unknown edge (draft 5); every read unknown through a marked entry (draft 6) | Rejected | `send(:include, …)`, `C.include(M)` and `prepend_mod_with` record no edge, only the dynamic mark (SI:6437–6439, 6457–6463), so there is no closure to test; and declining every read through a mark would turn 41–51 % of GitLab's pairs `Dynamic` where master types them. The mark keeps exactly master's declines. |
| Leaving the existing readers on master's breadth-first walk and migrating call sites one by one to a new reader (draft 9) | Rejected | The singleton side of #1567 (`p1567_sing`) and the constant analog (`pconst`) fire on master through readers no migration list named; every unmigrated caller and plugin would keep a wrong order; and several walk implementations would remain, which is failure mode 3. Changing the walk inside every reader fixes all call sites at once and keeps every shape. |
| Two skip worlds only — every skip made, every skip skipped — as the fork an existing reader consults (#1578 at `72cfcb820`) | Rejected | A mix of skips can put a third definer first (the probe in § The chain: Ruby `"d"`, master silent, the two-world chain fires); its own ADR-24 text admits it. Master's answer whenever two or more relevant skips exist is the required rule. |
| On a skip-world disagreement, an existing reader answers the skipped world (the chain's own linearisation) | Rejected | It would fix #1570 (`Base#foo`) but add false positives master does not have on the reopened-body shapes (`retro_super2`, `retro_mod3`, `supposs_type2`), where master's walk is right; the chain PR's contract is to introduce no firing master lacks, so a contested chain returns master's answer (`MasterOrder`) and #1570 is fixed by PR C's `Unknown` at migrated sites. |
| A truthy unknown sentinel returned in the node position by the existing readers (draft 8) | Rejected | Nine wrappers return a reader's result under other names and their callers dereference far from the reader (`expression_typer.rb:2366, 2413`, `void_tail_summary.rb:175`, `statement_evaluator.rb:437`), often under `rescue StandardError`, so a dereference detector cannot be complete and a miss becomes a silent `nil`; and the sentinel would cross the plugin API (`plugin/base.rb:613`; `inference-engine.md:654, 661`). A separate value-typed API with opt-in migration keeps every existing caller and plugin on master's answer. |
| "Absent means `NoMethodError`" (draft 4) | Rejected | The chain sees only project classes (`scope.rb:1586–1600`); `Object#to_s` and `Enumerable#to_a` answer (`absent_arity`, `gemmod3`). |
| A cap on reachable `possible` edges (draft 4) | Rejected | GitLab's Project reaches 8 and Group 10 through hooks; 146 of 25,865 owners exceed four. Relevance leaves at most three per name there. |
| A discovery-data change for the chain (separating tables, recording statement order, recording the file of an edge) | Rejected | The tables already separate prepends and keep order (`scope.rb:1287–1288`; SI:5829, 7354); the fuzz diverges in 0.2 % of cases only under same-module interleaving, which the census finds nowhere; reopened bodies fork (skip worlds) and a multi-file class declines at the edge level (WD2), neither needing the file of an edge. |
| Every mixin edge of a multi-file class position-unknown (draft 6) | Rejected | It declines on a single defining closure: 107 GitLab classes and 0.8 % of pairs, Namespace losing 89 of 198 names through the nested `class Namespace; class TraversalHierarchy` style; and "two or more files' closures" needs the file of an edge, which the merge drops. The edge-level rule costs 169 pairs (0.04 %). |
| Agreement between the certain-only world and the union world; `certain_*` siblings; copying `class_methods` as `def self.` rows; hook instantiation in this ADR; a separate ADR for the chain; the overlay; the fuzzer as a CI gate; PHPStan-style per-includer re-analysis; continuing the piecewise ports | Rejected or deferred as in drafts 3–5 | Reasons unchanged: compensating definers; table copies; `M::ClassMethods` is an edge; fold-level facts need their own probes and witness; ADR-24 owns the order (ADR-49 economy, ADR-97 budget); not byte-identical; 2–7 % load rate; multiplies work by includer count; 0.2 % of a cold run. |

## Consequences

Positive:

- The variant rule and byte-identity for behaviour changes are gone; a disagreement between two
  context computers is a fixture with a Ruby witness or nothing.
- One chain is the reference for resolution inside every existing reader; #1567 on both sides, #1568 and
  #1571 are fixed by it at every call site and for every plugin, and #1570 is fixed where PR C migrates a
  firing site; no consumer walks ancestry on its own except the allowlisted union walks; this ADR adds
  nothing to the chain's data.
- No read carries a direction label; a migrated firing site answers or is silent by one rule, floored by
  the `SourceArity` differential; every other site and every plugin reads the corrected order through the
  same readers; a member holds `possible` facts only once its copy paths are paired and its slot reads
  migrated.
- `module_function` has one implementation; #1550, both `vis.rb` false positives and the ancestry probes
  are fixed under a stated relation.

Negative:

- **Precision cost of unknown.** A definer reached only through `possible` facts, contested with another,
  below a position-unknown edge or on one side of a relevant skipped include answers `Dynamic`;
  relationship lints are silent where some world has no super method. On GitLab, `avatar_url` and
  `strong_memoize` read as unknown through Avatarable's hook (correct for the prepended
  `ShadowMethods`, a precision loss for `strong_memoize`); at a migrated site a chain whose worlds
  disagree types `Dynamic`, and at an unmigrated one it keeps master's answer (14 GitLab pairs).
  **Defs inside blocks** become `possible` definers: the review counted 74 of 7,181 defs in Mastodon,
  3,772 of GitLab's including `ee/` (about 142 exempt as meta-new blocks; `prepended do` alone holds 354)
  and 162 of 9,657 in Rigor's `lib` (132 in `Data.define` blocks, exempt); the rest (`class_methods`,
  `included`, `prepended`, `helpers`, `class_eval`) type `Dynamic` until the follow-up ADR positions them.
  About 1–7 % of mixin edges on Mastodon are `possible`.
- **Typing through marked entries is unchanged**, deliberately: 41–51 % of GitLab's pairs and 4.7–7.6 %
  of Mastodon's resolve at or beyond a marked class, and only master's declines apply there. A later
  decision may widen the mark's effect under WD7(f), with the count.
- **User-visible sig-gen changes** (PR B), each with a changelog entry.
- **Grandfathered sets**: 371 producer entries in 69 files (`producers.yml`), the chain's allowlist, and
  the slot readers the census reports converge only as bugs are filed.
- One small sibling per admitting member, a `with` that raises on a half pair, and a `SCHEMA` bump.
- No speed is claimed.

## Open questions for the maintainer

1. **Scope of `possible`.** As stated, or restrict to direct-body control flow? *Default: as stated.*
2. **Typing through a possible-only definer** answers `Dynamic`. *Default: accept.*
3. **The relevance cap.** Four relevant edges and skips together. *Default: four; it trips on three GitLab
   classes through skips alone and possibly on six Project names, which the chain PR measures.*
4. **Multi-file classes.** A read declines only when two or more of the class's mixin edges' closures
   define the name; no file-per-edge record or load-order table is proposed. *Default: as stated.*
5. **#1572**: the chain's external-definer read for typing. *Default: a follow-up of the chain PR,
   before PR C.*
6. **Block-def exemption.** Exempt the meta-new blocks Rigor already recognises; everything else waits
   for the follow-up. *Default: as stated.*
7. **Sig-gen changes in the changelog.** *Default: yes, one entry for PR B.*
8. **Pace for the grandfathered sets.** *Default: by filed bug; the gates prevent growth.*
9. **The follow-up ADR's timing.** *Default: after PR C lands.*
