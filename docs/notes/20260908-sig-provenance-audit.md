# Provenance of every declaration in `sig/` — the seeding audit for ADR-107 G3 (2026-09-08)

Status: seeding audit for [#825](https://github.com/rigortype/rigor/issues/825), the third gate
[ADR-107](../adr/107-checked-types-and-typeless-comments.md) § Gates names. Measured on
`sig-provenance-gate-825` at `origin/master`, rbs 4.x, Ruby 4.0.5.

ADR-107 § Decision gives `sig/` a provenance rule that follows
[ADR-5](../adr/5-robustness-principle.md)'s asymmetry: a **return** type is generated (clause 1 —
`rigor sig-gen` proves it from the body), a **parameter** type is authored intent (clause 2 keeps it
lenient and inference never derives one), and **anything else hand-written is a gap `sig-gen` could
not close**, which [ADR-14](../adr/14-rbs-sig-generation.md)'s contradiction rule says must be
recorded rather than assumed. Until this audit, nothing had ever asked which of the three each of
the 1,251 declarations under `sig/` was in.

## Commands

Everything below comes from the gate's own classifier, so the note and the gate cannot drift:

```sh
nix --extra-experimental-features 'nix-command flakes' develop --command \
  bundle exec ruby -Ilib -Ispec/support -rsig_provenance_auditor \
    -e 'SigProvenanceAuditor.report(root: Dir.pwd)'
```

The classifier parses every `.rbs` under `sig/` with `RBS::Parser.parse_signature`, runs
`Rigor::SigGen::Generator` over `lib/` in-process with `include_private: true`, and joins on
(class, method). Cross-checks quoted below used the CLI form of the same pass
(`bundle exec exe/rigor sig-gen --diff --format=json lib`) and, for the `no_source` breakdown only,
Ruby reflection over a fully-required `lib/` — reflection is a measurement instrument here, not part
of the gate.

Runtime, 12-core M3 Max: **13.6 s user / 19.0 s wall** for the command above end to end; the
generator pass alone is **~10 s** in a warm process. That is the reason the gate lives in
`spec/rigor/sig_gen/provenance_spec.rb` and not in `spec/docs/`: `make docs-check` is 1.2 s of load
plus 5.4 s of examples today, and hanging a 10 s pass off it would nearly triple the cheap gate.

## Classifications

`sig-gen` compares **returns only**; parameters are never inferred (ADR-5 clause 2), so a
declaration whose return matches inference is earned however its parameters are written.

