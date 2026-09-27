# ADR-119 — Certainty on discovery facts, direction on reads: a witness gate replaces byte-identity

Status: **Proposed, 2026-09-28.** Awaiting the maintainer's acceptance. Nothing behaviour-changing has
landed. Landed already, byte-identical and independent of this decision: #1551 (the layered
def-nesting lookup). In flight as Draft PRs, also byte-identical: the `module_function` state
extraction and the three gates (§ Migration). Every `file:line` below is at `origin/master`
`7ae2c829b`; SI is `lib/rigor/inference/scope_indexer.rb`.

Grounding: the four design-review rounds on #1531 and #1507 (2026-09-28), the two adversarial critiques
they answered, `docs/notes/20260928-declaration-walk-remaining-walkers.md` (on the #1531 branch), and
the probes reproduced in this ADR's Context. ADR-49 archetype: deliberative; stakes: high (it moves
the false-positive envelope of every discovery table).

## Context

ADR-116 WD5 moved `ScopeIndexer`'s table walkers onto one declaration walk, each port required to be
byte-identical to the walker it replaced, with a named *variant* wherever the walkers disagreed
(`docs/adr/116-hot-file-restructuring.md:160–184`). Four tables were ported (#1517, #1522, #1527). A
contract for the next four walkers went through three adversarial review rounds on #1531 and did not
converge; the ports were paused. The reviews and this ADR's own probes attribute that to five failure
modes, each of which the Decision below addresses by mechanism rather than by another list.

1. **Enumeration in prose never converges.** Every list was incomplete in the next round: the quirk
   list (H1), the "four versus twenty walkers" pause scope, and finally the context computers outside
   `ScopeIndexer` — sig-gen's own `module_function` rule (`lib/rigor/sig_gen/generator.rb:665–688`),
   `Effects::DefinitionContext` (`lib/rigor/effects/definition_context.rb:34`), `Plugin::NodeContext`
   (`lib/rigor/plugin/node_context.rb:22`), `SyntheticMethodScanner#build_hierarchy`
   (`lib/rigor/inference/synthetic_method_scanner.rb:369`), the ActiveRecord `ModelDiscoverer`, and
   the evaluator's own class entry (`lib/rigor/inference/statement_evaluator.rb:2699, 2719, 5178`).
   32 files under `lib/` and 24 under `plugins/` dispatch on `Prism::ClassNode`.
2. **Variants were found by reading code and diffing walker against walk**, so they grew as
   O(walkers × categories): `RULE_VARIANTS` went from none to four rules in three slices
   (`lib/rigor/inference/declaration_walk/traversal.rb:89–94`) and the draft needed six more. They
   protect behaviour no corpus exercises — #1527's control switched each variant to the walk's rule and
   found no divergence in 67,137 files — and a shadow sweep over a corpus that lacks a construct passes
   without checking anything (S1). `RIGOR_SHADOW_RULE_WALK` is set by no workflow or Makefile target.
3. **One semantic question had several implementations and no reference.** `module_function`'s
   definee is computed as a sibling-statement toggle (SI:4948–4979), as a prescan that enters blocks and
   control flow (SI:4217–4238), as an orderless self-extend (SI:6185–6198), and as sig-gen's
   direct-statement toggle (`generator.rb:665–688`). Ruby's own answer is run-dependent: a bare call
   inside `if`, `each {}`, `tap {}`, a called lambda or a called `def self.setup` takes effect; an
   uncalled lambda does not; a bare `public`/`private`/`protected` resets it; `def self.x` gets no
   instance copy; the named form snapshots the earlier `def`, so a later redefinition is public
   (probed on Ruby 4.0.5 during the review; the probes become WD5 fixtures in Migration step 3).
4. **Byte-identity was demanded against walkers that are wrong or deliberately over-approximate.**
   The extends walker over-approximates on purpose, in the ADR-5-safe direction (SI:5958–5963).
   #1518–#1520 are rules wrong in several walkers at once. #1550 is a false positive on correct Ruby:
   `module_function :label` followed by a redefinition resolves the *later* `def`, because
   `record_module_function_names` reads a name map in which a later `def` overwrites the earlier
   (SI:5030–5042). A rule fires on `Helpers2#fmt2` overridden privately after
   `if true; module_function; end`, although Ruby makes the module's copy private
   (`lib/rigor/analysis/check_rules.rb:3710–3720`; reproduced with `rigor check` during the review).
5. **The justification shifted** from speed to C2 without a criterion for landing a port. The speed
   case was measured and found absent: the four remaining walks are about 0.2 % of a cold run
   (`docs/adr/116-hot-file-restructuring.md:175` still calls the merge "the wall lever").

Two more findings bound the design. The typed pre-passes — ivars, cvars, globals, constants — call
`scope.type_of` under a scope carrying the project seed and the plugin registry (SI:1713, 1755,
1774, 2110, 2230, 2995; registry at SI:969–980), so they are not pure functions of a file. And a
table-level approximation *direction* is ill-posed: visibility is read to fire and silenced by `nil`
(`check_rules.rb:3710–3720`), constants are read in both directions (`lib/rigor/scope.rb:136–155`),
ancestry both suppresses `undefined-method` and makes override rules fire (`check_rules.rb:3743ff`),
and a single-valued table cannot hold a superset — an extra singleton def *displaces* the right one
(last-write-wins, SI:5007–5013).

## Decision

**Criterion.** A discovery producer is judged by a relation Ruby can witness, never by identity to a
predecessor: a fact is either *certain* (it holds in every execution of the file's declaration bodies)
or *possible* (it holds in some), and each reader states which it consumes. A change to a producer
lands when a reproduced bug's witness fixture goes from failing to passing and the two artifact diffs
are adjudicated (§ Landing criterion). Speed is measured and is never the reason.

### WD1 — Certainty on facts, direction on reads

- *Set-valued members* obey `certain ⊆ every run ⊆ certain ∪ possible`. Storage is two tables per
  member, not tagged values: the existing member holds `certain` facts and a sibling `possible_*`
  member exists only where a producer emits `possible` facts. No per-entry allocation; both stay
  Marshal-clean for seed bundles and fork payloads.
- *Single-valued members* hold a `certain` value or a frozen list of alternatives. A reader asking for
  one value receives `nil` when alternatives exist. The precedents are the header-nesting alternatives
  (`lib/rigor/scope/discovery_index.rb:83–85`), the rule contract that `nil` visibility silences
  (`check_rules.rb:3714–3720`), and the extends fold's `||=`, which never displaces (SI:6228).
- *Readers choose by direction*, once per `Scope` reader (`scope.rb:988–1824`; every read of a
  discovery table goes through one of them, ADR-53 WD2):
  - a read that **fires because a fact is absent** — `user_def_for`, `singleton_def_for`,
    `includes_of`, `prepends_of`, `superclass_of`, `known_user_class?`, `published_constant?` — treats
    `possible` as present and so withholds;
  - a read that **fires because a fact is present** — `discovered_method_visibility`,
    `locally_declared_constant?`, the override rules' ancestor walk — uses `certain` only;
  - a read that **chooses between two precise answers** (the RBS bridge's shadow test,
    `lib/rigor/inference/method_dispatcher/rbs_dispatch.rb:509–512`) uses `certain` and falls to the
    gradual answer when only `possible` facts exist.
  This is ADR-5 applied per read instead of per table.

### WD2 — Edge certainty and includer-parameterised facts

- An `include`, `prepend` or `extend` edge is `certain` when the call is a direct statement of a
  `class`/`module` body (or of a hook instantiated through a `certain` edge, one hop), and `possible`
  otherwise: inside control flow, inside a method, through `send`, or with a computed argument.
- A fact may be emitted with `owner = :includer`. The project fold instantiates it once per edge as
  `fact[owner := C]` with certainty `min(edge, fact)`. Instantiation happens in the fold, never in a
  file's bundle, because the includer's rows derive from the module's file (ADR-85 WD4 rebuilds from
  bundles on every recheck, so the fold is the right place).
- First recognition scope: modules with `extend ActiveSupport::Concern`, and their `included do … end`
  (owner = includer, instance side, sibling-order visibility inside the block) and
  `class_methods do … end` (owner = includer, singleton side). This is the scope
  `SyntheticMethodScanner` already recognises for macro calls (`synthetic_method_scanner.rb:286,
  318–334, 346–360`, one hop for nested concerns at `:280`). Today every walker treats those blocks as
  ordinary calls under the concern's own owner — `included` and `class_methods` are in neither the
  eval-family lists (SI:2755, 2770) nor the opaque list (SI:2762), so `rebound_block_self` answers nil
  (SI:2918–2925) and `walk_mixin_call_children` walks the block with `current_class` = the concern
  (SI:5862–5889). A `module_function` inside either block is a runtime `NameError` (`class_eval` on a
  Class) and yields no fact.
- Reference: PHPStan analyses a trait once per using class in that class's scope, never standalone
  (`references/phpstan/website/src/_posts/how-phpstan-analyses-traits.md:50`). Ruby needs certainty on
  the edge because `include` is a call; PHP's `use` is a declaration.

### WD3 — Classification of every `DiscoveryIndex` member

A spec classifies each of the 39 `Data.define` members (`discovery_index.rb:13–51`) into exactly one
class and fails on an unclassified member, so the set is code-derived and never vacuous.

| Class | Members | Reference |
| --- | --- | --- |
| Set-valued (WD1 pair) | `discovered_methods`, `discovered_includes`, `discovered_prepends`, `discovered_extends`, `discovered_classes`, `published_constant_names`, `published_constant_alias_names`, `local_constant_names`, `constant_writers`, `constant_shadowers`, `constant_sources`, `discovered_refinements`, `discovered_global_write_census`, `patched_line_readers` | Ruby witness |
| Single-valued (value or alternatives) | `discovered_def_nodes`, `discovered_singleton_def_nodes`, `discovered_superclasses`, `discovered_method_visibilities`, `discovered_header_nestings`, `data_member_layouts`, `struct_member_layouts` | Ruby witness (`source_location` for def identity) |
| Typed | `declared_types`, `class_ivars`, `class_cvars`, `program_globals`, `in_source_constants`, `param_inferred_types`, `published_constant_ivars` (provisional) | The type lattice: union and `Dynamic` already express uncertainty; WD1 does not apply |
| Syntactic | `discovered_def_nestings`, `discovered_deferred_ranges`, `discovered_def_sources`, `discovered_singleton_def_sources`, `discovered_class_sources`, `discovered_parameter_envelopes` | The parse; second derivation (the ADR-53 shadow harness, kept for these) |
| Run state | `run_generation`, `program_global_seeds`, `clears_last_status`, `defines_case_equality`, `implicit_self_evidence` | None |

### WD4 — The tripwire

A spec computes, at run time, the set of files under `lib/` and `plugins/` that match
`Prism::(Class|Module|SingletonClass)Node`, and compares it with a committed allowlist in which each
entry names the shared helper it uses (`DeclarationWalk::Context`, the `module_function` helper) or
the reason it does not. Any new file fails the spec. The 56 files matching today are grandfathered
with a reason each.

### WD5 — The witness

One spec fixture per filed bug, executed in a subprocess under the Flake's Ruby, records
`Module.nesting`, `instance_methods(false)`, `singleton_methods(false)`, the three visibility sets,
`ancestors` and `Method#source_location`, and compares them with the tables under WD1's relation and,
for def identity, by line. A fixture must fail on `master` before its fix, so every fixture is its own
positive control. Programs that fail to load are dropped: the relation is quantified over runnable
programs, and the corpus diff covers the rest. The fuzzer stays a local tool until its load rate on
the constructs that matter (measured at 2–7 %) exceeds 50 %.

### WD6 — Landing criterion

A change to any producer of declaration facts — a `ScopeIndexer` walker, a `DeclarationWalk`
collector, sig-gen, Effects, a plugin discoverer — lands when:

- (a) it fixes a reproduced bug: a WD5 fixture fails before and passes after;
- (b) the PR carries the corpus diagnostics diff **and** the corpus `rigor sig-gen` output diff, with
  every changed line adjudicated under the false-positive rule in the PR body; sig-gen is in scope
  because `visibility_excludes?` hides visibility changes from diagnostics (`generator.rb:738–747`,
  first in `classify_def` at `:912–913`);
- (c) it claims neither byte-identity to a predecessor nor a variant.

A refactor with no bug has no criterion and does not land; a port onto `DeclarationWalk` is neither
required nor gated.

### What each part removes, and what remains

| Failure mode | Removed by | Remains |
| --- | --- | --- |
| 1 Prose enumeration | WD3 (members are `Data.define`-derived, completeness-gated); WD4 (computers are a grep output) | The 56 grandfathered files converge only as bugs are filed against them |
| 2 Variants by reading; vacuous sweeps | WD1 + WD6(c): no variants exist; a disagreement is a fixture or nothing; WD5: a fixture is a positive control | Unknown constructs are found by users, not generated |
| 3 Several `module_function` implementations | One helper with a three-valued answer (`certain` / `possible` / none), read per WD1 direction (§ Migration B, C) | — |
| 4 Byte-identity to wrong legacy | WD1 + WD6: over-approximation is legal only as `possible`, read in the withholding direction | A fabricated `certain` fact no fixture covers stays until reported |
| 5 Shifting justification | WD6: bug, witness, two diffs; speed is never the reason | Triage decides what counts as reproduced |

## Migration

**Before acceptance — byte-identical or an ordinary bug fix, no ADR needed.**

1. **#1551 (merged).** `merge_def_nestings` returns a layered lookup instead of copying the project
   table per analysed file (SI:349–354); 263 ms of a 18.95 s Mastodon cold profile.
2. **`module_function` state extraction (Draft, in flight).** A pure move of the three `ScopeIndexer`
   answers and sig-gen's behind one helper with four entry points; shadow-checked on the corpus.
3. **The three gates (Draft, in flight).** The WD3 classification spec over today's members; the WD4
   tripwire with today's 56 files; the WD5 harness with fixtures for #1518, #1519, #1520 and #1550
   marked pending.
4. **#1548.** The seeded deferred-ranges reuse keys on path presence (SI:312–314) while analysis parses
   with `version:` (`lib/rigor/analysis/runner.rb:1985–1994`) and the pre-pass without (SI:7198), and
   the mutation oracle seeds a mutant with its parent's ranges
   (`lib/rigor/protection/discovery_seed.rb:97–108`, `diagnostic_oracle.rb:52–55`). Key it on content
   digest plus parse version, or drop it.

**After acceptance — the first behaviour-changing PRs, each under WD6.**

| PR | Change | Expected corpus diff | Expected sig-gen diff | False-positive check |
| --- | --- | --- | --- | --- |
| A — #1550 | The named form snapshots the last receiverless `def` before the call; a later redefinition is a public instance `def` | Zero (rare construct) | The singleton keeps the earlier body's type | Fixture asserts `P9.a == 1`; removing a fabricated later-def singleton can only replace a suppressed call with the correct type |
| B — reset and receiverless-only | A bare `public`/`private`/`protected` ends the toggle; `def self.x` gets no instance copy; `attr_reader` is private without a singleton copy; `define_method` gets both; sig-gen bypasses `visibility_excludes?` for module functions | Zero expected; any new firing is on code where Ruby raises | Module functions after a reset stop rendering as singletons; `private; module_function; def b` now renders its singleton (today omitted) | Fixtures P1, P2, P3, P10, P12, P13; existence rows removed are `certain` rows Ruby never creates |
| C — `possible` `module_function` | A bare call inside control flow, a block or a singleton-method body preceding the `def` is `possible`: existence through a self-extend edge (`||=`, never displacing `def self.config`), visibility `nil` | Silences the two `vis.rb` firings; may silence override checks on Rails concerns (see D) | A notice on `possible` module functions | Fixtures A, B, C, E, F, H, J; a `nil` visibility can only withhold |
| D — edge certainty and concern instantiation (WD2) | Direct-statement edges `certain`; `included do` / `class_methods do` facts instantiated per includer in the fold | Adds singleton methods and visibilities under every Mastodon model that includes a concern (86 concern files, 60 `included do`, 21 `class_methods do`, 764 include sites in `app`); override checks regain the rows C silenced where the edge is `certain` | `class_methods` defs appear as `def self.` on includers | Fixtures with a concern and two includers, asserting Ruby's `singleton_methods(false)` and visibility sets per includer |

## Relationship to other ADRs

- **[ADR-116](116-hot-file-restructuring.md) WD5 — partially superseded.** Its byte-identity requirement
  and variant rule (`:160–184`) are retired; a blockquote at that point names this ADR. The four ported
  collectors stay as they are; each `RULE_VARIANTS` entry is deleted when a WD5 fixture shows the walk's
  rule conformant or the variant a bug. #1531 closes as superseded; its note remains as the list of
  candidate fixtures. The README row for ADR-116 drops "WD5 in progress".
- **[ADR-53](53-scope-discovery-index-separation.md)** — the shadow harness's role narrows to the
  syntactic members of WD3; the "generic-visitor rewrite: Deferred" row (`:233`) is marked superseded by
  this ADR's mechanism, which needs no rewrite. WD2's explicit keyed readers are the choke points WD1
  attaches direction to.
- **[ADR-85](85-seed-bundles-and-lazy-def-node-handles.md) WD2 — amended.** Bundles carry the
  `possible_*` sibling tables and single-valued alternatives; the next `IncrementalSnapshot::SCHEMA`
  bump (`lib/rigor/cache/incremental_snapshot.rb:143`, currently 29; #1545 also bumps it) covers the
  new rows, and `docs/internal-spec/cache.md` documents them. WD2 instantiation runs in the fold, per
  WD4's rebuild-from-bundles rule.
- **[ADR-46](46-incremental-dependency-graph.md)** — unchanged: `includes_of` already records a class
  dependency on the module (`scope.rb:1275`), so a concern edit re-checks its includers today.
- **[ADR-15](15-ractor-concurrency.md)** — the two-table storage and alternatives are plain frozen data;
  no module-level memo is added. **[ADR-5](5-robustness-principle.md)** — WD1's read directions are its
  principle applied per read. **[ADR-38](38-additional-initializers.md)** — the typed pre-pass's
  registry read (SI:969–980) is unchanged and is why the typed members are outside WD1.
- **`rigor sig-gen` output is a gated artifact** (WD6(b)); ADR-89 WD1's declaration signature is not
  changed by this ADR.

## Rejected / deferred alternatives

| Candidate | Status | Reason |
| --- | --- | --- |
| A per-file declaration-fact IR (round 1): one emitter, tables as folds, facts cached by digest | Rejected | The typed pre-passes are not pure per file (SI:1713–2995 with the seed and registry); the flow-sensitive ivar pass (SI:396–411) does not fit rows; the default path never loads a snapshot (`runner.rb:1558–1563`), so caching is #120, not an IR property; and quirks would return as fold policies. |
| Ruby as the judge of every disagreement | Rejected | The same text has several Ruby answers (Context 3); the extends over-approximation is deliberate (SI:5958–5963); Zeitwerk namespace synthesis makes correct fixtures raise; six members have no runtime counterpart. Ruby is WD5's *witness* for a stated relation, not a judge. |
| One approximation policy per table | Rejected | Visibility, constants and ancestry are each read in both directions, and a single-valued table cannot be a superset (Context, last paragraph). Direction belongs on the read (WD1). |
| A per-file overlay over the frozen seed for all merged tables | Rejected | Not byte-identical as specified: it omitted the kind-promoting union (SI:3267–3270), refinements (SI:3183–3184), envelopes (`lib/rigor/source/parameter_envelope.rb:64`) and the header-nesting bucket merge (SI:5355–5362), three iterating consumers, and the memo's cross-class reads (`lib/rigor/inference/expression_typer.rb:2434–2441`). The sound remainder after #1551 is about 90 ms. |
| The fuzzer as a CI gate | Deferred | It loads 28 % of its programs and 2–7 % of those containing `self::` headers, eval rebinding, `class <<` or factory blocks; its construct families are grammar productions the author enumerates. It stays local until its load rate is measured above 50 %. |
| PHPStan-style per-includer re-analysis of hook bodies for diagnostics | Deferred | WD2 instantiates *discovery facts* per edge, which is a substitution over rows. Re-running the typed pre-pass and rules per includer multiplies 81 block bodies by their includer counts on Mastodon; PHPStan's collector idiom (report once when every user agrees, else per context, `phpstan-src/src/Rules/Comparison/FunctionCallConstantConditionRule.php:87–130`) is the pattern to adopt if that is ever wanted. |
| Continuing the piecewise ports under ADR-116 WD5 | Rejected | The four remaining walks are about 0.2 % of a cold run; each port added variants that protect behaviour no corpus exercises; the contract needed a definee it could not agree on. Ports become optional refactors judged by WD6. |

## Consequences

Positive:

- The variant rule, the byte-identity requirement and the shadow sweeps over non-syntactic tables are
  gone; a disagreement between two context computers is a fixture with a Ruby witness or nothing.
- `module_function` has one implementation with one three-valued answer; #1550 and the `vis.rb` false
  positives are fixed under a stated relation instead of relitigated.
- Rails concerns' `class_methods` defs and hook visibilities become `certain` per includer where the
  include is a direct statement, so the override and visibility checks keep their true positives there.
- The member set and the computer set are outputs of the code, not of a reading.

Negative:

- **Precision cost of `possible`.** A hook or visibility call reached through a `possible` edge, a
  conditional inside a hook, a `send`-style include, a hand-written `self.included` with a non-`base`
  receiver, or a concern chain deeper than one hop stays `possible`: existence readers withhold and
  visibility reads answer `nil`, so some true positives on such code are lost. WD2 recovers the common
  Rails shape; the rest is the price of the false-positive rule.
- **User-visible sig-gen changes** (PRs B and D): module functions after a visibility reset stop
  rendering as singletons, previously omitted module functions appear, and includers gain `def self.`
  entries from `class_methods`. Each ships with a changelog entry.
- **56 grandfathered context computers** converge only as bugs are filed; the tripwire stops growth but
  sets no pace.
- Two tables where there was one for the members that emit `possible` facts, and a `SCHEMA` bump.
- No speed is claimed. #1551's saving was independent of this decision.

## Open questions for the maintainer

1. **Scope of `possible`.** Keep the definition as stated, with WD2 recovering concerns, or restrict
   `possible` to direct-body control flow and treat blocks as `none`? *Default: as stated.*
2. **Sig-gen changes in the changelog.** *Default: yes, one user-facing entry per PR B and D.*
3. **Pace for the grandfathered files.** A deadline for plugin discoverers, or convergence by filed
   bug only? *Default: by filed bug; the tripwire prevents growth.*
4. **Storage of `possible` facts.** Sibling tables only where emitted (as decided), or tagged values?
   *Default: sibling tables; measure Mastodon's bundle load before revisiting.*
5. **Triage authority.** When a fixture shows Ruby and a deliberate over-approximation disagree (the
   extends table, SI:5958–5963), who rules? *Default: the over-approximation is `possible` and
   conformant; no ruling needed.*
6. **The fuzzer in CI.** *Default: not until its construct load rate is measured above 50 %.*
