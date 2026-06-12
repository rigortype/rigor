# Rails monorepo survey (per-sub-gem Dynamic-fall + FP hunt)

2026-06-12. Read-only engine-behaviour survey across the twelve
`rails/rails` sub-gems (`/Users/megurine/repo/ruby/rigor-survey/rails`).
**No `lib/` (rigor) changes.** The target is a working release tree, so
every `error` diagnostic is a false-positive candidate. Sibling of
`20260612-cruby-stdlib-survey.md`; this note re-measures the same
engine against *framework* code (heavy metaprogramming + generics).

Per the mission framing the user **excuses metaprogramming and heavy
generics** (Rails is saturated with both). The deliverable separates
"expected metaprog Dynamic" from **plain general code that should type
but doesn't**. Only the latter feeds the ranked attack order.

## Methodology + an important performance finding

Per sub-gem: `rigor coverage --format=json lib` (precise ratio) +
`rigor check --no-cache` (diagnostics), cwd=`<rails>/<gem>`,
`BUNDLE_GEMFILE=<rigor>/Gemfile`, flake-wrapped.

**Whole-`lib` analysis is pathological on this corpus.** `rigor check
lib` (the default sequential path) ran *single-core* for **>20 min** on
activestorage's 47 files and never finished within budget — while each
file analysed **individually completes in ~1 s**. `--workers=8` did not
help (1093 s user ≈ 1107 s wall = no parallelism engaged). The cost is
superlinear in the *number of files analysed in one process* (cross-file
state accumulation), not any single pathological file. This is itself a
finding worth a perf ADR follow-up (whole-project cross-file state
growth; cf. the ADR-44/52 allocation work — that targeted per-dispatch
churn, not per-process file-count scaling).

**Consequence for this survey:** all `check` numbers below are from a
**per-file** sweep (`rigor check <file>` looped over `find lib`, 60 s
per-file timeout). Validation: actiontext whole-`lib` (the largest gem
that *did* finish) gives **2 err / 2 warn**, byte-for-byte the same
errors the per-file sweep reports — so per-file is faithful for
file-local mechanisms. The one place it over-reports is **cross-file
ivar definite-assignment** (an ivar written in file A, read in file B,
now reads `nil`): that inflates the `… for nil` / `possible-nil` buckets
in ivar-heavy gems. Flagged inline where it bites.

Coverage is read whole-`lib` where it finished (it shares the same
scaling wall — activestorage coverage was computed per-file: 0.497).

## Per-gem chosen config

`.rigor.yml` per sub-gem (uncommitted in the rails checkout — left in
place, **not** committed there). All carry `target_ruby: "4.0"`,
`paths: [lib]`, `cache.path: tmp/.rigor/cache`, and
`rigor-activesupport-core-ext` (every gem leans on AS core_ext).
Per-gem additions:

| Gem | Plugins (beyond core-ext) | Note |
| --- | --- | --- |
| activesupport | — | core-ext only (it *is* AS) |
| activemodel | — | |
| activejob | rigor-activejob | |
| actionmailer | rigor-actionmailer | |
| actioncable | rigor-actioncable | |
| activerecord | rigor-activerecord | |
| actionpack | rigor-actionpack | |
| actionview | rigor-actionpack | shares the AP plugin |
| actionmailbox | — | **dropped** rigor-activerecord: with no `db/schema.rb` it only emits a per-file `load-error` warning and adds overhead |
| actiontext | — | dropped rigor-activerecord/activestorage (no schema) |
| activestorage | — | dropped rigor-activerecord/activestorage (no schema) |
| railties | — | |

**Plugin caveat (rigor-activerecord, no schema):** on activerecord
itself the AR plugin emits one `load-error` *warning* per file
(`schema file db/schema.rb not found; AR call checks skipped`) → **402
warnings of pure noise** in the activerecord column below. It is a
configuration artifact (no schema in a library tree), not a Rigor
finding; subtract it from the warning count. The schema-less satellite
gems had it dropped for this reason.

## Per-gem coverage / error table

`prec` = `coverage` precise_ratio (precise tiers ÷ typed expressions).
`err` / `warn` = per-file-sweep error / warning diagnostic counts.

