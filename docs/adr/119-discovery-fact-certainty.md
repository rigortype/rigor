# ADR-119 — Certainty on discovery facts, direction on reads: a witness gate replaces byte-identity

Status: **Proposed, 2026-09-28.** Awaiting the maintainer's acceptance. Nothing behaviour-changing has
landed. Landed already, byte-identical and independent of this decision: #1551 (the layered
def-nesting lookup). In flight as Draft PRs, also byte-identical: the `module_function` state
extraction and the four gates (§ Migration). Every `file:line` below is at `origin/master`
`dde39b6d4`; SI is `lib/rigor/inference/scope_indexer.rb`.

Grounding: the design-review rounds on #1531 and #1507 (2026-09-28), the adversarial critiques they
answered, the review of this ADR's first draft on #1562, and the probes reproduced in Context. ADR-49
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
   (`lib/rigor/inference/statement_evaluator.rb:2699, 2719, 5178`). 57 files under `lib/` and
   `plugins/` dispatch on `Prism::(Class|Module|SingletonClass)Node`. On the read side the same
   thing holds: `Scope` exposes every table raw (`lib/rigor/scope.rb:41–75`) and 17 files outside the
   table owners read them directly, some on purpose (`rbs_dispatch.rb:854–863`).
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

Three findings bound the design. The typed pre-passes — ivars, cvars, globals, constants — call
`scope.type_of` under a scope carrying the project seed and the plugin registry (SI:1713, 1755, 1774,
2110, 2230, 2995; registry at SI:969–980), so they are not pure functions of a file. A table-level
approximation *direction* is ill-posed: visibility is read to fire and silenced by `nil`
(`check_rules.rb:3710–3720`), constants are read in both directions (`scope.rb:136–155`), and the
override rules' ancestor walk is built from the same readers — `includes_of`, `superclass_of`,
`user_def_for`, `known_user_class?` — that suppress `undefined-method` elsewhere
(`check_rules.rb:3776–3807`; `discovered_method?` at `scope.rb:987` has 38 callers and serves both
`check_rules.rb:952` and the RBS bridge's shadow test at `rbs_dispatch.rb:518, 522`). And a
single-valued table cannot hold a superset: an extra singleton def *displaces* the right one
(last-write-wins, SI:5007–5013), and scalar consumers deref the value (`runner.rb:590–616`).

## Decision

**Criterion.** A discovery producer is judged by a relation Ruby can witness, never by identity to a
predecessor: a fact is *certain* (it holds in every execution of the file's declaration bodies) or
*possible* (it holds in some), and each **call site** that reads a table states which it consumes. A
behaviour change to a producer lands when a reproduced bug's witness fixture goes from failing to
passing and the two artifact diffs are adjudicated (WD7). A behaviour-preserving change lands under
byte-identity and the shadow harness, as before. Speed is measured and is never the reason.

### WD1 — Certainty on facts; today's tables keep today's meaning

- Every existing member keeps exactly its current contents and semantics: it holds the **union**
  (`certain ∪ possible`), which is what every reader consumes today. No existing reader — a `Scope`
  reader, a raw table read, a scalar deref — changes meaning until it is migrated.
- A set-valued member that acquires `possible` facts gains a `certain_*` sibling holding the
  `certain` subset. The relation per member is `certain_* ⊆ member`, and, for the per-file
  contribution before the fold, `certain ⊆ every run ⊆ member`.
- A single-valued member keeps its scalar slot and today's fold (later-wins, or `||=` where the fold
  already never displaces, SI:6228). It gains a `contested_*` sibling: the set of keys whose value
  differs between certain and possible alternatives. Slots never hold Arrays; `runner.rb:616`,
  `rbs_dispatch.rb:866` and every other scalar deref are unaffected. Precedents: the header-nesting
  alternatives (`lib/rigor/scope/discovery_index.rb:83–85`) and the `nil`-silences-the-rule contract
  (`check_rules.rb:3714–3720`).
- Storage is two tables, not tagged values: no per-entry allocation; both stay Marshal-clean for seed
  bundles and fork payloads.

### WD2 — Direction per call site

Direction is a property of what a read *does*, not of the reader. A reader used in both directions
offers both forms and the call site chooses:

- A read that **withholds** — its fact's presence suppresses a diagnostic or widens an answer
  (`undefined-method` suppression at `check_rules.rb:952`, `user_def_for` for return inference,
  ancestor resolution, `published_constant?`) — reads the union: today's behaviour, unchanged.
- A read that **fires** — its fact's presence makes a diagnostic fire or narrows an answer
  (`def.override-visibility-reduced` and its ancestor walk at `check_rules.rb:3776–3807`, the private
  visibility firing at `check_rules.rb:2648–2649`, `locally_declared_constant?`) — reads `certain_*`,
  and reads `nil` for a key in `contested_*`.
- A read that **chooses between two precise answers** (the RBS bridge's shadow test,
  `rbs_dispatch.rb:518, 522`) keeps the union until its own fixture shows a direction; it is listed as
  an open call site, not decided here.

Mechanically: `Scope` gains `certain_*` readers beside the existing ones (`certain_method_visibility`,
`certain_includes_of`, `certain_user_def_for`, …, each returning `nil`/empty for a contested key);
existing readers are untouched. A **read-site allowlist spec** greps `lib/` and `plugins/` for reads of
the raw tables outside their owners (`scope.rb`, `scope/discovery_index.rb`, `scope_indexer.rb`,
`runner/project_pre_passes.rb`; 17 files today) and for calls of the direction-bearing `Scope`
readers, and compares them with a committed list in which each site is marked *withholding*
(safe by default: it reads the union) or *firing* (migrated to a `certain_*` reader in a named PR, or
pending). Any new site fails the spec until listed. The label is self-declared; a *firing* site
that is mislabelled *withholding* keeps today's behaviour, which is the failure this ADR exists to
fix but never a new one, and each migration PR carries a fixture that fires under a `possible` fact
before the migration and not after.

### WD3 — Edge certainty and concern hooks, against Ruby's semantics

- An `include`, `prepend` or `extend` edge is `certain` when the call is a direct statement of a
  `class`/`module` body or of a hook instantiated through a `certain` edge (one hop), and `possible`
  otherwise: inside control flow, inside a method, through `send`, or with a computed argument.
- Recognition scope for the first cut: modules whose body has `extend ActiveSupport::Concern`, as
  `SyntheticMethodScanner#concern_module_body?` recognises them (`synthetic_method_scanner.rb:318–326`).
  Today every walker treats their hooks as ordinary calls under the concern's own owner: `included`
  and `class_methods` are in neither the eval-family lists (SI:2755, 2770) nor the opaque list
  (SI:2762), so `rebound_block_self` answers nil (SI:2918–2925) and the mixin walk records an
  `include N` inside `included do` as the concern including `N` (SI:5862–5889). The scanner collects
  `included do` calls (`:326–336`) and replays *macro calls only* per includer (`:346–362`); it does
  not handle `class_methods` and does not replay nested concerns (`:280–284`).
- **`class_methods do … end`** defines methods on the module `M::ClassMethods` (Ruby's
  `const_set`), and each includer `extend`s that module; the includer's own `def self.x` wins whichever
  is written first, and `C.singleton_methods(false)` is empty (probed on Ruby 4.0.5 with the bundle's
  `ActiveSupport::Concern`). So the facts are: the block's `def`s are ordinary instance defs of
  `M::ClassMethods` (a real constant, whether spelled `class_methods do` or `module ClassMethods`),
  and each include edge `C ← M` yields an **`extend M::ClassMethods` edge for `C`** with the edge's
  certainty. The existing extends fold (SI:6218–6230) then gives Ruby's precedence for free: it copies
  the module's defs into `C`'s singleton table with `||=`, so `C`'s own `def self.x` is never displaced,
  and `Narrowing`'s singleton-ancestry readers see the edge (`implicit_self.rb:69, 109, 135`;
  `macro_block_self_type.rb:161`). No `def self.` row is copied.
