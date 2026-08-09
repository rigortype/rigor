# `check_rules.rb` fused-protection re-measure — the first census with a live type axis

Status: measurement note, no design commitments. Observations taken against `origin/master` @
`31b5f656`, macOS arm64, Ruby 4.0.5, 2026-08-09.

## Why

Every fused number recorded on [#135](https://github.com/rigortype/rigor/issues/135) for
`lib/rigor/analysis/check_rules.rb` is **test-axis-only**. The file's own doc comment quoted
`` `# rigor:disable-file all` `` in backticks, and the suppression patterns matched anywhere inside a
comment, so the documentation file-suppressed the 3,000-line file that defines the rules
([#306](https://github.com/rigortype/rigor/issues/306)). `DiagnosticOracle` therefore killed **0 of
914** mutants there — a structurally impossible result for a live type net, and the recon's largest
finding. PR #314 anchored every marker to the start of the comment and the file became checkable.

Since the recon, seven PRs added **136 examples** across six new per-topic spec files
(#309/#310/#311/#314/#325/#326), and two engine changes landed that touch this file's rules:
[#327](https://github.com/rigortype/rigor/pull/327) (the `OptimisticOrigin` polarity gate, which also
took a `flow.always-truthy-condition` directive back out of `check_rules.rb`) and #313's diagnosis.

So the recon's `169 → 95 test-killed → 74 raw → 70 de-noised, 56.2 % fused` is not a baseline. This
note re-derives the census with both axes live and decides whether a wave 3 is warranted.

## Harness invocation and site mode

The measured configuration is `tool/mutation/self_mutate.rb`'s **fused** pass (ADR-70 static ∪
dynamic) at `--site biteable`, a **complete census** — no `--limit`, so no sampling:

```
bundle exec ruby tool/mutation/self_mutate.rb --site biteable --json \
  lib/rigor/analysis/check_rules.rb
```

`:biteable` keeps only concrete-type dispatch sites (the FP-safe default); it is the same scope
reduction PR #287 named, and at the recon it was also the only axis that *could* bite. `--site all`
stays infeasible — see § Scope caveat.

**`SpecMap` resolves all thirteen per-topic specs.** PR #307 taught the harness the
`lib/rigor/a/b.rb -> spec/rigor/a/b/*_spec.rb` directory convention; the `[fused]` log line names
`argument_type`, `collector_diagnostic_builders`, `nil_argument_mismatch`,
`non_nil_argument_mismatch`, `override_and_return_type`, `raise_non_exception`,
`refined_receiver_dispatch`, `remaining_rule_families`, `rule_walk_equivalence`,
`safe_navigation_undefined_method`, `suppression`, `union_undefined_method`, `wrong_arity`. (The
issue comments say "seven" — that was the count *at recon time*; waves 1 and 2 added six more.)

### How it was actually driven

The harness cannot be interrupted and resumed, and this session's per-command ceiling is 10 minutes,
so the census ran through a chunked scratch driver over index slices — the approach PR #287
precedented. The fidelity contract with `self_mutate.rb` is *identical*, not "equivalent":

- **site ordering** — `MutationScanner#kept_mutations` (private, via `send`) with
  `site_selector: :biteable`, `limit: nil`, `seed: 1`, `base_scope: nil`, `discovery_seed: nil`,
  exactly `Driver#scanner`;
- **type verdict** — `MutationScanner#classify` (private, via `send`) against the same
  `DiagnosticOracle` baseline;
- **test runner** — plain `system` with `out`/`err` to `/dev/null`, i.e. `BundledRunner`: the rspec
  subprocess inherits Rigor's OWN Bundler env, because the SUT bundle is Rigor's;
- **spec command** — `bundle exec rspec` + `SpecMap.for(path)`, reimplemented verbatim.

The driver's only additions are pacing and resumption (a wall-clock budget checked *before* starting
an rspec run, and skipping indices already recorded), neither of which can change a verdict.

**The harness's own fused mode was smoke-tested separately and agrees exactly.** `--site biteable
--limit 30 --seed 1` through unmodified `self_mutate.rb` reports `type_killed: 24, test_killed: 6,
unprotected: 0`; the driver's records for those same thirty sites carry the same thirty verdicts. A
`--site all --limit 6 --seed 3` fused run through the harness likewise reports `1 / 5 / 0`.

The site index was also checked for stability before reusing a prior partial run: the 169 sites
enumerated now are byte-identical in `(index, line, operator, method, receiver, rule)` to those a
killed earlier attempt enumerated, so its first chunk composed into this census rather than being
re-measured.

## The funnel, both runs side by side

| | recon (pre-#306 fix) | this re-measure (`31b5f656`) |
| --- | ---: | ---: |
| sites measured (`:biteable`) | 169 | 169 |
| **type-killed** | **0** | **131** |
| type-survivors reaching the test axis | 169 | 38 |
| **test-killed** | **95** | **38** |
| **raw survivors** | **74** | **0** |
| declared declines removed in de-noising | 4 | 0 |
| **de-noised survivors** | **70** | **0** |
| **fused protection** | **56.2 %** | **100.0 %** |

The type axis went from killing nothing to killing **131 of 169** sites, and every one of the 38
mutants it does not bite is caught by the suite. **No mutant at this site mode survives both axes.**

### The 2×2, and which cells are sound

`scan_file_fused` short-circuits: the expensive suite run is paid only for type-survivors. So a
site's test verdict is simply *not observed* when the type axis kills it, and a full contingency
table would cost 169 suite runs (≈ 3 h) rather than 38. Two cells are nonetheless sound, because the
recon observed the test axis on **all** 169 sites (its type axis killed nothing) and the suite has
only *grown* since — a recon test-kill cannot have become a test-survivor.

| | test-killed | test-survived | total |
| --- | ---: | ---: | ---: |
| **type-killed** | **75** (both) | 56 (type retired them) | 131 |
| **type-survived** | **38** | **0** | 38 |
| total | 113 | 56 | 169 |

- **75 killed by both axes** — recon test-kills that the now-live type axis also bites.
- **56 killed by the type axis** — recon *raw survivors*, i.e. sites nothing caught before. Whether
  the 136 new examples would also kill these is unobserved, by the short-circuit; "56" is
  "the type axis kills them", not "only the type axis kills them".
- **38 killed by the test axis alone** — of which 20 were already test-killed at the recon
  (re-confirmed) and **18 are recon raw survivors closed by waves 1 and 2**.
- **0 survive both.**

Consistency: 75 + 56 = 131 type-killed; 20 + 18 = 38 test-killed; 131 + 38 = 169.

## Per-family attribution of the recon's 74 raw survivors

Joined on `(enclosing method, operator, method, receiver)` rather than line, because the file shifted
between the two runs. 74 of 74 matched, and the complement is exactly 95 — reproducing the recon's
own reported test-kill count, which validates the join. Six survivors needed a receiver-blind
fallback: #306 rewrote the suppression **regex literals themselves** (markers anchored with `\A`), so
the receiver text of those sites legitimately changed.

| recon family | recon survivors | retired by the type axis | retired by the new examples | still open |
| --- | ---: | ---: | ---: | ---: |
| return_type + override | 16 | 16 | 0 | **0** |
| suppression system | 12 | 3 | 9 | **0** |
| collector diagnostics (builders B) | 8 | 8 | 0 | **0** |
| argument_type | 8 | 7 | 1 | **0** |
| pipeline / orchestration | 5 | 5 | 0 | **0** |
| wrong_arity | 5 | 5 | 0 | **0** |
| nil_receiver / safe navigation | 5 | 1 | 4 | **0** |
| unreachable_branch builders | 5 | 5 | 0 | **0** |
| undefined_method | 4 | 2 | 2 | **0** |
| always_raises + raise_non_exception | 3 | 1 | 2 | **0** |
| dump_type / assert_type | 2 | 2 | 0 | **0** |
| visibility_mismatch | 1 | 1 | 0 | **0** |
| **total** | **74** | **56** | **18** | **0** |

Every remaining survivor is attributed, and the "still open" column is empty in every family — so
there is no survivor to classify as new-vs-persistent. Two families are worth a sentence anyway:

- **`suppression system` is the one family the new examples carried** (9 of 12), which is expected:
  it is the family #306 lived in, and PR #314 authored `suppression_spec.rb`'s 34 examples alongside
  the fix. Its three type-axis retirements are precisely the sites whose regex literals #306 rewrote.
- **`return_type + override`, the densest family at recon (16), is now entirely type-killed.** Its
  survivors were `Diagnostic.from_name_loc` / `translate` / `instance_definition` call chains — the
  shapes that only become type-visible once the file is no longer file-suppressed.

## Declared declines

**None.** The recon de-noised 74 → 70 by declaring four sites out of scope: L194×2 and L215×2, in
`run_node_collectors` / `shadow_verify_node_collectors`, reachable only under
`RIGOR_SHADOW_RULE_WALK=1`, where any divergence *raises* — a harness invariant rather than
example-shaped behaviour (the PR #289 Ractor-gating precedent). All five `pipeline / orchestration`
survivors, the four declines among them, are now **type-killed**: `ENV["RIGOR_SHADOW_RULE_WALK"]` is
an ordinary `RBS::Unnamed::ENVClass#[]` dispatch site, and once the file is checked the type net bites
it regardless of whether the branch it guards ever runs.

The decline was therefore correct as *test-axis* reasoning and is simply obsolete: no site needed
removing from this census's denominator, and 0 raw survivors de-noise to 0.

Note what has *not* changed — the region is still test-unobservable. See the negative control below,
which poisons that exact method and watches the suite stay green.

## Why 100 % is a measurement and not an artifact

A run that errors out yields false *survivors*; a run whose suite command is broken yields false
*kills*, and every mutant looks caught. A 100 % result is the shape that failure mode takes, so it
was checked directly rather than assumed.

- **Green baseline**: `TestSuiteOracle#green?` passes on clean code (405 examples, 0 failures), so
  `runner.call → true` is reachable and `killed? = !runner.call` can return false.
- **Negative controls**, through the same oracle, runner and spec command:

  | control | verdict |
  | --- | --- |
  | identity mutant (`mutant_source == original`) | **SURVIVED** |
  | poison inside `shadow_verify_node_collectors` (`RIGOR_SHADOW_RULE_WALK`-gated) | **SURVIVED** |

  The second is the decisive one: it breaks a real method with a real name error, and the default
  suite cannot see it, exactly as the recon's decline predicted. The oracle is fully capable of
  reporting a survivor on this file; it reported none because there are none at this site mode.
- **Disk was never a factor** — see § Honesty. The earlier attempt at this census died on
  `Errno::ENOSPC`, which is precisely how false survivors get manufactured, so free space was checked
  before every chunk and never fell below 278 GiB.
- The working tree was verified clean (`git status --porcelain` empty) after the census and after the
  controls, so no mutant was left on disk and no verdict was taken against a dirty file.

## Decision: no wave 3

**Criterion** — the same exhaustion criterion waves 1 and 2 used: *a wave is warranted iff the census
at the measured site mode leaves de-noised raw survivors, i.e. sites that can be broken without
either the type net or a spec noticing.* This census leaves **zero**. There is no authorship unit to
scope, disjoint or otherwise, so the "smallest set of parallelisable units" is the empty set.

`check_rules.rb` is **done at `--site biteable`**. Checkbox 1's next tier members are the giant files
the issue body lists that PRs #282/#287/#289 did not sweep.

Two second-order results worth carrying forward:

- **The live type axis made the census cheaper, not just better.** The gradual short-circuit pays the
  suite only for type-survivors, so 131 of 169 sites never reached rspec: the predicted ~63 min of
  test-axis wall time came in around 35 min. A file that is genuinely type-checked is a file that is
  cheap to mutation-test.
- **The wave-1/wave-2 spec investment is not made redundant by the type axis.** 38 sites are caught
  by the suite alone, 18 of them closed by waves 1 and 2, and each is a site no type could reach.

## Scope caveat: 745 of 914 sites remain unmeasured

`--site all` also mutates `Dynamic`-receiver dispatch sites. On this file it is **914 sites**
(re-derived here, matching the recon's `sites_all_mode`), and since the type axis cannot bite a
`Dynamic` receiver, nearly every additional site would pay a full suite run — ≈ 6.1 h of rspec. It
stays infeasible, so **745 sites are unmeasured** and this note's 100 % is a statement about
`:biteable` only.

The per-family inventory, so the gap stays visible rather than implicit. Families are the recon's
taxonomy, assigned by enclosing method; methods that never produced a recon survivor have no family
label and are pooled in the last row.

| recon family | `:all` sites | `:biteable` (measured) | unmeasured |
| --- | ---: | ---: | ---: |
| return_type + override | 88 | 20 | 68 |
| suppression system | 64 | 17 | 47 |
| nil_receiver / safe navigation | 20 | 8 | 12 |
| collector diagnostics (builders B) | 20 | 8 | 12 |
| undefined_method | 18 | 6 | 12 |
| argument_type | 14 | 9 | 5 |
| dump_type / assert_type | 12 | 2 | 10 |
| pipeline / orchestration | 8 | 5 | 3 |
| wrong_arity | 7 | 5 | 2 |
| visibility_mismatch | 6 | 1 | 5 |
| always_raises + raise_non_exception | 5 | 4 | 1 |
| unreachable_branch builders | 5 | 5 | 0 |
| (methods with no recon survivor — unlabelled) | 647 | 79 | 568 |
| **total** | **914** | **169** | **745** |

## Finding: the spec suite leaks temp directories, and the mutation harness multiplies it

This is recorded because it is what killed the previous attempt at this census, and because the
harness is the thing that makes it accumulate.

Rigor's specs create `Dir.mktmpdir` directories without removing them. Measured on this machine, in a
freshly-entered Flake shell with an empty `$TMPDIR`:

| run | examples | wall | entries left in `$TMPDIR` | size |
| --- | ---: | ---: | ---: | ---: |
| `rspec spec/rigor/analysis/check_rules/` (the covering suite) | 405 | 1m40s | 3 | 21.8 MB |
| `make test` (full suite) | 9,093 | 9m06s | 25 | 86 MB |

The prefixes are `rigor-scanner-spec-*` (18 of the 25), `rigor-spec-{cache,workspace,sig}-*`,
`rigor-plugin-spec-cache-*`, `rigor-mutant-*`, `rigor-brute-force*`, and Ruby's own default
`d<YYYYMMDD>-<pid>-<rand>`.

**The mutation harness turns a small leak into a large one**, because a fused census is a suite run
*per type-survivor*: this census ran ~45 invocations of the covering suite, so it alone leaked on the
order of **1 GB**. At the recon's protection level it would have been far worse — 74 raw survivors
plus 95 test-kills meant 169 suite runs, ~3.7 GB for one census.

On this machine at the time of writing: **249 `/tmp/nix-shell.*` directories, ~24 GB**, of which 79
predate today and hold 7.0 GB. That is ~100 MB per Flake session, consistent with the per-run figure
above.

**Nothing was deleted.** Free space was never a constraint during this session (278–301 GiB
throughout), and the brief's own safety rule — remove only directories whose entries are all
`rigor-`-prefixed — rules the stale ones out anyway: they contain Ruby-default `d20260805-*` entries
alongside the `rigor-` ones. The durable fix is in the specs, not in periodic sweeping: block-form
`Dir.mktmpdir { ... }`, or an `after` hook that removes what an example created.

## Honesty / environment

Machine: 12-core macOS arm64, Ruby 4.0.5, everything through the Nix Flake. Free space on
`/System/Volumes/Data` was checked before every chunk: 142 GiB at the start, 278–301 GiB thereafter,
never near the 2 GiB floor that would have invalidated a chunk.

The census ran as five sequential chunks plus a reused first chunk from an earlier attempt that the
site-index check proved compositional. Wall-clock figures in this note are indicative rather than
clean-room: the machine carried ordinary desktop load throughout, and the census is I/O- and
subprocess-bound rather than a benchmark.

**This measurement predates [PR #328](https://github.com/rigortype/rigor/pull/328)**, which was still
open at `31b5f656`. It shares one declaration-sourced ADR-58 predicate across the
`possible-nil-receiver` and `argument-type` consumers, so it changes engine behaviour in the
`argument_type` family — the one family where a recon survivor was closed by an example
(`argument_type_spec.rb`'s "still fires on a LOCAL COPY" case, which deliberately pins current
behaviour and says to flip it when #324 lands). The census would need re-running only if #328 changed
the *site* set; it does not change `check_rules.rb`, so the 169 sites stand, and a type-axis verdict
can only move in the direction of more kills.