| gem | files | prec | err | warn | top FP class | verdict |
| --- | --- | --- | --- | --- | --- | --- |
| activesupport | 301 | 0.513 | 44 | 38 | regex-global possible-nil (C1) + Class-singleton metaprog | mostly metaprog + C1/C3; few general |
| activemodel | 76 | 0.453 | 3 | 1 | `for nil` (cross-method ivar) | clean; artifacts only |
| activejob | 54 | 0.471 | 4 | 0 | `singleton(Hash)#ruby2_keywords_hash` (builtin gap) | 2 genuine builtin gaps |
| actionmailer | 23 | 0.424 | 1 | 0 | possible-nil (`mail.decoded`) | clean |
| actioncable | 46 | 0.502 | 13 | 2 | nio4r element mis-typed `String` (external-lib) | metaprog/external; 1 arity |
| actionmailbox | 22 | 0.548 | 0 | 1 | — | clean (0 errors) |
| actiontext | 34 | 0.515 | 2 | 2 | possible-nil + `renderer for Class` (metaprog) | clean |
| activestorage | 47 | 0.497 | 1 | 0 | — (1 file timed out) | clean |
| actionpack | 156 | 0.455 | 36 | 18 | `superclass`/ancestry possible-nil + `delegate for Class` | metaprog ancestry + C1 |
| actionview | 120 | 0.455 | 32 | 6 | `Regexp.last_match[]` possible-nil (C1) + `Numeric#to_f` | C1 + genuine catalog gaps |
| activerecord | 402 | 0.421 | 224 | 439\* | relation-builder `define_method` metaprog (`Integer` recv) | ~90% metaprog; \*439 warn = AR-plugin no-schema noise |
| railties | 159 | 0.533 | 18 | 5 | `Shellwords#split` arg-mismatch + generator metaprog | mixed; 2 genuine arg-type |

Mean precise ratio across gems: **~0.48**. Coverage is dominated by the
`constant` + `nominal` tiers; `dynamic_top` is ~45–58 % everywhere,
i.e. roughly half of every Rails sub-gem types opaquely — consistent
with how metaprog-dense the framework is.

## Cross-gem diagnostic totals (per-file sweep, all 12 gems)

| Rule | Sev | Count | Dominant driver |
| --- | --- | --- | --- |
| `call.undefined-method` | error | **322** | see cluster table below |
| `flow.always-truthy-condition` | warning | 62 | constant-folded guards + loop-rebind locals |
| `call.possible-nil-receiver` | error | **43** | C1 regex-global / C3 nilable builtin return |
| `call.unresolved-toplevel` | warning | 20 | toplevel implicit-self (ADR-34) |
| `def.return-type-mismatch` | warning | 17 | ivar-state Dynamic-fall through accessors (C2) |
| `call.wrong-arity` | error | 10 | external-lib RBS arity gaps (Redis/Thread/nio4r) |
| `def.override-visibility-reduced` | warning | 9 | framework override visibility |
| `call.argument-type-mismatch` | error | 3 | `Shellwords#split`, `ENV#[]` arg sigs |
| `def.ivar-write-mismatch` | warning | 2 | genuine heterogeneous ivar writes |
| `flow.unreachable-clause` | info | 1 | (ADR-47, vacuous) |
| `load-error` | warning | 402 | **AR-plugin no-schema noise — discard** |

### `call.undefined-method` (322) decomposed by receiver

| Receiver cluster | Count | Class | Verdict |
| --- | --- | --- | --- |
| `singleton(ActiveRecord)` (`.deprecator`, `.reading_role`, `.application_record_class`, …) | 137 | metaprog (`mattr_accessor`/`class_attribute`) | **EXCUSED** |
| `Integer` — all in `activerecord/.../query_methods.rb` (`joins!`, `where!`, `_select!`, …) | 47 | metaprog (relation builder `define_method` over `MULTI_VALUE_METHODS`; receiver mis-typed `Integer`) | **EXCUSED** |
| `Class` (`redefine_method`, `delegate`, `class_attribute`, `mattr_accessor`) | 32 | metaprog (AS core_ext on `Class`) | **EXCUSED** (core-ext plugin partial) |
| `nil` (`first`/`pop`/`each`/`module_eval`/`method_defined?`) | 23 | cross-method/block ivar nil — **per-file-inflated** | mostly ARTIFACT (sweep mode) |
| `singleton(ERB::Util)` | 11 | module-singleton `def self.` chain | ARTIFACT — **module-singleton gap** (queued) |
| `Numeric` (`to_f`×4 + 10 others) | 14 | core-type catalog gap | **GENUINE — general-code** |
| `singleton(File)#atomic_write`, `singleton(Hash)#ruby2_keywords_hash[?]`, etc. | ~58 | mixed: monkey-patched core (`File.atomic_write` is AS-defined) + true builtin gaps | MIXED |

## Dynamic-fall mechanism bucket table (general-code only)

Metaprog clusters above are excused and dropped here. These are the
mechanisms behind *plain code that should type*, ranked by radius. They
**re-confirm the CRuby-stdlib survey's C1/C2/C3** across a second corpus.