- **`included do … end`** is `class_eval`'d on the includer once, at the include statement. Its facts
  are applied **at the include point** as if written there in `C`'s body: its `def`s are `C`'s own
  instance defs at that position; visibility inside the block is the block's own sibling-order state,
  starting public; a mixin call inside it is an edge of `C`. Precedence: a `C` def written *after* the
  include wins (today's later-wins fold) and carries `C`'s own visibility state (probe: `included do;
  private; def helper2` then `def helper2` in `C` is public); a `C` def written *before* the include is
  redefined by the block. Under a `possible` edge the slot keeps today's fold and the key joins
  `contested_*`.
- A concern included into a plain module runs its hook on that module (probe: `Mod.singleton_class`
  includes `M::ClassMethods`), and that module's later includers do not re-run it; a concern included
  into a concern is deferred to the eventual class: one hop, deeper chains stay `possible`. A
  `module_function` inside a hook is a `NameError` when the includer is a Class and takes effect when
  it is a Module (probe); it yields a fact only for module includers.
- **One implementation.** Concern recognition, hook collection and per-includer edge enumeration move
  into one `Concerns` helper; the project fold instantiates facts through it, and
  `SyntheticMethodScanner`'s replay takes its includer list from the same helper instead of its own
  `concern_index`. Instantiation runs in the fold, never in a file's bundle: the includer's rows derive
  from the concern's file (ADR-85 WD4 rebuilds from bundles on every recheck).
- **Dependency edges.** An instantiated def carries a def-source row (`"path:line"` inside the
  concern) under `C`'s key in `(singleton_)def_sources`, so `DependencyRecorder.read_site` records the
  concern's file (`lib/rigor/analysis/dependency_recorder.rb:283` drops a nil site today), and the
  concern's path is added to `discovered_class_sources[C]` (SI:7686–7693), which `record_class_dependency`
  reads (`scope.rb:1769–1771`). The existing extends fold writes no source rows either (SI:6218–6230);
  the same PR adds them. `symbol_fingerprints` (`runner.rb:590–616`) then fingerprints the instantiated
  bodies from the concern's nodes or handles, so editing a concern's `class_methods` body re-checks
  its includers' callers under `--incremental`.
- **Sig-gen.** Renders `extend M::ClassMethods` in `C`'s declaration (the renderer emits no mixin
  lines today, `lib/rigor/sig_gen/renderer.rb:68–94`; this is a new line kind), the block's defs as
  instance methods of `M::ClassMethods`, and `included do` defs as `C`'s own defs with their block
  visibility. Today it would render a `class_methods` def as an instance method of `M`.
