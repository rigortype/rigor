# ADR-119 — Certainty on discovery facts, candidate-set reads over the resolution chain

Status: **Proposed, 2026-09-28; revised 2026-10-01.** Awaiting the maintainer's acceptance. Landed
ahead of it, each on its own merits: #1551 (the layered def-nesting lookup) and #1563 (the
`module_function` readings behind one helper, `lib/rigor/inference/module_function_state.rb`), both
byte-identical; the gates of WD4–WD6 (#1566, `spec/rigor/declaration_facts/`); the
`unpositioned_mixins` member (#1584, data only, nothing read it); and the resolution chain
(#1578, `lib/rigor/scope/resolution_chain.rb`), an ADR-24 amendment that fixes #1567, #1568, #1571 and
#1587 and is the first behaviour change in this line. Landing ahead of acceptance, not yet merged: #1593
(Draft, narrowed under review), the fix for the block shapes of #1592, a singleton-side mixin written in
a block that master neither records nor lists; #1592's hook shapes stay open. WD1–WD3, the decisions
this ADR itself makes, are open: no `possible` fact exists, no read answers *unknown*, and the storage
siblings, the candidate-set reads and the first lane-2 PR on them (PR C) wait on acceptance. **Citation
baseline:** `file:line` cites are at `origin/master` `a841adac4`; SI is
`lib/rigor/inference/scope_indexer.rb`, RC is `lib/rigor/scope/resolution_chain.rb`, MA is
`lib/rigor/inference/scope_indexer/mixin_accumulator.rb`.

Grounding: the design-review rounds on #1531 and #1507, the thirteen drafts of this ADR reviewed
adversarially on #1562, the chain PR's own measurements (a witness suite against Ruby, an 8,000-program
fuzz, a mixin census over Mastodon, Redmine, GitLab, Rails and Rigor, and an instrumented run over
Rigor's `lib/` and Mastodon v4.5.10, all in #1578's description), #1584's allocation sweep, #1593's
review, and the probes named in Context and WD2, each run under `rigor check --no-cache` (workers 0)
and Ruby 4.0.5 against `a841adac4`'s engine, with Ruby's own answer beside it. ADR-49 archetype:
deliberative; stakes: high (the false-positive envelope of every ancestry read).

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
   `ScopeIndexer` — sig-gen's own `module_function` rule (`lib/rigor/sig_gen/generator.rb:667`),
   `Effects::DefinitionContext` (`lib/rigor/effects/definition_context.rb:58`),
   `SyntheticMethodScanner#build_hierarchy` (`lib/rigor/inference/synthetic_method_scanner.rb:369`), the
   ActiveRecord `ModelDiscoverer`'s `included do` descent
   (`plugins/rigor-activerecord/lib/rigor/plugin/activerecord/model_discoverer.rb:471, 518`). WD6's
   tripwire now lists 391 such producers in 71 files (`spec/rigor/declaration_facts/producers.yml`).
   On the read side, `Scope` exposes every table raw (`lib/rigor/scope.rb:41–52`), and before #1578 six
   consumers walked ancestry on their own while four more loop over the raw tables on purpose, to record
   no ADR-46 edge (`rbs_dispatch.rb:854–863`; `macro_block_self_type.rb:157`; `scope.rb:1295`
   `singleton_extends_of`, which `narrowing.rb:3160` walks; `shadowed_rescue_collector.rb:234`).
2. **Variants were found by reading code**, so they grew as O(walkers × categories)
   (`lib/rigor/inference/declaration_walk/traversal.rb:89`), protect behaviour no corpus exercises
   (#1527's control found no divergence in 67,137 files), and a shadow sweep over a corpus that lacks a
   construct passes without checking anything.
3. **One semantic question had several implementations and no reference.** `module_function`'s definee
   was computed four ways until #1563 put the readings behind one helper, byte-identical, so the four
   semantics still stand (SI:4224, 4605, 4913, 4979; `generator.rb:667`). Ruby's answer is
   run-dependent (a bare call inside `if`, `each {}` or a called `def self.setup` takes effect; a bare
   visibility call resets it; `def self.x` gets no instance copy; the named form snapshots the earlier
   `def`). **Method resolution order had the same problem**: two breadth-first walks, `SourceArity`'s
   level walk with its own agreement rule and eight hedges, and none was Ruby's order — three false
   positives on correct programs (#1567 on both sides, #1568 at error level, and #1570). The first two
   are fixed by the chain; #1570 is not, for a reason § The chain states.
4. **Byte-identity was demanded against walkers that are wrong or deliberately over-approximate.** The
   extends walker over-approximates on purpose, in the ADR-5-safe direction (SI:6063–6069), and
   under-approximates in the unsafe one: a singleton-side mixin inside a block or a method is dropped
   (#1592, finding (d)). #1518–#1520 are rules wrong in several walkers at once. #1550 is a false
   positive on correct Ruby (the named form resolves the *later* `def`; the reading lives at
   SI:4975–4979 over `ModuleFunctionState.each_singleton_copy`).
5. **The justification shifted** from speed to C2 without a criterion for landing a port; the speed case
   was measured and found absent (`docs/adr/116-hot-file-restructuring.md:175` still calls the merge
   "the wall lever").

Seven findings bound the design. **(a)** The typed pre-passes call `scope.type_of` under the project
seed and the plugin registry (nine sites, SI:1738–3020), so they are not pure per file. **(b)** A
direction per table or per read is ill-posed: visibility is read to fire and silenced by `nil`,
constants are read both ways (`scope.rb:140`), and on an ancestor walk keeping a `possible` edge
shadows a further ancestor while dropping it exposes one. **(c)** A candidate set over a breadth-first
walk is not sound either: a certain nearest definer in a wrong order. **(d) Some edges have no position
that is a fact, and some singleton-side edges are not recorded at all.** An `include` inside a method
takes effect when the method is called; an `included do include A end` edge is recorded on the concern
but Ruby applies it to the includer, and a `prepend` there lands ahead of the includer (GitLab's
`CacheMarkdownField` prepends inside both `included do` and `class_methods do`); two files reopening
one class order their includes by load order; and an include the chain skips as already present
becomes positioned by a later reopening (`class C < Base; include M` then `class Base; include M; end`
gives Ruby `[C, M, Base, M]`, a single linearisation `[C, Base, M]`). Since #1584 and #1578 the first
three are *unsettled* chains and the fourth is a counted *fork* (§ The chain). On the singleton side
the extend walk descends into no block it does not recognise (SI:6119–6121, 6197–6208), so
`[1].each { extend X }`, `[1].each { class << self; include X; end }` and a concern's `included do
extend X end` leave `discovered_extends` without `X` and `unpositioned_mixins` empty, and a hook
`def self.included(base) = base.extend(X)` lists `"*"` on the hook module's own `:extend` side only,
which no includer's singleton chain draws on; in each of the four shapes `class K < Base` with
`def self.bar = 1` on `Base` and `def bar = "X"` on `X`, `K.bar.upcase` fires `call.undefined-method`
on master while Ruby prints `"X"` (#1592, pre-existing before #1578; the direct-body control
`extend X if ENV["E"]` is listed, unsettled and silent). #1593 records and lists the block shapes
whose `self` is the class; the hook shapes stay open (§ The chain, WD3). **(e) Some edges are not
recorded, only marked**: `send(:include, M)`, the receiver form `C.include(M)` and helpers such as
`prepend_mod_with` add nothing to the mixin tables (`MIXIN_CALL_NAMES` holds `include` and `prepend`,
SI:5624; `SURFACE_MIXIN_HELPER`, SI:6697); each stamps `ENVELOPE_DYNAMIC_MARK` on the class (SI:6720,
6730), and since #1584 also lists `"*"` on the owner's side in `unpositioned_mixins`. Three readers
decline on the mark today — `SourceArity` (`dynamic_surface?`, `source_arity.rb:244`), the
RBS-ancestor typing arms (`rbs_dispatch.rb:621, 656, 739–748`) and `program_may_answer?` /
`mixin_may_answer?` (`check_rules.rb:2506, 2522`) — and every other read types through it. **(f) The
chain sees only project classes**, so "absent means `NoMethodError`" is false: with `include M if X`
and `M#to_s(fmt)`, `Object#to_s` answers when `X` is unset, yet `call.wrong-arity` fires; `include M;
include Enumerable` fires an error-level `undefined method 'first' for 1` although `Enumerable#to_a`
answers (#1572). A project module is a project entry only under the reader's flavour (RC:339–349): a
module whose every method is a `define_method` in a loop has no `discovered_methods` row, fails
`known_user_class?` (`scope.rb:1623–1626`) and enters an includer's `:methods` chain as an **external**
entry carrying the dynamic mark. **(g)** A single-valued table has no union (last-write-wins, SI:4963)
and scalar consumers deref the value (`runner.rb:598–607`).

**What landed between the first draft and this one.** The chain (#1578, 2026-09-30) replaced every
"which definer" walk inside the engine's readers with one Ruby-order implementation and one decision
method, changing no reader's signature; its corpus diagnostics and `rigor sig-gen` output are identical
to master's on Rigor's `lib/` (0/0 default, 0/0 strict), Mastodon v4.5.10 (21/21 default, 1,043/1,043
strict) and `sig-gen` over `lib/` (9,208 lines), five witness fixtures fail against master's `lib/`,
and engine allocations moved −0.03 % on a plain run and +5.1 % on a recording run (#1590). Its
instrumented precision run (#1578's description, § "Precision") is the number this ADR now designs
against: on Rigor's `lib/` 339 of 5,336 chains are unsettled and 1.0 % of 135,225 reads answer from
master's order; on Mastodon 1,273 of 11,714 chains are unsettled, 49 carry one retro-eligible fork,
none carries another kind, and **21.3 % of 145,182 reads answer from master's order, every one on an
unsettled chain** (the unsettled figures are carried forward as #1591). `unpositioned_mixins` (#1584)
is the data those verdicts read; it cost +0.03 % allocations and moved the seed-bundle and snapshot
schemas (now `Descriptor::SCHEMA_VERSION = 14`, `lib/rigor/cache/descriptor.rb:75`;
`IncrementalSnapshot::SCHEMA = 33`, `lib/rigor/cache/incremental_snapshot.rb:159`).

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
decline**: an unsettled chain answers master's order, so marking a chain unsettled helps only where
master's answer is right; where it is wrong, the only tool is the migrated read's `Unknown` (#1593's
review, § The chain).

### The chain this ADR builds on (ADR-24 amendment, landed by #1578)

Binding text: ADR-24 § "Amendment 2026-09-28" (`docs/adr/24-self-method-call-resolution.md:522–697`)
and `docs/internal-spec/inference-engine.md:662`. This ADR relies on the following and states no more.

- **One walker, one decision.** `Scope::ResolutionChain` (RC:82) replays CRuby's `include_modules_at`
  over the tables — prepends before the class, includes after it in statement order, a module already
  anywhere in the chain skipped, a skipped module before the superclass moving the insertion point, the
  singleton side through the recorded `extend` and `class << self; include` edges under the include
  rule — and is internal: nothing joins the `Scope` surface `spec/rigor/public_api_drift_spec.rb:9–14`
  pins, and `sig/rigor/scope.rbs` is unchanged. Every "which definer" reader of the engine reads it:
  `user_def_through_ancestors` (`scope.rb:1339`), `singleton_def_through_ancestors` (`:1378`, which
  now reaches an extended module's includes, #1567's singleton shape),
  `external_ancestor_name_candidates` (`:1412`), `discovered_method_through_ancestors?` (`:1460`), the
  override rules' walk `each_project_ancestor` (`check_rules.rb:3800`) behind
  `nearest_ancestor_visibility` (`:3837`) and `nearest_ancestor_method_def` (`:3931`), the visibility
  rule's prepend-region check (`:2664`, #1568), `SourceArity`'s levels (`source_arity.rb:109–129`,
  every hedge kept), `Reflection.ancestor_constant_scopes`
  (`lib/rigor/reflection/constant_ancestors.rb:41–64`, #1571) and `ExpressionTyper#related_to_owner?`
  (`expression_typer.rb:2675`). Each keeps its signature and return type; only which definer it answers
  moved. `ResolutionChain#settle` (RC:146–158) is the one decision: `:chain` or `:master`.
  `spec/rigor/scope/ancestry_walker_detection_spec.rb` fails on any other method that reads two of the
  **ten** ancestry readers (`includes_of`, `prepends_of`, `superclass_of`, `singleton_extends_of`, the
  four raw tables, `enqueue_ancestors`, `ResolutionChain.direct_ancestors`;
  `spec/support/ancestry_walker_scan.rb:13–17`), reads one in a loop or a recursive method, or reads
  the retro world itself (`:117–127`); 14 walkers remain, allow-listed with a reason (`:47–88`): eleven
  unions used only to withhold and three bridge walks over RBS-declared edges the tables do not carry.
  **Two of the bridges are first-definer walks outside the chain**, kept because they interleave edges
  the chain cannot see: `macro_block_self_type#singleton_extends_reach?` (`:157`; Ruby's singleton order
  for what it sees) and `rbs_dispatch#each_source_ancestor_candidate`
  (`lib/rigor/inference/method_dispatcher/rbs_dispatch.rb:861`; breadth-first, its
  `allowed_rbs_complete_ancestor` guard deferred to #1572).
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
  `spec/integration/resolution_chain_witness_spec.rb`, is that shape: Ruby runs `D#foo`, both worlds
  read `Deep#foo`, master's order happens to reach `D`). A singleton superclass that only `extend`s
  resolves as external and settles to master with the weight of two (RC:724–729).
- **Unsettled chains.** `Builder#mark_unsettled` (RC:698–701) marks a node when
  `DiscoveryIndex#unpositioned_mixins` lists anything on the side being linearised, or when its class
  is declared in two or more files (`discovered_class_sources`, seeded on every run since #1584) and has
  two or more edges on that side; the mark propagates to every chain that draws on the node (RC:547–552,
  636), so a concern's `included do include A end` edges taint every includer's **instance** chain
  transitively, and `settle` answers `:master` for an unsettled chain whatever its fork count (RC:151).
  What propagates is a boolean: `Frame` hands up `unsettled` beside the fork count (RC:547–552), the
  memo tuple stores it (RC:656), and an unsettled chain never builds its retro world (RC:573). The
  pinned shapes are a conditional include, an include inside a method body, a class declared in two
  files, a concern with `included do include A end` and a hook that includes another
  (`spec/integration/ruby_order_resolution_spec.rb:374–438`). **On the singleton side the mark does
  not cross an include edge**: an included module's `:extend`-side entries (a hook's `"*"`) are read
  only when that module's own singleton chain is built (RC:683–684), which no includer's singleton
  chain does, so `K`'s singleton chain in Context (d) stands with no fork and no mark while Ruby's
  carries `X`. #1593 first tried to propagate the mark through the include closure and withdrew it
  under review: master's singleton walk is superclass-only (the `MasterOrder` answer of
  `singleton_def_through_ancestors`), so an unsettled includer answered `Base.bar` for `class C < Base;
  extend A` with `A` including `M` — #1567's singleton false positive back — and still `Base.bar` for
  the hook shapes. **A mark is worth adding only where master's order is right; a hook edge needs a
  reader that declines, or the follow-up ADR's model.**
- **`unpositioned_mixins`** (#1584; `discovery_index.rb:37`, classified `:set_valued` at `:83`) is
  `{owner => {include: [names], extend: [names]}}`, `:include` the instance side and `:extend` the
  singleton side. `ScopeIndexer::MixinAccumulator` (MA) lists an edge written anywhere but as a direct
  statement of the class's own body or its `class << self` body, in a declaration that is itself a
  direct statement (`direct_body`, MA:54–62; `note`, MA:84–89): inside a `def`, a block (`included do`,
  `class_eval`), a conditional or modifier `if`, a declaration wrapped in either, or the receiver form
  `Base.prepend(M)`. A call the walk cannot record — `include helper`, `include(*MODS)`,
  `send(:include, M)`, `C.include(M)`, `singleton_class.include M`, a call on a hook parameter
  (`with_hook_params`, MA:66–72) or an eval block on one — lists the sentinel `"*"` (`WILDCARD`, MA:35;
  `taint`, MA:92–94). A module written to both the include and the prepend table of one class
  (SI:6020–6026) and a repeated `extend` (SI:6362–6377, #1573) taint their side. **The list is only
  as complete as the walk that feeds it**: the instance walk descends into every child, so an
  `include` inside `[1].each { }` is recorded and listed, while the extend walk returns from a block
  it does not recognise without walking it (SI:6119–6121, 6197–6208), so on master the singleton side
  lists a direct-body statement's conditional edge and a hook's `"*"` and nothing written in a block
  or a method (#1592). #1593, as narrowed under review, records and lists an `extend` (or a `class <<
  self` mixin) inside a block whose `self` is provably the class — a self-preserving iterator
  (`each`, `times`, `map`, `tap` and their kin) on a literal or constant receiver, written as a direct
  statement of the class body — and leaves a block that rebinds `self`, a method body and a hook
  unrecorded, because recording the edge under the lexical class is wrong when `self` is something
  else. The edges stay in `discovered_includes`, `discovered_prepends` and `discovered_extends`; the
  table folds by union (SI:7844), is re-keyed with the class-keyed tables (SI:8511), rides the ADR-85
  bundles and the ADR-89 declaration signature with the mixin lists in source order (SI:7250).
  Consumer obligations are in `inference-engine.md:67`.
- **Marked entries keep exactly master's declines and add none.** The four sites in Context (e) are the
  only declines on `ENVELOPE_DYNAMIC_MARK`; #1578 preserved each and its specs pin them
  (`ruby_order_resolution_spec.rb:175–195`). Typing through a marked entry is a known remainder, not a
  rule: on GitLab 1,730 entities carry the mark (ApplicationController, Project, Group, User, Issue,
  MergeRequest, Ci::Build among them), so 4,041 of 18,164 classes and 41–51 % of (class, name) pairs
  resolve at or beyond one; on Mastodon 4.7–7.6 %. Declining there would turn that share `Dynamic`.
- **Three name-resolution flavours** (RC:280, 339–349): `:methods` via `known_user_class?`,
  `:constants` via the declared namespaces, `:arity` via `SourceArity`'s predicate with #986's ambiguous
  names expanded. A bug fix does not unify them.
- **Dependency contract (ADR-46).** `search` records the root and every project entry ahead of the
  answer (RC:169–183); `settle` files every entry after the answer through `record_beyond`, with the
  negative class edge on a project entry's unqualified name and, for an external entry, only the sites
  of the names it can denote and **no negative edge** (RC:204–217, the `unless entry.external?` at
  RC:214, so an unrelated `Admin::Comparable` does not re-check every consumer of `Comparable`);
  nothing more is filed when the root heads its own chain and answers itself (RC:206). A master answer
  records every class that order lists. `spec/rigor/analysis/unsettled_chain_incremental_spec.rb` pins
  warm equals cold for a module past the answer gaining an unpositioned edge and for a new file
  reopening it. A per-consumer de-duplication of those edges is #1590.
- **What it leaves open, and this ADR does not reopen:** #1570 (a one-fork disagreement whose readers
  keep master's answer; `ruby_order_resolution_spec.rb:142–147` pins it with a "flip this when ADR-119
  PR C" comment), #1572 (an external definer ahead of a project one), #1573 (a repeated `extend`'s
  position), #1588 (`combine_rekeyed_entries`, SI:8630, merges a re-keyed class's includes in the wrong
  order), #1589 (CRuby's trailing duplicate from prepend propagation; first-occurrence order unaffected),
  #1590, #1591 (the 21.3 %), #1592's hook shapes (`included do extend X end`, `class_methods do`,
  `base.extend(X)` in a hook: the edge is recorded nowhere on the includer, no mark reaches its
  singleton chain, and master's order does not see it either, so the false positive stays in every
  existing reader until the follow-up ADR's concern model; WD3 states what a migrated read does
  meanwhile), and the two table gaps ADR-24 § "What the tables cannot express" records.

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
  `Base.prepend(M)`) is only read more conservatively. **The subset claim is about recorded edges.** On
  master it holds for the instance side and for a direct-body singleton statement only: a singleton-side
  edge inside a block or a method is in neither the member nor the list (Context (d), #1592) — a
  fabricated *absence*, the ADR-5-unsafe direction, since the chain then stands without the module.
  #1593 records and lists the block shapes whose `self` is the class; a block that rebinds `self`, a
  method body and a hook's singleton-side edge stay unrecorded and unlisted, which WD3's obligation
  covers at a migrated site and nothing covers in an existing reader. A candidate-set read treats each
  named entry as *possible and unordered* and `"*"` as an unknown definer of every name. v12's
  `position_unknown_*` triple is withdrawn: the landed member is that triple, per side, with the
  sentinel v12 lacked.
- **The definer members get siblings.** A set-valued member that admits `possible` facts has a
  `possible_*` sibling of the same shape (`discovered_methods`: `name → kind` maps with `:both`,
  `discovery_index.rb:134`, the relation per pair; `discovered_deferred_ranges`: rows). A single-valued
  member that admits them keeps its slot and today's fold and has a `contested_*` sibling — the keys
  whose value depends on a `possible` fact, including keys whose only definer is `possible`
  (`discovered_def_nodes`, `discovered_singleton_def_nodes`, `discovered_method_visibilities`,
  `discovered_parameter_envelopes`). Slots never hold a new wrapper.
- Siblings **always exist** for admitting members. `DiscoveryIndex#with` (Data's, reopened at
  `discovery_index.rb:55`) is overridden to accept a member and its sibling only **together**; passing
  one without the other raises. The copy paths iterate one declaration of pairs (ADR-116 C1) and drop a
  pair only when **both** are empty — today's `reject { … empty? }` at `discovery_seed.rb:107` drops
  members one at a time and would strand a non-empty sibling. Each copy path has a round-trip spec on a
  fixture whose siblings are non-empty *and* one whose siblings are empty. Marshal-clean, plain frozen
  data; the ADR-85 bundles carry the pair and the next `SCHEMA` bump covers it.
- **Admission precondition.** A member may admit `possible` facts only once (i) every copy path passes
  its round-trip specs and (ii), for a single-valued member, every read the census records for it
  outside the table owners consults `contested_*` or goes through a `Scope` reader. The census is
  `spec/rigor/declaration_facts/admission_census_spec.rb` (#1566, `admission_census.yml`): per member,
  the files outside the owners (`scope.rb`, `scope/discovery_index.rb`, `scope_indexer.rb` and its
  collectors, `runner/project_pre_passes.rb`) that read or copy the whole table, and the files that read
  or copy every member at once. That file is the slot-reader migration list, distinct from the chain's
  walker allow-list.

### WD2 — Candidate-set reads over the chain

A read that answers a question about a member — definer, visibility, arity, type, or which ancestor —
is defined over the chain, and asks `settle`:

- **The internal API.** `Rigor::Inference::DefinerResolution.resolve(scope, class_name, method_name,
  side, question:)` is the candidate-set read. It is not a `Scope` method, so the pinned public surface
  is unchanged. It returns `Known(answer)` — keyed by the question: a `[node, owner]` pair for
  `:definer`, a visibility for `:visibility`, an envelope for `:arity`, so candidates that agree on the
  answer but differ in node are still `Known` —, `Unknown`, or `Absent`. A result is consumed only by
  an exhaustive `case/in` in the same method, with an arm for each of the three and **no `else` or `in
  _` arm** that could fold `Unknown` into a firing arm; it is never stored, returned or truth-tested
  (`Absent` and `Unknown` are both truthy). PR C adds the spec that enforces this syntactically at
  every call site. Only this ADR's behaviour PRs migrate a site to it, each under WD7 lane 2 with a
  fixture; every other site reads through the existing readers.
- **`settle` stays the single decision.** PR C gives `settle` a caller-supplied option (the migrated
  read passes it; existing readers do not) under which (i) a `:master` verdict becomes `:unknown`, and
  (ii) an unsettled mark is discharged per name by the relevance rule below. No reader reads the fork
  count, the retro world, the marks or the unpositioned table itself; the detection spec's guard
  (`ancestry_walker_detection_spec.rb:117–127`) extends to the option's inputs. Verdict (i) needs no
  new data of any kind: #1570 and the conditional-include arity shape stop firing at `SourceArity`'s
  decision point on the boolean the chain already carries.
- **Worlds and candidates.** On `:chain` the read walks the chain and collects the **candidate set**:
  the first definer, and, where that definer is `possible` (a `contested_*` key or a `possible_*`
  entry), the next definer as well, repeated while the definer is `possible`; *absent* joins the set
  when nothing follows. For a retro-eligible fork the candidate set is the answer `settle`'s block
  computes in the retro world, so the chain stands only where both worlds give the same set. The read
  answers `Known` when every candidate gives the same answer to the question asked, `Unknown`
  otherwise. The set is linear in the number of `possible` definers on the path, so **v12's cap of four
  is retired**: no world of edges is ever enumerated.
- **The marks (PR C's chain-memo change).** Relevance needs what marked a chain, and the chain does
  not carry it: `Frame` hands up a boolean and `settle` returns on it (RC:547–552, 151). PR C makes
  `Frame` and the memo tuple (RC:656) carry the **marks** — per marking node: the side, each named
  entry listed for it (`"*"` included), and whether the multi-file rule fired — and keeps `unsettled?`
  as the boolean the existing readers see (RC:127). A chain narrows for a name only when **every** mark
  on it, its own node's and every drawn-on node's, is discharged for that name; one undischarged mark
  keeps `:unknown`. The retro world an unsettled chain never built (RC:573) is built on demand once
  every mark is discharged, under the same budget (`build_retro`, RC:601–609). This changes no
  discovery table; it grows the chain memo, and WD7(d) names its cost.
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
    (`discovered_method?(…, :method_missing, :instance)`, the test at `check_rules.rb:1513`); (iii) no
    project entry records `n` in `discovered_methods` (either kind, over the union) **or in
    `discovered_method_visibilities`** — a visibility-only statement such as `private :to_s` is
    recorded in the second and not the first (probe: `module V; def foo = "v"; private :to_s; end`
    gives `discovered_methods["V"] == {foo: :instance}` and `discovered_method_visibilities["V"] ==
    {foo: :public, to_s: :private}`), and it moves the answer to the `:visibility` question. Under
    (i)–(ii) the shapes the review found are not discharged: `include Ext if ENV["B"]` with `Ext`
    undeclared (an external closure entry RBS does not know; master fires `call.undefined-method` on
    `C.new.foo.upcase` through `Base#foo`, and a gem's `Ext#foo` may answer), and `include U if
    ENV["X"]` with `U`'s methods defined by `%i[foo].each { |n| define_method(n) … }` (no `foo` row,
    the `<dynamic>` mark, and `U` an external entry of `C`'s `:methods` chain; master fires the same
    diagnostic).
  - **A multi-file mark** on node `N` (two or more files, two or more edges on the side read) names no
    entry: it is discharged for `n` when at most **one** of `N`'s edges' closures records `n`, each
    closure tested under (i)–(iii); every closure that records `n` beyond the first keeps the mark.
  - `"*"` is never discharged; a chain with a fork is never narrowed; a discharged mark still records
    the closure's edges (below). The argument, to be witnessed and not yet: with no fork, every entry
    reached the chain by one route, so an unpositioned module's presence, absence or position adds or
    removes only its own closure's entries and moves no other entry's first occurrence; a closure that
    cannot answer `n` — no definer of it, no `method_missing`, no dynamic surface, no external RBS does
    not know, no `"*"` — therefore cannot move the first definer of `n`.
  - **Why the rule stops at a fork.** The two-fork shape — `class C < Base` where `Base` includes `M`,
    `C` written as `include M; include X; include Z` and `Z` including `W` then `M` — shows why forks
    are *counted*: Ruby answers a name `X` and `W` both define from `W` when `Base` ran first
    (`[C, Z, W, X, Base, M]`) and from `X` when `Base` was reopened later (`[C, Z, X, M, W, Base, M]`),
    although `M`'s closure defines nothing (run under Ruby 4.0.5; the chain counts two forks and
    answers `X` from master's order). It does **not** test relevance: two forks are `:master` before
    any mark is read. The clause matters only on an unsettled chain with exactly one retro-eligible
    fork, and there this ADR makes no argument either way; it excludes the fork because the single-route
    argument above is stated for the fork-free case only. **PR C's required witnesses for the clause**
    are that shape, both ways: `class C < Base; include M; include Q if ENV["Q"]; end` with `Base`
    including `M`, `M#foo`, `Base#foo` and `Q#bar` only (one fork on `M`, retro-eligible; one
    irrelevant mark; the chain is `[C, Q, Base, M]`, `forks == 1`, unsettled, no retro world) — Ruby
    answers `Base#foo` when `Base` ran first and `M#foo` when it was reopened, in both `Q`-worlds, so
    the read is `Unknown` by the fork rule once the mark is discharged; and the same with `include X`
    ahead of `Q` and `X#foo`, where Ruby answers `X#foo` in all four worlds and the read still stays
    `Unknown`, pinned as this clause's deliberate decline with a "flip this if relevance is extended to
    one-fork chains" comment. What relevance recovers is measured by PR C (#1591's breakdown of
    Mastodon's 1,273 unsettled chains, which concerns dominate); GitLab's Project, Group and User carry
    forks from hook-duplicated includes (v12 counted two relevant skips on six Project names), so they
    stay `Unknown` at migrated sites until the follow-up ADR positions hook edges. This is inferred
    from v12's count, not re-measured.
- **Marked entries.** A chain entry carrying the dynamic mark keeps exactly master's declines (§ The
  chain) and adds none.
- **The absent candidate** (typing sites and relationship lints only; `SourceArity` is silent on
  *absent* already). *Absent* is dropped only when **no RBS Rigor loads — the project `sig/`,
  plugin-synthesised RBS, and the RBS of every external entry in the chain — declares a method of that
  name for the receiver's RBS ancestors, `Object` included, and none of them declares `method_missing`
  or `respond_to_missing?`**. An external entry RBS does not know counts as defining the name, and the
  read is `Unknown`. Otherwise the external definer is a candidate with its RBS signature as its answer
  (`Object#to_s` disagrees with `M#to_s(fmt)`: `Unknown`; `Enumerable#to_a` is the first definer:
  #1572). For `def.override-visibility-reduced` and `def.method-visibility-mismatch`, *absent* always
  counts.
- **The `SourceArity` differential.** `SourceArity` as it stands at `a841adac4` — its level rule and its
  eight hedges: `load_order_dependent?` (`source_arity.rb:168`), `object_extension_may_shadow?`
  (`:178`), and under `clean_level?` (`:239–242`) `dynamic_surface?` (`:244`), `project_patched?`
  (`:248`) and `external_mixin_lacks_method?` (`:269`, the RBS-known-and-lacks test for an external
  mixin at a level), then `public_at?` (`:278`), `chain_free_of_hooks?` (`:285`) and
  `subclasses_agree?` (`:301`) — is kept as an oracle behind a flag. Over the WD5 fixtures and the
  lane-2 corpus (the survey checkouts `docs/agents/measurement.md` names, Mastodon, Redmine and GitLab
  among them, `check --no-cache` before and after), the set of `call.wrong-arity` firings after a
  change must be a subset of the oracle's; a firing outside that set is allowed only for a mechanism
  the PR names and the fixture witnesses. **Each firing the change removes is adjudicated** as a false
  positive silenced or a true positive lost, with the count of each in the PR; declining on an
  unsettled chain removes coverage on a fifth of a Rails app's reads (#1591), and the ADR accepts that
  only against that count.
- **Conditional definers.** A `def` inside control flow, a method body, or a block **other than the
  immediately-evaluated meta-new blocks Rigor already treats as class bodies** — the constant-write
  forms `K = Class.new`/`Module.new`/`Struct.new`/`Data.define do … end` (`meta_new_block_split`,
  SI:3788; `meta_new_constant_rvalue?`, SI:8692) and the bare-factory blocks the walk recognises
  (`AnonymousMetaClass.block_form_receiver`, `lib/rigor/inference/anonymous_meta_class.rb:42`), whose
  certainty is that of the enclosing statement — is a `possible` definer: its slot in the def-node
  tables, its visibility and its parameter envelope (`Scope#parameter_envelopes_of`, `scope.rb:1680`)
  are contested. `class_methods`, `included`, `prepended`, `helpers` and `class_eval` blocks stay
  `possible` until the follow-up ADR positions them.
- **Existence reads.** A boolean read used positively (`discovered_method?` at `check_rules.rb:951`,
  `known_user_class?`, `published_constant?`) answers over the union, withholding by construction; a
  presence test on a reader's result answers over the union in the reader's order (the master-code
  probes #1578 left unchanged: `ProjectMethodOwnership.source_defines?`, `instance_self_answers?`,
  `closure_escape_analyzer.rb:118`, `error_info.rb:174`, `expression_typer.rb:1665`,
  `guard_rebinding.rb:272`, the active_model_serializers plugin;
  `spec/rigor/scope/resolution_chain_existence_spec.rb`); a negated or compared boolean read
  (`singleton_context_def?`, `check_rules.rb:3671–3673`) becomes a candidate-set read when PR C
  migrates it.
- **ADR-46 recording.** A candidate-set read records what `search` and `settle` record — the class edges
  of every entry on the chain, the closures relevance tests included — and relevance adds, for each
  closure entry it tests, the negative method edge on `Owner#name` (`DependencyRecorder.read_missing(:method,
  …)`, as `SourceArity#settle_by_definitions` files it, `source_arity.rb:86`), because
  `Scope#discovered_method?` (`scope.rb:991–997`) records nothing itself, **and, for each external
  closure entry it tests, the negative class edge on the unqualified name of its spelling**
  (`read_missing(:class, …)`, the edge `record_beyond` files for a project entry and by design not for
  an external one, RC:214): relevance turned the external's absence from the project into an answer,
  so a new file declaring `module Ext` must re-check the consumer, and the over-trigger on an unrelated
  `Admin::Ext` is the price, paid on unsettled chains only. A warm run then re-checks the consumer when
  the module gains a `def` of that name or a file declares it.
- Cost: on a standing chain with no `possible` definer the set is a singleton and the read costs one
  memoised chain plus the `settle` it already pays; relevance costs, only on unsettled chains, the
  memoised closure of each named entry and, per closure entry, three table probes (methods,
  visibilities, `method_missing`), the dynamic-mark test and, for an external, one RBS lookup. The
  constant tables admit no `possible` facts in this ADR.

### WD3 — What is certain

A fact is `certain` when its statement executes whenever the file's top level executes: reachable
through `class`, `module` and `class << self` bodies alone, with no enclosing control flow, block,
method body, `rescue`/`else`/`ensure` clause or `BEGIN`/`END`; the meta-new blocks named in WD2 count as
bodies. Everything else is `possible`. A reopening whose `class` keyword sits inside a conditional makes
its statements `possible` however many other definitions exist. An unconditional `include` in a `class
<< self` body is a `certain` singleton-side edge. Certainty and position are two questions:
`unpositioned_mixins` answers the second for edges, WD3 the first for definers, and the mixin edges need
only the second (WD1). **The extends fold stays in this ADR**: both sites (SI:401, 7752) copy with `||=`
(SI:6398); a copy through a `possible` extend edge — `extend X if …`, `class << self; include X if …`,
and after #1593 an `extend X` inside a self-preserving block — marks the key contested. **Deferred to
a follow-up ADR**: hook facts instantiated per includer (PHPStan's trait model,
<https://phpstan.org/blog/how-phpstan-analyses-traits>). Today every walker treats `included do` and
`class_methods do` as ordinary calls under the concern's own owner; `SyntheticMethodScanner` replays
`included do` macro calls only (`synthetic_method_scanner.rb:336`); `ModelDiscoverer` descends into
`included do` for overrides (`model_discoverer.rb:471, 518`). The follow-up owns the precedence rules
probed on ActiveSupport 8.1.3 (`extend X; include M` resolves to `M::ClassMethods`, the reverse to `X`;
`prepend M` beats the includer's own `def self.build`; `include M, N` applies right to left; a `def
self.x` in `included do` is the includer's singleton method), the incremental closure, the ADR-89
signature and the fold's def-source rows. **Until then, the hook obligation is two-sided.** On the
instance side a hook edge is listed on the concern and every includer's chain is unsettled (§ The
chain), which is safe because master's instance-side order sees the concern's recorded edges. On the
singleton side a hook's edge — `included do extend X end`, `class_methods do`, `base.extend(X)` in a
hook — is recorded on no includer, no mark reaches the includer's singleton chain, and master's
superclass-only singleton walk does not see it either (#1592; the taint #1593 tried and withdrew, §
The chain), so no chain state can carry it. **A migrated singleton-side read therefore declines by
the closure, not the chain**: it answers `Unknown` when any module in the receiver's include/prepend
closure lists anything on its own `:extend` side (a hook's `"*"`; verified: `def self.included(base) =
base.extend(X)` lists `{include: ["*"], extend: ["*"]}` on the hook module), records a singleton
`included`, `extended`, `prepended` or `inherited` def (verified: `discovered_methods["H"] ==
{included: :singleton}`), or extends `ActiveSupport::Concern` (the concern shape lists nothing and
defines no hook of its own; the only signal is `discovered_extends["C"] == ["ActiveSupport::Concern"]`,
a name test the follow-up ADR replaces with the plugin-owned model). Existing readers keep master's
singleton answer, and #1592's hook shapes stay a false positive there until the follow-up ADR. A
singleton-side migration in PR C waits for #1593 to land, so that a block `extend` is at least a
recorded, listed edge.

### WD4 — Classification of every `DiscoveryIndex` member, with structural checks (landed)

`DiscoveryIndex::MEMBER_CLASSES` (`discovery_index.rb:73–125`, #1566) puts each `Data.define` member
(`:13–54`; 40 today, `unpositioned_mixins` among them since #1584) in exactly one of five classes with
a one-line reason, and `spec/rigor/declaration_facts/member_classes_spec.rb` fails on a member that is
unclassified or classified twice and checks each class's shape on a two-file fixture project. A table
added to the index must be classified in the same change.

| Class | Members | Shape check | Reference |
| --- | --- | --- | --- |
| `:set_valued` (may admit `possible_*`) | `discovered_classes`, `discovered_methods`, `discovered_refinements`, `discovered_global_write_census`, `discovered_includes`, `discovered_prepends`, `discovered_extends`, `unpositioned_mixins`, `discovered_class_sources`, `discovered_deferred_ranges`, `constant_sources`, `constant_writers`, `constant_shadowers`, `published_constant_names`, `local_constant_names`, `published_constant_alias_names`, `published_constant_ivars` | collections of names or rows; where the member admits `possible`, its sibling exists and every sibling entry is in the member | Ruby witness |
| `:single_valued` (may admit `contested_*`) | `discovered_def_nodes`, `discovered_singleton_def_nodes`, `discovered_def_sources`, `discovered_singleton_def_sources`, `discovered_method_visibilities`, `discovered_parameter_envelopes`, `discovered_superclasses`, `discovered_header_nestings`, `data_member_layouts`, `struct_member_layouts` | a slot kind recorded per member, no certainty wrapper; where the member admits `contested_*`, the sibling exists and its keys ⊆ member keys | Ruby witness (`source_location` for def identity) |
| `:typed` | `declared_types`, `class_ivars`, `class_cvars`, `program_globals`, `program_global_seeds`, `in_source_constants`, `param_inferred_types` | every leaf is a `Rigor::Type` value | The type lattice |
| `:syntactic` | `discovered_def_nestings`, `patched_line_readers`, `clears_last_status`, `defines_case_equality`, `implicit_self_evidence` | the same value from the file's parse alone (the ADR-53 shadow harness stays for these) | The parse |
| `:run_state` | `run_generation` | an opaque token only the runner's seed supplies | None |

The siblings WD1 adds join `MEMBER_CLASSES` as a sixth class when the first one lands: a `possible_*`
sibling has its member's shape and is `⊆ member`; a `contested_*` sibling is a Set of the member's keys;
a sibling exists iff its member admits `possible`.

### WD5 — The witness, at two levels

- **Table level** (landed, #1566: `spec/support/declaration_witness.rb`, fixtures under
  `spec/integration/fixtures/declaration_witness/`, `witness_spec.rb`). A fixture runs under the suite's
  Ruby with a time limit and records `Module.nesting` at each line that runs, each module's methods by
  side and visibility with their `source_location`, its mixins, its superclass, and the class of each
  class variable's value; the witness compares them with the index the runner seeds and
  `ScopeIndexer.index` (SI:103) builds. A set-valued table must satisfy `certain ⊆ runtime ⊆ certain ∪
  possible`, a single-valued one must agree wherever it answers. Since no `possible_*` table exists yet,
  every entry reads as `certain` except the self-extend edge Ruby does not show. `issue_1518`,
  `issue_1519`, `issue_1520` and `issue_1550` are `pending` beside a pin of today's exact violations
  (`witness_spec.rb:74–113`). The singleton-side block shapes of #1592 are the relation's `runtime ⊄
  certain ∪ possible` case that no fixture held; #1593 adds the block shapes at the read level and pins
  the hook shapes at their false positive.
- **Read level** (landed, #1578: `spec/integration/resolution_chain_witness_spec.rb`, 21 fixtures, and
  `spec/integration/ruby_order_resolution_spec.rb`). Each fixture runs under the Flake Ruby in a
  subprocess and reports `Method#owner`, `source_location` and `Module#ancestors`; the chain's project
  entries, its first definer and its `super` chain are compared, in the skip world or the retro world
  the fixture names, and a query listed under `master:` is one the worlds answer differently. This is
  the only witness for the chain, the fork rule and the unsettled rule, whose tables are correct while
  the reads are wrong. **PR C adds** fixtures for every candidate-set rule: the relevance rule's
  positive shapes for both kinds of mark, its five non-discharge shapes (an external closure entry RBS
  does not know, a dynamic-surfaced closure entry, a visibility-only statement, a `method_missing`, and
  a `"*"`), the two one-fork witnesses of WD2, WD3's three singleton-side decline signals, a
  conditional definer, the absent rule, and #1570.
- A fixture must fail on `master` before its fix. **Limit:** one run witnesses one execution; "every
  world" is approximated by fixture variants that take each branch, and a fabricated `certain` fact is
  caught only where a variant's run lacks it. The fuzzer stays local until its load rate on the
  constructs that matter (2–7 %) exceeds 50 %.

### WD6 — The producer tripwire (landed)

`spec/rigor/declaration_facts/producers_spec.rb` (#1566) parses every Ruby file under `lib/` and
`plugins/*/lib/` with Prism and lists each method, or class or module body, that (i) references a
declaration node class or its `Prism::Visitor` hook, (ii) names a node-type symbol, (iii) names a
visibility or mixin keyword as a symbol, or (iv) reads a constant built from one (`CLASS_BODY_NODES`,
SI:4106); or (v) is reachable, through same-file calls, from `ScopeIndexer.index` (SI:103),
`.accumulate_project_index` (SI:7797), `.finalize_def_index` (SI:7743), a multi-file entry point or any
method another covered file calls as `ScopeIndexer.x`, and writes into a table parameter; or (vi)
includes `DeclarationWalk::Collector`. Rule (v) is what marks the bug sites rules i–iv miss —
`record_module_function_names` (SI:4975), `record_singleton_def_node` (SI:4963),
`fold_extends_into_singleton_tables` (SI:6387) and `apply_alias_def_nodes` (SI:6792). `producers.yml`
holds 391 entries in 71 files: 371 `grandfathered`, a closed list pinned by count and digest, and 20
justified since, the mixin-accumulator producers of #1584 among them. A new producer must be recorded
with a reason; `RIGOR_REGENERATE_GATES=1` adds it as `TODO`, which the spec rejects until it is
justified. What the scan cannot see is in the spec's header (`producers_spec.rb:20–22`): dispatch on
`node.class.name`, on `Prism::Node#type` through a variable, through `const_get`, by duck typing, or on
a keyword spelled as a String. The tripwire lists producers; it does not see a producer that returns
from a node without walking it (the extend walk's block return, #1592), which only a witness catches.

### WD7 — Landing rules

Two lanes. Neither lane's list is sufficient: the review loop of `docs/agents/contribution-flow.md`
applies to every PR, and no listed gate may be skipped or replaced by a claim.

- **Lane 1 — behaviour-preserving changes** (refactors, ports onto `DeclarationWalk`, new data nothing
  reads, performance and allocation work, deleting a `RULE_VARIANTS` entry the walk's rule reproduces):
  byte-identical corpus diagnostics, byte-identical corpus `rigor sig-gen` output, the shadow harness
  wherever a table is rebuilt, the per-merge allocation sweep. A port may not change a fact. #1584
  landed under this lane (+0.03 % allocations).
- **Lane 2 — behaviour changes** to declaration facts or to how a read answers, in a `ScopeIndexer`
  walker, a `DeclarationWalk` collector, `ModuleFunctionState`, the fold, `ResolutionChain`, sig-gen,
  Effects, a plugin discoverer or a `Scope` reader, and deleting a `RULE_VARIANTS` entry whose variant
  was a bug. Necessary, not sufficient: (a) a reproduced bug's WD5 fixture fails before and passes
  after; (b) the corpus diagnostics diff **and** the corpus sig-gen diff, every changed line adjudicated
  under the false-positive rule (`visibility_excludes?` hides visibility changes from diagnostics,
  `generator.rb:732, 907`); (c) neither byte-identity to a predecessor nor a variant is claimed; (d) the
  per-merge allocation sweep runs and its answer is in the PR, on a plain **and** a recording run, and
  a change to the chain memo's tuple (WD2's marks, the on-demand retro world) reports the memo's growth
  separately from the recording edges; (e) for any change that can add or remove a `call.wrong-arity`
  firing, the `SourceArity` differential with its adjudicated removals; (f) a change that can widen a
  read to `Dynamic` reports, over the lane-2 corpus, the change in the (class, name) census of reads
  answering `Dynamic` taken from `rigor check --no-cache`'s own scopes (an instrumented run, since
  `rigor coverage` seeds from `DiscoverySeed.discovery_tables`, `lib/rigor/cli/coverage_scan.rb:60`,
  and `rigor type-of` reads every cross-file declaration as `Dynamic[top]`,
  `docs/agents/measurement.md:60–65`), with `rigor coverage`'s `dynamic_specific` / `dynamic_top` tiers
  (`coverage_command.rb:38–39`) as a secondary figure; (g) a change that adds an unsettled mark shows,
  on a fixture, that master's answer is right where the mark sends the reader — the check #1593's
  first draft failed. #1578 landed under this lane with (a)–(f): five fixtures failing on master,
  identical corpus and sig-gen diffs, the allocation sweep, the `SourceArity` levels A/B, and the
  precision run in Context. #1593 lands under it.

### What each part removes, and what remains

| Failure mode | Removed by | Remains |
| --- | --- | --- |
| 1 Prose enumeration | WD4 (members `Data.define`-derived, shape-checked; landed); WD6 (producers parsed; landed); WD1 (copy paths paired; slot readers censused, landed); the chain's detection spec (landed; the `case/in` discipline checked syntactically in PR C) | Grandfathered producers, walkers and slot readers converge as bugs are filed; the patterns are themselves stated lists; a walk that returns without descending is invisible to the tripwire (#1592) |
| 2 Variants by reading; vacuous sweeps | WD1 + WD7(c): no variants; a disagreement is a fixture or nothing; WD5 at both levels (landed) | Unknown constructs are found by users; one run witnesses one execution |
| 3 Several implementations of one question | `module_function`: one helper (#1563); resolution order: one chain inside every engine reader (#1578) | The helper preserves four semantics until PRs B–C; the allow-listed union walks and two RBS-interleaving first-definer bridges stay by design; concern hooks wait for the follow-up ADR |
| 4 Byte-identity to wrong legacy | WD1 + WD2 + WD7: over-approximation is legal only as `possible`; a migrated read answers from no `possible` definer, no unpositioned edge and no unsettled or forked chain; a marked entry keeps master's declines | A fabricated `certain` fact no fixture covers stays until reported; a hook's singleton-side edge is invisible to every existing reader until the follow-up ADR; typing through marked entries stays as on master, 41–51 % of GitLab's pairs; unmigrated readers keep master's answer on 21.3 % of Mastodon's reads |
| 5 Shifting justification | WD7: two lanes with fixed, necessary gates (#1584 and #1578 landed under them) | Triage decides what counts as reproduced |

## Migration

**Landed before acceptance.** #1551 (lane 1); #1563 (lane 1; the `module_function` readings behind one
helper, shadow-checked on the corpus); #1566 (lane 1; the four gates, recording today's behaviour);
#1584 (lane 1; `unpositioned_mixins`, `discovered_class_sources` on every run, the signature carrying
mixin order); #1578 (lane 2; the chain, `settle`, `MasterOrder`, the walker allow-list, the read-level
witness). **Still to land before acceptance:** #1593 (lane 2, narrowed under review: a block `extend`
or `class << self` mixin under a self-preserving iterator on a literal or constant receiver, written as
a direct statement of the class body, recorded and listed on `:extend`; no includer taint; the hook
shapes pinned at their false positive under #1592), on which WD1's mixin-member claim and any
singleton-side migration in PR C depend; #1548 (key the seeded deferred-ranges reuse, SI:336, on
content digest plus parse version, or drop it); WD1's `with` pairing and round-trip specs (lane 1);
the `SourceArity` oracle flag (lane 1); pending witness fixtures for #1570, #1572 and #1573. #1531
closes as superseded by this ADR.

**After acceptance — under WD7 lane 2.**

| PR | Change | Expected corpus diff | Expected sig-gen diff | False-positive check |
| --- | --- | --- | --- | --- |
| A — #1550 | The named form snapshots the last receiverless `def` before the call (SI:4975) | Zero (rare) | The singleton keeps the earlier body's type | Fixture asserts `Fmt.label == "one"` |
| B — reset, receiverless-only, privatisation | A bare visibility call ends the toggle; `def self.x` gets no instance copy; `attr_reader` private, no singleton copy; `define_method` both; a `certain` module function's instance copy recorded private (SI:6441–6448); sig-gen bypasses `visibility_excludes?` for module functions | Zero on existence; `Helpers#fmt` stops firing | Module functions after a reset stop rendering as singletons; omitted ones appear | Probes P1–P13, `vis.rb` |
| C1 — firing sites | `DefinerResolution` over the chain; `settle`'s option with the `:unknown` verdict and per-name relevance over the marks the chain memo now carries; `possible` definers and the mixin members' unpositioned reading; the `case/in` spec. Migrates **the `:arity` question at `SourceArity`'s decision point** (`walk_to_owner`, `source_arity.rb:109–129`: a `:master` verdict answers no envelope, and the walk's reads are recorded as read since another file's edit can lift it — #1570 and the conditional-include arity shape stop firing here on the boolean alone, with no new discovery data), the override super-method lint (`each_project_ancestor`, `check_rules.rb:3800`, and `override_visibility_diagnostic`, `:3736`), the visibility mismatch (`:2664`) and `singleton_context_def?` (`:3671`, with WD3's singleton-side decline). Admits `possible` facts into `discovered_methods`, the def-node tables, `discovered_method_visibilities`, `discovered_parameter_envelopes` and `discovered_deferred_ranges` once WD1's precondition holds for each | Silences #1570, the conditional-include and conditional-def arity shapes and the `Helpers2#fmt2` override; may silence firings that resolved through a `possible`-only definer; **every removed `call.wrong-arity` adjudicated** | A notice on `possible` module functions; `possible` definers render nothing new (RBS has no conditional form) | Every fixture at both witness levels; the differential; the two one-fork witnesses stay `Unknown`; the five non-discharge shapes stay `Unknown`; the #1591 breakdown reported; WD7(d) on the memo |
| C2 — typing sites | Return inference through `resolve_user_def_through_ancestors` (`expression_typer.rb:2471, 2496`, where `Unknown` types `Dynamic`) and the singleton memo (`:2386`, with WD3's singleton-side decline); the absent rule with its RBS census | Silences the conditional-definer and conditional-include `call.undefined-method` shapes, and the #1592 hook shapes at the migrated singleton site (`Unknown`, not a fix); `gemmod3` waits for #1572 | None expected | WD7(f) census before and after, adjudicated: GitLab's core models type `Dynamic` at these sites until PR D, and the PR states the count |
| D — hook facts per includer | Deferred to the follow-up ADR | — | — | — |

Precision estimate, unchanged from v12 and not re-measured (the landed PRs changed no producer that
moves it): about 13 of 940 mixin calls in Mastodon's `app`, 6 of 85 in `app/lib`, sit outside
unconditional bodies; Redmine has 17 `send(:include)` and 6 mixin calls inside methods. What C1 and C2
cost on Mastodon is bounded above by the 21.3 % of reads already answering from master, and relevance
lowers it by an amount PR C measures.

## Relationship to other ADRs

- **[ADR-24](24-self-method-call-resolution.md) — amended (landed).** Its § "Amendment 2026-09-28" is
  the binding text for the chain, `settle`, forks, unsettled chains, the single walker and the
  dependency edges; slice 2's breadth-first walk carries the superseded note (`:345–350`). Its #1570
  paragraph (`:634–644`) says what this ADR says: fixed by PR C at `SourceArity`'s decision point, with
  no new discovery data (the chain-memo change is relevance's, WD2, not #1570's). This ADR's reads are
  defined over that chain and add certainty on top. #1593 changes a producer, not the chain; the
  withdrawn includer taint is recorded here so it is not tried again.
- **[ADR-116](116-hot-file-restructuring.md) WD5 — partially superseded.** Byte-identity and the variant
  rule (`:160–184`) are retired for behaviour changes; its guardrails remain lane 1. The four ported
  collectors stay; `RULE_VARIANTS` entries are deleted under the lane their case belongs to. #1531
  closes as superseded; the README row drops "WD5 in progress" at acceptance. C1 is what WD1 applies to
  the copy paths.
- **[ADR-53](53-scope-discovery-index-separation.md)** — the shadow harness narrows to WD4's syntactic
  members and lane 1; the "generic-visitor rewrite: Deferred" row (`:233`) is marked superseded.
- **[ADR-85](85-seed-bundles-and-lazy-def-node-handles.md) WD2 — amended (landed for
  `unpositioned_mixins`).** Bundles carry the new member as plain data (`Descriptor::SCHEMA_VERSION`
  14, `IncrementalSnapshot::SCHEMA` 33); the WD1 siblings take the next bump, and
  `docs/internal-spec/cache.md` documents them.
- **[ADR-89](89-semantic-propagation-gates.md)** — the declaration signature carries the mixin lists in source order and the
  unpositioned table (SI:7250, landed by #1584), so an edit that only reorders or guards an include
  moves it; ADR-89 WD1 is otherwise unchanged.
- **[ADR-46](46-incremental-dependency-graph.md)** — preserved by the chain's dependency contract and
  WD2's recording through `Scope` readers, plus the negative class edge relevance files for a tested
  external; #1590 is a cost lever, not a contract change.
- **[ADR-17](17-monkey-patch-pre-evaluation.md)** — the fold's subtraction (SI:7754) is a consumer
  policy the WD5 relation is stated around.
- **[ADR-15](15-ractor-concurrency.md)** — plain frozen data; the chain memo is per index (RC:285–299).
  **[ADR-5](5-robustness-principle.md)** — unknown-is-silence at every migrated read.
  **[ADR-38](38-additional-initializers.md)** — the typed pre-pass's registry read is why the typed
  members are outside WD1.
- **[ADR-2](2-extension-api.md) — unchanged.** Plugins keep the same readers with the same shapes
  (`docs/internal-spec/inference-engine.md:655` for `user_def_for`, `:663` for the pair-returning walk)
  and received the corrected order as a bug fix; `Scope::ResolutionChain` and `DefinerResolution` are
  internal. Exposing either to plugins needs its own ADR-2 amendment. WD3's `ActiveSupport::Concern`
  name test is the one framework name the engine reads until the follow-up ADR moves the concern model
  behind the plugin API.
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
| Marking an includer's singleton chain unsettled on a hook's `:extend` entry (#1593's first draft) | Withdrawn | Unsettled means master's order, not a decline; master's singleton walk is superclass-only, so the taint reintroduced #1567's singleton false positive and removed none of #1592's. A hook edge needs the follow-up ADR's model or, at a migrated site, `Unknown` (WD3). |
| Recording a block `extend` under the lexical class whatever the block (#1593's first draft) | Withdrawn | Wrong when the block rebinds `self`; #1593 records only self-preserving iterators on a literal or constant receiver, as direct statements. |
| Per-name relevance on a chain with one retro-eligible fork (draft 13 rejected it on the two-fork shape) | Deferred | The two-fork shape is `:master` before any mark is read, so it decides nothing here. On a one-fork chain the fork rule compares the two worlds itself, and whether an irrelevant mark may be discharged there is not argued in this ADR; the witnessed cost of stopping at a fork is the `include M; include X; include Q if …` shape, `Unknown` at migrated sites though Ruby answers `X#foo` in all four worlds. Extending the rule needs its own argument and witness. |
| Discharging a mark on a closure with no project definer of the name (draft 13) | Rejected | Vacuous on an external entry (`include Ext if …`: a gem's `Ext#foo` may answer) and on a dynamically defined module (no row, the `<dynamic>` mark; master fires on `C.new.foo.upcase`), and blind to `private :to_s` and `method_missing`. The rule now requires a closure that provably cannot answer the name. |
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
  #1570 is fixed where C1 migrates the arity site. No consumer walks ancestry on its own except the 14
  allow-listed union and bridge walks, and a spec keeps it so.
- No read carries a direction label; a migrated site answers or is silent by one rule, floored by the
  `SourceArity` differential; every other site and every plugin reads the corrected order through the
  same readers; a member holds `possible` facts only once its copy paths are paired and its slot reads
  migrated. The mixin members hold them already, as `unpositioned_mixins`, for the edges the walks
  record.
- `module_function` has one implementation; #1550, both `vis.rb` false positives and the ancestry
  probes are fixed under a stated relation.

Negative:

- **Precision cost of unknown.** At a migrated site a `possible`-only definer, a contested definer, a
  relevant unpositioned edge or a chain that does not stand answers `Dynamic`; relationship lints are
  silent where some world has no super method. On Mastodon the ceiling is 21.3 % of ancestor reads
  (#1591) before relevance; on GitLab, Project, Group and User stay `Unknown` at migrated sites until
  the follow-up ADR, and typing through their marked entries stays as on master. Relevance stops at a
  fork, so a one-fork chain whose worlds agree still declines. A migrated singleton-side read declines
  on every class whose closure holds a concern or a hook (WD3), which on a Rails app is most models.
  **Defs inside blocks** become `possible` definers: v12 counted 74 of 7,181 defs in Mastodon, 3,772
  of GitLab's including `ee/` (about 142 exempt as meta-new blocks; `prepended do` alone holds 354)
  and 162 of 9,657 in Rigor's `lib` (132 in `Data.define` blocks, exempt); the rest type `Dynamic` at
  migrated sites until the follow-up positions them.
- **A hook's singleton-side edge stays a false positive in the existing readers** (#1592's hook
  shapes) until the follow-up ADR; no chain mark can fix it, since a mark sends the reader to master's
  order, and WD3's decline reaches migrated sites only.
- **Coverage cost of declining.** C1's `SourceArity` stops firing on unsettled chains: on a Rails app a
  fifth of ancestor reads. Each removed firing is adjudicated in the PR; a true positive lost there is
  the price of the false positives silenced, and the count decides whether relevance must land first.
- **Recording cost.** A recording run pays +5.1 % allocations for the after-answer edges `settle`
  files (#1578), before #1590; C1's relevance adds the closure probes and, for a tested external, a
  negative class edge, on unsettled chains only, and grows the chain memo by the marks, which WD7(d)
  reports on both runs.
- **User-visible sig-gen changes** (PR B), each with a changelog entry.
- **Grandfathered sets**: 371 producer entries, the chain's 14 allow-listed walkers and the slot readers
  the census reports converge only as bugs are filed.
- One small sibling per admitting definer member, a `with` that raises on a half pair, a `SCHEMA` bump.
- No speed is claimed.

## Open questions for the maintainer

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
   is not acceptable, or if #1592's hook shapes are reported from a corpus.*
10. **Relevance on a one-fork chain.** Deferred here; the agreeing-worlds witness is pinned as a
    decline. *Default: deferred until PR C's #1591 breakdown shows the share it would recover.*
11. **WD3's singleton-side decline signals.** The `ActiveSupport::Concern` name test is a framework
    name in the engine. *Default: accept until the follow-up ADR, with the plugin API as its home.*