| Bucket | Mechanism | Radius (Rails) | Same as stdlib? | Precision-additive | Class |
| --- | --- | --- | --- | --- | --- |
| **G1. Regex-global / `last_match` nil-union** | `str.gsub!(re){ $2.capitalize! }`, `match = Regexp.last_match; match[:k]`, `$1 ? … : …` → receiver typed `T?` → possible-nil on every downstream `[]`/`capitalize!`/`<<` | **high** (every parser: inflector, erb_tracker, route parsing, template handlers) | = stdlib **C1** | yes (removes FP) | engine — global-var flow typing + post-`=~`/`scan` narrowing |
| **G2. Nilable builtin return consumed without guard** | `StringScanner#skip → Integer?`, `String#unpack → Array?`, `Hash#[] → V?` read then `< … ` / `[2]=` / `<<` | high | = stdlib **C3** | partly (some genuinely miss) | engine/catalog — over-nilable builtin return sigs; narrow where the call provably hits |
| **G3. `Numeric#to_f` (+ `Float#round` over-widening)** | `(time_delta / 60.0).round` types `Numeric` (round overloads join `Integer|Float`→`Numeric`), then `Numeric#to_f` is **absent from the catalog** → undefined-method on a plain arithmetic chain | medium (any `Float#round`-then-coerce; date/number helpers) | new (stdlib leaned on Integer/Float directly) | yes | catalog — add `Numeric#to_f`/`to_i`/`to_r`; revisit `Float#round` zero-arg→`Integer` | 
| **G4. Cross-method/-file ivar state-join → nil-union / Dynamic** | ivar written in N methods/files, read in another → `Dynamic[top]`/`nil`; surfaces as `def.return-type-mismatch` through accessors and `… for nil` | high (but **per-file mode inflates the nil half** here) | = stdlib **C2** | mostly | engine — ivar declared-type inference / definite-assignment (queued) |
| **G5. Module-singleton `def self.x` chains** | `ERB::Util` self-calls, `SecureRandom`/`Date` singleton helpers resolve partially; cross-`def self` chains fall to undefined-method | low–medium (stdlib-confirmed-small; Rails leans on instance mixins) | = stdlib **C4** | yes | engine — known queued (ADR-57 module-singleton follow-up) |

External-library element/receiver mis-typing (nio4r `@nio.select` element →
`String`; Redis/Thread arity) is **not** a general-code engine bug — it
is the absence of RBS for those gems and degrades correctly to Dynamic
in principle; the few `String`/arity firings are where a bad fold leaked
instead of Dynamic, a narrow C2-adjacent artifact, not a ranked target.

## Ranked attack order — GENERAL-code mechanisms only

1. **G1 — regex-global / `Regexp.last_match` post-match narrowing.**
   Highest cross-corpus radius (drives the bulk of the 43 possible-nil
   here *and* ~180 in the stdlib survey). FP-pure win (the code works
   because the pattern matched). Same engine work both surveys point at:
   type `$1..$9`/`$~`/`Regexp.last_match` and narrow them non-nil on the
   match-success edge. **Do this first; it pays two corpora.**
2. **G2 — over-nilable builtin returns (`StringScanner#skip`,
   `String#unpack`, `Hash#[]`-in-provably-present position).** Catalog
   precision; medium effort, removes a steady stream of possible-nil.
3. **G3 — `Numeric#to_f`/`to_i`/`to_r` catalog entries + `Float#round`
   zero-arg → `Integer`.** Smallest, cheapest, fully self-contained
   catalog fix; turns a genuine undefined-method on plain arithmetic
   into precise typing. Good warm-up slice.
4. **G4 — cross-method/-file ivar definite-assignment.** Largest latent
   radius but the queued, hard one (ADR-46 incremental dep-graph is the
   substrate). Note this survey's per-file mode *over-states* its nil
   half — re-measure whole-`lib` once the file-count scaling wall (the
   perf finding above) is addressed, else the signal is contaminated.
5. **G5 — module-singleton `def self.x` resolution.** Confirmed *small*
   radius on both corpora (Rails and stdlib lean on instance methods /
   mixins). Already queued as the ADR-57 follow-up; low priority by
   measured yield.

### Cross-cutting prerequisite

The **whole-`lib` file-count scaling wall** (per-process cost
superlinear in files analysed; ~1 s/file alone vs >20 min for 47
together, `--workers` inert) blocks honest whole-project re-measurement
and is the single biggest obstacle to running Rigor on a real Rails app.
It deserves its own perf investigation ahead of G4 (which needs
whole-`lib` runs to measure correctly).
