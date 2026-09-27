# ADR-119 — Certainty on discovery facts, candidate-set reads over one Ruby-order chain

Status: **Proposed, 2026-09-28.** Awaiting the maintainer's acceptance. Nothing behaviour-changing has
landed. Landed already, byte-identical and independent of this decision: #1551 (the layered
def-nesting lookup). Open as a Draft, byte-identical: #1563 (the `module_function` readings behind one
helper). The gates are tracked in #1566 and not yet opened. Every `file:line` below is at
`origin/master` `19a9c054c`; SI is `lib/rigor/inference/scope_indexer.rb`.

Grounding: the design-review rounds on #1531 and #1507 (2026-09-28), the adversarial critiques they
answered, the three reviews of this ADR's drafts on #1562, and the probes reproduced in Context (all
re-run against `rigor check --no-cache` and Ruby 4.0.5 for this draft). ADR-49 archetype: deliberative;
stakes: high (it moves the false-positive envelope of every discovery table).

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
   (`lib/rigor/inference/statement_evaluator.rb:2699, 2719, 5178`). Under the rule WD6 states, 47
   methods in `scope_indexer.rb` and 64 other files compute declaration context. On the read side the
   same thing holds three times over: `Scope` exposes every table raw (`lib/rigor/scope.rb:41–75`) and
   36 files outside the table owners read them; six consumers walk ancestry themselves through
   `includes_of`/`superclass_of` (`lib/rigor/analysis/check_rules.rb:1137, 1518, 2524, 3787`;
   `lib/rigor/analysis/check_rules/source_arity.rb:98–121`;
   `lib/rigor/inference/last_line/implicit_self.rb:69, 83, 101`; `lib/rigor/reflection/constant_ancestors.rb`;
   `lib/rigor/inference/method_dispatcher/singleton_mixin_dispatch.rb`;
   `lib/rigor/inference/expression_typer.rb:2067`); and the seed paths copy explicit member lists
   (`lib/rigor/analysis/runner.rb:2016`, `worker_session.rb:344`,
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
   definee is computed as a sibling-statement toggle (SI:4948–4979), as a prescan that enters blocks and
   control flow and stamps a `kind` on deferred-range rows (SI:4217–4238, 4260–4271), as an orderless
   self-extend (SI:6185–6198), and as sig-gen's direct-statement toggle (`generator.rb:665–688`). The
   visibility walker ignores it entirely (SI:6279–6420). Ruby's own answer is run-dependent: a bare
   call inside `if`, `each {}`, `tap {}`, a called lambda or a called `def self.setup` takes effect; an
   uncalled lambda does not; a bare `public`/`private`/`protected` resets it; `def self.x` gets no
   instance copy; `attr_reader` becomes private with no singleton copy; the named form snapshots the
   earlier `def`, so a later redefinition is public. **Method resolution order has the same problem:**
   two walks are breadth-first (`scope.rb:1358–1376` with `enqueue_ancestors` at `:1593`;
   `check_rules.rb:3748–3763`), `SourceArity` walks by superclass level with its own agreement rule
   (`source_arity.rb:38, 98–121`), and none is Ruby's order. Two false positives on master need no
   uncertainty at all: `include A` where `A` includes `M#foo` makes `C.new.bar.upcase` an
   `undefined-method` on `1` because breadth-first reaches `Base#foo` before `M#foo` (#1567), and a
   public method in a prepended module is ignored, so `def.method-visibility-mismatch` fires at error
   level on `C.new.foo` (#1568).
4. **Byte-identity was demanded against walkers that are wrong or deliberately over-approximate.**
   The extends walker over-approximates on purpose, in the ADR-5-safe direction (SI:5958–5963).
   #1518–#1520 are rules wrong in several walkers at once. #1550 is a false positive on correct Ruby:
   `module_function :label` followed by a redefinition resolves the *later* `def`, because
   `record_module_function_names` reads a name map in which a later `def` overwrites the earlier
   (SI:5030–5042). `def.override-visibility-reduced` fires on a private override of `Helpers2#fmt2`
   after `if true; module_function; end`, although Ruby makes the module's copy private
   (`check_rules.rb:3710–3720`).
5. **The justification shifted** from speed to C2 without a criterion for landing a port. The speed
   case was measured and found absent: the four remaining walks are about 0.2 % of a cold run
   (`docs/adr/116-hot-file-restructuring.md:175` still calls the merge "the wall lever").

Five findings bound the design. The typed pre-passes — ivars, cvars, globals, constants — call
`scope.type_of` under a scope carrying the project seed and the plugin registry (SI:1713, 1755, 1774,
2110, 2230, 2995; registry at SI:969–980), so they are not pure functions of a file. A table-level
approximation *direction* is ill-posed: visibility is read to fire and silenced by `nil`
(`check_rules.rb:3710–3720`) and constants are read in both directions (`scope.rb:136–155`). A per-read
direction is ill-posed too: on an ancestor walk, keeping a `possible` edge shadows a further ancestor
and dropping it exposes one — `class C < Base; include M if ENV["X"]; end` with `M#foo(required)` and
`Base#foo` fires `call.wrong-arity` on `C.new.foo` today, code that runs when `X` is unset; with `M#foo`
private and `C#foo` private, a certain-only override walk reaches `Base#foo` and fires. **A candidate set
collected along a breadth-first walk is not sound either**: with `module A; include M if ENV["X"]; end`
and `class C < Base; include A; private def foo`, breadth-first reaches the certain `Base` before `M`,
so the set is `{Base}` and the rule fires although Ruby's super method is the private `M#foo` when `X` is
set; with `include M if X; include N; include M`, the possible edge moves the certain `M` ahead of `N`
(Ruby's skip-if-present rule), and a walk that stops at `N` fires although Ruby's owner is `M` when `X`
is unset. Finally a single-valued table has no union: an extra singleton def *displaces* the right one
(last-write-wins, SI:5007–5013), and scalar consumers deref the value (`runner.rb:590–616`).

## Decision

**Criterion.** A discovery producer is judged by a relation Ruby can witness, never by identity to a
predecessor: a fact is *certain* (it holds whenever the file's top level executes) or *possible* (it
holds in some execution). A read answers only when its answer is the same under every assignment of the
`possible` facts it depends on; otherwise it answers *unknown*, and every consumer already treats
unknown as silence (ADR-5: a `nil` visibility silences the rule, a `Dynamic` type withholds). One
Ruby-order ancestor chain is the reference every read is defined over. A behaviour change lands under
WD7's second lane; a behaviour-preserving change under its first. Speed is never the reason.

### WD1 — Storage: today's tables keep today's meaning; `possible` lives beside them

- Every existing member keeps exactly its current contents and semantics: the **union**
  (`certain ∪ possible`), which is what every reader consumes today. Existing readers, raw reads and
  scalar derefs (`runner.rb:590–616`, `rbs_dispatch.rb:871`) keep their meaning.
- A set-valued member that admits `possible` facts has a `possible_*` sibling of the same shape holding
  only the `possible` facts, so `certain = member − possible_*`; for `discovered_methods`, whose values
  are `name → kind` maps with `:both` (`scope.rb:986–992`, `discovery_index.rb:68`), the relation is per
  `(class, name)` pair. A single-valued member that admits `possible` facts keeps its scalar slot and
  today's fold and has a `contested_*` sibling: the keys whose value depends on a `possible` fact,
  including keys whose only definer is `possible`. Slots hold what they hold today and never a new
  wrapper.
- Siblings **always exist** for admitting members, empty by default. `DiscoveryIndex#with` is
  overridden in the class body (`discovery_index.rb:55`) to raise when a member is passed without its
  sibling or a sibling without its member, so the seed and copy paths of Context 1 cannot drop one —
  `Data#with` would otherwise keep the base value silently. Each copy path gets a round-trip spec: applied
  to a fixture index with non-empty siblings, it preserves them.
- Both stay plain frozen data, Marshal-clean for seed bundles and fork payloads.
- **Admission precondition.** A member may admit `possible` facts only once (i) every copy path
  iterates one declaration of members and siblings (ADR-116 C1) and passes its round-trip spec, and (ii)
  for a single-valued member, every raw read of its slot outside the table owners consults `contested_*`
  or goes through a `Scope` reader. The census that reports (ii) is a Prism spec over `lib/` and
  `plugins/`: it flags a call of a `discovered_*`, `published_constant_names`, `local_constant_names` or
  `*_member_layouts` method, and a short key (`[:def_nodes]`, `fetch(slot)`) **only when the key reaches a
  member through a local alias** — a `%i[…]` list or Hash literal in the same file that maps it to a
  member, as `discovery_seed.rb:100–105` and `DISCOVERY_FIELD` (`parameter_inference_collector.rb:258`) do
  — so an unrelated `:methods` elsewhere is excluded by construction. The table owners are `scope.rb`,
  `scope/discovery_index.rb`, `scope_indexer.rb` and `runner/project_pre_passes.rb`. The census is the
  migration list, not a gate on reads.

### WD2 — One Ruby-order chain, and candidate-set reads over it

- **`Scope#resolution_chain(class_name, side)`** is the only code that walks `includes_of`,
  `prepends_of`, `superclass_of` and the extends table transitively. It returns Ruby's linearised
  ancestors: for the instance side, prepended modules before the class, the class, its included modules
  in Ruby's order (a later `include` is a no-op when the module is already present), then the superclass
  chain likewise; for the singleton side, the metaclass, its `extend`s and `class << self` includes, then
  the superclass metaclasses. Each entry carries the certainty of the edge it was reached through. A
  Prism spec fails on any other method that calls two or more of those readers, or one of them inside a
  loop or a recursive method; today that is the six consumers of Context 1, which become the finite
  migration list, and `user_def_through_ancestors` (`scope.rb:1358`) and `each_project_ancestor`
  (`check_rules.rb:3748`) become callers of the chain. The chain fixes #1567 and #1568.
- **Candidate-set reads.** A read that answers a question about a member — definer, visibility, arity,
  type, or which ancestor — computes the chain under **every assignment** of the `possible` edges of the
  class and its ancestors (held or not), takes the first definer in each chain, and collects the set of
  those definers, with *absent* as a member when some assignment has none. It answers when every
  candidate gives the same answer to the question asked, and *unknown* (`nil`, empty, `Dynamic`)
  otherwise. This is what "the position depends on a possible edge" means: an edge whose presence
  changes the first definer changes the set. A class whose reachable ancestry holds more than four
  `possible` edges answers unknown for every such read. In the common case there are no `possible` edges,
  the set is a singleton, and the read costs one chain (memoised per class per index, as today's walks
  are) plus one membership test per edge.
- **The absent candidate, per question.** For arity, type and return questions, *absent* is dropped:
  in that world the call raises `NoMethodError`, so a precise answer from the agreeing definers is sound.
  For questions about a relationship to a super method — `def.override-visibility-reduced`,
  `def.method-visibility-mismatch` — *absent* counts, so the read is unknown whenever some assignment has
  no definer.
- **Existence reads.** A read that asks whether *some* fact exists and is used positively
  (`discovered_method?` at `check_rules.rb:952`, `known_user_class?`, `published_constant?`) answers over
  the union, withholding by construction. A negated or compared existence read —
  `singleton_context_def?` is `discovered_method?(…, :singleton) && !discovered_method?(…, :instance)`
  (`check_rules.rb:3633–3636`) — is a candidate-set read; the WD2 spec flags every `!`/`unless` use of an
  existence reader as part of the migration list.
- The constant tables admit no `possible` facts in this ADR; nothing emits them yet.

### WD3 — What is certain

- A fact is `certain` when the statement that produces it executes whenever the file's top level
  executes: it is reachable from the top level through `class`, `module` and `class << self` bodies
  alone, with no enclosing control flow, block, method body, `rescue`/`else`/`ensure` clause or
  `BEGIN`/`END`. Everything else is `possible`: an `include` inside `if`, a mixin call inside a method or
  a block (`included do`, `class_eval`), a `send`, a computed argument, **a reopening whose `class`
  keyword sits inside a conditional** (its statements are conditional however many other definitions of
  the class exist), and **a `def` inside control flow or a block**, which is a `possible` definer and
  makes its slot contested. An unconditional `include` in a `class << self` body is a `certain` edge on
  the singleton side (the extends walker records it as an extend since #915, SI:5966, 6022).
- **The extends fold stays in this ADR.** Both fold sites (per file, SI:376; in the project fold,
  SI:7563) copy an extended module's defs into the class's singleton table with `||=` (SI:6218–6230). A
  copy through a `possible` extend edge — `extend X if …`, `class << self; include X if …` — marks the
  key contested and never copies as certain. Its witness is read-level (WD5).
- **Deferred to a follow-up ADR: hook facts instantiated per includer.** `ActiveSupport::Concern`'s
  `included do` and `class_methods do` run once per includer in the includer's context, PHPStan's trait
  model (<https://phpstan.org/blog/how-phpstan-analyses-traits>). Today every walker treats those blocks
  as ordinary calls under the concern's own owner (`included` and `class_methods` are in neither the
  eval-family lists, SI:2755, 2770, nor the opaque list, SI:2762; `rebound_block_self`, SI:2918–2925; the
  mixin walk, SI:5862–5889); `SyntheticMethodScanner` replays `included do` macro calls only
  (`synthetic_method_scanner.rb:326–362`); the ActiveRecord `ModelDiscoverer` recognises a concern by its
  `included do` block, not by the `extend` line
  (`plugins/rigor-activerecord/lib/rigor/plugin/activerecord/model_discoverer.rb:549–550, 573`).
  Ruby
  4.0.5 with ActiveSupport 8.1.3 gives the precedence rules the follow-up must state: `extend X; include M`
  resolves `build` to `M::ClassMethods` and the reverse order to `X`; `prepend M` puts `M::ClassMethods`
  ahead of the includer's own `def self.build` in either order and runs `prepended`; `include M, N`
  applies right to left; a `def self.x` inside `included do` is the includer's singleton method; a concern
  included into a plain module extends `ClassMethods` onto that module. The follow-up also owns the
  incremental closure (`discovered_class_sources` means "files that declare C", `runner.rb:626–630`;
  `symbol_fingerprints_from_index` folds only the changed files, `incremental_session.rb:868–876`), the
  ADR-89 declaration signature (SI:7024), and the def-source rows the extends fold does not write
  (`lib/rigor/analysis/dependency_recorder.rb:283`).

### WD4 — Classification of every `DiscoveryIndex` member, with structural checks

A spec classifies each of the 39 `Data.define` members (`discovery_index.rb:13–53`) into exactly one
class, fails on an unclassified member, and asserts each class's structural property on an index built
from a fixture project. The classes follow the #1566 rulings.

| Class | Members | Structural assertion | Reference |
| --- | --- | --- | --- |
| Set-valued (may admit `possible_*`) | `discovered_methods` (`name → kind`, relation per pair), `discovered_includes`, `discovered_prepends`, `discovered_extends`, `discovered_classes`, `published_constant_names`, `published_constant_alias_names`, `local_constant_names`, `constant_writers`, `constant_shadowers`, `constant_sources`, `published_constant_ivars`, `discovered_refinements`, `discovered_global_write_census`, `discovered_deferred_ranges` (rows; `kind`/`owner` from the shared `module_function` helper) | values are Sets/Arrays/Hashes of names, pairs or rows; where the member admits `possible`, its sibling exists and every sibling entry is in the member | Ruby witness |
| Single-valued (may admit `contested_*`) | `discovered_def_nodes`, `discovered_singleton_def_nodes`, `discovered_def_sources`, `discovered_singleton_def_sources`, `discovered_superclasses`, `discovered_method_visibilities`, `discovered_header_nestings`, `discovered_parameter_envelopes` (a join to `OPAQUE`), `data_member_layouts`, `struct_member_layouts` | each slot holds the value kind it holds today and no certainty wrapper; where the member admits `contested_*`, the sibling exists and its keys ⊆ member keys | Ruby witness (`source_location` for def identity) |
| Typed | `declared_types`, `class_ivars`, `class_cvars`, `program_globals`, `program_global_seeds`, `in_source_constants`, `param_inferred_types` | every leaf is a `Rigor::Type` value | The type lattice; WD1 does not apply |
| Syntactic | `discovered_def_nestings`, `discovered_class_sources`, `patched_line_readers`, `clears_last_status`, `defines_case_equality` | rebuilt byte-identically by the shadow oracle on the fixture | The parse; the ADR-53 shadow harness stays for these |
| Never in a seed | `run_generation`, `implicit_self_evidence` (a lazy, mutable `SelfEvidence` holding the Prism root) | absent from every seed bundle | None |

Deferred ranges and def sources are not syntactic: the range rows carry the `module_function`
definee (SI:4260–4271) and the def sources come from the definee walker (SI:7622) and feed the
ADR-17/#735 suppression through `Scope` (`scope.rb:1045, 1094, 1111, 1127, 1143`).

### WD5 — The witness, at two levels

- **Table level.** One spec fixture per filed bug, executed in a subprocess under the Flake's Ruby,
  records `Module.nesting`, `instance_methods(false)`, `singleton_methods(false)`, the three visibility
  sets and `Method#source_location`, and compares them with the **per-file** tables (`build_file_index`,
  SI:7284) under WD1's relation. The relation is stated per file because `finalize_def_index` deliberately
  subtracts plain cross-file defs (SI:7565–7569, ADR-17).
- **Read level.** For each fixture variant, `Module#ancestors`, `Method#owner` and the visibility of the
  resolved method are compared with `resolution_chain` and the candidate-set reads' answers: the read
  must answer the variant's value or unknown, never a different value. This is the only witness for the
  extends fold and for #1567/#1568, whose tables are correct while the reads are wrong.
- A fixture must fail on `master` before its fix, so every fixture is its own positive control.
  **Limit:** one run witnesses one execution; "every assignment" is approximated by fixture variants
  that take each branch of the construct under test, and a fabricated `certain` fact is caught only
  where a variant's run lacks it. Programs that fail to load are dropped. The fuzzer stays a local tool
  until its load rate on the constructs that matter (measured at 2–7 %) exceeds 50 %.

### WD6 — The producer tripwire

A spec parses every `.rb` under `lib/` and `plugins/` with Prism and marks a **method** a producer when
its body (i) references `ClassNode`, `ModuleNode` or `SingletonClassNode` as a `Prism::` constant path
or a bare constant, in any position — `when`, `is_a?`, `===`, a read; (ii) names the symbols
`:class_node`, `:module_node` or `:singleton_class_node`; (iii) reads a constant whose assignment in the
same file contains (i) or (ii) — `CLASS_BODY_NODES` (SI:4081), `IVAR_BARRIER_NODES`; or, failing those,
(iv) names a visibility or mixin keyword as a symbol (`:private`, `:protected`, `:public`,
`:module_function`, `:include`, `:extend`, `:prepend`), which catches `effects/visibility.rb`. A class
whose body has an `include …Collector` statement is a producer as a whole. Reproduced at `19a9c054c`:
47 methods in `scope_indexer.rb` (36 by i–iii, 11 by iv), 64 other files (54 by i–iii, 8 by iv only,
plus the four collectors), 171 methods in all; `record_module_function_names`,
`record_singleton_def_node`, `fold_extends_into_singleton_tables` and `apply_alias_def_nodes` are among
the 47 because they name the keyword symbols or are reached by (iii). The spec compares the set with a
committed allowlist of `file#method` entries; any new entry fails. **What remains:** a computer that
dispatches on `node.class.name` strings, on `Prism::Node#type` through a variable, or on a keyword
spelled as a String is not found; the allowlist freezes the set and certifies nothing about how an entry
computes its context.

### WD7 — Landing rules

Two lanes. Neither lane's list is sufficient: the review loop of `docs/agents/contribution-flow.md`
applies to every PR, and no listed gate may be skipped or replaced by a claim.

- **Lane 1 — behaviour-preserving changes**: refactors, ports onto `DeclarationWalk`, performance and
  allocation work in any producer or reader, and the deletion of a `RULE_VARIANTS` entry whose variant
  the walk's rule reproduces. They land under byte-identical corpus diagnostics, byte-identical corpus
  `rigor sig-gen` output, the shadow harness wherever a table is rebuilt, and the per-merge allocation
  sweep (ADR-116's guardrails). A port may not change a fact; a change to a fact is a lane-2 change.
- **Lane 2 — behaviour changes to declaration facts** or to how a read answers, in a `ScopeIndexer`
  walker, a `DeclarationWalk` collector, the fold, `resolution_chain`, sig-gen, Effects, a plugin
  discoverer or a `Scope` reader, and the deletion of a `RULE_VARIANTS` entry whose variant was a bug.
  They land only when all of the following hold, and these are necessary, not sufficient:
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
| 1 Prose enumeration | WD4 (members are `Data.define`-derived and shape-checked); WD6 (producers are parse outputs); WD1 (copy paths are structurally paired and round-trip-tested; slot readers are a census); WD2 (ancestry walkers are a parse output and one chain is the reference) | Grandfathered producers and slot readers converge only as bugs are filed; the census's and tripwire's patterns are themselves stated lists |
| 2 Variants by reading; vacuous sweeps | WD1 + WD7(c): no variants; a disagreement is a fixture or nothing; WD5: a fixture is a positive control at both levels | Unknown constructs are found by users, not generated; one run witnesses one execution |
| 3 Several implementations of one question | `module_function`: one helper (#1563) read through WD2; resolution order: one chain (WD2) | Concern hooks stay several implementations until the follow-up ADR |
| 4 Byte-identity to wrong legacy | WD1 + WD2 + WD7: over-approximation is legal only as `possible`, and no read answers from it | A fabricated `certain` fact no fixture covers stays until reported |
| 5 Shifting justification | WD7: two lanes with fixed, necessary gates; speed is never the reason | Triage decides what counts as reproduced |

## Migration

**Before acceptance — byte-identical, or an ordinary bug fix under the normal review loop.**

1. **#1551 (merged).** `merge_def_nestings` returns a layered lookup (SI:349–354).
2. **#1563 (Draft).** The `module_function` readings behind one helper; shadow-checked on the corpus.
3. **The gates (#1566, to be opened as Drafts).** The WD4 classification spec with its structural
   assertions; the WD6 producer tripwire with today's 171 `file#method` entries and four collectors; the
   WD2 ancestry-walker spec with today's six consumers; the WD1 census, the `with` pairing check and the
   round-trip specs; the WD5 harness at both levels with fixtures for #1518, #1519, #1520, #1550, #1567,
   #1568, the `module_function` probes and the ancestry probes of Context, all marked pending.
4. **#1548.** Key the seeded deferred-ranges reuse (SI:312–314) on content digest plus parse version, or
   drop it (analysis parses with `version:`, `runner.rb:1985–1994`; the pre-pass does not, SI:7198; the
   mutation oracle seeds a mutant with its parent's ranges, `discovery_seed.rb:97–108`).
5. **Declaration-driven copy paths (lane 1).** The paths of Context 1 iterate one declaration of members
   and siblings; byte-identical; the precondition every admission needs.
6. **`resolution_chain`, fixing #1567 and #1568 — an ordinary bug-fix PR amending ADR-24.** ADR-24 owns
   implicit-self resolution and already states the order ("its own definitions, then its ancestors",
   `docs/adr/24-self-method-call-resolution.md:98–100`); the chain is the implementation that order was
   missing. It lands before this ADR's acceptance with the read-level witness as its spec, the corpus
   diff, and a partial-supersession blockquote in ADR-24. It is not a separate ADR: a Ruby-order chain is
   a mechanical correction with an executable reference (ADR-49 economy; ADR-97's index budget), and it
   is what stops every later review from relitigating walk order. It carries no certainty yet; every
   entry is `certain` until PR C admits the mixin members.

**After acceptance — the first behaviour-changing PRs, each under WD7 lane 2.**

| PR | Change | Expected corpus diff | Expected sig-gen diff | False-positive check |
| --- | --- | --- | --- | --- |
| A — #1550 | The named form snapshots the last receiverless `def` before the call; a later redefinition is a public instance `def` | Zero (rare construct) | The singleton keeps the earlier body's type | Fixture asserts `P9.a == 1` |
| B — reset, receiverless-only, privatisation | A bare `public`/`private`/`protected` ends the toggle; `def self.x` gets no instance copy; `attr_reader` is private without a singleton copy; `define_method` gets both; a `certain` module function's instance copy is recorded private (the visibility walker ignores `module_function` today, SI:6279–6420); sig-gen bypasses `visibility_excludes?` for module functions | Zero on existence; `def.override-visibility-reduced` stops firing on `Helpers#fmt`; any new firing is on code where Ruby raises | Module functions after a reset stop rendering as singletons; `private; module_function; def b` renders its singleton | Fixtures P1, P2, P3, P10, P12, P13 and `vis.rb`; rows removed are rows Ruby never creates |
| C — candidate-set reads and the first `possible` facts | The readers and walks of WD2 become candidate-set reads over `resolution_chain` (a possible-only definer now types `Dynamic`; the extends fold marks contested keys). Then, once WD1's precondition holds for **every member this PR writes into** — `discovered_includes`, `discovered_prepends`, `discovered_extends`, `discovered_methods`, `discovered_def_nodes`, `discovered_singleton_def_nodes`, `discovered_method_visibilities`, `discovered_deferred_ranges` — conditional mixin edges, conditional `def`s and a bare `module_function` inside control flow, a block or a singleton-method body become `possible` | Silences the `Helpers2#fmt2`, `bfsvis`, `idemvis2`, `expose`, `extend`, `sclass`, `condclass` and `conddef` firings of Context and the review's probes; may silence checks that resolved through a possible-only definer; Rails concerns keep today's answers | A notice on `possible` module functions; `possible` edges render nothing new (RBS has no conditional form) | Fixtures A, B, C, E, F, H, J and the ancestry probes at both witness levels; a candidate-set read can only withhold where today's read fires |
| D — hook facts per includer | Deferred to the follow-up ADR (WD3) | — | — | — |

Precision estimate (the review's `edges.rb`, re-run here over Mastodon's `app/lib`): 6 of 85 mixin
calls sit outside unconditional bodies (3 in `class << self` bodies, 2 in `included do`, 1 under a
conditional reopening); the review's whole-app figure is about 13 of 940. Redmine has 17 `send(:include)`
and 6 mixin calls inside methods. Precision does not collapse.

## Relationship to other ADRs

- **[ADR-24](24-self-method-call-resolution.md) — amended by Migration step 6.** It owns implicit-self
  resolution and its ancestor order; `resolution_chain` is that order's implementation, and the
  breadth-first walks it replaces (`scope.rb:1358`, `check_rules.rb:3748`) are marked superseded in place.
- **[ADR-116](116-hot-file-restructuring.md) WD5 — partially superseded.** Its byte-identity requirement
  and variant rule (`:160–184`) are retired for behaviour changes; a blockquote at that point names this
  ADR. Its guardrails remain the gate for lane 1. The four ported collectors stay; a `RULE_VARIANTS`
  entry is deleted under lane 1 when the walk's rule reproduces the variant and under lane 2 when the
  variant was a bug. #1531 closes as superseded; its note remains as the list of candidate fixtures. The
  README row for ADR-116 drops "WD5 in progress". ADR-116 C1 is what WD1's admission precondition applies
  to the copy paths.
- **[ADR-53](53-scope-discovery-index-separation.md)** — the shadow harness's role narrows to WD4's
  syntactic members and to lane 1; the "generic-visitor rewrite: Deferred" row (`:233`) is marked
  superseded by this ADR's mechanism, which needs no rewrite. WD2's keyed readers are where the
  candidate-set reads live.
- **[ADR-85](85-seed-bundles-and-lazy-def-node-handles.md) WD2 — amended.** Bundles carry the
  `possible_*` and `contested_*` siblings; the next `IncrementalSnapshot::SCHEMA` bump
  (`lib/rigor/cache/incremental_snapshot.rb:148`, currently 30) covers the new rows, and
  `docs/internal-spec/cache.md` documents them.
- **[ADR-46](46-incremental-dependency-graph.md)** — unchanged by this ADR; the gaps the follow-up must
  close are recorded in WD3.
- **[ADR-17](17-monkey-patch-pre-evaluation.md)** — the fold's subtraction of plain cross-file defs
  (SI:7565–7569) is a consumer policy the WD5 relation is stated around, not a violation of it.
- **[ADR-15](15-ractor-concurrency.md)** — the sibling tables are plain frozen data; the chain memo is
  per index, as today's walk memos are. **[ADR-5](5-robustness-principle.md)** — unknown-is-silence is its
  principle applied at every read. **[ADR-38](38-additional-initializers.md)** — the typed pre-pass's
  registry read (SI:969–980) is unchanged and is why the typed members are outside WD1.
- **`rigor sig-gen` output is a gated artifact** in both lanes (WD7); ADR-89 WD1's declaration
  signature is not changed by this ADR.
- **Follow-up ADR (to be numbered): hook facts per includer.** Owns WD3's deferred part.

## Rejected / deferred alternatives

| Candidate | Status | Reason |
| --- | --- | --- |
| A per-file declaration-fact IR (round 1) | Rejected | The typed pre-passes are not pure per file (SI:1713–2995); the flow-sensitive ivar pass (SI:396–411) does not fit rows; the default path never loads a snapshot (`runner.rb:1558–1563`); quirks would return as fold policies. |
| Ruby as the judge of every disagreement | Rejected | The same text has several Ruby answers (Context 3); the extends over-approximation is deliberate (SI:5958–5963); Zeitwerk namespace synthesis makes correct fixtures raise; five members have no runtime counterpart. Ruby is WD5's *witness* for a stated relation. |
| One approximation policy per table | Rejected | Visibility, constants and ancestry are each read in both directions, and a single-valued table cannot be a superset. |
| `certain` facts in the existing member with `possible_*` beside it (first draft) | Rejected | Every unmigrated reader would silently become certain-only, and a scalar deref would meet an alternatives Array (`runner.rb:616`, `rbs_dispatch.rb:871`). |
| Direction fixed once per `Scope` reader (first draft) | Rejected | The override walk uses the readers that suppress `undefined-method` (`check_rules.rb:3748–3807`). |
| Direction fixed per call site with a labelled allowlist (second draft) | Rejected | On an ancestor walk neither direction is safe (Context, last paragraph); labels were self-declared. |
| Candidate sets collected along today's breadth-first walks (third draft) | Rejected | Breadth-first is not Ruby's order: `bfsvis` and `idemvis2` fire with a certain nearest definer, and #1567/#1568 fire with no uncertainty at all. The set must be collected over Ruby's chain under every assignment (WD2). |
| Agreement between the certain-only world and the union world | Rejected as the rule | Two `possible` definers with compensating answers make both worlds agree while a run holding only one differs; "every assignment" covers it, with a cap. |
| A `certain` edge inside a conditional reopening only when no other definition of the class exists | Rejected | Whether another definition exists is a project-wide fact, and the reopening's statements are conditional regardless (`condclass` fires today and would keep firing). |
| `certain_*` siblings (second draft) | Rejected | A near-full copy of each admitting table. |
| Copying `class_methods` defs as `def self.` rows on each includer | Rejected | Ruby puts them on `M::ClassMethods`, which the includer extends; the probes' ordering rules (WD3) show the model is an edge with a position. Owned by the follow-up ADR. |
| Concern-hook instantiation inside this ADR (second draft's WD3) | Deferred to the follow-up ADR | Its facts live in the fold; its precedence rules need their own probes; its incremental and ADR-89 consequences are open. |
| A separate small ADR for `resolution_chain` | Rejected | ADR-24 already owns the order; the chain is a mechanical correction with an executable reference (ADR-49 economy, ADR-97's index budget). An amendment blockquote records it. |
| A per-file overlay over the frozen seed | Rejected | Not byte-identical as specified (SI:3267–3270, 3183–3184, 5355–5362; `parameter_envelope.rb:64`; `expression_typer.rb:2434–2441`); about 90 ms after #1551. |
| The fuzzer as a CI gate | Deferred | 28 % of its programs load, 2–7 % of those with the constructs that matter; stays local until above 50 %. |
| PHPStan-style per-includer re-analysis of hook bodies for diagnostics | Deferred | Multiplies the typed pre-pass and rules by includer counts; the collector idiom (`src/Rules/Comparison/FunctionCallConstantConditionRule.php` in <https://github.com/phpstan/phpstan-src>) is the pattern if ever wanted. |
| Continuing the piecewise ports under ADR-116 WD5 | Rejected | About 0.2 % of a cold run; variants protect behaviour no corpus exercises; the contract needed a definee it could not agree on. Ports remain lane-1 refactors. |

## Consequences

Positive:

- The variant rule and the byte-identity requirement for behaviour changes are gone; a disagreement
  between two context computers is a fixture with a Ruby witness or nothing.
- One chain is the reference for method resolution; #1567 and #1568 are fixed by it, and no consumer
  walks ancestry on its own.
- No reader carries a direction label and no reader list is hand-kept: a read answers or is silent by
  one rule, and a member holds `possible` facts only once its copy paths are paired and its slot reads
  are migrated.
- `module_function` has one implementation with one three-valued answer; #1550, both `vis.rb` false
  positives and the eight ancestry probes are fixed under a stated relation.

Negative:

- **Precision cost of unknown.** A definer reached only through `possible` facts, or contested with
  another, now answers `Dynamic` where today it answers a precise type; relationship lints are silent
  wherever some assignment has no super method. The follow-up ADR recovers the common Rails shape; the
  rest is the price of the false-positive rule (about 1–7 % of mixin edges on Mastodon, § Migration).
- **User-visible sig-gen changes** (PR B), each with a changelog entry.
- **Grandfathered sets**: 171 producer methods in 65 files, six ancestry walkers and the slot readers the
  census reports converge only as bugs are filed; the tripwires stop growth but set no pace.
- One small sibling per admitting member, a `with` that raises on a mismatched copy, and a `SCHEMA` bump.
- No speed is claimed. #1551's saving was independent of this decision.

## Open questions for the maintainer

1. **Scope of `possible`.** As stated (blocks, methods, conditionals, conditional reopenings and
   conditional `def`s), or restrict to direct-body control flow? *Default: as stated.*
2. **Typing through a possible-only definer.** Candidate-set reads turn today's precise type into
   `Dynamic` there. *Default: accept; it is the false-positive rule.*
3. **The assignment cap.** Four `possible` edges per reachable ancestry (16 chains) before answering
   unknown. *Default: four; revisit if Rails corpora hit it.*
4. **Sig-gen changes in the changelog.** *Default: yes, one user-facing entry for PR B.*
5. **Pace for the grandfathered sets.** *Default: by filed bug; the gates prevent growth.*
6. **Triage authority** when a fixture shows Ruby and a deliberate over-approximation disagree.
   *Default: the over-approximation is `possible` and conformant.*
7. **The fuzzer in CI.** *Default: not until its construct load rate exceeds 50 %.*
8. **The follow-up ADR's timing.** *Default: after PR C lands, so its fixtures build on candidate-set
   reads over the chain.*