- Reference: PHPStan analyses a trait once per using class, in that class's scope, never standalone
  (<https://phpstan.org/blog/how-phpstan-analyses-traits>; `src/Analyser/NodeScopeResolver.php` in
  <https://github.com/phpstan/phpstan-src>). Ruby needs certainty on the edge because `include` is a
  call; PHP's `use` is a declaration.

### WD4 — Classification of every `DiscoveryIndex` member, with structural checks

A spec classifies each of the 39 `Data.define` members (`discovery_index.rb:13–53`) into exactly one
class, fails on an unclassified member, and asserts each class's structural property on an index built
from a fixture project, so a member that carries the wrong shape fails, not only a missing label.

| Class | Members | Structural assertion | Reference |
| --- | --- | --- | --- |
| Set-valued (WD1 pair) | `discovered_methods`, `discovered_includes`, `discovered_prepends`, `discovered_extends`, `discovered_classes`, `published_constant_names`, `published_constant_alias_names`, `local_constant_names`, `constant_writers`, `constant_shadowers`, `constant_sources`, `discovered_refinements`, `discovered_global_write_census`, `discovered_deferred_ranges` (rows; the `kind`/`owner` columns come from the shared `module_function` helper) | values are Sets/Arrays/Hashes of names or rows; where a `certain_*` sibling exists, `certain_* ⊆ member` | Ruby witness |
| Single-valued (scalar + `contested_*`) | `discovered_def_nodes`, `discovered_singleton_def_nodes`, `discovered_def_sources`, `discovered_singleton_def_sources`, `discovered_superclasses`, `discovered_method_visibilities`, `discovered_header_nestings`, `data_member_layouts`, `struct_member_layouts` | no slot holds an Array or Set of alternatives; `contested_*` keys ⊆ member keys | Ruby witness (`source_location` for def identity) |
| Typed | `declared_types`, `class_ivars`, `class_cvars`, `program_globals`, `program_global_seeds`, `in_source_constants`, `param_inferred_types`, `published_constant_ivars` (provisional) | every leaf is a `Rigor::Type` value | The type lattice: union and `Dynamic` express uncertainty; WD1 does not apply |
| Syntactic | `discovered_def_nestings`, `discovered_class_sources`, `discovered_parameter_envelopes`, `patched_line_readers`, `clears_last_status`, `defines_case_equality` | rebuilt byte-identically by the shadow oracle on the fixture | The parse; the ADR-53 shadow harness stays for these |
| Run state | `run_generation`, `implicit_self_evidence` | absent from every seed bundle | None |

Deferred ranges and def sources are not syntactic: the range rows carry the `module_function`
definee (SI:4260–4271) and the def sources come from the definee walker (SI:7622) and feed the
ADR-17/#735 suppression through `Scope` (`scope.rb:1045, 1094, 1111, 1127, 1143`). Both change in
Migration PRs B–D and are gated by WD5, not by byte-identity.

### WD5 — The witness

One spec fixture per filed bug, executed in a subprocess under the Flake's Ruby, records
`Module.nesting`, `instance_methods(false)`, `singleton_methods(false)`, the three visibility sets,
`ancestors`, `Method#owner` and `Method#source_location`, and compares them with the **per-file**
tables (`build_file_index`, SI:7284) under WD1's relation and, for def identity, by line. The relation
is stated per file because `finalize_def_index` deliberately subtracts plain cross-file defs (SI:7565–7569,
ADR-17); that subtraction is a consumer policy, not a witness failure. A fixture must fail on
`master` before its fix, so every fixture is its own positive control. **Limit:** one run witnesses one
execution; "every run" is approximated by fixture variants that take each branch of the construct
under test, and a fabricated `certain` fact is caught only where a variant's run lacks it. Programs
that fail to load are dropped. The fuzzer stays a local tool until its load rate on the constructs
that matter (measured at 2–7 %) exceeds 50 %.

### WD6 — The tripwires

- **Producers.** A spec computes, at run time, (i) the files under `lib/` and `plugins/` matching
  `Prism::(Class|Module|SingletonClass)Node` (57 today), (ii) the files naming a visibility or mixin
  keyword as a symbol (`:private`, `:protected`, `:public`, `:module_function`, `:include`, `:extend`,
  `:prepend`), which catches `effects/visibility.rb`-style computers, and (iii) inside
  `scope_indexer.rb`, each **method** whose body has a `when Prism::(Class|Module|SingletonClass)Node`
  arm, by parsing the file with Prism. It compares each set with a committed allowlist. Any new file or
  new method fails. The allowlist freezes the set; it does not certify that an entry uses a shared
  helper, and this ADR claims no more than that for it.
- **Readers.** The WD2 read-site allowlist.

### WD7 — Landing rules

- **Behaviour-preserving changes** — refactors, ports onto `DeclarationWalk`, performance and
  allocation work in any producer or reader — land as they do today: byte-identical corpus
  diagnostics, the shadow harness wherever a table is rebuilt, and the per-merge allocation sweep
  (ADR-116 guardrails). A port may not change a fact; a change to a fact is a behaviour change.
- **Behaviour changes to declaration facts** — in a `ScopeIndexer` walker, a `DeclarationWalk`
  collector, the fold, sig-gen, Effects, a plugin discoverer, or a read site's direction — land when:
  - (a) a reproduced bug's WD5 fixture fails before and passes after;
  - (b) the PR carries the corpus diagnostics diff **and** the corpus `rigor sig-gen` output diff, every
    changed line adjudicated under the false-positive rule in the PR body; sig-gen is in scope because
    `visibility_excludes?` hides visibility changes from diagnostics (`generator.rb:738–747`, first in
    `classify_def` at `:912–913`);
  - (c) the PR claims neither byte-identity to a predecessor nor a variant.

### What each part removes, and what remains

| Failure mode | Removed by | Remains |
| --- | --- | --- |
| 1 Prose enumeration | WD4 (members are `Data.define`-derived, shape-checked); WD6 (producers are grep and parse outputs); WD2's read-site allowlist (readers are a grep output, safe by default) | Grandfathered producers and read sites converge only as bugs are filed; a read site's direction label is self-declared |
| 2 Variants by reading; vacuous sweeps | WD1 + WD7(c): no variants; a disagreement is a fixture or nothing; WD5: a fixture is a positive control | Unknown constructs are found by users, not generated; one run witnesses one execution |
| 3 Several `module_function` implementations | One helper with a three-valued answer, read per WD2 direction (Migration B, C); WD3's one `Concerns` helper | — |
| 4 Byte-identity to wrong legacy | WD1 + WD7: over-approximation is legal only as `possible`, read in the withholding direction | A fabricated `certain` fact no fixture covers stays until reported |
| 5 Shifting justification | WD7: two lanes with fixed gates; speed is never the reason | Triage decides what counts as reproduced |

## Migration

**Before acceptance — byte-identical or an ordinary bug fix, no ADR needed.**

1. **#1551 (merged).** `merge_def_nestings` returns a layered lookup instead of copying the project
   table per analysed file (SI:349–354).
2. **`module_function` state extraction (Draft, in flight).** A pure move of the three `ScopeIndexer`
   answers and sig-gen's behind one helper with four entry points; shadow-checked on the corpus.
3. **The four gates (Draft, in flight).** The WD4 classification spec with its structural assertions;
   the WD6 producer tripwire with today's files and methods; the WD2 read-site allowlist with today's
   sites, all marked *withholding*; the WD5 harness with fixtures for #1518, #1519, #1520, #1550 and the
   `module_function` probes marked pending.
4. **#1548.** The seeded deferred-ranges reuse keys on path presence (SI:312–314) while analysis parses
   with `version:` (`runner.rb:1985–1994`) and the pre-pass without (SI:7198), and the mutation oracle
   seeds a mutant with its parent's ranges (`lib/rigor/protection/discovery_seed.rb:97–108`,
   `diagnostic_oracle.rb:52–55`). Key it on content digest plus parse version, or drop it.

