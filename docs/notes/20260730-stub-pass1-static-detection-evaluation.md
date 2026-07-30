# `stub_missing_referenced_types` pass 1 — does static detection agree with the builder?

Status: measurement note, 2026-07-30. Rigor `master` @ `0535bf1e`, rbs 4.1.0, Ruby 4.0.5, macOS
(Darwin 25.5, 12 cores). Feeds [#207](https://github.com/rigortype/rigor/issues/207). No design
commitments beyond what the numbers support.

## Why

`RbsLoader.stub_missing_referenced_types` finds the types a project's RBS references but no loaded
signature declares (ADR-5 tier 2), and its detector — `unresolved_referenced_types` — builds **every**
project class instance- and singleton-side with a throwaway `RBS::DefinitionBuilder` and reads the
missing name out of the raised `NoTypeFoundError`. Correct by construction, and on our own tree
**7.84M allocations, 33% of a cold `check lib`**, to find nothing.

[#207](https://github.com/rigortype/rigor/issues/207) recorded direction 1 (share the builder)
as measured and declined, leaving direction 2 — detect dangling references *statically*, without
building definitions — as the only lever with headroom, gated on one question:

> a **false** detection stubs a name that would have resolved, and an empty stub shadowing a real type
> is worse than the fail-soft miss ADR-5 tier 2 exists to prevent.

So this is an evaluation, not an implementation: **does static detection agree with builder-based
detection on real projects?**

## Method

A probe (`PROBE_ARM`) prepends onto `RbsLoader`'s singleton and wraps `unresolved_referenced_types`.
The builder arm replicates no `lib/` logic — it calls the real method through `super`. Arms:

| arm | detector run | detector applied |
| --- | --- | --- |
| `baseline` | builder | builder (production behaviour) |
| `agree` | both | builder (behaviour unchanged; measures set agreement) |
| `static` | static | static |
| `none` | neither | nothing (the control) |

The static detector mirrors the raise sites, read out of `references/rbs`:

- `DefinitionBuilder#validate_type_presence` over super-class args, module self-type args, and
  extended-module args (`definition_builder.rb:219`, `:237`, `:283`);
- `VarianceCalculator#type` over every method type `validate_type_params` walks — which raises for
  `ClassInstance` / `Interface` / `Alias` only (`variance_calculator.rb:158`), and **skips
  `initialize`** (`definition_builder.rb:529`).

Membership uses the builder's own primitive, `env.type_name?(env.normalize_type_name(name.absolute!))`,
so a flagged name is one no declaration in the env provides. Every name is tagged with the syntactic
bucket it came from, so the report can slice a **parity** scope (what the builder validates) out of the
wider sweep (which also sees `initialize`, singleton-method and `@ivar` types).

Corpus: eight real projects that ship RBS through `signature_paths:` (`rigor` itself, textbringer,
herb, haml, kramdown, rgl, binpacker, conference-app), plus three purpose-built fixtures. `rigor check
--no-cache --format json` throughout, so the env build always runs (ADR-45's run-result cache would
otherwise serve an unanalyzed result).

**The harness can say "yes" before any silence is believed.** Fixture 1 is a 17-shape matrix, one
dangling-reference shape per class. Fixture 3 carries a `Rigor.dump_type` channel; the `none` control
reports `dump_type: "widget"` (literal, inferred from the body — the class did not build) where
`baseline` and `static` both report `dump_type: String` and a `def.return-type-mismatch` the untyped
arm never produces. Neither the agreement result nor the equal-diagnostics result is vacuous.

## Result 1 — the shape matrix: static is a strict superset, and the extra names are attributable

| shape | builder | static | bucket |
| --- | --- | --- | --- |
| method return / param / block-param type, `attr_reader` type, generic arg, nested (`M::Deep`), interface (`_M`), type-alias (`m`) name, super-class args, mixin args | found | found | parity |
| type only in `def initialize:` | **missed** | found | `initialize` |
| type only in `def self.x:` | **missed** | found | `singleton_method` |
| type only in `@ivar:` | **missed** | found | `ivar` |
| missing super-class *name* (`class C < Gone`) | missed | missed | — (`NoSuperclassFoundError`) |
| missing mixin *name* (`include Gone`) | missed | missed | — (`NoMixinFoundError`) |
| type only inside a `type` alias body, or in a `CONST:` decl | missed | missed | — (not built by pass 1) |

Zero builder-only names. The three static-only buckets are exactly the positions the builder does not
validate, and excluding them gives **byte-exact parity** with the builder.

## Result 2 — corpus agreement (pass 1)

`entries` = project `class_decls` swept. `parity` = static restricted to the parity buckets.

| target | entries | builder | static | parity | builder-only | builder ms / alloc | static ms / alloc |
| --- | --- | --- | --- | --- | --- | --- | --- |
| rigor (`lib`) | 1,924 | 0 | 2 | **0** | none | 1,504 / 7,841,764 | 31 / 10,393 |
| conference-app | 4,234 | 1 | 1 | **1** | none | 4,261 / 12,785,744 | 67 / 32,887 |
| herb | 1,498 | 74 | 75 | **75** | none | 115 / 321,871 | 9 / 7,229 |
| binpacker | 1,384 | 0 | 2 | **0** | none | 54 / 79,077 | 3 / 5,433 |
| textbringer | 1,408 | 0 | 0 | 0 | none | 88 / 156,452 | 6 / 5,996 |
| haml | 1,402 | 0 | 0 | 0 | none | 330 / 118,417 | 10 / 5,428 |
| kramdown | 1,385 | 0 | 0 | 0 | none | 197 / 117,208 | 7 / 5,518 |
| rgl | 1,392 | 0 | 0 | 0 | none | 79 / 92,398 | 5 / 5,447 |

- **No detection is lost anywhere**: the builder-only column is empty on every target and every fixture.
- Parity scoping reproduces the builder exactly on 7 of 8; on **herb** it finds one name the builder
  misses (`serialized_erb_content_node`) — the builder surfaces only the *first* missing reference per
  class per build, so a class with two dangling references hides one per pass.
- The two extra names on rigor and binpacker (`Binpacker::LptScheduler`, `Binpacker::MultifitScheduler`)
  come only from `initialize`/singleton/`@ivar` buckets, and the parity scope excludes them.

## Result 3 — behaviour is unchanged, and the wider scope costs without buying

Diagnostics compared as a digest of the sorted diagnostic array, `baseline` vs `static` vs
`static`-parity, all ten targets: **identical on every one** (rigor `5169afb3e8`, textbringer
`db353bbf2e`, herb `d9495d6ed4`, haml `622c1946f4`, kramdown `67be5e50b7`, rgl `eb42851277`,
binpacker `f916308d10`, conference-app `6609736389`).

Whole-run allocations tell the arms apart, and argue for the parity scope:

| target | baseline | static (all buckets) | static (parity) |
| --- | --- | --- | --- |
| conference-app | 30,399,182 | 4,978,447 (−83.6%) | 4,978,465 (−83.6%) |
| rigor (`lib`) | 23,809,468 | 16,431,573 (−31.0%) | 15,988,804 (−32.8%) |
| herb | 7,011,335 | 5,534,843 (−21.1%) | 5,534,864 (−21.1%) |
| binpacker | 1,903,964 | 2,119,128 (**+11.3%**) | 1,838,304 (−3.4%) |

binpacker is the case that decides the scope: stubbing the two extra `initialize`/`@ivar`-only names
adds declarations, costs 11% more allocations than doing nothing, and changes no diagnostic. **Restrict
a static detector to the parity buckets.**

Three paired runs of `rigor check --no-cache lib` on our own tree:

| arm | allocations | pass-1 alloc | pass-1 ms | wall |
| --- | --- | --- | --- | --- |
| baseline | 23,808,440 / 23,808,238 / 23,808,164 | 7,841,785 | 809 / 859 / 810 | 9.93 / 9.05 / 9.16s |
| static (parity) | 15,988,706 / 15,988,684 / 15,988,674 | 21,257 | 54 / 13 / 15 | 8.72 / 8.07 / 8.48s |

**−7,819,593 allocations (−32.8%)**, pass 1 itself −99.7%, wall −0.7 to −1.2s, diagnostics digest
identical in all six runs. Within-arm spread is ~300 objects.

### Why a false detection is structurally hard here

The FP hazard #207 names is a name that *would have resolved* being stubbed. A static detector that
decides membership with `env.type_name?(env.normalize_type_name(name))` cannot produce one: the
predicate is the builder's own, evaluated against the same env, so a resolvable name is never flagged.
The residual risk is not "unknown name mistaken for known" but the reverse — mis-*walking* the AST, e.g.
treating a type **variable** as a class name. `RBS::Types::Variable` is a distinct node class from
`ClassInstance`, and the parity walk collects only the three node classes the variance calculator itself
raises on. What remains is the scope question Result 3 answers empirically.

## Result 4 — two live defects the evaluation surfaced

Both are independent of #207's perf question and reproduce on a real project.

**(a) One unparseable stub name discards the whole batch.** `append_stub_declarations` emits
`class <name>` for every missing name, in **one** buffer. A dangling *interface* (`_Foo`) or *type-alias*
(`foo`) reference therefore emits `class _Foo` / `class foo`, which `RBS::Parser` rejects, and
`rescue ::RBS::BaseError; nil` drops **every** stub in the batch — including the well-formed ones. The
project gets no stub at all, and every affected class stays fail-soft `Dynamic`: precisely the
regression ADR-5 tier 2 exists to prevent.

Real instance: on **herb**, all 74 missing names are dangling type aliases (`serialized_*_node`), so
today `stub_missing_referenced_types` is a **complete no-op** there. Proof: the `none` control (stub
nothing) and `baseline` (production, 74 names "applied") produce byte-identical diagnostics
(`d9495d6ed4`), while baseline burns +3.11M allocations — **44% of herb's cold run** — to achieve it.

**(b) The fixpoint does not converge when (a) fires, so `MAX_STUB_PASSES` always runs 5 times.** With
no declaration added, pass N+1 re-detects the identical set. Fixture 1 (which includes an interface and
an alias shape) reports the same 10 names five times; drop those two shapes and it converges in 2
passes. herb: 5 passes. The waste scales with the detector — on a rigor-sized project, 5 × 7.84M.

A candidate fix — emit the declaration kind each name requires (`interface _Foo`, `type foo = untyped`,
`module` for a namespace prefix, `class` otherwise) and validate each declaration on its own before
emitting, so one bad name cannot poison the batch — measured on herb:

| arm | passes | allocations | precise coverage | diagnostics |
| --- | --- | --- | --- | --- |
| baseline (today) | 5 | 7,011,335 | 59.3% | `d9495d6ed4` |
| baseline + fixed kinds | **2** | 4,900,554 (−30.1%) | **60.0%** (+0.7pp, +134 nodes) | `d9495d6ed4` |
| static parity + fixed kinds | **2** | 4,253,905 (−39.3%) | — | `d9495d6ed4` |

FP-free (diagnostics unchanged), −30% allocations, and the project's own `sig/` starts contributing.

## Correction from the implementation (2026-07-30, same day)

The evaluation's parity scope included a walk over the project's own `interface_decls`. Implementing it
([#240](https://github.com/rigortype/rigor/pull/240)) showed the builder does **not** report a dangling
reference inside a project interface, even when a project class includes that interface —
`validate_type_params` does not variance-walk the methods a class imports from one. The walk therefore
excludes project interfaces, and the exclusion is pinned by spec. It costs no coverage on this corpus:
re-reading the bucket tags, all 75 of herb's names came from `member_method`, and no name anywhere came
only from `interface_method`. herb's one extra name over the builder is the first-error-per-class masking
described above, not the interface walk.

## Verdict

- **Static detection agrees with builder-based detection.** Parity-scoped, it reproduces the builder's
  set on every corpus target, loses no detection anywhere, and finds one name the builder's
  first-error-per-class masking hides. Diagnostics are identical on all ten targets, against a control
  that proves the channel is sensitive.
- **The scope must be the parity buckets.** The wider sweep (`initialize` / singleton / `@ivar`) changes
  no diagnostic and costs allocations (binpacker +11.3%).
- **Cost**: pass 1 drops from 7.84M to 21k allocations on our own `lib` — −32.8% of the whole cold run,
  and −83.6% on a Rails-shaped project.
- **Result 4 lands first.** It is smaller, it fixes a precision regression on a real project, and it
  shrinks what the detector is even asked to do.

## Reproducing

Probe, driver, fixtures and per-arm JSON reports are session-scratch, not committed. The shape is:
prepend a module onto `Rigor::Environment::RbsLoader.singleton_class` overriding
`unresolved_referenced_types`, run the CLI with `cwd` on the target and `BUNDLE_GEMFILE` borrowing this
repo's bundle (see the survey-project invocation in
[`20260529-rigor-survey-project-init-baseline.md`](20260529-rigor-survey-project-init-baseline.md)), and
diff the sorted `--format json` diagnostics per arm. Targets without a `signature_paths:` entry need a
config whose `paths:` / `signature_paths:` are **absolute** — a `--config` outside the project resolves
relative paths against the config's own directory, not the cwd.
