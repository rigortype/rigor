# ADR-119 — Certainty on discovery facts, candidate-set reads over the resolution chain

Status: **Accepted, 2026-10-01** (proposed 2026-09-28, revised to v16 on 2026-10-01), with every default in
§ Open questions. Landed
ahead of it, each on its own merits: #1551 (the layered def-nesting lookup) and #1563 (the
`module_function` readings behind one helper, `lib/rigor/inference/module_function_state.rb`), both
byte-identical; the gates of WD4–WD6 (#1566, `spec/rigor/declaration_facts/`); the
`unpositioned_mixins` member (#1584, data only, nothing read it); and the resolution chain
(#1578, `lib/rigor/scope/resolution_chain.rb`), an ADR-24 amendment that fixes #1567, #1568, #1571 and
#1587 and is the first behaviour change in this line; #1593 (2026-10-01), which records the
provably-run block shapes of #1592 (§ The chain); #1597 (witness fixtures for #1570, #1572, #1573 and
#1594 that flip with their fixes); #1598 (#1548 closed: a seeded file's deferred ranges are re-walked
and compared); #1600, which carries WD1's sibling pairs beside their members on every copy path, so
WD1 is implemented with every sibling empty; and #1599, the cross-commit `call.wrong-arity`
differential with its fixtures and CI job. WD2 and WD3, the reads this ADR decides, are open: no
`possible` fact exists, no read answers *unknown*, and the first lane-2 PR on them (PR C) is next. **Citation baseline:** `file:line` cites are at `origin/master` `fd10d71a7` (#1599
merged); SI is
`lib/rigor/inference/scope_indexer.rb`, RC is `lib/rigor/scope/resolution_chain.rb`, MA is
`lib/rigor/inference/scope_indexer/mixin_accumulator.rb`.

Grounding: the design-review rounds on #1531 and #1507, the fourteen drafts of this ADR reviewed
adversarially on #1562, #1578's measurements (a Ruby witness suite, an 8,000-program fuzz, a mixin
census over five corpora, an instrumented run over Rigor's `lib/` and Mastodon v4.5.10), #1584's
allocation sweep, #1593's review, and the probes named in Context and WD2, each run under `rigor check
--no-cache` (workers 0) and Ruby 4.0.5 against `a841adac4`'s engine (master before #1593) with Ruby's
own answer beside it. ADR-49 archetype: deliberative; stakes: high (the false-positive envelope of
every ancestry read).

**Scope.** Three decisions, three documents, each the smallest that holds. The **resolution chain** is
ADR-24's (§ "Amendment 2026-09-28", landed): Ruby's linearisation, when it stands, and its dependency
contract. **This ADR** owns the gates, certainty on facts, and candidate-set reads over that chain. A
**follow-up ADR** owns concern hooks instantiated per includer. § The chain restates only what this ADR
relies on.

## Context

ADR-116 WD5 moved `ScopeIndexer`'s table walkers onto one declaration walk, each port required to be
byte-identical to the walker it replaced, with a named *variant* wherever the walkers disagreed
(`docs/adr/116-hot-file-restructuring.md:160–184`). Four tables were ported (#1517, #1522, #1527); the
contract for the next four went through three adversarial rounds on #1531 and did not converge. The
reviews attribute that to five failure modes, each of which the Decision addresses by mechanism.

1. **Enumeration in prose never converges.** Every list was incomplete in the next round: the quirk
   list, the "four versus twenty walkers" pause scope, then the context computers outside
   `ScopeIndexer` — sig-gen's `module_function` rule (`lib/rigor/sig_gen/generator.rb:667`),
   `Effects::DefinitionContext` (`lib/rigor/effects/definition_context.rb:58`),
   `SyntheticMethodScanner#build_hierarchy` (`lib/rigor/inference/synthetic_method_scanner.rb:369`), the
   ActiveRecord `ModelDiscoverer`'s `included do` descent (`model_discoverer.rb:471, 518`). WD6's
   tripwire now lists 393 such producers in 71 files (`spec/rigor/declaration_facts/producers.yml`).
   On the read side, `Scope` exposes every table raw (`lib/rigor/scope.rb:42–60`), and before #1578
   six consumers walked ancestry on their own while four more loop over the raw tables on purpose.
2. **Variants were found by reading code**, so they grew as O(walkers × categories)
   (`lib/rigor/inference/declaration_walk/traversal.rb:89`), protect behaviour no corpus exercises
   (#1527's control found no divergence in 67,137 files), and a shadow sweep over a corpus that lacks a
   construct passes without checking anything.
3. **One semantic question had several implementations and no reference.** `module_function`'s definee
   was computed four ways until #1563 put the readings behind one helper, byte-identical, so the four
   semantics still stand (SI:4233, 4614, 4922, 4988; `generator.rb:667`), and Ruby's answer is
   run-dependent. **Method resolution order had the same problem**: two breadth-first walks,
   `SourceArity`'s level walk with its own agreement rule and eight hedges, none Ruby's order — three
   false positives on correct programs (#1567 on both sides, #1568 at error level, #1570). The first
   two are fixed by the chain; #1570 is not (§ The chain).
4. **Byte-identity was demanded against walkers that are wrong or deliberately over-approximate.** The
   extends walker over-approximates on purpose, in the ADR-5-safe direction (SI:6072–6078), and
   under-approximated in the unsafe one until #1593: a singleton-side mixin inside a block — including
   a block inside a method — was dropped, while one written directly in a method body was recorded and
   listed (#1592, finding (d)). #1518–#1520 are rules wrong in several walkers at once; #1550 is a false
   positive on correct Ruby (the named form resolves the *later* `def`, SI:4984–4988).
5. **The justification shifted** from speed to C2 without a criterion for landing a port; the speed case
   was measured and found absent (`docs/adr/116-hot-file-restructuring.md:175` still calls the merge
   "the wall lever").

Seven findings bound the design. **(a)** The typed pre-passes call `scope.type_of` under the project
seed and the plugin registry (nine sites, SI:1747–3029), so they are not pure per file. **(b)** A
direction per table or per read is ill-posed: visibility is read to fire and silenced by `nil`,
constants are read both ways (`scope.rb:140`), and on an ancestor walk keeping a `possible` edge
shadows a further ancestor while dropping it exposes one. **(c)** A candidate set over a breadth-first
walk is not sound either: a certain nearest definer in a wrong order. **(d) Some edges have no position
that is a fact, and some singleton-side edges are not recorded at all.** An `include` inside a method
takes effect when the method is called; an `included do include A end` edge is recorded on the concern
but Ruby applies it to the includer, and a `prepend` there lands ahead of the includer; two files
reopening one class order their includes by load order; and an include the chain skips as already
present becomes positioned by a later reopening (Ruby `[C, M, Base, M]` against one linearisation).
Since #1584 and #1578 the first three are *unsettled* chains and the fourth is a counted *fork*. On the
singleton side, before #1593, the extend walk descended into no block it did not recognise: a block's
`extend X` or `class << self; include X; end` — in a class body, inside a method, or in a concern's
`included do` — was neither recorded nor listed, and a hook's `base.extend(X)` lists `"*"` on the hook
module only, which no includer's singleton chain draws on; in each shape `K.bar.upcase` fired
`call.undefined-method` through `Base.bar` while Ruby runs `X#bar` (#1592, pre-existing), whereas the
direct-body `extend X if ENV["E"]` and a method body's `extend X` were listed, unsettled and silent.
#1593 walks a block that provably runs once with the body's `self` (`extends_block_plan`, SI:6225;
`runs_body_block_once?`, SI:6258) and still skips the rest.
**(e) Some edges are not recorded, only marked**: `send(:include,
M)`, the receiver form `C.include(M)` and helpers such as `prepend_mod_with` add nothing to the mixin
tables (`MIXIN_CALL_NAMES`, SI:5633; `SURFACE_MIXIN_HELPER`, SI:6812); each stamps
`ENVELOPE_DYNAMIC_MARK` on the class (SI:6835, 6845) and, since #1584, lists `"*"` on the owner's side
in `unpositioned_mixins`. Three readers decline on the mark (`source_arity.rb:244`;
`rbs_dispatch.rb:621, 656, 739–748`; `check_rules.rb:2506, 2522`); every other read types through it.
**(f) The chain sees only project classes**, so "absent means `NoMethodError`" is false:
with `include M if X` and `M#to_s(fmt)`, `Object#to_s` answers when `X` is unset, yet
`call.wrong-arity` fires; `include M; include Enumerable` fires an error-level `undefined method
'first' for 1` although `Enumerable#to_a` answers (#1572). A project module is a project entry only
under the reader's flavour (RC:339–349): a module whose every method is a `define_method` in a loop
has no `discovered_methods` row, fails `known_user_class?` (`scope.rb:1680–1683`) and enters an
includer's `:methods` chain as an **external** entry carrying the dynamic mark. **(g)** A single-valued
table has no union (last-write-wins, SI:4972) and scalar consumers deref the value (`runner.rb:605–609`).

**What landed between the first draft and this one.** The chain (#1578, 2026-09-30) replaced every
"which definer" walk inside the engine's readers with one Ruby-order implementation and one decision
method, changing no reader's signature; its corpus diagnostics and `rigor sig-gen` output are identical
to master's on Rigor's `lib/` and Mastodon v4.5.10 (default and strict profiles; 9,208 sig-gen lines),
five witness fixtures fail against master's `lib/`, and engine allocations moved −0.03 % on a plain
run and +5.1 % on a recording run (#1590). Its instrumented precision run (#1578's description, §
"Precision") is the number this ADR now designs against: on Rigor's `lib/` 339 of 5,336 chains are
unsettled and 1.0 % of 135,225 reads answer from master's order; on Mastodon 1,273 of 11,714 chains
are unsettled, 49 carry one retro-eligible fork, none carries another kind, and **21.3 % of 145,182
reads answer from master's order, every one on an unsettled chain** (carried forward as #1591).
`unpositioned_mixins` (#1584) is the data those verdicts read; it cost +0.03 % allocations and bumped
the seed-bundle and snapshot schemas (`descriptor.rb:80`; `incremental_snapshot.rb:165`; bumped again
by #1593 and #1600). Since then: #1598 closed #1548 (`merge_deferred_ranges_seed`, SI:344–350,
re-walks a seeded file's ranges and keeps the seed only when the rows are equal, so no digest or
parse-version member was needed); #1600 landed WD1's sibling pairs, all empty; #1597 landed the witness
fixtures for #1570, #1572, #1573 and #1594, each `pending` on its fix (WD5); #1599 landed the cross-commit
arity differential and its CI job (WD2).

## Decision

**Criterion.** A discovery producer is judged by a relation Ruby can witness, never by identity to a
predecessor: a fact is *certain* (it holds whenever the file's top level executes) or *possible*. A
read answers only when its answer is the same under every world the tables leave open — every
assignment of the `possible` facts it depends on, and every order the chain cannot vouch for — and
otherwise answers *unknown*, which every consumer treats as silence (ADR-5). Two readers carry that
verdict differently. An **existing reader** keeps its return shape and, where the chain does not
stand, answers what its predecessor answered (`ResolutionChain::MasterOrder`, RC:361), so no firing is
added and none is removed by the chain alone. The **internal candidate-set read** (WD2) answers
`Unknown`, in a value type separate from *absent*, and only the firing and typing sites this ADR's PRs
migrate consult it. A marked entry keeps exactly master's declines and adds none. A behaviour change
lands under WD7's second lane; a behaviour-preserving change under its first. **Unsettled is not a
decline** (§ The chain, "The lesson of #1593 and #1594").

### The chain this ADR builds on (ADR-24 amendment, landed by #1578)

Binding text: ADR-24 § "Amendment 2026-09-28" (`docs/adr/24-self-method-call-resolution.md:522–697`)
and `docs/internal-spec/inference-engine.md:670`. This ADR relies on the following and states no more.

- **One walker, one decision.** `Scope::ResolutionChain` (RC:82) replays CRuby's `include_modules_at`
  over the tables — prepends before the class, includes after it in statement order, a module already
  anywhere in the chain skipped, a skipped module before the superclass moving the insertion point, the
  singleton side through the recorded `extend` and `class << self; include` edges under the include
  rule — and is internal: nothing joins the `Scope` surface `spec/rigor/public_api_drift_spec.rb`
  pins, and `sig/rigor/scope.rbs` is unchanged. Every "which definer" reader of the engine reads it,
  keeping its signature and return type: `user_def_through_ancestors` (`scope.rb:1396`),
  `singleton_def_through_ancestors` (`:1435`; #1567's singleton shape),
  `external_ancestor_name_candidates` (`:1469`), `discovered_method_through_ancestors?` (`:1517`), the
  override rules' `each_project_ancestor` (`check_rules.rb:3800`) behind `nearest_ancestor_visibility`
  (`:3837`) and `nearest_ancestor_method_def` (`:3931`), the visibility rule's prepend-region check
  (`:2664`, #1568), `SourceArity`'s levels (`source_arity.rb:109–129`, every hedge kept),
  `Reflection.ancestor_constant_scopes` (`constant_ancestors.rb:41–64`, #1571) and
  `ExpressionTyper#related_to_owner?` (`expression_typer.rb:2675`). `ResolutionChain#settle`
  (RC:146–158) is the one decision: `:chain` or `:master`.
  `spec/rigor/scope/ancestry_walker_detection_spec.rb` fails on any other method that reads two of the
  ten ancestry readers (`spec/support/ancestry_walker_scan.rb:13–17`), reads one in a loop or a
  recursive method, or reads the retro world itself (`:117–127`); 14 walkers remain, allow-listed with
  a reason (`:47–88`): eleven unions used only to withhold and three bridge walks over RBS-declared
  edges the tables do not carry, two of them first-definer walks outside the chain —
  `macro_block_self_type#singleton_extends_reach?` (`:157`; Ruby's singleton order for what it sees)
  and `rbs_dispatch#each_source_ancestor_candidate` (`method_dispatcher/rbs_dispatch.rb:861`;
  breadth-first, its `allowed_rbs_complete_ancestor` guard deferred to #1572).
- **Forks, and when the chain stands.** The tables hold the statements' final state, not the order they
  ran. The replay counts a *fork* wherever an entry reached the chain by a second route — an include
  skipped because the chain carries the module (RC:789–792), a prepend skipped in the prepend region
  (RC:757–760), or an entry of a prepended module's sub-chain the class already carries (RC:762); a
  direct prepend of the module itself forks nothing (the `modules.include?` test at RC:762), and a
  same-owner repeated `prepend` is dropped, first statement winning (RC:752). A fork whose second world
  is not "the insertion made anyway" settles to master without a retro world (`fork_without_retro`,
  RC:806–809). `settle` answers `:chain` on **no fork**; on **exactly one fork** that is an include-side
  skip at or after the class on the last entry of the sub-chain, it builds the retro world (the
  insertion made anyway, abandoned past 100 project entries, RC:601–609) and answers `:chain` only
  where the reader's block gives the same answer there; on **any other fork, or two or more**,
  `:master` without a retro world — more than two worlds exist and agreement between two proves
  nothing (the witness "two skips of which neither world reaches the definer Ruby calls",
  `spec/integration/resolution_chain_witness_spec.rb`). A singleton superclass that only `extend`s
  resolves as external and settles to master with the weight of two (RC:724–729).
- **Unsettled chains.** `Builder#mark_unsettled` (RC:698–701) marks a node when
  `DiscoveryIndex#unpositioned_mixins` lists anything on the side being linearised, or when its class
  is declared in two or more files (`discovered_class_sources`, seeded on every run since #1584) and has
  two or more edges on that side; the mark propagates to every chain that draws on the node (RC:547–552,
  636), so a concern's `included do include A end` edges taint every includer's **instance** chain
  transitively, and `settle` answers `:master` for an unsettled chain whatever its fork count (RC:151).
  What propagates is a boolean: `Frame` hands up `unsettled` beside the fork count (RC:547–552), the
  memo tuple stores it (RC:656), and an unsettled chain never builds its retro world (RC:573). The
  pinned shapes are `spec/integration/ruby_order_resolution_spec.rb:414–478`. On the singleton side the
  mark does not cross an include edge: an included module's `:extend`-side entries (a hook's `"*"`)
  are read only when that module's own singleton chain is built (RC:683–684), which no includer's
  singleton chain does, so `K`'s singleton chain in Context (d) stands with no fork and no mark while
  Ruby's carries `X`.
- **The lesson of #1593 and #1594: unsettled is not a decline.** An unsettled chain answers master's
  order, so a mark helps only where master's answer is right, and it can make a right chain wrong.
  #1594: a concern's `included do include A end` with `A` including `M#foo`, and `class C < Base;
  include Concern` with `Base#foo` — the chain alone is `[C, Concern, A, M, Base]`, no fork, and
  answers `M#foo` as Ruby does (Ruby's order is `[C, A, M, Concern, Base]`; the chain misplaces the
  concern but reaches the same first definer); the mark #1584 lists on the concern sends every includer
  to master's `Base#foo`, an error-level `call.undefined-method` on correct code (pre-existing: master
  before #1578 answered the same). #1593's first draft propagated a hook's `:extend` mark through the
  include closure to the includer's singleton chain; master's singleton walk is superclass-only, so the
  taint answered `Base.bar` for `class C < Base; extend A` with `A` including `M` — #1567's singleton
  false positive back — and still `Base.bar` for the hook shapes; it was withdrawn. The rule this ADR
  draws: **a mark is added only where master's order is shown right for the shape (WD7(g)); where it
  is wrong, the only sound tool is a migrated read's `Unknown` (WD2, WD3), and the existing readers
  keep master's false positive until the follow-up ADR models hooks per includer.**
- **`unpositioned_mixins`** (#1584; `discovery_index.rb:37`, classified `:set_valued` at `:116`) is
  `{owner => {include: [names], extend: [names]}}`, `:include` the instance side and `:extend` the
  singleton side. `ScopeIndexer::MixinAccumulator` lists an edge written anywhere but as a direct
  statement of the class's own body or its `class << self` body, in a declaration that is itself a
  direct statement (`direct_body`, MA:55–63; `note`, MA:101–106), and lists the sentinel `"*"` for a
  call the walk cannot record (`WILDCARD`, MA:35; `taint`, MA:109–111; a hook parameter's call through
  `with_hook_params`, MA:83–89); the rule and the consumer obligations are in `inference-engine.md:67`.
  **The list is only as complete as the walk that feeds it**: the instance walk descends into every
  child, so an `include` inside `[1].each { }` is recorded and listed, while the extend walk, until
  #1593, returned from a block it did not recognise without walking it, so the singleton side listed a
  direct-body statement's conditional edge, a method body's `extend`, and a hook's `"*"`, and nothing
  written in a block (#1592). **#1593 (landed 2026-10-01, narrowed three times in review)** records a
  block's `extend` or `class << self` mixin as a *positioned* edge only where the block provably runs
  at least once with `self` preserved, as a direct class-body statement (`runs_body_block_once?`,
  SI:6258; `literal_or_self?`, SI:6272) — `tap` / `then` on a literal receiver, a non-empty literal
  Array or Hash under `each` / `map` and kin, a positive Integer literal's `times`, a non-empty
  integer-literal Range — and records and lists nothing for every other block (`extends_block_plan`,
  SI:6216, `:skip`), so `items.each { extend X }`, a block inside a method and a concern's `included
  do extend X end` stay unrecorded and unlisted. What remains after #1593 is MA's rule for an opaque
  eval block (`block_mixes_in?`, SI:6003–6010): a block that holds a mixin call on the class's own
  `self` must at least list `"*"` (tracked by #1592).
- **Marked entries keep exactly master's declines and add none.** The sites in Context (e) are the only
  declines on `ENVELOPE_DYNAMIC_MARK`; #1578 preserved each (`ruby_order_resolution_spec.rb:215–235`).
  Typing through a marked entry is a known remainder, not a rule: on GitLab 1,730 entities carry the
  mark (Project, Group, User, Issue, MergeRequest among them), so 41–51 % of (class, name) pairs
  resolve at or beyond one; on Mastodon 4.7–7.6 %. Declining there would turn that share `Dynamic`.
- **Three name-resolution flavours** (RC:280, 339–349): `:methods` via `known_user_class?`,
  `:constants` via the declared namespaces, `:arity` via `SourceArity`'s predicate with #986's ambiguous
  names expanded. A bug fix does not unify them.
- **Dependency contract (ADR-46).** `search` records the root and every project entry ahead of the
  answer (RC:169–183); `settle` files every entry after the answer through `record_beyond`, with the
  negative class edge on a project entry's unqualified name and, for an external entry, only the sites
  of the names it can denote and **no negative edge** (RC:204–217, the `unless entry.external?` at
  RC:214); nothing more is filed when the root heads its own chain and answers itself (RC:206). A
  master answer records every class that order lists; `spec/rigor/analysis/unsettled_chain_incremental_spec.rb`
  pins warm equals cold. A per-consumer de-duplication of those edges is #1590.
- **What it leaves open, and this ADR does not reopen:** #1570 (a one-fork disagreement whose readers
  keep master's answer; `ruby_order_resolution_spec.rb:142–147` pins it with a "flip this when ADR-119
  PR C" comment), #1572 (an external definer ahead of a project one), #1573 (a repeated `extend`'s
  position), #1588 (`combine_rekeyed_entries`, SI:8819, merges a re-keyed class's includes in the wrong
  order), #1589 (CRuby's trailing duplicate from prepend propagation), #1590, #1591 (the 21.3 %),
  #1592's unprovable-block and hook shapes, #1594 (WD3 states what a migrated read does meanwhile), and
  the two table gaps ADR-24 § "What the tables cannot express" records.

Where this ADR needs more than the tables hold — the position of a hook-driven or in-method edge, the
order of a multi-file class's edges, an edge that is only marked, a hook's singleton-side edge — it
declines or keeps master's answer rather than adding data. The one exception is what PR C computes
from data already there: which *names* an unpositioned edge's closure defines (WD2).

### WD1 — Storage: today's tables keep today's meaning; `possible` lives beside them

- Every existing member keeps exactly its current contents and semantics, the **union**
  (`certain ∪ possible`). Existing readers, raw reads and scalar derefs keep their meaning.
- **The mixin members need no sibling.** `unpositioned_mixins` lists, per side, every *recorded* edge
  of `discovered_includes`, `discovered_prepends` and `discovered_extends` whose presence or position is
  not a fact: an edge under control flow inside a body is listed (it is not a direct statement), so a
  *possible* mixin edge that the walk records is listed, and a listed edge that is certain (a top-level
  `Base.prepend(M)`) is only read more conservatively. The claim is about recorded edges: a
  singleton-side edge inside a block is in neither the member nor the list (#1592) — a fabricated
  *absence*, the ADR-5-unsafe direction, since the chain then stands without the module — and #1593
  closed it for provably-run blocks only (§ The chain); a hook's singleton-side edge is never recorded
  on the includer. WD3's obligation covers both at a migrated site; nothing covers them in an existing
  reader. v12's `position_unknown_*` triple is withdrawn for this member.
- **The definer members get siblings (landed, #1600).** `DiscoveryIndex::SIBLINGS`
  (`discovery_index.rb:81–88`) pairs each member designated to admit `possible` facts with its sibling:
  `discovered_methods` and `discovered_deferred_ranges` (set-valued) with `possible_discovered_methods`
  and `possible_discovered_deferred_ranges`, of the member's shape and `⊆ member` (a `discovered_methods`
  pair is `{class => {name => kind}}` with `:both`, `METHOD_KIND_BOTH`, `:178`); `discovered_def_nodes`,
  `discovered_singleton_def_nodes`, `discovered_method_visibilities` and
  `discovered_parameter_envelopes` (single-valued; the slot keeps today's fold) with a `contested_*`
  sibling, a Set of **key paths** into the member — `[class, name]`, and `[class, [kind, name]]` for an
  envelope — one per entry whose value depends on a `possible` fact, including an entry whose only
  definer is `possible`. Every sibling is empty until a producer admits a fact (C1), so every member
  keeps its meaning. Slots never hold a new wrapper.
- **Siblings always travel with their members (landed, #1600).** `DiscoveryIndex#with` (`:469–479`)
  raises on a member or sibling that arrives without its partner; `DiscoveryIndex.compact_pairs`
  (`:436–448`) drops a pair only when **both** halves are empty and **completes a half pair** with the
  empty value, so a non-empty sibling is never stranded by an empty member (the per-table `reject {
  empty? }` the seed had, `discovery_seed.rb:108–111`). The siblings ride as one `siblings:` sub-hash
  through the accumulator, the fold (`fold_siblings`, SI:7619), the compact-header rename
  (`rename_siblings`, SI:7645, which re-keys a class-keyed sibling with its member and leaves the
  path-keyed `possible_discovered_deferred_ranges` alone), `finalize_def_index` (SI:7926) and the ADR-85
  bundle (SI:7836, 7879). `spec/rigor/scope/discovery_sibling_pairing_spec.rb` round-trips all seven copy
  paths with non-empty siblings *and* with empty ones; the seed-bundle and snapshot schemas were bumped
  (`descriptor.rb:80`, `incremental_snapshot.rb:165`).
- **Admission precondition.** A member may admit `possible` facts only once (i) its pair round-trips
  (landed for all six) and (ii), for a single-valued member, every read the census records for it
  outside the table owners consults `contested_*` or goes through a `Scope` reader. The census is
  `spec/rigor/declaration_facts/admission_census_spec.rb` (#1566, `admission_census.yml`): per member,
  the files outside the owners that read or copy the whole table, and the files that read or copy
  every member at once — the slot-reader migration list, distinct from the chain's walker allow-list.
  Errata (2026-10-01): the census spec's header (`admission_census_spec.rb:14`) says a member admits
  `possible` facts "only once its entry here is empty", which contradicts (ii) — a whole-table read
  that only tests existence or identity, or keys a cache, is one WD2 allows, and #1600's paired copies
  are reads the census must keep listing — and the census has no field to record that a read consults
  `contested_*`. C1d0 adds a per-file `justified:` classification (an existence, identity or cache-key
  read WD2 allows; a paired copy of #1600's), moves value reads behind `Scope` readers, and rewords the
  header to (ii); Q12 asks the maintainer to confirm.
- **C1's storage obligations**, recorded here and not acceptance blockers: `discovered_def_sources` and
  `discovered_singleton_def_sources` (single-valued, first-wins) have no sibling — C1 adds one or states
  that they are read only beside `discovered_def_nodes`; whether an envelope table's project-wide key and
  its class marks (`ENVELOPE_MODULE_MARK`, `ENVELOPE_DYNAMIC_MARK`, `discovery_index.rb:213–214`) can be
  contested; the extends fold (`fold_extends_into_singleton_tables`, SI:6502) and `subtract_def_methods`
  (SI:7971) follow-through for a `possible` copy; and `possible_discovered_deferred_ranges`' path keys
  under the compact-header rename, which today leaves them alone.
  Errata (2026-10-08), C1d0 resolves each (PR #1617, lane 1, behaviour byte-identical):
  - *The two def-source tables carry no sibling.* They are site tables — dependency edges, positions and
    fingerprints — and no read takes a definer, visibility, arity or type from them; certainty does not move a
    site. Three reads decide from a site and are left to C1d, which must handle each: `Scope#same_file_top_level_def?`
    (`scope.rb:1164–1168`) and the #1097 pair `#singleton_def_shadows_call?` and `#instance_def_shadows_call?`
    (`scope.rb:1229–1260`, over `user_singleton_def_site_for` and `user_def_site_for`), where a conditional def's
    site would answer "shadows" for a definer decision. This corrects the draft's "read only beside
    `discovered_def_nodes`", which no census entry supports.
  - *Envelope marks are never contested.* `ENVELOPE_PROJECT_WIDE`, `ENVELOPE_MODULE_MARK` and
    `ENVELOPE_DYNAMIC_MARK` are presence facts that only decline a read; a contested envelope path is always
    `[class, [kind, name]]`.
  - *The extends fold follows its siblings* (`fold_extends_into_singleton_tables`, both sites: the per-file
    fold after the unpositioned union is settled, and `finalize_def_index`). A copy is *listed* when
    `unpositioned_mixins[class][:extend]` names the module as written or holds `"*"`. A slot the copy wrote
    (it was `nil`) is contested when the edge is listed or the source slot is contested; a slot another copy
    wrote stays that copy's. The singleton name is `possible` when the edge is listed or the source name is
    possible on the instance side, unless the singleton already answered it certainly, and the fold writes
    `:singleton` only, never `:both`, because the instance side is not touched. A certain copy removes
    `:singleton` from the name's possible kind (`:both` becomes `:instance`). So a value-only contest has a
    certain name (a contested source reached through a certain edge contests the slot and leaves the name
    certain), and a certain module after a possible one leaves the slot contested and the name certain. The
    per-file path copies the seed's tables on write, so what carries is the seed's siblings plus this file's
    additions less the names a certain copy settles; a seed slot the file's own `def` replaces keeps its
    contested mark, which over-contests and is safe, and letting the file win is C1d's refinement.
  - *`subtract_def_methods` follows its sibling.* The same drop applies to `possible_discovered_methods`
    (`subtract_sibling_methods!`) for the instance half only: `:instance` is removed, `:both` becomes
    `:singleton` and `:singleton` stays, because a def is the instance side and the member keeps the name's
    singleton half. That keeps the sibling a subset of its member, and a conditional singleton extend over a
    class that defines the name keeps it possible. It is not `subtract_def_methods`'s rule, which drops a
    singleton-only member entry too.
  - *The deferred-ranges sibling is not admitted until C2.* `possible_discovered_deferred_ranges` is keyed by
    path, so the compact-header rename leaves it alone as it leaves the member alone, and no producer fills
    it before C2's typing sites need it.
  - *The rename skip is behaviourally indistinguishable today.* A path key is never a compact class name, so
    `rename_siblings` leaves `possible_discovered_deferred_ranges` alone whether `SIBLINGS_KEYED_BY_PATH` skips
    it or the Hash arm re-keys it, and neither arm rewrites a row's class name. The earlier compact-header
    example pinned nothing about the skip; it now pins that the sibling's rows keep the class name the member's
    rows keep, and the constant documents intent until a path-keyed sibling can hold a key the rename would
    change.

### WD2 — Candidate-set reads over the chain

A read that answers a question about a member — definer, visibility, arity, type, or which ancestor —
is defined over the chain, and asks `settle`:

- **The internal API.** `Rigor::Inference::DefinerResolution.resolve(scope, class_name, method_name,
  side, question:, from: 0, &answer_in)` is the candidate-set read (errata 2026-10-01: `from:` and the
  block were under-specified). `from:` is the chain index the read starts at — `0` for a definer read,
  the position after the class for the override rules' walk (`each_project_ancestor`), a level's start
  for `SourceArity` — and `answer_in` is the per-chain answer function: given a chain and a start, it
  computes the question's answer over that world (a level's agreed envelope, a visibility, the nearest
  definer), so `settle`'s block applies the same function to the retro world and the override rules
  can place an RBS-declared parent in it. It is not a `Scope` method, so the pinned public surface is
  unchanged. It returns `Known(answer, owner)` — `answer` keyed by the question: a `[node, owner]`
  pair for `:definer`, a visibility for `:visibility`, an envelope for `:arity`, so candidates that
  agree on the answer but differ in node are still `Known`; `owner` the entry that answered, for the
  diagnostic's text —, `Unknown`, or `Absent`. A result is consumed only by
  an exhaustive `case/in` in the same method, with an arm for each of the three and **no `else` or `in
  _` arm** that could fold `Unknown` into a firing arm; it is never stored, returned or truth-tested
  (`Absent` and `Unknown` are both truthy). PR C adds the spec that enforces this syntactically at
  every call site; every site this ADR's PRs do not migrate reads through the existing readers.
- **`settle` stays the single decision.** PR C gives `settle` a caller-supplied option (the migrated
  read passes it; existing readers do not) under which (i) a `:master` verdict becomes `:unknown`, and
  (ii) an unsettled mark is discharged per name by the relevance rule below. No reader reads the fork
  count, the retro world, the marks or the unpositioned table itself; the detection spec's guard
  (`ancestry_walker_detection_spec.rb:117–127`) extends to the option's inputs. Verdict (i) needs no
  new data of any kind: #1570 and the conditional-include arity shape stop firing at `SourceArity`'s
  decision point on the boolean the chain already carries.
- **Worlds and candidates.** On `:chain` the read walks the chain and collects the **candidate set**:
  the first definer and, while that definer is `possible` (a `contested_*` key or a `possible_*`
  entry), the next; *absent* joins the set when nothing follows. For a retro-eligible fork the candidate
  set is the answer `settle`'s block computes in the retro world, so the chain stands only where both
  worlds give the same set. The read answers `Known` when every candidate gives the same answer to the
  question asked, `Unknown` otherwise. The set is linear in the number of `possible` definers on the
  path, so **v12's cap of four is retired**: no world of edges is ever enumerated.
- **The marks (PR C's chain-memo change).** Relevance needs what marked a chain, and the chain does
  not carry it: `Frame` hands up a boolean and `settle` returns on it (RC:547–552, 151). PR C makes
  `Frame` and the memo tuple (RC:656) carry the **marks** — per marking node: the side, each named
  entry listed for it (`"*"` included), and whether the multi-file rule fired — and keeps `unsettled?`
  as the boolean the existing readers see (RC:127). A chain narrows for a name only when **every** mark
  on it, its own node's and every drawn-on node's, is discharged for that name. Errata (2026-10-01):
  a mark is discharged only on a fork-free chain (below), so a discharged chain has no retro world to
  build; the on-demand `build_retro` (RC:573, 601–609) this bullet named is unreachable under the rule
  as decided and belongs only to a Q10 relaxation. This changes no discovery table; it grows the chain
  memo, and WD7(d) names its cost.
- **Per-name relevance (the narrowing of `unsettled`, #1591).** A mark is discharged for the queried
  name only on a chain with **no fork**. Two kinds of mark, two rules:
  - **A named entry** `Q` listed on node `N`'s side (`Q ≠ "*"`) is discharged for name `n` when `Q`'s
    **closure** — every entry of `Q`'s own instance chain, memoised — satisfies all of: (i) every
    entry is a project entry, or an external entry that RBS knows and whose declaration lacks `n`
    (`Rigor::Reflection.rbs_class_known?` and `instance_method_definition(...).nil?`,
    `lib/rigor/reflection.rb:71, 386`, the test `SourceArity#external_mixin_lacks_method?` already
    applies, `source_arity.rb:269`); (ii) no project entry carries the dynamic mark
    (`DiscoveryIndex.rewritten_surface?` over `parameter_envelopes_of`, as `dynamic_surface?` at
    `source_arity.rb:244`), lists `"*"` on the side read, or records `method_missing`
    (`discovered_method?(…, :method_missing, :instance)`, as `check_rules.rb:1513`); (iii) no project
    entry records `n` in `discovered_methods` (either kind, over the union) **or in
    `discovered_method_visibilities`** — a visibility-only statement such as `private :to_s` is
    recorded in the second table only and moves the answer to the `:visibility` question. Under (i)
    and (ii) `include Ext if …` with `Ext` undeclared and `include U if …` with `U`'s methods from a
    `define_method` loop are not discharged; master fires on `C.new.foo.upcase` in both.
  - **A multi-file mark** on node `N` (two or more files, two or more edges on the side read) names no
    entry: it is discharged for `n` when at most **one** of `N`'s edges' closures records `n`, where a
    closure that fails (i) or (ii) counts as recording `n`.
  - `"*"` is never discharged; a chain with a fork is never narrowed; a discharged mark still records
    the closure's edges (below). The argument, to be witnessed and not yet: with no fork, every entry
    reached the chain by one route, so an unpositioned module's presence, absence or position adds or
    removes only its own closure's entries and moves no other entry's first occurrence; a closure that
    cannot answer `n` therefore cannot move the first definer of `n`.
  - **Why the rule stops at a fork.** The single-route argument is stated for the fork-free case only,
    and this ADR makes no argument for a one-fork chain either way; the two-fork shape of the earlier
    drafts (`include M; include X; include Z` over a `Base` including `M`, Ruby answering `W` or `X` by
    load order) is `:master` before any mark is read and decides nothing here. **PR C's discriminating
    witness** is `class C < Base; include M; include X; include Q if ENV["Q"]; end` with `Base`
    including `M`, `M#foo`, `X#foo`, `Base#foo` and `Q#bar` only: one retro-eligible fork on `M`, one
    irrelevant mark, chain `[C, Q, X, Base, M]` unsettled, and Ruby answers `X#foo` in all four worlds
    (both load orders, `Q` present or absent) — the read stays `Unknown`, pinned as this clause's
    deliberate decline with a "flip this if relevance is extended to one-fork chains" comment. Its
    sibling without `X` (Ruby `Base#foo` or `M#foo` by load order, in both `Q`-worlds) stays
    `Unknown` by this clause too — a forked chain is never narrowed, so no retro comparison runs — and
    is kept as the guard of a future Q10 relaxation, under which the fork rule must still answer
    `Unknown` there (errata 2026-10-01: today it does not distinguish the two rules).
    GitLab's Project, Group and User carry forks from hook-duplicated includes (inferred from v12's
    skip counts), so they stay `Unknown` at migrated sites until the follow-up ADR.
- **Marked entries.** A chain entry carrying the dynamic mark keeps exactly master's declines (§ The
  chain) and adds none.
- **The absent candidate** (typing sites and relationship lints only; `SourceArity` is silent on
  *absent* already). *Absent* is dropped only when **no RBS Rigor loads — the project `sig/`,
  plugin-synthesised RBS, and the RBS of every external entry in the chain — declares a method of that
  name for the receiver's RBS ancestors, `Object` included, and none of them declares `method_missing`
  or `respond_to_missing?`**. An external entry RBS does not know counts as defining the name, and the
  read is `Unknown`. Otherwise the external definer is a candidate with its RBS signature as its answer
  (`Object#to_s` disagrees with `M#to_s(fmt)`: `Unknown`; `Enumerable#to_a` is the first definer,
  #1572). For the two override lints, *absent* always counts.
- **The `SourceArity` differential (cross-commit; landed, #1599).** `SourceArity` — its level rule
  and its eight hedges: `load_order_dependent?` (`source_arity.rb:168`), `object_extension_may_shadow?`
  (`:178`), and under `clean_level?` (`:239–242`) `dynamic_surface?` (`:244`), `project_patched?`
  (`:248`) and `external_mixin_lacks_method?` (`:269`), then `public_at?` (`:278`),
  `chain_free_of_hooks?` (`:285`) and `subclasses_agree?` (`:301`) — is compared across **two
  commits**, not against an in-tree oracle flag: a frozen copy of the rule would still read the live
  scope, chain and tables the change moves and agree with it by construction. `tool/engine_diag_diff.rb`
  archives the merge-base engine and the head engine whole, runs each in a fresh process over the same
  corpus, and prints the `call.wrong-arity` rows the head removed and added. The firings after a change
  must be a subset of the base's; a firing outside that set is allowed only for a mechanism the PR names
  and a fixture witnesses. **Each difference is adjudicated** in
  `spec/integration/fixtures/arity_differential/arity_adjudication.yml` — a removed row as
  `fp-silenced` or `tp-lost`, an added row only as `named-mechanism`; each entry carries the merge-base
  sha it was written against (`base:`), so only the entries for the current merge base adjudicate or
  count as stale (an entry matching no row fails the run), entries for another base are listed as
  ignored and go dormant once their PR merges, and a rebase updates `base` — with the count of each
  verdict in the PR. The fixture directory holds the shapes C1 is meant to silence (#1570's `C.new.foo`
  call, a conditional `def`, a conditional `include`), two controls it must keep (#1570's `E.new.foo(1)`
  and the literal surface, which the survivors' floor does not cover), and `survivors/`, five plain
  firings that are real arity errors under Ruby: the floor (`--require-rows-in survivors/:5`) counts
  them in the base **and** the head, and an adjudication entry under a floored path fails whatever its
  verdict, so what the floor protects cannot be adjudicated away. Errata (2026-10-01): the conditional
  `def` and `include` fixtures guard on `RUBY_VERSION > "3"`, which is true under the suite's Ruby 4.0,
  so both calls raise `ArgumentError` there and C1's silencing of them is adjudicated `tp-lost` by
  design — the price of a `possible` definer, not a false positive fixed; and all 10 base rows come from
  `arity_differential/` (verified with master's engine: the five survivors, the three shapes and the two
  controls), `declaration_witness/` contributing no `call.wrong-arity` row. CI's `arity-differential`
  job (`.github/workflows/ci.yml:818–848`) runs it on every PR that changes code, over both directories;
  the lane-2 corpus run is the same command with the survey checkouts (`docs/agents/measurement.md:54`).
  Declining on an unsettled
  chain removes coverage on a fifth of a Rails app's reads (#1591), and the ADR accepts that only against
  the adjudicated count.
- **Conditional definers.** A `def` inside control flow, a method body, or a block **other than the
  immediately-evaluated meta-new blocks Rigor already treats as class bodies** — the constant-write
  forms `K = Class.new`/`Module.new`/`Struct.new`/`Data.define do … end` (`meta_new_block_split`,
  SI:3797; `meta_new_constant_rvalue?`, SI:8882) and the bare-factory blocks the walk recognises
  (`AnonymousMetaClass.block_form_receiver`, `lib/rigor/inference/anonymous_meta_class.rb:42`), whose
  certainty is that of the enclosing statement — is a `possible` definer: its slot in the def-node
  tables, its visibility and its parameter envelope (`Scope#parameter_envelopes_of`, `scope.rb:1737`)
  are contested. `class_methods`, `included`, `prepended`, `helpers` and `class_eval` blocks stay
  `possible` until the follow-up ADR positions them.
- **Existence reads.** A boolean read used positively (`discovered_method?` at `check_rules.rb:951`,
  `known_user_class?`, `published_constant?`) answers over the union, withholding by construction; a
  presence test on a reader's result answers in the reader's order (the seven probes #1578 left
  unchanged, `resolution_chain_existence_spec.rb`); a negated or compared boolean read
  (`singleton_context_def?`, `check_rules.rb:3671–3673`) becomes a candidate-set read in PR C.
- **ADR-46 recording.** A candidate-set read records what `search` and `settle` record — the class edges
  of every entry on the chain, the closures relevance tests included — and relevance adds, for each
  closure entry it tests, the negative method edge on `Owner#name` (`DependencyRecorder.read_missing(:method,
  …)`, as `SourceArity#settle_by_definitions` files it, `source_arity.rb:86`), because
  `Scope#discovered_method?` (`scope.rb:1048–1054`) records nothing itself, **and, for each external
  closure entry it tests, the negative class edge on the unqualified name of its spelling**
  (`read_missing(:class, …)`, which `record_beyond` files for a project entry and by design not for an
  external one, RC:214), so a new file declaring `module Ext` re-checks the consumer; the over-trigger
  on an unrelated `Admin::Ext` is the price, paid on unsettled chains only.
- Cost: on a standing chain with no `possible` definer the read costs one memoised chain plus the
  `settle` it already pays; relevance costs, on unsettled chains only, the memoised closure of each
  named entry and, per closure entry, three table probes, the dynamic-mark test and, for an external,
  one RBS lookup. The constant tables admit no `possible` facts in this ADR.

### WD3 — What is certain

A fact is `certain` when its statement executes whenever the file's top level executes: reachable
through `class`, `module` and `class << self` bodies alone, with no enclosing control flow, block,
method body, `rescue`/`else`/`ensure` clause or `BEGIN`/`END`; the meta-new blocks named in WD2 count as
bodies. Everything else is `possible`. A reopening whose `class` keyword sits inside a conditional makes
its statements `possible` however many other definitions exist. An unconditional `include` in a `class
<< self` body is a `certain` singleton-side edge. Certainty and position are two questions:
`unpositioned_mixins` answers the second for edges, WD3 the first for definers, and the mixin edges need
only the second (WD1). **The extends fold stays in this ADR**: both sites (SI:410, 7940) copy with `||=`
(SI:6512); a copy through a `possible` extend edge — `extend X if …`, `class << self; include X if …`,
`def self.setup; extend X; end` — marks the key contested. **Deferred to a follow-up ADR**: hook facts
instantiated per includer (PHPStan's trait model, <https://phpstan.org/blog/how-phpstan-analyses-traits>).
Today every walker treats `included do` and `class_methods do` as ordinary calls under the concern's
own owner; `SyntheticMethodScanner` replays `included do` macro calls only
(`synthetic_method_scanner.rb:336`); `ModelDiscoverer` descends into `included do` for overrides
(`model_discoverer.rb:471, 518`). The follow-up owns the precedence rules probed on ActiveSupport
8.1.3 (`extend X; include M` resolves to `M::ClassMethods`, the reverse to `X`; `prepend M` beats the
includer's own `def self.build`), the incremental closure, the ADR-89 signature and the fold's
def-source rows. **Until then, the hook obligation is two-sided, and on neither side is a mark
enough.** On the instance side a hook edge is listed on the concern and every includer's chain is
unsettled (§ The chain), which keeps master's answer — wrong wherever the hook's module defines the
name (#1594); only a migrated read's `Unknown` is sound there, and existing readers keep master's
false positive until the follow-up ADR. On the singleton side a hook's edge — `included do extend X
end`, `class_methods do`, `base.extend(X)` in a hook — is recorded on no includer, no mark reaches the
includer's singleton chain, and master's superclass-only singleton walk does not see it either
(#1592), so no chain state can carry it. **A migrated singleton-side read therefore declines by the
closure, not the chain** (superseded: the errata below makes the decline positional): it answers
`Unknown` when any module on the receiver's **instance chain**
(its own and its superclasses' includes and prepends, so a concern on `ApplicationRecord` counts for
every model) lists anything on its own `:extend` side (a hook's `"*"`), records a singleton `included`,
`extended`, `prepended` or `inherited` def (`extended` and `inherited` are redundant with the `"*"` a
hook's mixin call already lists, and harmless), or extends `ActiveSupport::Concern` — the concern
shape's only signal, a framework name the follow-up ADR moves behind the plugin API.
Existing readers keep master's singleton answer, and #1592's hook shapes stay a false positive there
until the follow-up ADR. With #1593 landed, a singleton-side migration in PR C may proceed; a block
the walk still cannot vouch for stays unrecorded and unlisted, which no read-side signal detects (§ The
chain's remaining obligation).

**Errata (2026-10-08), PR C2-a: the singleton-side decline is positional.** This supersedes the closure
decline above (and the matching Consequences bullet); `Inference::SingletonHookDecline` implements it,
`spec/integration/definer_resolution_witness_spec.rb` § "the singleton side" witnesses it, each fixture
beside Ruby's `singleton_class.ancestors` and `Method#owner`. Ruby's `C.singleton_class.ancestors` is
`#<Class:C>`, `C`'s extends (the last `extend` nearest), `#<Class:Base>`, `Base`'s extends, and so on,
an external superclass contributing its whole tail. A hook reaches `K`'s singleton chain in two ways
only: (U1) `K.extend(X)`, `class_methods do`, a concern's `ClassMethods` insert `X` after `#<Class:K>`
and before `#<Class:K.superclass>`; (U2) `included do def self.x end`, `define_singleton_method` and
`singleton_class.class_eval` define on `#<Class:K>` itself. So a hook of level `i` cannot move a definer at
or before the level's head, and a definer found at `#<Class:K_j>`, written in `K_j`'s own body, is immune
to every hook of levels `j` and deeper.

- **The read.** On a chain `settle` lets stand, the last candidate's *bound* is its index when it is
  `#<Class:K_j>` and its `def`'s recorded nesting starts with `K_j`, one past it otherwise (an extended
  module's entry, a `def` written in a reopening block), and the chain's length when nothing answers.
  The levels tested are those that start before the bound and do not end before `from`. The read is
  `Unknown` when a tested level's own instance level (`K_i`, its prepends and includes with their
  closures: the first level of `K_i`'s instance chain) or its singleton segment (`#<Class:K_i>` and its
  extends' closures) holds a *hook-capable* entry, or when a level deeper than the shallowest tested
  level is hook-capable by the same test, since its `inherited` defines on every subclass's singleton
  and need not be its class's own `def` (a concern's `class_methods do def inherited`, a hook extending
  the class with a module that defines it, `define_singleton_method(:inherited)`). An external
  superclass deeper than that is hook-capable unless RBS knows it: its `inherited` is unknown by
  construction. (The first draft argued this from `class_attribute`; ActiveSupport 8.1's writer
  redefines `__class_attr_<name>`, not the public name, so that argument does not hold. A
  plugin-declared exemption for a framework superclass whose `inherited` defines nothing public is the
  future narrowing.)
- **Hook-capable.** A project entry, or a declared module the chain holds as external (a candidate of
  its spelling is a `discovered_class_sources`, `discovered_classes`, `discovered_includes` or
  `discovered_extends` key; an ambiguous spelling tests every declared candidate, any capable one
  declining), that lists `"*"` on either side, records `included`, `extended`, `prepended`, `inherited`,
  `append_features`, `extend_object` or `prepend_features` on either side or as an envelope key (a
  module's instance `def inherited` is a hook once extended; `singleton_class.define_method(:inherited)`
  is recorded as an instance method and `define_singleton_method(:inherited)` only as an opaque
  envelope), or extends `ActiveSupport::Concern`; and an undeclared external RBS does not know. An RBS-known external is
  clean (WD2(i)'s limit); the dynamic mark is not a hook signal.
- **Externals by side.** An external superclass entry stands for its whole tail and is tested with
  `Reflection.singleton_method_definition` (which reaches `Class`, `Module` and `Kernel`); an extended
  external module with `instance_method_definition`; the implicit tail after a project last superclass
  as `Object`'s singleton side.
- **Fold copies.** The extends fold (`fold_extends_into_singleton_tables`) copies an extended module's
  `def` onto the class's singleton tables, so the class entry answers for it. That is not where Ruby
  finds the method: an entry between the class and the module (an RBS-known external that declares the
  name, a nearer module's include) answers first, and on #1607's fork the copy agrees across both
  worlds while Ruby's do not. A class entry whose `def` is the receiverless node the fold copied — its
  nesting head names a module of the same level's singleton segment and that module's instance table
  holds the same node — is therefore asked past, and the module answers at its own entry. A `def C.x`
  or `class << C; def x; end` written inside the module's body shares the nesting head but is the
  class's own; it is not a copy and declines with the next case. (The walk records such a `def C.x` as
  the module's instance method too, so the node identity alone does not tell it apart; its receiver
  does.) One whose
  nesting head names a module that level does not hold declines: the fold and the chain resolved the
  `extend`'s name differently (`extend X` inside `module A` with both `X` and `A::X` declared, where the
  fold copies the top-level `X`; and `extend ::X`, which the extends table records as `X` and the chain
  resolves to `A::X` — a chain mis-resolution of its own).
- **ADR-46.** Per tested project entry, its class edge and the negative class edge on its unqualified
  name; per tested external, its candidates' class edges and the negative class edge on its spelling's
  last segment. The verdicts do not depend on the name asked and are memoised per entry in the chain's
  flavor bucket with their edges, replayed while a recording is active.
- **Known remainders** (pinned, not fixed): `class << self; prepend P` is recorded as an `extend`, so
  `P` is invisible ahead of an own `def self.x` (§ The chain); a concern is capable for every name; an
  own `def self.x` is trusted against its own level's U2 hooks and same-class redefinitions — an
  `included do def self.x end` or a plain `def self.included(b) = b.define_singleton_method(:x)` run
  after it, a later `define_singleton_method(:x)`, `singleton_class.class_eval { def x }`,
  a singleton `alias_method` or `class << self; attr_accessor :x` (the owner is right, the body is
  shadowed); a `class Class; def inherited` monkeypatch is unseen; a superclass that only `extend`s adds two forks, so every read on its
  subclasses is `Unknown`, own `def self.x` included. A `def` in `class << self` records the nesting
  `["C"]` (#1305); if #1305 records `#<Class:C>`, such a def reads as not own, which declines more.
  `instance_eval { def x }` is not a remainder any more: C1d-a's certainty classifier records a `def` in a
  non-meta block as POSSIBLE, which contests the singleton slot, so the read declines.
- **Consequences.** Measured on Mastodon `af3596316` (`app`, `lib` and `config`, tables from
  `DiscoverySeed`, `:definer` reads): of 272 own `def self.x` reads (a project class's singleton `def`
  whose nesting head is the class), 1 is `Unknown` (`UserSettings::DSL.included`, whose own `"*"` mark
  `settle` never discharges) where the closure rule declined 112; of 437 inherited reads (a name a
  project superclass's own body defines, read on a subclass that does not), 366 are `Unknown` against
  346 under the closure rule. Testing deeper levels as tested levels accounts for 105 of them (247 when
  only a deeper class's own `inherited` counted), and the external-superclass clause for 14 more (352
  without it), on subclasses of superclasses RBS does not know there (`ActiveModel::Serializer`,
  `ActiveRecord::Base`, `Thor`).
- **The C1c row** (§ Migration): `singleton_context_def?` was retired for `Scope#singleton_class_body?`
  (a lexical fact no world varies), not migrated through `resolve`; C1c has no singleton-side read.
- **The C2 rows, from C2 planning:** (E1) C2 migrates only the typing call at `expression_typer.rb:2283`
  (`try_user_method_inference`), through a new memo; the existence reads (`:1638`, `:2127`) and the
  self-purity scan (`:3660`) stay on the union. (E2) The absent rule's RBS census is moot at the typing
  sites. (E5) The conditional-include pins are `tp-lost` by design, as WD2 adjudicated them for C1b.
  (E6) #1572's pending pin will pass at C2-b1, where the read is `Unknown`, which fixes nothing; Q5 and
  the C2 row are read that way. (E7) The conditional-definer shape moves only once C1d-a fills the
  siblings.

### WD4 — Classification of every `DiscoveryIndex` member, with structural checks (landed)

`DiscoveryIndex::MEMBER_CLASSES` (`discovery_index.rb:107–170`, #1566) puts each `Data.define` member
(`:13–59`; 46 today: `unpositioned_mixins` since #1584, the six siblings since #1600) in exactly one
of six classes with a one-line reason, and `spec/rigor/declaration_facts/member_classes_spec.rb` fails
on a member that is
unclassified or classified twice and checks each class's shape on a two-file fixture project. A table
added to the index must be classified in the same change.

| Class | Members | Shape check | Reference |
| --- | --- | --- | --- |
| `:set_valued` (may admit `possible_*`) | `discovered_classes`, `discovered_methods`, `discovered_refinements`, `discovered_global_write_census`, `discovered_includes`, `discovered_prepends`, `discovered_extends`, `unpositioned_mixins`, `discovered_class_sources`, `discovered_deferred_ranges`, `constant_sources`, `constant_writers`, `constant_shadowers`, `published_constant_names`, `local_constant_names`, `published_constant_alias_names`, `published_constant_ivars` | collections of names or rows; where the member admits `possible`, its sibling exists and every sibling entry is in the member | Ruby witness |
| `:single_valued` (may admit `contested_*`) | `discovered_def_nodes`, `discovered_singleton_def_nodes`, `discovered_def_sources`, `discovered_singleton_def_sources`, `discovered_method_visibilities`, `discovered_parameter_envelopes`, `discovered_superclasses`, `discovered_header_nestings`, `data_member_layouts`, `struct_member_layouts` | a slot kind recorded per member, no certainty wrapper; where the member admits `contested_*`, the sibling exists and its keys ⊆ member keys | Ruby witness (`source_location` for def identity) |
| `:typed` | `declared_types`, `class_ivars`, `class_cvars`, `program_globals`, `program_global_seeds`, `in_source_constants`, `param_inferred_types` | every leaf is a `Rigor::Type` value | The type lattice |
| `:syntactic` | `discovered_def_nestings`, `patched_line_readers`, `clears_last_status`, `defines_case_equality`, `implicit_self_evidence` | the same value from the file's parse alone (the ADR-53 shadow harness stays for these) | The parse |
| `:run_state` | `run_generation` | an opaque token only the runner's seed supplies | None |
| `:sibling` (landed, #1600) | `possible_discovered_methods`, `possible_discovered_deferred_ranges`, `contested_discovered_def_nodes`, `contested_discovered_singleton_def_nodes`, `contested_discovered_method_visibilities`, `contested_discovered_parameter_envelopes` | `possible_*` has its member's shape and every entry is in the member; `contested_*` is a Set of key paths that resolve in the member (`spec/support/declaration_member_shapes.rb:48–80`), checked against injected values while no producer fills one | Its member's |

A sibling exists **iff its member is declared in `DiscoveryIndex::SIBLINGS`** — designated to admit
`possible` facts, whether or not a producer fills it yet — and the shape check gates the key-path form:
`[class, name]`, and `[class, [kind, name]]` for an envelope, each resolving in the member.

### WD5 — The witness, at two levels

- **Table level** (landed, #1566: `spec/support/declaration_witness.rb`, fixtures under
  `spec/integration/fixtures/declaration_witness/`, `witness_spec.rb`). A fixture runs under the suite's
  Ruby and records nesting, methods by side and visibility with `source_location`, mixins, superclass
  and class-variable classes, compared with the index `ScopeIndexer.index` (SI:103) builds. A set-valued
  table must satisfy `certain ⊆ runtime ⊆ certain ∪ possible`, a single-valued one must agree wherever
  it answers. Since no `possible_*` table exists yet, every entry reads as `certain` except the
  self-extend edge Ruby does not show. `issue_1518`, `issue_1519`, `issue_1520` and `issue_1550` are
  `pending` beside a pin of today's exact violations (`witness_spec.rb:75–119`), and so is
  `issue_1573` since #1597 (`:131–140`). #1592's block shapes are the relation's `runtime ⊄ certain ∪
  possible` case that no fixture held; #1593 added its block shapes at the read level
  (`ruby_order_resolution_spec.rb:588`) and pinned the hook shapes at their false positive
  (`:718–735`).
- **Read level** (landed, #1578: `spec/integration/resolution_chain_witness_spec.rb`, 21 fixtures, and
  `spec/integration/ruby_order_resolution_spec.rb`). Each fixture runs under the Flake Ruby in a
  subprocess and reports `Method#owner`, `source_location` and `Module#ancestors`; the chain's project
  entries, its first definer and its `super` chain are compared, in the skip world or the retro world
  the fixture names. This is the only witness for the chain, the fork rule and the unsettled rule, whose
  tables are correct while the reads are wrong. Since #1597 the open issues are pinned here too, each
  `pending` on its fix, with Ruby's answer from a `RubyRun` subprocess under a timeout
  (`spec/support/ruby_run.rb`): #1570 as a diagnostic that flips with C1b
  (`ruby_order_resolution_spec.rb:198–209`), #1572 as a diagnostic with its own fix (`:751–790`), #1573
  at the table (above) and the read (`resolution_chain_witness_spec.rb:875–925`), the lane-2 producer
  fix, and #1594 as a diagnostic under an `ActiveSupport::Concern` shim that flips with C2
  (`:796–843`). **PR C adds** fixtures for every candidate-set rule: the
  relevance rule's positive shapes for both kinds of mark, its five non-discharge shapes (an external
  closure entry RBS does not know, a dynamic-surfaced closure entry, a visibility-only statement, a
  `method_missing`, and a `"*"`), the one-fork witness and its guard, #1594 at a migrated instance-side
  site, WD3's three singleton-side signals, a conditional definer, the absent rule, and the flips of
  #1597's pins: #1570's in C1b, #1594's in C2 (errata 2026-10-01; the #1594 pin names C2, the #1570 pin says C1 and is reworded to C1b when C1b lands).
- A fixture must fail on `master` before its fix. **Limit:** one run witnesses one execution; "every
  world" is approximated by fixture variants that take each branch, and a fabricated `certain` fact is
  caught only where a variant's run lacks it. The fuzzer stays local until its load rate on the
  constructs that matter (2–7 %) exceeds 50 %.

### WD6 — The producer tripwire (landed)

`spec/rigor/declaration_facts/producers_spec.rb` (#1566) parses every Ruby file under `lib/` and
`plugins/*/lib/` with Prism and lists each method, or class or module body, that (i) references a
declaration node class or its `Prism::Visitor` hook, (ii) names a node-type symbol, (iii) names a
visibility or mixin keyword as a symbol, or (iv) reads a constant built from one (`CLASS_BODY_NODES`,
SI:4115); or (v) is reachable, through same-file calls, from `ScopeIndexer.index` (SI:103),
`.accumulate_project_index` (SI:7986), `.finalize_def_index` (SI:7926), a multi-file entry point or any
method another covered file calls as `ScopeIndexer.x`, and writes into a table parameter; or (vi)
includes `DeclarationWalk::Collector`. Rule (v) is what marks the bug sites rules i–iv miss
(SI:4984, 4972, 6502, 6907). `producers.yml`
holds 393 entries in 71 files: 371 `grandfathered`, a closed list pinned by count and digest, and 22
justified since. A new producer must be recorded with a reason; `RIGOR_REGENERATE_GATES=1` adds it as
`TODO`, which the spec rejects until it is justified. What the scan cannot see is in the spec's header
(`producers_spec.rb:20–22`); nor does it see a producer that returns from a node without walking it
(the extend walk's block return, #1592), which only a witness catches.

### WD7 — Landing rules

Two lanes. Neither lane's list is sufficient: the review loop of `docs/agents/contribution-flow.md`
applies to every PR, and no listed gate may be skipped or replaced by a claim.

- **Lane 1 — behaviour-preserving changes** (refactors, ports onto `DeclarationWalk`, new data nothing
  reads, performance and allocation work, deleting a `RULE_VARIANTS` entry the walk's rule reproduces):
  byte-identical corpus diagnostics, byte-identical corpus `rigor sig-gen` output, the shadow harness
  wherever a table is rebuilt, the per-merge allocation sweep. A port may not change a fact. #1584
  (+0.03 % allocations), #1598 and #1600 landed under this lane.
- **Lane 2 — behaviour changes** to declaration facts or to how a read answers, in a `ScopeIndexer`
  walker, a `DeclarationWalk` collector, `ModuleFunctionState`, the fold, `ResolutionChain`, sig-gen,
  Effects, a plugin discoverer or a `Scope` reader, and deleting a `RULE_VARIANTS` entry whose variant
  was a bug. Necessary, not sufficient: (a) a reproduced bug's WD5 fixture fails before and passes
  after; (b) the corpus diagnostics diff **and** the corpus sig-gen diff, every changed line adjudicated
  under the false-positive rule (`visibility_excludes?` hides visibility changes from diagnostics,
  `generator.rb:732, 907`); (c) neither byte-identity to a predecessor nor a variant is claimed; (d) the
  per-merge allocation sweep runs and its answer is in the PR, on a plain **and** a recording run —
  errata (2026-10-01): `tool/engine_alloc_ab.rb` measures a plain `rigor check --no-cache` only (its
  options are `--base`, `--head`, `--corpus`, `--target`, `--thresholds`, `--summary`), so until it
  gains a mode the recording run is measured by its method by hand: each engine archived whole, a cold
  `rigor check --incremental` over the same frozen corpus in a fresh process, counting
  `GC.stat(:total_allocated_objects)`, as #1578 reported it — and a change to the chain memo's tuple
  (WD2's marks) reports the memo's growth separately from the recording edges; (e) for any change that can add or remove a `call.wrong-arity`
  firing, the cross-commit differential (WD2): CI's `arity-differential` job green, every removed row
  adjudicated `fp-silenced` or `tp-lost` and every added row `named-mechanism` under the PR's merge
  base, the survivors' floor held in base and head, and the lane-2 corpus run's adjudication in the PR;
  (f) a change that can widen a
  read to `Dynamic` reports, over the lane-2 corpus, the change in the (class, name) census of reads
  answering `Dynamic` taken from `rigor check --no-cache`'s own scopes (an instrumented run, since
  `rigor coverage` seeds from `DiscoverySeed.discovery_tables`, `lib/rigor/cli/coverage_scan.rb:60`,
  and `rigor type-of` reads every cross-file declaration as `Dynamic[top]`,
  `docs/agents/measurement.md:60–65`), with `rigor coverage`'s `dynamic_specific` / `dynamic_top` tiers
  (`coverage_command.rb:38–39`) as a secondary figure; (g) **from this ADR on**, a change that adds an
  unsettled mark or a taint shows on a fixture that master's answer is right where the mark sends the
  reader — #1584's concern mark had no such gate and fails it at #1594's shape, and #1593's first
  draft failed it at #1567's (§ The chain). #1578 landed under this lane with (a)–(f); #1593 landed
  under it, (g) included.

### What each part removes, and what remains

| Failure mode | Removed by | Remains |
| --- | --- | --- |
| 1 Prose enumeration | WD4 (members `Data.define`-derived, shape-checked; landed); WD6 (producers parsed; landed); WD1 (copy paths paired; slot readers censused, landed); the chain's detection spec (landed; the `case/in` discipline checked syntactically in PR C) | Grandfathered producers, walkers and slot readers converge as bugs are filed; the patterns are themselves stated lists; a walk that returns without descending is invisible to the tripwire (#1592) |
| 2 Variants by reading; vacuous sweeps | WD1 + WD7(c): no variants; a disagreement is a fixture or nothing; WD5 at both levels (landed) | Unknown constructs are found by users; one run witnesses one execution |
| 3 Several implementations of one question | `module_function`: one helper (#1563); resolution order: one chain inside every engine reader (#1578) | The helper preserves four semantics until PRs B–C; the allow-listed union walks and two RBS-interleaving first-definer bridges stay by design; concern hooks wait for the follow-up ADR |
| 4 Byte-identity to wrong legacy | WD1 + WD2 + WD7: over-approximation is legal only as `possible`; a migrated read answers from no `possible` definer, no unpositioned edge and no unsettled or forked chain; a marked entry keeps master's declines | A fabricated `certain` fact no fixture covers stays until reported; a hook's edge on either side is a false positive in every existing reader until the follow-up ADR (#1592, #1594); typing through marked entries stays as on master, 41–51 % of GitLab's pairs; unmigrated readers keep master's answer on 21.3 % of Mastodon's reads |
| 5 Shifting justification | WD7: two lanes with fixed, necessary gates (#1584 and #1578 landed under them) | Triage decides what counts as reproduced |

## Migration

**Landed before acceptance.** #1551 (lane 1); #1563 (lane 1); #1566 (lane 1; the four gates); #1584
(lane 1; `unpositioned_mixins`, `discovered_class_sources` on every run, the signature carrying mixin
order); #1578 (lane 2; the chain, `settle`, `MasterOrder`, the walker allow-list, the read-level
witness); #1593 (lane 2; the provably-run block shapes, § The chain); #1597 (the witness fixtures for
#1570, #1572, #1573 and #1594, `pending` on their fixes); #1598 (lane 1; #1548 closed by re-walking a
seeded file's deferred ranges, SI:344–350); #1600 (lane 1; WD1's sibling pairs, every sibling empty);
#1599 (the cross-commit arity differential, its fixtures and its CI job). **Still to land before
acceptance:** nothing remains. #1531 closes as superseded by this ADR.

**After acceptance — under WD7's lanes (each row names its lane). The C1 split below was adopted at C1
planning (errata 2026-10-01); C1a lands relevance so it is live at the first firing site, as Q3 decided.**

| PR | Change | Expected corpus diff | Expected sig-gen diff | False-positive check |
| --- | --- | --- | --- | --- |
| A — #1550 | The named form snapshots the last receiverless `def` before the call (SI:4975) | Zero (rare) | The singleton keeps the earlier body's type | Fixture asserts `Fmt.label == "one"` |
| B — reset, receiverless-only, privatisation | A bare visibility call ends the toggle; `def self.x` gets no instance copy; `attr_reader` private, no singleton copy; `define_method` both; a `certain` module function's instance copy recorded private (SI:6556–6563); sig-gen bypasses `visibility_excludes?` for module functions | Zero on existence; `Helpers#fmt` stops firing | Module functions after a reset stop rendering as singletons; omitted ones appear | Probes P1–P13, `vis.rb` |
| C1a — the read and relevance (lane 1) | `DefinerResolution.resolve(…, from:, &answer_in)` with `Known(answer, owner)`; `settle`'s option (the `:unknown` verdict, per-name relevance over the marks the chain memo now carries); the `case/in` spec. No site consults it yet, so no diagnostic moves; relevance is live from the first firing site (Q3) | None | None | WD5's relevance fixtures; WD7(d) on the memo |
| C1b — `SourceArity` (lane 2) | Both settles at the arity rule's decision points: `walk_to_owner` (`source_arity.rb:109–129`) **and** `subclass_levels` (`:315–320`, the per-subclass level `subclasses_agree?` reads), each answering no envelope on `:unknown`, the walk's reads recorded as read since another file's edit can lift it; `MasterOrder.arity_levels` (RC:421) is then dead and removed; the #1570 pin flips; the `issue_1570_skipped_include.rb` header comment is corrected to its firing lines (22 and 23) and the #1570 pin's text to C1b | Silences #1570 and the conditional-`def` and conditional-`include` shapes, the latter two adjudicated `tp-lost` by design (WD2); may silence firings that resolved through a `possible`-only definer; **every removed `call.wrong-arity` adjudicated** | None | The cross-commit differential with the survivors' floor; the one-fork witness and its guard stay `Unknown` |
| C1c — relationship lints (lane 2) | The override super-method lint (`each_project_ancestor`, `check_rules.rb:3800`, and `override_visibility_diagnostic`, `:3736`), the visibility mismatch (`:2664`) and `singleton_context_def?` (`:3671`, with WD3's singleton-side decline), each through `resolve` with `from:` past the class and an `answer_in` that places an RBS-declared parent | Silences the lints where some world has no super method | None | The five non-discharge shapes stay `Unknown`; WD5's lint fixtures |
| C1d0 — storage (lane 1) | WD1's C1 obligations: a sibling, or a read-only-beside-`discovered_def_nodes` statement, for the two def-source tables; the envelope key and class marks; the extends fold and `subtract_def_methods` follow-through; the census's `justified:` classification and header (Q12) | None | None | The pairing spec extended; the census spec, whose `justified:` check fails on a read or copy of a contested-sibling member without an entry, on an entry naming an unrecorded file, and on a kind outside `existence`, `identity`, `cache_key`, `paired_copy` and `consults_contested` |
| C1d — `possible` facts (lane 2) | WD3's producers fill the siblings: a conditional `def`'s slot, visibility and envelope contested, a conditional `discovered_methods` entry `possible`; constructs the `Helpers2#fmt2` fixture (no such file is in the tree; its silencing needs the contested visibility, which interacts with PR B) | May silence firings that resolved through a `possible`-only definer; the `Helpers2#fmt2` override | `possible` definers render nothing new (RBS has no conditional form) | Both witness levels; the differential |
| C1e — sig-gen notice (optional) | A notice on `possible` module functions | None | The notice | The sig-gen diff |
| C2 — typing sites | Return inference through `resolve_user_def_through_ancestors` (`expression_typer.rb:2471, 2496`, where `Unknown` types `Dynamic`) and the singleton memo (`:2386`, with WD3's singleton-side decline); the absent rule with its RBS census | Silences the conditional-definer and conditional-include `call.undefined-method` shapes, #1594 at this site, and the #1592 hook shapes at the migrated singleton site (`Unknown`, not a fix); `gemmod3` waits for #1572 | None expected | WD7(f) census before and after, adjudicated: GitLab's core models type `Dynamic` at these sites until PR D, and the PR states the count |
| D — hook facts per includer | Deferred to the follow-up ADR | — | — | — |

Errata (2026-10-08), from C1d planning; C1d splits into C1d-a (WD3's classifier and the def-contribution
producers: `possible_discovered_methods`, the def-node, singleton def-node and envelope contests; #1623) and C1d-b
(the contested visibilities):

- *The C1c row's `singleton_context_def?` is stale.* C1c read a receiverless def's singleton context from the scope
  (`Scope#singleton_class_body?`) and the indexer's record of the node, not through a candidate-set read, and
  `DefinerResolution.resolve` still raises on `side: :singleton`. So the singleton-side contests C1d-a produces
  (`contested_discovered_singleton_def_nodes`) have no migrated reader yet; `DefinerResolution#possible?` is the only
  sibling reader, on the instance side.
- *WD3's `rescue` wording.* A `begin` WITHOUT a `rescue` clause keeps its main statements and its `ensure` clause
  certain (either they run or the raise leaves the file's top level); a `begin` WITH one is possible throughout,
  main statements included, because a rescued raise skips every statement after the raising one
  (`lib/rigor/inference/scope_indexer/certainty.rb`).
- *The Consequences counts of defs in blocks are v12's, not today's.* Under C1d-a's classifier, counting every
  `def` node in the tree, Rigor's `lib` has 8 possible defs of 8,634 (at #1623's head), the survey's Mastodon
  checkout (`af3596316`, `app lib config`) 78 of 7,208, almost all in `class_methods` and `included` blocks, and
  GitLab's `app/controllers` 3 of 4,345.
- *Two accepted limits of the classifier (#1626).* A top-level `return if …` guard, and a `||=` meta-new constant
  write (`K ||= Class.new do … end`), are classified certain though Ruby can skip what follows the guard or the
  write; and a possible `alias` over-contests its source name, so a certain `def` of the source reads contested too.
  Each errs toward `Unknown` or toward a contested slot, never toward a firing, and each is accepted as
  imprecision rather than fixed in C1d-a.
- *The C1d row's `Helpers2#fmt2`.* Its override silencing needs only C1d-b's contested visibility; PR B is needed only
  for the fabricated singleton copy.

Precision estimate, unchanged from v12 and not re-measured (the landed PRs changed no producer that
moves it): about 13 of 940 mixin calls in Mastodon's `app`, 6 of 85 in `app/lib`, sit outside
unconditional bodies; Redmine has 17 `send(:include)` and 6 mixin calls inside methods. What C1 and C2
cost on Mastodon is bounded above by the 21.3 % of reads already answering from master, and relevance
lowers it by an amount PR C measures.

## Relationship to other ADRs

- **[ADR-24](24-self-method-call-resolution.md) — amended (landed).** Its § "Amendment 2026-09-28" is
  the binding text for the chain, `settle`, forks, unsettled chains, the single walker and the
  dependency edges; slice 2's breadth-first walk carries the superseded note (`:345–350`). Its #1570
  paragraph (`:634–644`) says what this ADR says: fixed by PR C (C1b) at `SourceArity`'s two decision points, with
  no new discovery data (the chain-memo change is relevance's, WD2, not #1570's). This ADR's reads are
  defined over that chain and add certainty on top.
- **[ADR-116](116-hot-file-restructuring.md) WD5 — partially superseded.** Byte-identity and the variant
  rule (`:160–184`) are retired for behaviour changes; its guardrails remain lane 1. The four ported
  collectors stay; `RULE_VARIANTS` entries are deleted under the lane their case belongs to. #1531
  closes as superseded; the README row drops "WD5 in progress" at acceptance.
- **[ADR-53](53-scope-discovery-index-separation.md)** — the shadow harness narrows to WD4's syntactic
  members and lane 1; the "generic-visitor rewrite: Deferred" row (`:233`) is marked superseded.
- **[ADR-85](85-seed-bundles-and-lazy-def-node-handles.md) WD2 — amended (landed).** Bundles carry
  `unpositioned_mixins` and the six WD1 siblings as plain data (the schema bumps of #1584, #1593 and
  #1600); `docs/internal-spec/inference-engine.md:75` documents the siblings.
- **[ADR-89](89-semantic-propagation-gates.md)** — the declaration signature carries the mixin lists in source order and the
  unpositioned table (SI:7365, landed by #1584), so an edit that only reorders or guards an include
  moves it; ADR-89 WD1 is otherwise unchanged.
- **[ADR-46](46-incremental-dependency-graph.md)** — preserved by the chain's dependency contract and
  WD2's recording through `Scope` readers, plus the negative class edge relevance files for a tested
  external; #1590 is a cost lever, not a contract change.
- **[ADR-17](17-monkey-patch-pre-evaluation.md)** — the fold's subtraction (SI:7941) is a consumer
  policy the WD5 relation is stated around.
- **[ADR-15](15-ractor-concurrency.md)** — plain frozen data; the chain memo is per index (RC:285–299).
  **[ADR-5](5-robustness-principle.md)** — unknown-is-silence at every migrated read.
  **[ADR-38](38-additional-initializers.md)** — the typed pre-pass's registry read is why the typed
  members are outside WD1.
- **[ADR-2](2-extension-api.md) — unchanged.** Plugins keep the same readers with the same shapes
  (`docs/internal-spec/inference-engine.md:655` for `user_def_for`, `:663` for the pair-returning walk)
  and received the corrected order as a bug fix; `Scope::ResolutionChain` and `DefinerResolution` are
  internal. Exposing either to plugins needs its own ADR-2 amendment. WD3's `ActiveSupport::Concern`
  name test is the one framework name the engine reads until the follow-up ADR.
- **`rigor sig-gen` output is a gated artifact** in both lanes.
- **Follow-up ADR (to be numbered): hook facts per includer**, on both sides.

## Rejected / deferred alternatives

| Candidate | Status | Reason |
| --- | --- | --- |
| A per-file declaration-fact IR (round 1) | Rejected | Typed pre-passes are not pure per file (SI:1738–3020); the ivar pass does not fit rows; the default path loads no snapshot. |
| Ruby as the judge of every disagreement | Rejected | Several Ruby answers per text (Context 3); deliberate over-approximation (SI:6063–6069); Zeitwerk fixtures raise; five members have no runtime counterpart. Ruby is WD5's *witness*. |
| One approximation policy per table; direction per reader; direction per call site | Rejected (drafts 1–2) | Visibility, constants and ancestry are read both ways; on a walk neither direction is safe; labels were self-declared. |
| Candidate sets over the breadth-first walks (draft 3) | Rejected | Not Ruby's order (#1567, #1568). |
| A single linearisation for a skipped include (draft 5) | Rejected | A body reopened after a subclass linearised positions the module differently; the landed fork rule counts every second route and stands only where the worlds provably agree. |
| Two skip worlds only, or master's answer at two or more *relevant* skips (drafts 5–12) | Superseded by #1578 | A mix of skips puts a third definer first (the two-fork shape in WD2). The chain counts every fork and stands on none but the one two-world shape, per answer. |
| A `position_unknown_*` sibling per mixin member (drafts 6–12) | Withdrawn | `unpositioned_mixins` (#1584) is that data per side, with the `"*"` sentinel the sibling lacked; a recorded `possible` mixin edge is a subset of it. One member instead of three siblings. |
| "Through `send`" as a position-unknown edge; every read unknown through a marked entry (drafts 5–6) | Rejected | `send(:include, …)`, `C.include(M)` and `prepend_mod_with` record no edge, only the mark and now `"*"`; declining every read through a mark would turn 41–51 % of GitLab's pairs `Dynamic`. The mark keeps exactly master's declines. |
| A hook's `:extend` mark propagated to includers' singleton chains, and a block `extend` recorded under the lexical class whatever the block (#1593's first drafts) | Withdrawn | § The chain, "The lesson of #1593 and #1594": a mark sends the reader to master's order, and the lexical class is wrong once `self` is rebound or the block may not run. |
| Per-name relevance on a chain with one retro-eligible fork (draft 13 rejected it on the two-fork shape) | Deferred | The two-fork shape decides nothing (`:master` before any mark is read); on a one-fork chain the fork rule compares the worlds itself, and whether an irrelevant mark may be discharged there is not argued here. The witnessed cost is WD2's discriminating shape, `Unknown` though Ruby answers `X#foo` in all four worlds. |
| Discharging a mark on a closure with no project definer of the name (draft 13) | Rejected | Vacuous on an external entry and on a dynamically defined module, blind to `private :to_s` and `method_missing` (WD2). The rule now requires a closure that provably cannot answer the name. |
| An in-tree `SourceArity` oracle behind a flag (drafts 4–15) | Replaced by #1599 | A frozen copy of the rule still reads the live scope, chain and tables the change moves, so it agrees with the change by construction; the differential compares two archived engines (WD2). |
| A cap of four relevant edges and skips, with world enumeration (drafts 4–12) | Retired | The read no longer enumerates worlds of edges: a relevant unpositioned edge is `Unknown` and `possible` definers form a linear candidate list. Nothing is left to cap. |
| Leaving the existing readers on the breadth-first walk and migrating call sites one by one (draft 9) | Rejected | #1567's singleton side and #1571 fired through readers no migration list named; changing the walk inside every reader fixed all call sites at once and kept every shape (#1578). |
| A truthy unknown sentinel returned in the node position by the existing readers (draft 8) | Rejected | Nine wrappers return a reader's result under other names and dereference far from it, often under `rescue StandardError`; a dereference detector cannot be complete, and the sentinel would cross the plugin API (`plugin/base.rb:178`; `inference-engine.md:655, 663`). |
| "Absent means `NoMethodError`" (draft 4) | Rejected | The chain sees only project classes; `Object#to_s` and `Enumerable#to_a` answer. |
| A discovery-data change for the chain (separating tables, recording the file of an edge) | Rejected | The tables already separate prepends and keep order; the fuzz diverged only under same-module interleaving, which the census finds nowhere; a multi-file class declines at the edge level (§ The chain) without the file of an edge. |
| Every mixin edge of a multi-file class unpositioned (draft 6) | Rejected | It declines on a single defining closure: 107 GitLab classes, Namespace losing 89 of 198 names. The edge-level rule costs 169 pairs (0.04 %), and relevance narrows it per name. |
| Agreement between the certain-only world and the union world; `certain_*` siblings; hook instantiation in this ADR; a separate ADR for the chain; the overlay; the fuzzer as a CI gate; continuing the piecewise ports | Rejected or deferred as in drafts 3–5 | Reasons unchanged: compensating definers; table copies; fold-level facts need their own probes and witness; ADR-24 owns the order (ADR-49 economy, ADR-97 budget); not byte-identical; 2–7 % load rate; 0.2 % of a cold run. |

## Consequences

Positive:

- The variant rule and byte-identity for behaviour changes are gone; a disagreement between two
  context computers is a fixture with a Ruby witness or nothing.
- One chain is the reference for resolution inside every engine reader, landed: #1567 on both sides,
  #1568 and #1571 are fixed at every call site and for every plugin, with no firing added on any corpus;
  #1570 is fixed where C1b migrates both arity decision points. No consumer walks ancestry on its own except the 14
  allow-listed union and bridge walks, and a spec keeps it so.
- No read carries a direction label; a migrated site answers or is silent by one rule, floored by the
  cross-commit arity differential; every other site and every plugin reads the corrected order through the
  same readers; a member holds `possible` facts only once its copy paths are paired and its slot reads
  migrated. `module_function` has one implementation; #1550, both `vis.rb` false positives and the
  ancestry probes are fixed under a stated relation.

Negative:

- **Precision cost of unknown.** At a migrated site a `possible`-only definer, a contested definer, a
  relevant unpositioned edge or a chain that does not stand answers `Dynamic`; relationship lints are
  silent where some world has no super method. On Mastodon the ceiling is 21.3 % of ancestor reads
  (#1591) before relevance; on GitLab, Project, Group and User stay `Unknown` at migrated sites until
  the follow-up ADR. Relevance stops at a fork, so a one-fork chain whose worlds agree still declines.
  A migrated singleton-side read declines where a hook could land ahead of its answer (WD3, errata
  2026-10-08; the closure rule it replaced declined on every class whose instance chain holds a concern
  or a hook — on a Rails app, every model under an `ApplicationRecord` concern). **Defs inside blocks**
  become `possible` definers: v12 counted 74 of 7,181 defs in Mastodon, 3,772 of GitLab's including
  `ee/` (about 142 exempt as meta-new blocks) and 162 of 9,657 in Rigor's `lib` (132 exempt); the rest
  type `Dynamic` at migrated sites until the follow-up positions them.
- **A hook's edge on either side stays a false positive in the existing readers** (#1592's hook
  shapes, #1594) until the follow-up ADR; no chain mark can fix it (§ The chain), and WD3's decline
  reaches migrated sites only.
- **Coverage cost of declining.** C1's `SourceArity` stops firing on unsettled chains: on a Rails app a
  fifth of ancestor reads. Each removed firing is adjudicated in the PR; a true positive lost there is
  the price of the false positives silenced, and the count decides whether relevance must land first.
- **Recording cost.** A recording run pays +5.1 % allocations for the after-answer edges `settle`
  files (#1578), before #1590; C1 adds the closure probes, a tested external's negative class edge and
  the chain memo's marks, which WD7(d) reports on both runs.
- **User-visible sig-gen changes** (PR B), each with a changelog entry.
- **Grandfathered sets**: 371 producer entries, the chain's 14 allow-listed walkers and the slot readers
  the census reports converge only as bugs are filed.
- Six always-empty siblings beside their members, a `with` that raises on a half pair and two schema
  bumps (landed, #1600), carried on every copy path until C1 fills them.
- No speed is claimed.

## Open questions for the maintainer

Resolved at acceptance (2026-10-01): every default below is adopted.

1. **Scope of `possible`.** As stated, or restrict to direct-body control flow? *Default: as stated.*
2. **Typing through a possible-only definer** answers `Dynamic`. *Default: accept.*
3. **C1 before or after relevance.** C1 may decline on every unsettled chain at `SourceArity` and land
   relevance in the same PR, or land relevance first and measure #1591's breakdown. *Default: one PR,
   with the adjudicated count of removed firings deciding whether it merges.*
4. **Multi-file classes.** A read declines only when two or more of the class's edges' closures define
   the name, on a fork-free chain. *Default: as stated.*
5. **#1572**: the chain's external-definer read for typing. *Default: a follow-up of the chain, before
   C2.*
6. **Block-def exemption.** Exempt the meta-new blocks Rigor already recognises; everything else waits
   for the follow-up. *Default: as stated.*
7. **Sig-gen changes in the changelog.** *Default: yes, one entry for PR B.*
8. **Pace for the grandfathered sets.** *Default: by filed bug; the gates prevent growth.*
9. **The follow-up ADR's timing.** *Default: after C1 lands; before C2 if the WD7(f) census on GitLab
   is not acceptable, or if #1592's or #1594's shapes are reported from a corpus.*
10. **Relevance on a one-fork chain.** Deferred here; the agreeing-worlds witness is pinned as a
    decline. *Default: deferred until PR C's #1591 breakdown shows the share it would recover.*
11. **WD3's singleton-side decline signals.** The `ActiveSupport::Concern` name test is a framework
    name in the engine. *Default: accept until the follow-up ADR, with the plugin API as its home.*
12. **The census's `justified:` classification (C1d0; raised after acceptance, errata 2026-10-01).**
    WD1(ii) lets a whole-table read stay where it only tests existence or identity or keys a cache, or
    is one of #1600's paired copies, and otherwise moves it behind a `Scope` reader; the census spec's
    header still says "only once its entry here is empty". *Default: adopt the classification and
    reword the header; needs the maintainer's confirmation.* **Adopted (maintainer, 2026-10-08).**