**After acceptance — the first behaviour-changing PRs, each under WD7.**

| PR | Change | Expected corpus diff | Expected sig-gen diff | False-positive check |
| --- | --- | --- | --- | --- |
| A — #1550 | The named form snapshots the last receiverless `def` before the call; a later redefinition is a public instance `def` | Zero (rare construct) | The singleton keeps the earlier body's type | Fixture asserts `P9.a == 1`; removing a fabricated later-def singleton can only replace a suppressed call with the correct type |
| B — reset, receiverless-only, privatisation | A bare `public`/`private`/`protected` ends the toggle; `def self.x` gets no instance copy; `attr_reader` is private without a singleton copy; `define_method` gets both; a `certain` module function's instance copy is recorded private (the visibility walker ignores `module_function` today, SI:6279–6420); sig-gen bypasses `visibility_excludes?` for module functions | Zero expected on existence; `def.override-visibility-reduced` stops firing on `Helpers#fmt` (private overriding private); any new firing is on code where Ruby raises | Module functions after a reset stop rendering as singletons; `private; module_function; def b` now renders its singleton (today omitted) | Fixtures P1, P2, P3, P10, P12, P13 and `vis.rb`; existence rows removed are rows Ruby never creates |
| C — `possible` `module_function` and the first firing sites | A bare call inside control flow, a block or a singleton-method body preceding the `def` is `possible`: existence through a self-extend edge in the union (`||=`, never displacing `def self.config`), visibility contested. The override walk (`check_rules.rb:3776–3807`) and the private firing (`:2648–2649`) migrate to `certain_*` readers | Silences the `Helpers2#fmt2` firing; may silence override checks on Rails concerns (recovered by D) | A notice on `possible` module functions | Fixtures A, B, C, E, F, H, J; a contested visibility can only withhold at a firing site |
| D — edge certainty and concern hooks (WD3) | Direct-statement edges `certain`; `extend M::ClassMethods` edges and `included do` facts instantiated per includer through the `Concerns` helper, with def-source and class-source rows; the extends fold gains source rows; sig-gen renders the edge | On Mastodon (`app`: 86 concern files, 60 `included do`, 21 `class_methods do`, 764 include sites) singleton calls on models resolve through the edge instead of `undefined-method` suppression; override checks regain the rows C silenced where the edge is `certain` | `extend M::ClassMethods` lines on includers; `class_methods` defs move from `M` to `M::ClassMethods` | Fixtures with a concern and two includers, asserting `Method#owner`, `singleton_methods(false) == []`, own-def precedence in both orders, and the includer's later public `helper2` |

