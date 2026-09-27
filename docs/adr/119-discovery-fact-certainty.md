# ADR-119 — Certainty on discovery facts, candidate-set reads: a witness gate replaces byte-identity

Status: **Proposed, 2026-09-28.** Awaiting the maintainer's acceptance. Nothing behaviour-changing has
landed. Landed already, byte-identical and independent of this decision: #1551 (the layered
def-nesting lookup). Open as a Draft, byte-identical: #1563 (the `module_function` readings behind one
helper). The gates in § Migration are not yet opened. Every `file:line` below is at `origin/master`
`dde39b6d4`; SI is `lib/rigor/inference/scope_indexer.rb`.

Grounding: the design-review rounds on #1531 and #1507 (2026-09-28), the adversarial critiques they
answered, the two reviews of this ADR's drafts on #1562, and the probes reproduced in Context. ADR-49
archetype: deliberative; stakes: high (it moves the false-positive envelope of every discovery table).

## Context

ADR-116 WD5 moved `ScopeIndexer`'s table walkers onto one declaration walk, each port required to be
byte-identical to the walker it replaced, with a named *variant* wherever the walkers disagreed
(`docs/adr/116-hot-file-restructuring.md:160–184`). Four tables were ported (#1517, #1522, #1527). A
contract for the next four walkers went through three adversarial review rounds on #1531 and did not
converge; the ports were paused. The reviews and this ADR's probes attribute that to five failure
modes, each of which the Decision addresses by mechanism rather than by another list.

1. **Enumeration in prose never converges.** Every list was incomplete in the next round: the quirk
   list (H1), the "four versus twenty walkers" pause scope, then the context computers outside
   `ScopeIndexer` — sig-gen's own `module_function` rule (`lib/rigor/sig_gen/generator.rb:665–688`),
   `Effects::DefinitionContext` (`lib/rigor/effects/definition_context.rb:34`), `Effects::Visibility`,
   which reads visibility off a statement list and names no declaration node
   (`lib/rigor/effects/visibility.rb:7–40`), `Plugin::NodeContext` (`lib/rigor/plugin/node_context.rb:22`),
   `SyntheticMethodScanner#build_hierarchy` (`lib/rigor/inference/synthetic_method_scanner.rb:369`),
   the ActiveRecord `ModelDiscoverer`, and the evaluator's own class entry
   (`lib/rigor/inference/statement_evaluator.rb:2699, 2719, 5178`). Inside `scope_indexer.rb`, 21
   methods dispatch on a declaration node through a `when` arm and 15 more through `is_a?` or the
   `CLASS_BODY_NODES` Set (SI:4030, defined at SI:4081). On the read side the same thing holds:
   `Scope` exposes every table raw (`lib/rigor/scope.rb:41–75`), a member-name search finds 36 files
   outside the table owners reading them, some on purpose (`rbs_dispatch.rb:854–863`), and the seed
   paths copy explicit member lists (`lib/rigor/analysis/runner.rb:2006`, `worker_session.rb:344`,
   `lib/rigor/inference/parameter_inference_collector.rb:258`,
   `lib/rigor/protection/discovery_seed.rb:97–108`,
   `lib/rigor/cli/coverage_mutation.rb:135`, `lib/rigor/sig_gen/observation_collector.rb:92`) or read
   short keys (`lib/rigor/analysis/incremental_session.rb:872, 941, 969`).
2. **Variants were found by reading code and diffing walker against walk**, so they grew as
   O(walkers × categories): `RULE_VARIANTS` went from none to four rules in three slices
   (`lib/rigor/inference/declaration_walk/traversal.rb:89–94`) and the draft needed six more. They
   protect behaviour no corpus exercises — #1527's control switched each variant to the walk's rule and
   found no divergence in 67,137 files — and a shadow sweep over a corpus that lacks a construct passes
   without checking anything (S1). `RIGOR_SHADOW_RULE_WALK` is set by no workflow or Makefile target.
3. **One semantic question had several implementations and no reference.** `module_function`'s
   definee is computed as a sibling-statement toggle (SI:4948–4979), as a prescan that enters blocks and
   control flow and stamps a `kind` on deferred-range rows (SI:4217–4238, 4260–4271), as an orderless
   self-extend (SI:6185–6198), and as sig-gen's direct-statement toggle (`generator.rb:665–688`). The
   visibility walker ignores it entirely (SI:6279–6420). Ruby's own answer is run-dependent: a bare
   call inside `if`, `each {}`, `tap {}`, a called lambda or a called `def self.setup` takes effect; an
   uncalled lambda does not; a bare `public`/`private`/`protected` resets it; `def self.x` gets no
   instance copy; `attr_reader` becomes private with no singleton copy; the named form snapshots the
   earlier `def`, so a later redefinition is public (probed on Ruby 4.0.5 during the review; the probes
   become WD5 fixtures in Migration step 3).
4. **Byte-identity was demanded against walkers that are wrong or deliberately over-approximate.**
   The extends walker over-approximates on purpose, in the ADR-5-safe direction (SI:5958–5963).
   #1518–#1520 are rules wrong in several walkers at once. #1550 is a false positive on correct Ruby:
   `module_function :label` followed by a redefinition resolves the *later* `def`, because
   `record_module_function_names` reads a name map in which a later `def` overwrites the earlier
   (SI:5030–5042). `def.override-visibility-reduced` fires on a private override of `Helpers2#fmt2`
   after `if true; module_function; end`, although Ruby makes the module's copy private
   (`lib/rigor/analysis/check_rules.rb:3710–3720`; reproduced with `rigor check` during the review).
5. **The justification shifted** from speed to C2 without a criterion for landing a port. The speed
   case was measured and found absent: the four remaining walks are about 0.2 % of a cold run
   (`docs/adr/116-hot-file-restructuring.md:175` still calls the merge "the wall lever").

Four findings bound the design. The typed pre-passes — ivars, cvars, globals, constants — call
`scope.type_of` under a scope carrying the project seed and the plugin registry (SI:1713, 1755, 1774,
2110, 2230, 2995; registry at SI:969–980), so they are not pure functions of a file. A table-level
approximation *direction* is ill-posed: visibility is read to fire and silenced by `nil`
(`check_rules.rb:3710–3720`) and constants are read in both directions (`scope.rb:136–155`). A
**per-read direction is ill-posed too**: on a nearest-first ancestor walk, keeping a `possible` edge
shadows a further ancestor and dropping it exposes one, so either direction fires falsely. Probe
`class C < Base; include M if ENV["X"]; end` with `M#foo(required)` and `Base#foo`: today `rigor check`
reports `call.wrong-arity` on `C.new.foo`, which runs when `X` is unset; with `M#foo` private and `C#foo`
private, a certain-only override walk reaches `Base#foo` and fires `def.override-visibility-reduced`,
which the union walk stays silent on (the walk is built from `includes_of`, `superclass_of`,
`user_def_for` and `known_user_class?`, `check_rules.rb:3748–3807`; the same readers suppress
`undefined-method` at `:952`). And a single-valued table has no union: an extra singleton def
*displaces* the right one (last-write-wins, SI:5007–5013), and scalar consumers deref the value
(`runner.rb:590–616`).

## Decision

**Criterion.** A discovery producer is judged by a relation Ruby can witness, never by identity to a
predecessor: a fact is *certain* (it holds in every execution of the file's declaration bodies) or
*possible* (it holds in some). A read answers only when its answer does not depend on which `possible`
facts hold; otherwise it answers *unknown*, and every consumer already treats unknown as silence
(ADR-5: a `nil` visibility silences the rule, a `Dynamic` type withholds). A behaviour change to a
producer lands under WD7's second lane; a behaviour-preserving change under its first. Speed is
measured and is never the reason.

### WD1 — Storage: today's tables keep today's meaning; `possible` lives beside them

- Every existing member keeps exactly its current contents and semantics: it holds the **union**
  (`certain ∪ possible`), which is what every reader consumes today. Existing readers, raw reads and
  scalar derefs (`runner.rb:590–616`, `rbs_dispatch.rb:871`) keep their meaning.
- A set-valued member that admits `possible` facts has a `possible_*` sibling holding only the
  `possible` facts, so `certain = member − possible_*`. The sibling is small (a `certain_*` copy would
  double the table). A single-valued member that admits `possible` facts keeps its scalar slot and
  today's fold, and has a `contested_*` sibling: the keys whose value depends on a `possible` fact,
  including keys whose only definer is `possible` (no certain alternative). Slots hold what they hold
  today — a def node, a name, a chain, an alternatives list (`scope/discovery_index.rb:83–85`), a layout
  — and never a new wrapper.
- Siblings **always exist** for the members that admit `possible` facts, empty by default, so a copy
  path that drops one is a codec bug the WD4 spec catches, never a silent change of meaning.
- Both stay plain frozen data, Marshal-clean for seed bundles and fork payloads.
- **Admission precondition (C1).** A member may admit `possible` facts only once every path that
  copies or seeds discovery tables iterates one declaration of the members and their siblings —
  `Runner#project_scope_seed_tables` (`runner.rb:2006`), `WorkerSession` (`worker_session.rb:344`), the
  protection seed (`discovery_seed.rb:97–108`), the parameter-inference collector's `DISCOVERY_FIELD`
  (`parameter_inference_collector.rb:258`), the coverage seeds (`cli/coverage_scan.rb:58`,
  `cli/coverage_mutation.rb:135`), the sig-gen observation seed (`observation_collector.rb:92`), the
  incremental session's short-key reads (`incremental_session.rb:872, 941, 969`) and the bundle codec —
  and, for a single-valued member, once every raw read of its slot outside the table owners consults
  `contested_*` or goes through a `Scope` reader. The census is a spec: it parses `lib/` and `plugins/`
  with Prism and reports every `discovered_*`/`published_constant_names`/`local_constant_names`/
  `*_member_layouts` method call or `[:member]`/`fetch(:member)` short key outside `scope.rb`,
  `scope/discovery_index.rb`, `scope_indexer.rb` and `runner/project_pre_passes.rb`, keyed by member;
  a member whose census is non-empty may not be admitted. This ADR admits none; Migration PR C admits
  the first (`discovered_extends`, `discovered_methods`, `discovered_singleton_def_nodes`,
  `discovered_method_visibilities`) after its census is cleared.

### WD2 — Candidate-set reads

A read that answers a question about a member — its definer, visibility, arity, type, or the identity
of an ancestor — walks the union nearest-first as today and collects the **candidate set**: every
definer of the member it meets up to and including the first one reached through `certain` facts
only. The read answers when every candidate gives the same answer to the question asked, and answers
*unknown* (`nil`, empty, `Dynamic`) otherwise. A read that asks only whether *some* fact exists
(`discovered_method?` at `scope.rb:987`, `known_user_class?`, `published_constant?`) answers over the
union, which is withholding by construction, and every precise read downstream of it is a candidate-set
read, so a `possible` existence never yields a precise wrong answer.

- In the common case the nearest definer is certain, the set is a singleton, and the read costs what it
  costs today: one membership test in `possible_*` per visited edge, and the walk stops where it stops
  now. It walks further only past a `possible` definer.
- This is sound for nearest-first walks because it asks whether the answer depends on any `possible`
  fact on the path, not whether two chosen worlds agree. Agreement between the certain-only world and
  the union world is **not** sufficient: with `possible` `A#foo()` nearest, `possible` `B#foo(x)` next
  and certain `Base#foo()`, both worlds answer arity 0 while a run that includes only `B` needs one
  argument. The candidate set `{A, B, Base}` disagrees and answers unknown.
- For a single-valued slot the rule is the same within one class: a `contested_*` key answers unknown;
  a key with no certain definer is contested.
- No direction labels and no reader allowlist exist. The `Scope` readers that answer questions
  (`user_def_for`, `singleton_def_for`, `user_def_through_ancestors` at `scope.rb:1358`,
  `superclass_of`, `includes_of`, `prepends_of`, `discovered_method_visibility` at `scope.rb:1823`) and
  the walks built on them (`each_project_ancestor`, `check_rules.rb:3748`;
  `resolve_user_def_through_ancestors`, `expression_typer.rb:2474`) become candidate-set reads by
  implementation, and a raw slot read is admitted only under WD1's precondition.
- The constant tables (`published_constant_names`, `local_constant_names`) admit no `possible` facts in
  this ADR; nothing emits them yet.

### WD3 — Edge certainty

An `include`, `prepend` or `extend` edge is `certain` when the call is a direct statement of a
`class`/`module` body, and `possible` otherwise: inside control flow, inside a method, through `send`,
or with a computed argument. Today every such edge is recorded alike (`mixin_tables`, SI:5718;
`write_mixin_targets`, SI:5918); the `possible_includes`/`possible_prepends`/`possible_extends`
siblings carry the distinction, and WD2 reads it.

**Deferred to a follow-up ADR: hook facts instantiated per includer.** `ActiveSupport::Concern`'s
`included do` and `class_methods do` run once per includer in the includer's context, which is
PHPStan's trait model (<https://phpstan.org/blog/how-phpstan-analyses-traits>). Today every walker
treats those blocks as ordinary calls under the concern's own owner (`included` and `class_methods`
are in neither the eval-family lists, SI:2755, 2770, nor the opaque list, SI:2762; `rebound_block_self`,
SI:2918–2925; the mixin walk, SI:5862–5889), `SyntheticMethodScanner` replays `included do` macro
calls only (`synthetic_method_scanner.rb:326–362`) and the ActiveRecord `ModelDiscoverer` recognises a
concern by its `included do` block, not by the `extend` line
(`plugins/rigor-activerecord/lib/rigor/plugin/activerecord/model_discoverer.rb:549–550, 573`).
The probes on Ruby 4.0.5 with ActiveSupport 8.1.3 show the precedence rules the follow-up must state:
`extend X; include M` resolves `build` to `M::ClassMethods` and the reverse order to `X`; `prepend M`
puts `M::ClassMethods` ahead of the includer's own `def self.build` in either order and runs
`prepended`, not `included`; `include M, N` applies right to left, so `M` wins; a `def self.x` inside
`included do` is the includer's singleton method; a concern included into a plain module extends
`ClassMethods` onto that module, not its includers. The follow-up also owns the fold-level witness
(WD5 here compares per-file tables, which never contain instantiated facts), the incremental closure
(`discovered_class_sources` means "files that declare C", `runner.rb:626–630`; a recheck's
`symbol_fingerprints_from_index` folds only the changed files, `incremental_session.rb:868–876`), the
ADR-89 declaration signature (SI:7024), and the fact that the existing extends fold writes no
def-source rows (SI:6218–6230), so a call resolved through it records no dependency
(`lib/rigor/analysis/dependency_recorder.rb:283`).

### WD4 — Classification of every `DiscoveryIndex` member, with structural checks

A spec classifies each of the 39 `Data.define` members (`discovery_index.rb:13–53`) into exactly one
class, fails on an unclassified member, and asserts each class's structural property on an index built
from a fixture project, so a member that carries the wrong shape fails, not only a missing label.

| Class | Members | Structural assertion | Reference |
| --- | --- | --- | --- |
| Set-valued (may admit `possible_*`) | `discovered_methods`, `discovered_includes`, `discovered_prepends`, `discovered_extends`, `discovered_classes`, `published_constant_names`, `published_constant_alias_names`, `local_constant_names`, `constant_writers`, `constant_shadowers`, `constant_sources`, `discovered_refinements`, `discovered_global_write_census`, `discovered_deferred_ranges` (rows; the `kind`/`owner` columns come from the shared `module_function` helper) | values are Sets/Arrays/Hashes of names or rows; where the member admits `possible`, its sibling exists and `possible_* ⊆ member` | Ruby witness |
| Single-valued (may admit `contested_*`) | `discovered_def_nodes`, `discovered_singleton_def_nodes`, `discovered_def_sources`, `discovered_singleton_def_sources`, `discovered_superclasses`, `discovered_method_visibilities`, `discovered_header_nestings`, `data_member_layouts`, `struct_member_layouts` | each slot holds the value kind it holds today (node, handle, name, chain or alternatives list, layout) and no certainty wrapper; where the member admits `contested_*`, the sibling exists and its keys ⊆ member keys | Ruby witness (`source_location` for def identity) |
| Typed | `declared_types`, `class_ivars`, `class_cvars`, `program_globals`, `program_global_seeds`, `in_source_constants`, `param_inferred_types`, `published_constant_ivars` (provisional) | every leaf is a `Rigor::Type` value | The type lattice: union and `Dynamic` express uncertainty; WD1 does not apply |
| Syntactic | `discovered_def_nestings`, `discovered_class_sources`, `discovered_parameter_envelopes`, `patched_line_readers`, `clears_last_status`, `defines_case_equality` | rebuilt byte-identically by the shadow oracle on the fixture | The parse; the ADR-53 shadow harness stays for these |
| Run state | `run_generation`, `implicit_self_evidence` | absent from every seed bundle | None |

Deferred ranges and def sources are not syntactic: the range rows carry the `module_function`
definee (SI:4260–4271) and the def sources come from the definee walker (SI:7622) and feed the
ADR-17/#735 suppression through `Scope` (`scope.rb:1045, 1094, 1111, 1127, 1143`). Both change in
Migration PRs B and C and are gated by WD5, not by byte-identity.

### WD5 — The witness

One spec fixture per filed bug, executed in a subprocess under the Flake's Ruby, records
`Module.nesting`, `instance_methods(false)`, `singleton_methods(false)`, the three visibility sets,
`ancestors`, `Method#owner` and `Method#source_location`, and compares them with the **per-file**
tables (`build_file_index`, SI:7284) under WD1's relation and, for def identity, by line. The relation
is stated per file because `finalize_def_index` deliberately subtracts plain cross-file defs (SI:7565–7569,
ADR-17); that subtraction is a consumer policy, not a witness failure. Facts the fold synthesises
(the extends fold, SI:6218–6230; any future per-includer instantiation) are outside this witness and
belong to the follow-up ADR. A fixture must fail on `master` before its fix, so every fixture is its
own positive control. **Limit:** one run witnesses one execution; "every run" is approximated by
fixture variants that take each branch of the construct under test, and a fabricated `certain` fact is
caught only where a variant's run lacks it. Programs that fail to load are dropped. The fuzzer stays a
local tool until its load rate on the constructs that matter (measured at 2–7 %) exceeds 50 %.

### WD6 — The producer tripwire

A spec parses every Ruby file under `lib/` and `plugins/` with Prism and marks a **method** a producer
when its body references `Prism::ClassNode`, `Prism::ModuleNode` or `Prism::SingletonClassNode` in any
form — a `when` arm, `is_a?`, `===`, a bare constant read, the node-type symbols `:class_node`,
`:module_node`, `:singleton_class_node` — or references a constant whose definition, resolved by
parsing the constant assignments of the same file, contains one of them (`CLASS_BODY_NODES`, SI:4081;
`IVAR_BARRIER_NODES`). It also marks every class whose ancestry includes `DeclarationWalk::Collector`
(the ported collectors name no node class: three of the four match nothing, so ancestry is the only
signal), and every method naming a visibility or mixin keyword as a symbol (`:private`, `:protected`,
`:public`, `:module_function`, `:include`, `:extend`, `:prepend`), which catches
`effects/visibility.rb`-style computers. It compares the set with a committed allowlist of
`file#method` entries; any new entry fails. Today: 36 methods in `scope_indexer.rb`, four collectors,
and the methods of the other 56 files. **What remains:** a computer that dispatches on `node.class.name`
strings, on `Prism::Node#type` through a variable, or on a keyword spelled as a String, is not found;
the allowlist freezes the set and certifies nothing about how an entry computes its context.

### WD7 — Landing rules

Two lanes. Neither lane's list is sufficient on its own: the review loop of
`docs/agents/contribution-flow.md` applies to every PR, and a gate that is listed is a gate that runs.

- **Lane 1 — behaviour-preserving changes**: refactors, ports onto `DeclarationWalk`, performance and
  allocation work in any producer or reader. They land under byte-identical corpus diagnostics,
  byte-identical corpus `rigor sig-gen` output, the shadow harness wherever a table is rebuilt, and the
  per-merge allocation sweep (ADR-116's guardrails). A port may not change a fact; a change to a fact
  is a lane-2 change.
- **Lane 2 — behaviour changes to declaration facts** or to how a read answers, in a `ScopeIndexer`
  walker, a `DeclarationWalk` collector, the fold, sig-gen, Effects, a plugin discoverer or a `Scope`
  reader. They land only when all of the following hold, and these are necessary, not sufficient:
  - (a) a reproduced bug's WD5 fixture fails before and passes after;
  - (b) the PR carries the corpus diagnostics diff **and** the corpus `rigor sig-gen` output diff, every
    changed line adjudicated under the false-positive rule in the PR body; sig-gen is in scope because
    `visibility_excludes?` hides visibility changes from diagnostics (`generator.rb:738–747`, first in
    `classify_def` at `:912–913`);
  - (c) the PR claims neither byte-identity to a predecessor nor a variant;
  - (d) the per-merge allocation sweep runs and its answer is in the PR.

### What each part removes, and what remains

| Failure mode | Removed by | Remains |
| --- | --- | --- |
| 1 Prose enumeration | WD4 (members are `Data.define`-derived and shape-checked); WD6 (producers are parse outputs); WD1's admission census (readers and copy paths are parse outputs, and a member is admitted only when its census is empty) | Grandfathered producers converge only as bugs are filed; the census's search patterns are themselves a list, stated in WD1 |
| 2 Variants by reading; vacuous sweeps | WD1 + WD7(c): no variants; a disagreement is a fixture or nothing; WD5: a fixture is a positive control | Unknown constructs are found by users, not generated; one run witnesses one execution |
| 3 Several `module_function` implementations | One helper with a three-valued answer (#1563), consumed through WD2 (Migration B, C) | Concern hooks stay several implementations until the follow-up ADR |
| 4 Byte-identity to wrong legacy | WD1 + WD2 + WD7: over-approximation is legal only as `possible`, and no read answers from it | A fabricated `certain` fact no fixture covers stays until reported |
| 5 Shifting justification | WD7: two lanes with fixed, necessary gates; speed is never the reason | Triage decides what counts as reproduced |

## Migration

**Before acceptance — byte-identical or an ordinary bug fix, no ADR needed.**

1. **#1551 (merged).** `merge_def_nestings` returns a layered lookup instead of copying the project
   table per analysed file (SI:349–354).
2. **#1563 (Draft).** A pure move of the three `ScopeIndexer` `module_function` answers and sig-gen's
   behind one helper with four entry points; shadow-checked on the corpus.
3. **The gates (to be opened as Drafts).** The WD4 classification spec with its structural assertions;
   the WD6 producer tripwire with today's `file#method` entries; the WD1 admission census, reporting
   today's reads and copy paths per member; the WD5 harness with fixtures for #1518, #1519, #1520,
   #1550, the `module_function` probes and the two ancestor-walk probes of Context, all marked pending.
4. **#1548.** The seeded deferred-ranges reuse keys on path presence (SI:312–314) while analysis parses
   with `version:` (`runner.rb:1985–1994`) and the pre-pass without (SI:7198), and the mutation oracle
   seeds a mutant with its parent's ranges (`discovery_seed.rb:97–108`, `diagnostic_oracle.rb:52–55`).
   Key it on content digest plus parse version, or drop it.
5. **Declaration-driven copy paths (lane 1).** The seed and bundle paths listed in WD1 iterate one
   declaration of members and siblings; byte-identical, and the precondition every admission needs.

**After acceptance — the first behaviour-changing PRs, each under WD7 lane 2.**

| PR | Change | Expected corpus diff | Expected sig-gen diff | False-positive check |
| --- | --- | --- | --- | --- |
| A — #1550 | The named form snapshots the last receiverless `def` before the call; a later redefinition is a public instance `def` | Zero (rare construct) | The singleton keeps the earlier body's type | Fixture asserts `P9.a == 1`; removing a fabricated later-def singleton can only replace a suppressed call with the correct type |
| B — reset, receiverless-only, privatisation | A bare `public`/`private`/`protected` ends the toggle; `def self.x` gets no instance copy; `attr_reader` is private without a singleton copy; `define_method` gets both; a `certain` module function's instance copy is recorded private (the visibility walker ignores `module_function` today, SI:6279–6420); sig-gen bypasses `visibility_excludes?` for module functions | Zero expected on existence; `def.override-visibility-reduced` stops firing on `Helpers#fmt` (private overriding private); any new firing is on code where Ruby raises | Module functions after a reset stop rendering as singletons; `private; module_function; def b` now renders its singleton (today omitted) | Fixtures P1, P2, P3, P10, P12, P13 and `vis.rb`; existence rows removed are rows Ruby never creates |
| C — candidate-set reads and the first `possible` facts | The `Scope` readers and walks of WD2 become candidate-set reads (a lane-2 change: a possible-only definer now types `Dynamic`); then, once the WD1 census for the four members is empty, a bare `module_function` inside control flow, a block or a singleton-method body preceding the `def` becomes a `possible` self-extend and a contested visibility, and an `include`/`prepend`/`extend` inside control flow or a method becomes a `possible` edge | Silences the `Helpers2#fmt2` firing and the `call.wrong-arity` on `C.new.foo` of Context; may silence checks that resolved through a possible-only definer; Rails concerns keep today's answers, since hook facts are not yet instantiated | A notice on `possible` module functions; `possible` edges render nothing new (RBS has no conditional form) | Fixtures A, B, C, E, F, H, J and the two ancestor-walk probes; a candidate-set read can only withhold where today's read fires |
| D — hook facts per includer | Deferred to the follow-up ADR (WD3) | — | — | — |

## Relationship to other ADRs

- **[ADR-116](116-hot-file-restructuring.md) WD5 — partially superseded.** Its byte-identity requirement
  and variant rule (`:160–184`) are retired for behaviour changes; a blockquote at that point names this
  ADR. Its guardrails remain the gate for lane 1. The four ported collectors stay; each `RULE_VARIANTS`
  entry is deleted when a WD5 fixture shows the walk's rule conformant or the variant a bug. #1531 closes
  as superseded; its note remains as the list of candidate fixtures. The README row for ADR-116 drops
  "WD5 in progress". ADR-116 C1 ("declare once") is what WD1's admission precondition applies to the
  seed and bundle paths.
- **[ADR-53](53-scope-discovery-index-separation.md)** — the shadow harness's role narrows to WD4's
  syntactic members and to lane 1; the "generic-visitor rewrite: Deferred" row (`:233`) is marked
  superseded by this ADR's mechanism, which needs no rewrite. WD2's explicit keyed readers are where the
  candidate-set reads live.
- **[ADR-85](85-seed-bundles-and-lazy-def-node-handles.md) WD2 — amended.** Bundles carry the
  `possible_*` and `contested_*` siblings; the next `IncrementalSnapshot::SCHEMA` bump
  (`lib/rigor/cache/incremental_snapshot.rb:148`, currently 30) covers the new rows, and
  `docs/internal-spec/cache.md` documents them.
- **[ADR-46](46-incremental-dependency-graph.md)** — unchanged by this ADR. The gaps the follow-up must
  close are recorded in WD3: an includer's class dependency records its own `discovered_class_sources`
  (`scope.rb:1769–1771`), and a call resolving through the extends fold has no def-source row to record
  (SI:6218–6230, `dependency_recorder.rb:283`).
- **[ADR-17](17-monkey-patch-pre-evaluation.md)** — the fold's subtraction of plain cross-file defs
  (SI:7565–7569) is a consumer policy the WD5 relation is stated around, not a violation of it.
- **[ADR-15](15-ractor-concurrency.md)** — the sibling tables are plain frozen data; no module-level
  memo is added. **[ADR-5](5-robustness-principle.md)** — WD2's unknown-is-silence is its principle
  applied at every read. **[ADR-38](38-additional-initializers.md)** — the typed pre-pass's registry
  read (SI:969–980) is unchanged and is why the typed members are outside WD1.
- **`rigor sig-gen` output is a gated artifact** in both lanes (WD7); ADR-89 WD1's declaration
  signature is not changed by this ADR.
- **Follow-up ADR (to be numbered): hook facts per includer.** Owns WD3's deferred part, the fold-level
  witness, the precedence rules, the incremental closure and the ADR-46/ADR-89 consequences.

## Rejected / deferred alternatives

| Candidate | Status | Reason |
| --- | --- | --- |
| A per-file declaration-fact IR (round 1): one emitter, tables as folds, facts cached by digest | Rejected | The typed pre-passes are not pure per file (SI:1713–2995 with the seed and registry); the flow-sensitive ivar pass (SI:396–411) does not fit rows; the default path never loads a snapshot (`runner.rb:1558–1563`), so caching is #120, not an IR property; and quirks would return as fold policies. |
| Ruby as the judge of every disagreement | Rejected | The same text has several Ruby answers (Context 3); the extends over-approximation is deliberate (SI:5958–5963); Zeitwerk namespace synthesis makes correct fixtures raise; six members have no runtime counterpart. Ruby is WD5's *witness* for a stated relation, not a judge. |
| One approximation policy per table | Rejected | Visibility, constants and ancestry are each read in both directions, and a single-valued table cannot be a superset (Context, last paragraph). |
| Storing `certain` facts in the existing member with `possible_*` beside it (first draft) | Rejected | Every unmigrated reader would silently become certain-only, and a scalar deref would meet an alternatives Array (`runner.rb:616`, `rbs_dispatch.rb:871`). |
| Direction fixed once per `Scope` reader (first draft) | Rejected | The override walk uses the same readers that suppress `undefined-method` (`check_rules.rb:3748–3807`). |
| Direction fixed per call site with a labelled read-site allowlist (second draft) | Rejected | On a nearest-first walk neither direction is safe: keeping a `possible` edge shadows a further ancestor (`call.wrong-arity` on `C.new.foo`), dropping it exposes one (`def.override-visibility-reduced` against `Base#foo`) — Context, last paragraph. Labels were self-declared, and a mislabelled site would fire once PRs add `possible` facts to the union. |
| Agreement between the certain-only world and the union world | Rejected as the rule (kept as a special case) | Two `possible` definers with compensating answers make both worlds agree while a run that holds only one of them differs (WD2's arity example). The candidate set covers every subset. |
| `certain_*` siblings (second draft) | Rejected | A near-full copy of each admitting table; `possible_*` is small and `certain = member − possible_*`. |
| Copying `class_methods` defs as `def self.` rows on each includer | Rejected | Ruby puts them on `M::ClassMethods`, which the includer extends; the extends fold's `||=` and the probes' ordering rules (WD3) show the model is an edge with a position, not copied rows. Owned by the follow-up ADR. |
| Concern-hook instantiation inside this ADR (second draft's WD3) | Deferred to the follow-up ADR | Its facts live in the fold, which WD5 cannot witness; its precedence rules need their own probes (WD3); its incremental closure and ADR-89 consequences are open (WD3); and it would put `discovered_class_sources` in two WD4 classes at once. |
| A per-file overlay over the frozen seed for all merged tables | Rejected | Not byte-identical as specified: it omitted the kind-promoting union (SI:3267–3270), refinements (SI:3183–3184), envelopes (`lib/rigor/source/parameter_envelope.rb:64`), the header-nesting bucket merge (SI:5355–5362), three iterating consumers, and the memo's cross-class reads (`expression_typer.rb:2434–2441`). The sound remainder after #1551 is about 90 ms. |
| The fuzzer as a CI gate | Deferred | It loads 28 % of its programs and 2–7 % of those containing `self::` headers, eval rebinding, `class <<` or factory blocks; its construct families are grammar productions the author enumerates. It stays local until its load rate is measured above 50 %. |
| PHPStan-style per-includer re-analysis of hook bodies for diagnostics | Deferred | Discovery facts per edge are a substitution over rows; re-running the typed pre-pass and rules per includer multiplies hook bodies by their includer counts. PHPStan's collector idiom (report once when every user agrees, else per context; `src/Rules/Comparison/FunctionCallConstantConditionRule.php` in <https://github.com/phpstan/phpstan-src>) is the pattern to adopt if that is ever wanted. |
| Continuing the piecewise ports under ADR-116 WD5 | Rejected | The four remaining walks are about 0.2 % of a cold run; each port added variants that protect behaviour no corpus exercises; the contract needed a definee it could not agree on. Ports remain possible as lane-1 refactors. |

## Consequences

Positive:

- The variant rule and the byte-identity requirement for behaviour changes are gone; a disagreement
  between two context computers is a fixture with a Ruby witness or nothing.
- No reader carries a direction label and no reader list is hand-kept: a read answers or is silent by
  one rule, and a member holds `possible` facts only once its census is empty.
- `module_function` has one implementation with one three-valued answer; #1550, both `vis.rb` false
  positives and the `call.wrong-arity` of Context are fixed under a stated relation.
- The member set and the producer set are outputs of the code.

Negative:

- **Precision cost of unknown.** A definer reached only through `possible` facts, or contested with
  another, now answers `Dynamic` where today it answers a precise type; a hook or visibility call
  reached through a `possible` edge, a conditional inside a hook, a `send`-style include, or a
  hand-written `self.included` stays `possible`, and firing checks are silent there. The follow-up ADR
  recovers the common Rails shape; the rest is the price of the false-positive rule.
- **User-visible sig-gen changes** (PR B): module functions after a visibility reset stop rendering as
  singletons, and previously omitted module functions appear. Each ships with a changelog entry.
- **Grandfathered sets**: 36 producer methods in `scope_indexer.rb`, four collectors and the methods of
  56 other files, plus the copy paths and raw slot reads the census reports, converge only as bugs are
  filed; the tripwire and the census stop growth but set no pace.
- One small sibling per admitting member, and a `SCHEMA` bump.
- No speed is claimed. #1551's saving was independent of this decision.

## Open questions for the maintainer

1. **Scope of `possible`.** Keep the definition as stated, or restrict `possible` to direct-body control
   flow and treat blocks as `none`? *Default: as stated.*
2. **Typing through a possible-only definer.** Candidate-set reads turn today's precise type into
   `Dynamic` there. Accept, or keep the precise type behind an opt-in? *Default: accept; it is the
   false-positive rule.*
3. **Sig-gen changes in the changelog.** *Default: yes, one user-facing entry for PR B.*
4. **Pace for the grandfathered sets.** A deadline for plugin discoverers and raw slot reads, or
   convergence by filed bug only? *Default: by filed bug; the tripwire and census prevent growth.*
5. **Triage authority.** When a fixture shows Ruby and a deliberate over-approximation disagree (the
   extends table, SI:5958–5963), who rules? *Default: the over-approximation is `possible` and
   conformant; no ruling needed.*
6. **The fuzzer in CI.** *Default: not until its construct load rate is measured above 50 %.*
7. **The follow-up ADR's number and timing.** *Default: opened after PR C lands, so its fixtures can
   build on candidate-set reads.*