> **Re-measured 2026-09-09**, after [#836](https://github.com/rigortype/rigor/issues/836) landed. The
> two tables below are the current numbers; the seeding figures stay quoted in the prose that reasons
> about them. What moved: `tighter_return` 15 → 8, and 73 declarations — every `-> void` the
> classifier matched to a `def` — left `generated` / `parameter_intent` / `declared_divergent` for
> the new `return_intent`. The nine stale declarations the audit turned up were also deleted between
> the two runs, which is why the in-scope total drops from 1,052 to 1,044.

| classification | n | earned? | what it means |
| --- | --- | --- | --- |
| `generated` | 163 | yes | the declared return is exactly what `sig-gen` proves, and no parameter is narrower than `untyped` |
| `parameter_intent` | 131 | yes | same return, plus at least one parameter or block typed by the author — ADR-5 clause 2's half |
| `return_intent` | 73 | yes | the declared return is `void` — authored intent no synthesis can produce, so `sig-gen` compares nothing (#836) |
| `tighter_return` | 8 | **marker required** | `sig-gen` proposes a narrower return; ADR-14 says apply it or record why not |
| `declared_divergent` | 108 | residue | declared and inferred returns differ and `sig-gen` will not propose the swap |
| `untranslatable_declared` | 0 | residue | `sig-gen` could not translate the declared return into a type object at all |
| `unrenderable` | 342 | residue | `sig-gen` declined the `def` (`sig.skipped.*`) |
| `unmatched_declaration` | 0 | residue | `sig-gen` found the `def`, the RBS environment did not resolve it to this declaration |
| `no_source` | 219 | residue | no `def` `sig-gen` can attribute to this declaration |
| `non_method` | 198 | out of scope | constants, type aliases, `include`, class and module headers |

**367 of 1,044 in-scope declarations (35.2%) are earned; 669 are residue; 8 need a marker.** (The
seeding run measured 358 of 1,052 earned, 679 residue, 15 markers.) Two buckets in the table are
empty by construction rather than by luck, and are kept because each names a real hole a future
`sig/` could fall into: `untranslatable_declared` fires when `Generator#build_declared_return` cannot
translate any overload, and `unmatched_declaration` fires for a `new_method` that is neither a
constructor stub nor declared `void`. Both are unit-tested on fixtures.

## Per file

`earned` is `generated` + `parameter_intent` + `return_intent`; `residue` is the unmarked total the
gate pins, and the two columns the seeding run showed empty everywhere (`untranslatable_declared`,
`unmatched_declaration`) are omitted rather than repeated as zeroes.

| file | `tighter_return` | `declared_divergent` | `unrenderable` | `no_source` | earned | residue |
| --- | --- | --- | --- | --- | --- | --- |
| `sig/prism_node_children.rbs` | 0 | 0 | 0 | 1 | 0 | 1 |
| `sig/rigor.rbs` | 0 | 10 | 39 | 2 | 25 | 51 |
| `sig/rigor/analysis/baseline.rbs` | 0 | 1 | 4 | 0 | 5 | 5 |
| `sig/rigor/analysis/check_rules/always_truthy_condition_collector.rbs` | 0 | 1 | 0 | 0 | 1 | 1 |
| `sig/rigor/analysis/check_rules/dead_assignment_collector.rbs` | 0 | 1 | 0 | 0 | 1 | 1 |
| `sig/rigor/analysis/dependency_source_inference/gem_resolver.rbs` | 0 | 1 | 0 | 0 | 2 | 1 |
| `sig/rigor/analysis/dependency_source_inference/index.rbs` | 0 | 0 | 0 | 0 | 1 | 0 |
| `sig/rigor/analysis/fact_store.rbs` | 0 | 4 | 1 | 12 | 15 | 17 |
| `sig/rigor/ast.rbs` | 0 | 0 | 1 | 0 | 4 | 1 |
| `sig/rigor/cache.rbs` | 1 | 0 | 1 | 0 | 0 | 1 |
| `sig/rigor/cli/diff_command.rbs` | 0 | 0 | 0 | 1 | 1 | 1 |
| `sig/rigor/cli/explain_command.rbs` | 0 | 0 | 0 | 1 | 1 | 1 |
| `sig/rigor/cli/sig_gen_command.rbs` | 0 | 1 | 0 | 1 | 0 | 2 |
| `sig/rigor/cli/type_scan_command.rbs` | 0 | 1 | 0 | 0 | 0 | 1 |
| `sig/rigor/environment.rbs` | 0 | 5 | 36 | 1 | 19 | 42 |
| `sig/rigor/inference.rbs` | 0 | 35 | 38 | 22 | 29 | 95 |
| `sig/rigor/inference/builtins/method_catalog.rbs` | 0 | 1 | 0 | 0 | 1 | 1 |
| `sig/rigor/inference/void_origin.rbs` | 0 | 0 | 0 | 5 | 1 | 5 |
| `sig/rigor/plugin.rbs` | 0 | 0 | 3 | 0 | 1 | 3 |
| `sig/rigor/plugin/access_denied_error.rbs` | 0 | 0 | 0 | 0 | 1 | 0 |
| `sig/rigor/plugin/base.rbs` | 0 | 7 | 19 | 0 | 6 | 26 |
| `sig/rigor/plugin/blueprint.rbs` | 0 | 0 | 3 | 0 | 1 | 3 |
| `sig/rigor/plugin/fact_store.rbs` | 0 | 0 | 1 | 1 | 4 | 2 |
| `sig/rigor/plugin/io_boundary.rbs` | 0 | 0 | 4 | 0 | 2 | 4 |
| `sig/rigor/plugin/load_error.rbs` | 0 | 0 | 2 | 1 | 1 | 3 |
| `sig/rigor/plugin/loader.rbs` | 0 | 0 | 4 | 0 | 1 | 4 |
| `sig/rigor/plugin/manifest.rbs` | 0 | 1 | 20 | 0 | 4 | 21 |
| `sig/rigor/plugin/registry.rbs` | 0 | 0 | 7 | 0 | 3 | 7 |
| `sig/rigor/plugin/services.rbs` | 0 | 0 | 0 | 0 | 1 | 0 |
| `sig/rigor/plugin/trust_policy.rbs` | 0 | 0 | 0 | 0 | 2 | 0 |
| `sig/rigor/plugin/type_node_resolver.rbs` | 0 | 0 | 0 | 0 | 1 | 0 |
| `sig/rigor/rbs_extended.rbs` | 0 | 4 | 4 | 15 | 12 | 23 |
| `sig/rigor/reflection.rbs` | 1 | 3 | 6 | 0 | 6 | 9 |
| `sig/rigor/scope.rbs` | 2 | 3 | 78 | 30 | 41 | 111 |
| `sig/rigor/source.rbs` | 0 | 2 | 7 | 0 | 7 | 9 |
| `sig/rigor/testing.rbs` | 0 | 0 | 4 | 0 | 0 | 4 |
| `sig/rigor/trinary.rbs` | 1 | 0 | 1 | 3 | 11 | 4 |
| `sig/rigor/type.rbs` | 3 | 27 | 59 | 123 | 156 | 209 |

## The 15 `tighter_return`s, and what they say about `sig-gen`

Every one, with the marker seeded for it. The ADR-14 dogfood pattern held — but not in the direction
the issue predicted. **Not one of the 15 is an inference incompleteness.** Twelve are the opposite:
inference is *more* precise than the declaration is meant to be, and applying the tightening would
narrow a contract that is deliberately wide.

The seven `void` rows are **no longer proposed** — #836 landed on 2026-09-09 and their markers came
out of `sig/` with it; they are kept here because the reading is what the fix is built on. Eight
remained after that fix; three of those (below) were applied on 2026-09-09 (#838) and their markers
are gone too. Five still carry their marker.

| declaration | declared | `sig-gen` proposes | reading |
| --- | --- | --- | --- |
| `Rigor::ValueSemantics.included` | `void` | `Module` | void-vs-value (fixed, #836) |
| `Rigor::Environment::ClassRegistry#register` | `void` | `ClassRegistry` | void-vs-value (fixed, #836) |
| `Rigor::Inference::StatementEvaluator#evaluate_block_if_present` | `void` | `[Type::t, Scope] \| nil` | void-vs-value (fixed, #836) |
| `Rigor::Inference::FallbackTracer#record_fallback` | `void` | `FallbackTracer` | void-vs-value (fixed, #836) |
| `Rigor::Inference::FallbackTracer#clear` | `void` | `FallbackTracer` | void-vs-value (fixed, #836) |
| `Rigor::Plugin::FactStore#each_fact` | `void` | `Array` | void-vs-value (fixed, #836) |
| `Rigor::Scope#enqueue_ancestors` | `void` | `Array \| nil` | void-vs-value (fixed, #836) |
| `Rigor::Cache::RbsCacheProducer.generation_cap` | `Integer` | `2` | literal over a shared contract |
| `Rigor::Trinary#to_s` | `String` | `"maybe" \| "no" \| "yes"` | literal over a shared contract |
| `Rigor::Type::Top#describe` | `String` | `"top"` | literal over a shared contract |
| `Rigor::Type::Bot#describe` | `String` | `"bot"` | literal over a shared contract |
| `Rigor::Type::BoundMethod#erase_to_rbs` | `String` | `"Method"` | literal over a shared contract |
| `Rigor::Reflection.class_ordering` | `Symbol` | `:disjoint \| :equal \| :subclass \| :superclass \| :unknown` | applicable (applied, #838) |
| `Rigor::Scope#user_def_through_ancestors` | `[untyped?, String?]` | `[untyped, String] \| [nil, nil]` | applicable (applied, #838) |
| `Rigor::Scope#singleton_def_through_ancestors` | `[untyped?, String?]` | `[untyped, String] \| [nil, nil]` | applicable (applied, #838) |

**Seven are `void`.** `Inference::RbsTypeTranslator` maps RBS `void` to `Type::Top`, and `Top` accepts
everything, so `Generator#tighter?` reports every `void`-declared method whose body happens to return
a typed value as a tightening. `void` is not a wide type the author would like narrowed — it is the
statement that the return value is not part of the contract, which is why `sig-gen` already spells
`initialize` as `-> void` unconditionally. Filed as **P1**,
[#836](https://github.com/rigortype/rigor/issues/836), and **fixed on 2026-09-09**:
`Generator#compare_against_declared` returns `equivalent` for a declared `void` without comparing it,
carrying `void` itself as the declared spelling, and the gate reads that as the new earned
`return_intent` — a `void` declaration needs no marker.

**Five pin a literal onto a contract shared with siblings.** `Top#describe` really does return
`"top"`, but `describe` is the polymorphic surface every type class implements, and every sibling
declares `String`; the same for `Trinary#to_s` and `BoundMethod#erase_to_rbs`.
`Generator#computed_literal_tightening?` exists for exactly this hazard but fires only when the body's
last expression is *not* a direct literal — here it is one, so the guard passes. Filed as **P2**,
[#837](https://github.com/rigortype/rigor/issues/837).

**Three were genuinely applicable**, and were left declared with a marker rather than applied when
the provenance gate landed — changing a declaration is a `sig/` edit that has to clear the precision
gate and Steep on its own, and that landing was not the commit to do it in. Filed as **P3**,
[#838](https://github.com/rigortype/rigor/issues/838), and **applied on 2026-09-09**: each declaration
now reads exactly what `sig-gen --diff --tighter-returns lib` proposes, the three `# sig-gen gap:
#838` markers are gone, and the residue pin in `spec/rigor/sig_gen/provenance_spec.rb` is unchanged —
`tighter_return` sits outside the residue pin (#845), so applying the tightenings moves rows within
the earned/marked bookkeeping, not the pinned residue counts.

## Where the residue declarations come from (679 at the seeding, 669 now)

### `unrenderable` — 342, every one `sig.skipped.untyped-return`

`sig-gen` inferred `Dynamic[top]` for the body and declined to emit `-> untyped`. The dominant shape
is an `attr_reader` over an ivar the class-ivar pre-pass could not type
(`Rigor::Configuration#target_ruby`, `#paths`, `#plugins`, `#cache_path`, …) — the
[ADR-58](../adr/58-ivar-field-typing.md) ivar-field-typing gap, whose WD1 landed and whose WD1b / WD2 /
WD3 have not. This is the single largest lever on the residue and the one number in this note most
worth watching: 342 declarations exist in `sig/` because inference answers `untyped` for the method.

### `no_source` — 227 at the seeding, 219 once the nine stale declarations below were deleted

`sig-gen` enumerates `def`s; `sig/` declares methods, and the two disagree in five ways. Measured by
Ruby reflection over a fully-required `lib/`:

| cause | n | example |
| --- | --- | --- |
| runtime-generated member (`Data.define`, `Struct.new`) | 82 | `Rigor::Analysis::FactStore::Target#kind`, `#new` |
| defined in the class but by metaprogramming, not a `def` | 69 | `Rigor::Type::Nominal#==` / `#eql?` / `#hash` from `ValueSemantics#value_fields` |
| inherited or mixed in | 67 | `Rigor::Type::Top#accepts` (owner `Type::AcceptanceRouter`), the five `CLI::*Command#initialize` (owner `CLI::Command`) |
| **no such method anywhere in `lib/`** | 8 | see below |
| **no such constant anywhere in `lib/`** | 1 | `Rigor::Inference::Builtins::NumericCatalog` |

The last two rows are the audit's only outright bugs: **nine declarations describing code that does
not exist.** Neither `make check`, `make steep-check`, nor `spec/rigor/public_api_drift_spec.rb`
noticed, because each of them asks whether the implementation matches `sig/` and none asks the
converse.

- `Rigor::Inference::StatementEvaluator#qualified_name_for`, `#render_constant_path`,
  `#captured_local_writes`, `#block_introduced_locals`
- `Rigor::Inference::ScopeIndexer#build_declaration_overrides`, `#qualified_name_for`,
  `#render_constant_path`
- the whole of `sig/rigor/inference/builtins/numeric_catalog.rbs` — `NumericCatalog` was folded onto
  the shared `MethodCatalog` loader (`NUMERIC_CATALOG = MethodCatalog.for_topic("numeric")`) and the
  class went with it

All nine are deleted by the commit that seeds the gate. `Prism::Node#rigor_each_child` is the one
`no_source` that is correct as written: `Rigor::Source::NodeChildren` compiles it per concrete node
class at load, which is what its file header already says.

### `declared_divergent` — 110 at the seeding, 108 since #836

The declared return differs from the inferred one and `sig-gen`'s guards refuse the swap. Two shapes,
both benign, and one worth naming:

- **34 declare `untyped`** where inference has a real type. These are the deliberate `untyped`s the
  files already explain in prose — `Rigor::Analysis::Runner#cache_store` and its siblings carry a
  comment saying `Rigor::Cache::Store` is not sig-covered yet and a named reference would raise
  `RBS::UnknownTypeName`. The gate's marker convention formalises what those comments were already
  doing informally.
- **the rest are declared lenience the generator protects**: `Configuration.discover` declares
  `String?` where the body proves `".rigor.dist.yml" | ".rigor.yml" | nil`;
  `CLI::TypeOfCommand#run` declares `Integer` against `0 | 1 | Integer`. `loses_declared_union_member?`
  and `replaces_untyped_type_arg?` fire, so no tightening is proposed and none should be.

None of them is a `def.return-type-mismatch`: a declaration *narrower* than the body proves is
gate G2's job (`make check --fail-on=warning`, [#827](https://github.com/rigortype/rigor/pull/827)),
and it is clean.

## What the gate does with all this

A per-declaration marker on 679 residue rows is not a gate, it is a rewrite of `sig/`, and a check
that fires 679 times on a correct tree is the failure mode `AGENTS.md` § Implementation Guidelines
puts above worst-case static reading. So G3 lands as two mechanisms:

1. **Hard rule, seeded now.** Every `tighter_return` carries a marker naming the issue that says why
   the declaration stays. Fifteen at the seeding, eight since #836; a ninth fails the gate on arrival.
2. **Ratchet, pinned now.** Per-file unmarked-residue counts are an exact snapshot in the spec. A new
   hand-written declaration raises its file's count and goes red; the author either marks it (a marker
   subtracts from the count) or moves the pin deliberately. Closing an engine gap lowers a count, and
   the gate says so rather than letting the slack accumulate.

The marker is a line in the member's own RBS comment:

```rbs
# sig-gen gap: #837 — every sibling type class declares `String`; see P2.
def describe: (?Symbol verbosity) -> String
```

A comment rather than a `%a{…}` annotation. [ADR-0](../adr/0-concept.md) requires the metadata to live
in the `.rbs` file and both spellings satisfy that, but the comment stays out of the `rigor:v1:`
directive namespace `Rigor::RbsExtended` owns and ADR-20 / ADR-103 keep extending, carries no version
token, is read by no engine path (an unrecognised `%a{}` is silently ignored today, but "silently
ignored" is a property that can change), and reads as prose. RBS binds it to the member, so the gate
reads it off the AST rather than by scanning lines. The number must resolve to a filed issue — it is
the pointer to the engine work that would let the generator answer, and a placeholder points at
nothing, so the gate does not accept one.

## The follow-up issues

Filed from this section, and each marker in `sig/` names the one for its category. Fifteen at the
seeding: seven pointed at #836, five at #837, three at #838. Five remain — the seven #836 markers
came out when that fix landed, and the three #838 markers came out when those tightenings were
applied.

**P1 — [#836](https://github.com/rigortype/rigor/issues/836) — `sig-gen` proposes a value tightening
for a method declared `void`.** `RbsTypeTranslator` maps `void` to `Type::Top`, `Top.accepts` is
total, so `Generator#tighter?` is true for every `void` method whose body returns something typed.
Seven of the fifteen `tighter_return`s in Rigor's own `sig/` are this, and an adopting project
running `sig-gen --diff` over a hand-written `sig/` sees it on every mutator. Evidence: the seven rows
in the table above. Area: `area:sig-gen`.

**Fixed 2026-09-09.** `compare_against_declared` classifies a declared `void` `equivalent` without
comparing it and carries `void` itself as the declared spelling, so `--diff` shows no change and
neither `--write` nor `--overwrite` can replace one; the gate's classifier reads that as the earned
`return_intent`, and a `void` declaration needs no marker. The reasoning is now in ADR-14 § "The
inference-vs-RBS contradiction rule": `void` is return intent, never a synthesizable type.

**P2 — [#837](https://github.com/rigortype/rigor/issues/837) — `sig-gen` proposes a literal return
for a method whose siblings declare the wide type.** `computed_literal_tightening?` refuses a
`Constant` tightening when the body's last expression is not a direct literal; when it *is* one
(`def describe(_v = :short) = "top"`) the guard passes and `"top"` is proposed for a method every
sibling type class declares as `String`. Pinning it would break the polymorphic surface. Fix: refuse
the tightening when an ancestor or a sibling implementation of the same method carries a wider
declaration — the inverse of the [#744](https://github.com/rigortype/rigor/issues/744) guard, which
already reasons about overrides in the other direction. Evidence: the five rows above. Area:
`area:sig-gen`.

**P3 — [#838](https://github.com/rigortype/rigor/issues/838) — apply the three tightenings `sig-gen`
is right about.** `Reflection.class_ordering` →
`:disjoint | :equal | :subclass | :superclass | :unknown`, and both `Scope#*_through_ancestors` →
`[untyped, String] | [nil, nil]`. Each is a `sig/` edit that has to clear
`rigor coverage --threshold 0.58 lib` and `make steep-check`, so it is its own change. Area:
`area:sig-gen`.

**Applied 2026-09-09.** All three declarations now match `rigor sig-gen --diff --tighter-returns lib`
exactly, and their `# sig-gen gap: #838` markers are gone. `make check --fail-on=warning`, the
precision gate, `make lint`, and `make steep-check` all stayed clean; the residue pin in
`spec/rigor/sig_gen/provenance_spec.rb` did not move, since `tighter_return` sits outside it (#845).

**P4 — [#839](https://github.com/rigortype/rigor/issues/839) — nothing checks that a declaration in
`sig/` describes a method that exists.** Nine did not (above). `make check` and `make steep-check`
compare the implementation against `sig/`; the converse direction — a declaration whose `def` was
deleted or renamed — is unchecked, and a stale declaration is worse than a missing one because RBS
resolves calls through it. The provenance gate now reports these as `no_source`, mixed in with 218
legitimate ones; a dedicated check that distinguishes them would be sharper. Area:
`area:self-testing`.

## What this does not measure

- **`plugins/*/sig` and `examples/*/sig`.** The gate walks the repository's own `sig/` only.
  `make check-plugins` covers a different property there.
- **Whether a declaration is *correct*.** Provenance says where the type came from, not whether it is
  right; `make check` (G2) and `make steep-check` answer that.
- **Parameter types.** By construction. ADR-5 clause 2 makes them the author's, and `sig-gen
  --observe` is the evidence source when one is wanted; the gate never inspects a parameter type
  except to tell `generated` from `parameter_intent`.