## Relationship to other ADRs

- **[ADR-116](116-hot-file-restructuring.md) WD5 — partially superseded.** Its byte-identity requirement
  and variant rule (`:160–184`) are retired for behaviour changes; a blockquote at that point names this
  ADR. Its guardrails remain the gate for behaviour-preserving work (WD7, first lane). The four ported
  collectors stay; each `RULE_VARIANTS` entry is deleted when a WD5 fixture shows the walk's rule
  conformant or the variant a bug. #1531 closes as superseded; its note remains as the list of
  candidate fixtures. The README row for ADR-116 drops "WD5 in progress".
- **[ADR-53](53-scope-discovery-index-separation.md)** — the shadow harness's role narrows to WD4's
  syntactic members and to WD7's first lane; the "generic-visitor rewrite: Deferred" row (`:233`) is
  marked superseded by this ADR's mechanism, which needs no rewrite. WD2's explicit keyed readers are
  the choke points the `certain_*` readers join.
- **[ADR-85](85-seed-bundles-and-lazy-def-node-handles.md) WD2 — amended.** Bundles carry the
  `certain_*` and `contested_*` siblings; the next `IncrementalSnapshot::SCHEMA` bump
  (`lib/rigor/cache/incremental_snapshot.rb:148`, currently 30) covers the new rows, and
  `docs/internal-spec/cache.md` documents them. WD3 instantiation runs in the fold, per WD4's
  rebuild-from-bundles rule.
- **[ADR-46](46-incremental-dependency-graph.md)** — corrected, not merely cross-noted: today an
  includer's class dependency records its own `discovered_class_sources` (`scope.rb:1769–1771`), and a
  call resolving through the extends fold has no def-source row to record (SI:6218–6230,
  `dependency_recorder.rb:283`). WD3 adds both rows so a concern edit reaches its includers' callers.
- **[ADR-17](17-monkey-patch-pre-evaluation.md)** — the fold's subtraction of plain cross-file defs
  (SI:7565–7569) is a consumer policy the WD5 relation is stated around, not a violation of it.
- **[ADR-15](15-ractor-concurrency.md)** — the sibling tables are plain frozen data; no module-level
  memo is added. **[ADR-5](5-robustness-principle.md)** — WD2's read directions are its principle
  applied per call site. **[ADR-38](38-additional-initializers.md)** — the typed pre-pass's registry
  read (SI:969–980) is unchanged and is why the typed members are outside WD1.
- **`rigor sig-gen` output is a gated artifact** (WD7(b)); ADR-89 WD1's declaration signature is not
  changed by this ADR.

## Rejected / deferred alternatives

| Candidate | Status | Reason |
| --- | --- | --- |
| A per-file declaration-fact IR (round 1): one emitter, tables as folds, facts cached by digest | Rejected | The typed pre-passes are not pure per file (SI:1713–2995 with the seed and registry); the flow-sensitive ivar pass (SI:396–411) does not fit rows; the default path never loads a snapshot (`runner.rb:1558–1563`), so caching is #120, not an IR property; and quirks would return as fold policies. |
| Ruby as the judge of every disagreement | Rejected | The same text has several Ruby answers (Context 3); the extends over-approximation is deliberate (SI:5958–5963); Zeitwerk namespace synthesis makes correct fixtures raise; six members have no runtime counterpart. Ruby is WD5's *witness* for a stated relation, not a judge. |
| One approximation policy per table | Rejected | Visibility, constants and ancestry are each read in both directions, and a single-valued table cannot be a superset (Context, last paragraph). Direction belongs on the call site (WD2). |
| Storing `certain` facts in the existing member and `possible_*` beside it (this ADR's first draft) | Rejected | Every unmigrated reader — 17 raw-reading files and every `Scope` reader — would silently become certain-only, and a scalar deref would meet an alternatives Array (`runner.rb:616`, `rbs_dispatch.rb:866`). Keeping the union in place makes every unmigrated reader safe by default. |
| Direction fixed once per `Scope` reader | Rejected | The override walk uses the same readers that suppress `undefined-method` (`check_rules.rb:3776–3807`), so a per-reader direction makes `include M if cond` fire the override rule. |
| Copying `class_methods` defs as `def self.` rows on each includer | Rejected | Ruby puts them on `M::ClassMethods` and the includer extends it; the includer's own `def self.x` wins in either order, and `singleton_methods(false)` is empty (probe). The extends fold's `||=` already encodes that precedence. |
| A per-file overlay over the frozen seed for all merged tables | Rejected | Not byte-identical as specified: it omitted the kind-promoting union (SI:3267–3270), refinements (SI:3183–3184), envelopes (`lib/rigor/source/parameter_envelope.rb:64`), the header-nesting bucket merge (SI:5355–5362), three iterating consumers, and the memo's cross-class reads (`expression_typer.rb:2434–2441`). The sound remainder after #1551 is about 90 ms. |
| The fuzzer as a CI gate | Deferred | It loads 28 % of its programs and 2–7 % of those containing `self::` headers, eval rebinding, `class <<` or factory blocks; its construct families are grammar productions the author enumerates. It stays local until its load rate is measured above 50 %. |
| PHPStan-style per-includer re-analysis of hook bodies for diagnostics | Deferred | WD3 instantiates *discovery facts* per edge. Re-running the typed pre-pass and rules per includer multiplies 81 hook bodies by their includer counts on Mastodon; PHPStan's collector idiom (report once when every user agrees, else per context; `src/Rules/Comparison/FunctionCallConstantConditionRule.php` upstream) is the pattern to adopt if that is ever wanted. |
| Continuing the piecewise ports under ADR-116 WD5 | Rejected | The four remaining walks are about 0.2 % of a cold run; each port added variants that protect behaviour no corpus exercises; the contract needed a definee it could not agree on. Ports remain possible as first-lane refactors under WD7. |

## Consequences

Positive:

- The variant rule and the byte-identity requirement for behaviour changes are gone; a disagreement
  between two context computers is a fixture with a Ruby witness or nothing.
- No existing reader changes meaning until a PR migrates it with a fixture; the read-site allowlist
  makes the reader set an output of the code.
- `module_function` has one implementation with one three-valued answer; #1550 and both `vis.rb`
  false positives are fixed under a stated relation.
- Rails concerns resolve as Ruby does: `class_methods` through an `extend M::ClassMethods` edge with
  the includer's own defs winning, `included do` defs at the include point; editing a concern reaches
  its includers' callers under `--incremental`.

Negative:

- **Precision cost of `possible`.** A hook or visibility call reached through a `possible` edge, a
  conditional inside a hook, a `send`-style include, a hand-written `self.included` with a non-`base`
  receiver, or a concern chain deeper than one hop stays `possible`: firing sites decline. WD3 recovers
  the common Rails shape; the rest is the price of the false-positive rule.
- **User-visible sig-gen changes** (PRs B and D): module functions after a visibility reset stop
  rendering as singletons, previously omitted module functions appear, `class_methods` defs move to
  `M::ClassMethods`, and includers gain `extend M::ClassMethods` lines. Each ships with a changelog
  entry.
- **Grandfathered sets**: 57 producer files plus the `scope_indexer.rb` methods, and 17 raw read
  sites, converge only as bugs are filed; the tripwires stop growth but set no pace, and the read-site
  labels are self-declared.
- Two tables where there was one for members that acquire `possible` facts, and a `SCHEMA` bump.
- No speed is claimed. #1551's saving was independent of this decision.

## Open questions for the maintainer

1. **Scope of `possible`.** Keep the definition as stated, with WD3 recovering concerns, or restrict
   `possible` to direct-body control flow and treat blocks as `none`? *Default: as stated.*
2. **The RBS bridge's shadow test** (`rbs_dispatch.rb:518, 522`): keep the union, or read `certain_*`
   and decline the bridge on a contested key? *Default: keep the union until a fixture shows a wrong
   answer either way.*
3. **Sig-gen changes in the changelog.** *Default: yes, one user-facing entry per PR B and D.*
4. **Pace for the grandfathered sets.** A deadline for plugin discoverers and raw read sites, or
   convergence by filed bug only? *Default: by filed bug; the tripwires prevent growth.*
5. **Storage of the siblings.** `certain_*`/`contested_*` tables only where a producer emits `possible`
   facts (as decided), or tagged values? *Default: siblings; measure Mastodon's bundle load before
   revisiting.*
6. **Triage authority.** When a fixture shows Ruby and a deliberate over-approximation disagree (the
   extends table, SI:5958–5963), who rules? *Default: the over-approximation is `possible` and
   conformant; no ruling needed.*
7. **The fuzzer in CI.** *Default: not until its construct load rate is measured above 50 %.*
