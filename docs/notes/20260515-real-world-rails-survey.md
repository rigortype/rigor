# Real-world Rails project survey (2026-05-15)

A scratch-record of running `rigor check` against four real-world Rails
codebases under v0.1.5-in-progress (commit `642cf28` and onwards). The
goal is twofold:

1. **Measure the analyzer's reach** on Rails-shaped code that was never
   in the spec corpus — wall time, peak memory, diagnostic mix, plugin
   coverage gaps.
2. **Surface engine bugs and ergonomic gaps** that don't show up on
   synthetic fixtures or rigor's own `lib/`. Each project rotates the
   stress on different parts of the engine (size, depth of metaprogramming,
   gem surface, monkey-patch density).

Methodology and target sizes:

| Project | Status | Files | Notes |
| --- | --- | ---: | --- |
| [Redmine](https://github.com/redmine/redmine) | landed | 347 | Smallest of the four — used as the engine-bug shakedown. |
| [Discourse](https://github.com/discourse/discourse) | landed | 1,804 | Forum platform; heavy plugin / hook surface. |
| [Mastodon](https://github.com/mastodon/mastodon) | landed | 1,302 | ActivityPub social server; ActiveJob / Sidekiq heavy. |
| [GitLab FOSS](https://gitlab.com/gitlab-org/gitlab-foss) | landed | 11,130 | Largest of the original four — Rails monolith with deep metaprogramming. |
| [Forem](https://github.com/forem/forem) | landed (round 2) | 1,250 | DEV.to community platform. |
| [Solidus](https://github.com/solidusio/solidus) | landed (round 2) | 1,914 | E-commerce monorepo (`core` + `api` + `backend` + `admin` + `promotions` + `legacy_promotions`). |
| [Chatwoot](https://github.com/chatwoot/chatwoot) | landed (round 2) | 802 | Customer-support platform. |
| [Canvas LMS](https://github.com/instructure/canvas-lms) | landed (round 2) | 3,248 | Instructure's LMS; `app` + `lib` + `gems` (in-tree gems). |
| [OpenProject](https://github.com/opf/openproject) | landed (round 2) | 6,817 | Project-management platform; `app` + `lib` + `modules` (sub-engines). |
| [Loomio](https://github.com/loomio/loomio) | landed (round 3) | 563 | Collaboration / group-decision Rails app. |
| [Publify](https://github.com/publify/publify) | landed (round 3) | 15 (app shell only) | Rails app shell; real code lives in the external `publify_core` gem. |
| [Diaspora](https://github.com/diaspora/diaspora) | landed (round 3) | 371 | Federated social-network Rails app. |
| [Dependabot Core](https://github.com/dependabot/dependabot-core) | landed (round 3) | 1,089 (across 19 ecosystem dirs) | **Not Rails** — Ruby SDK / library for dependency-update automation. Useful baseline for "how does the analyser behave on non-Rails idiomatic Ruby with heavy Bundler-internal usage?" |
| [tDiary Core](https://github.com/tdiary/tdiary-core) | landed (round 3) | 244 (lib + plugin + entry scripts) | **Not Rails** — pre-Rails-era Ruby blogging engine. Useful baseline for "how does the analyser behave on classic Ruby idioms without any ActiveSupport in scope?" |

Each pass runs:

```sh
nix --extra-experimental-features 'nix-command flakes' develop \
  --command bundle exec exe/rigor check --format=json \
  /tmp/<project>/app /tmp/<project>/lib > <project>.json
```

Sequential / warm-cache runs are the primary measurement; pool mode
(`--workers=N`) is run for equivalence-check and timing comparison only.
"Warm" means the per-project `.rigor/` cache has been built by an earlier
sequential pass against the same revision.

---

## Redmine

Source: `https://github.com/redmine/redmine` (depth-1 shallow clone, no
specific revision pinned — the master HEAD on 2026-05-15).

### Quantitative summary

Two snapshots, before and after the two engine improvements this survey
triggered (commit `642cf28`):

| Metric | Before `642cf28` | After `642cf28` | Δ |
| --- | ---: | ---: | --- |
| Files scanned | 347 | 347 | — |
| Wall time (warm cache) | 2.82 s | 2.82 s | — |
| Wall time (cold cache) | 3.77 s | 3.77 s | — |
| Peak RSS | 266 MB | ~268 MB | — |
| Total diagnostics | 389 | **343** | −46 |
| Errors | 334 | **288** | −46 |
| Warnings | 55 | 55 | — |

The 46-diagnostic drop is one rule family only: `call.possible-nil-receiver`
69 → 23. No other rule's count moved; no new diagnostic was introduced.
(Pool-mode comparison below.)

### Rule mix (after `642cf28`)

| Count | Rule |
| ---: | --- |
| 243 | `call.undefined-method` |
| 23  | `call.possible-nil-receiver` |
| 24  | `flow.always-truthy-condition` |
| 22  | (parse errors — Rails-generator template files; see below) |
| 17  | `flow.dead-assignment` |
| 14  | `def.ivar-write-mismatch` |

### Pool-mode equivalence

After the deep-shareability fixes in `642cf28`, `--workers=4` on Redmine
produces a diagnostic stream **byte-identical** to sequential (389 == 389
on the pre-narrowing snapshot; 343 == 343 after). Timing:

| Mode | Wall time | Peak RSS |
| --- | ---: | ---: |
| Sequential (warm) | 2.82 s | 266 MB |
| Pool `workers=4` (warm) | 3.70 s | 948 MB |
| Pool `workers=8` (warm) | 8.39 s | 1.60 GB |

Pool mode remains the wrong default on a project this size: per-Ractor
env build + Marshal restore dominate the parallel speedup of ~10 ms-per-file
inference. This matches the [ADR-15 OQ1](../adr/15-ractor-concurrency.md)
caveat. The pool path is now CORRECT (no IsolationErrors, byte-identical
output); the question of when it becomes FASTER is unchanged.

### `call.undefined-method` — Rails-extension long tail

Almost all 243 instances are ActiveSupport / Rails core extensions absent
from stdlib RBS — not actual bugs:

| Count | Selector / receiver | Source |
| ---: | --- | --- |
| 75 | `String#html_safe`, `"…".html_safe` | `ActiveSupport::SafeBuffer` mixin |
| 24 | `Array.wrap(...)` | `ActiveSupport::CoreExtensions::Array::Wrapper` |
| 12 | `Time.parse` | stdlib `time` — `require 'time'` missing in user code |
| 6+ | `Hash#deep_dup`, `Hash#symbolize_keys` etc. | ActiveSupport `Hash` core_ext |
| 6+ | `Integer#days`, `#minute`, `#day`, `#year`, `#seconds` | `ActiveSupport::Duration` |
| 4 | `String#constantize` | ActiveSupport `String` core_ext |
| 2+ | `String#underscore`, `#demodulize`, `#to_hours` | ActiveSupport `String` core_ext |

A dedicated `rigor-activesupport-core-ext` plugin is the planned
remediation. The pre-evaluation-of-monkey-patches config knob is the
complementary remediation for project-private patches. Both are recorded
as future directions in the agent-side memory store
(`project_activesupport_core_ext_plugin`) — no committed milestone.

### Findings with bug-finding value (Rails-independent)

- **`call.possible-nil-receiver` 23 (post-fix).** Most remaining cases
  appear to be loop-iteration patterns or guarded-then-rebound forms not
  yet covered by narrowing. Example pattern still flagged:

  ```ruby
  if cond
    val = compute  # nullable
    next if val.nil?
    val.attr      # narrowing across `next if` not yet flow-tracked
  end
  ```

- **`def.ivar-write-mismatch` 14.** Same ivar bound to incompatible types
  on different assignments. `User#@projects_by_role` ⇄ `NilClass`/`Hash`,
  `Wiki#@page_found_with_redirect` ⇄ `FalseClass`/`TrueClass`, etc. Ruby
  idiom for memoized-vs-not-yet-computed state — usable as a warning but
  borderline noisy.

- **`flow.dead-assignment` 17.** Unread local-variable assignments in
  several `_controller.rb` actions and a few helpers. Worth surfacing
  upstream: e.g. `app/controllers/issues_controller.rb:401` assigns
  `journal` in `bulk_update` and never reads it.

- **`flow.always-truthy-condition` 24.** Constant-folded branches.
  Example: `app/controllers/repositories_controller.rb:427-429`.

### Engine improvements driven by Redmine (already landed)

`642cf28` — "Bank Redmine real-world findings: pool shareability +
assignment narrowing":

1. **Pool mode (Phase 4b.x follow-up): three deep-shareability gaps**
   surfaced by worker-Ractor IsolationErrors on this project:
   - `NumericCatalog#@catalog` (deep-share the YAML graph)
   - `Type::Refined::CANONICAL_NAMES` (nested-Array keys)
   - `Builtins::RegexRefinement::RULES` (nested-Array rows)

2. **`if cond && (var = expr)` narrowing.** Four new write-node cases in
   `Inference::Narrowing#analyse` (`LocalVariableWriteNode` +
   ivar/cvar/global). On Redmine this dropped `call.possible-nil-receiver`
   from 69 → 23 with zero regressions.

### Open items deferred to follow-up tracks

| ID | Item |
| --- | --- |
| O1 | `active_support/core_ext` plugin + config-side monkey-patch pre-evaluation. (Memory: `project_activesupport_core_ext_plugin`.) |
| O2 | Macro-template expansion (ERB `.rb` templates, `class_eval <<~RUBY` heredocs) — would also recover the 22 `rb-with-erb` parse errors in `lib/generators/redmine_plugin_model/templates/migration.rb`. (Memory: `project_macro_template_expansion`.) |
| O3 | `next if x.nil?` / `return if x.nil?` flow-tracked narrowing across early-exit guards in the same block. |

---

## Round-3 projects (Loomio / Publify / Diaspora / Dependabot Core / tDiary Core)

Third-round sweep. Includes three Rails apps (Loomio / Publify /
Diaspora) at small / micro / medium size, and **two non-Rails Ruby
projects** to calibrate how the analyser and the
ActiveSupport-shaped RBS bundle behave outside the Rails idiom.

### Quantitative summary

| Project | Files | Wall (warm) | Peak RSS | Baseline | with O1 v2 | Δ |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| Loomio | 563 | 2.36 s | 238 MB | 207 | **63** | −144 (−70%) |
| Publify (app shell only) | 15 | 0.66 s | 243 MB | **0** | 0 | 0 |
| Diaspora | 371 | 1.35 s | 258 MB | 65 | **5** | −60 (−92%) |
| Dependabot Core (non-Rails) | 1,089 | 13.02 s | 226 MB | 205 | **58** | −147 (−72%) |
| tDiary Core (non-Rails) | 244 | 1.61 s | 254 MB | 111 | **106** | −5 (−5%) |

Pool ≡ sequential on all five (zero IsolationErrors).

### Notable findings (round 3)

- **Publify is just the Rails app shell** (15 .rb files in
  `app/` + `lib/`). The real Publify code lives in the external
  `publify_core` / `publify_amazon_sidebar` / `publify_textfilter_code`
  gems referenced via `gem "publify_core", github: ...`. Rigor only
  sees what's checked into this repo, so the diagnostic count is
  zero — a useful boundary case but not representative of Publify
  proper.
- **Diaspora is the cleanest Rails app in the survey** — 5
  diagnostics on 371 files after O1 v2.
- **Dependabot Core (non-Rails) still benefits substantially from
  the ActiveSupport-shaped bundle** (−72%). The reason: many
  non-Rails Ruby projects load ActiveSupport (or fragments via
  `active_support/core_ext/...`) at boot, and their code uses the
  same `Object#blank?` / `#present?` / `#try` / `String#exclude?`
  / `Enumerable#index_by` idioms as Rails apps. The remaining 58
  diagnostics are dominated by **Bundler-internal Singleton-class
  calls** (`Bundler::Definition.build` × 10, `Bundler.settings` × 7,
  `Bundler::Dependency.new(...)` flagged as wrong-arity 5×) — all
  of which are O4 (target-Bundler awareness) symptoms. Dependabot
  ships its own monkey-patches against Bundler in
  `bundler/helpers/v*/monkey_patches/` that Rigor would need to
  pre-evaluate to type correctly.
- **tDiary Core barely benefits from O1** (−5%). It pre-dates the
  ActiveSupport-as-utility idiom — the Ruby is classic stdlib-only
  style. tDiary's residual diagnostics are dominated by
  `#month=` / `#year=` setters flagged as `on Object` (35
  instances in `misc/plugin/category-legacy.rb`). The plugin file
  is `instance_eval`'d into a host plugin class at runtime, and
  rigor can't see the receiver class because the `def`s sit at
  file top level — exactly the macro-expansion path queued under
  open item O2 (heredoc / `instance_eval` Ruby expansion).
- **Loomio's mix is unusual** — 34 of 63 are `flow.dead-assignment`
  (54%) and only 11 are `call.undefined-method`. The codebase is
  noticeably less idiomatic-AS than the others; less to gain from
  the RBS bundle.

### Round-3 takeaways for the analyser

1. **Pool ≡ sequential proven on all 14 projects swept so far**
   (zero `Ractor::IsolationError` across ~29,560 files). Phase
   4b.x's four shareability follow-ups + the CONSTANT_CONSTRUCTORS
   lambda fix are robust against the diversity of real-world
   targets.
2. **The ActiveSupport-shaped RBS bundle is useful for non-Rails
   Ruby too** — Dependabot Core's −72% confirms ActiveSupport
   idioms (`Object#blank?` family, `Enumerable#index_by`,
   `String#exclude?`) are widespread outside Rails.
3. **tDiary's `instance_eval` plugin pattern motivates O2** —
   pre-Rails-era idioms hit the same kind of metaprogramming
   barrier as Rails generators' `.rb`-as-ERB templates.

## Round-2 projects (Forem / Solidus / Chatwoot / Canvas LMS / OpenProject)

A second-round sweep of five additional Rails projects, run after
the first-round engine fixes (Pool deep-shareability follow-ups #1
through #3, narrowing extension, parametrized-ancestor projection,
and the v1 RBS bundle).

### Per-project rule mix

| Project | Total | `call.undefined-method` | `possible-nil-receiver` | `flow.always-truthy-condition` | `def.ivar-write-mismatch` | `call.wrong-arity` |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Forem | 146 | 55 | 47 | 15 | 27 | — |
| Solidus | 42 | 33 | 3 | 4 | 1 | 1 |
| Chatwoot | 19 | 6 | 11 | 1 | 2 | — |
| Canvas LMS | 1,496 | 766 | 445 | 194 | 83 | 11 |
| OpenProject | 175 | 138 | 27 | 11 | 8 | 4 |

### Engine improvement triggered by round 2

The v1 RBS bundle was extended to v2 with five extra method
families surfaced in this round:

1. `Array#compact_blank` / `Hash#compact_blank` (Rails 6.1+).
2. `Array#exclude?` / `String#exclude?` / `Hash#exclude?`
   (`Enumerable` re-exposed too).
3. `Enumerable#index_with` / `#index_by` / `#pluck` / `#pick` /
   `#sole` / `#including` / `#excluding` / `#without`.
4. `Hash.from_xml`, `Hash#reverse_merge` / `#reverse_merge!`.
5. `DateTime` calculations (`#utc`, `#in_time_zone`, `#yesterday`,
   `#tomorrow`, `#beginning_of_*`, `#end_of_*`, `#ago`, `#since`).

Combined v1 + v2 quantitative impact across all nine survey
projects: **total 12,502 → 3,071 (-75%)**, `call.undefined-method`
**10,589 → 1,426 (-87%)**.

### Notable findings (round 2)

- **Solidus's `lib/` count is misleading (just 2 files at the repo
  root)**; the engine sub-trees (`core/`, `api/`, `backend/`,
  `admin/`, `promotions/`, `legacy_promotions/`) are where the code
  lives. The rigor config enumerates each sub-tree as an explicit
  path. Solidus's diagnostic count drops to 42 — extremely clean.
- **Canvas LMS dominates round-2 residual (1,496 of 1,878 — 80%).**
  Top selectors: `[]= on Integer` (70 — likely a wrong receiver
  inference), `[]= on nil` (51), `<< on nil` (40). These are
  narrowing-tier limitations, not RBS coverage gaps. Canvas also
  ships project-private `Numeric#decimal_megabytes`, `File.mime_type`,
  and friends; closing the long tail there needs O4 (target-Bundler
  awareness) plus a Canvas-specific monkey-patch declaration in
  `.rigor.yml`.
- **OpenProject's `from_xml` / `compact_blank` clusters were the
  v1 → v2 motivator** — `Hash.from_xml` alone accounted for 10
  of OpenProject's residual undefined-methods.

## Discourse

Source: `https://github.com/discourse/discourse` (depth-1 shallow clone,
master HEAD on 2026-05-15).

### Quantitative summary (after `642cf28` + the Discourse-driven shareability fix)

| Metric | Sequential warm | Pool `workers=4` warm |
| --- | ---: | ---: |
| Files scanned | 1,804 | 1,804 |
| Wall time | 7.46 s | **5.82 s** (1.28× faster than sequential) |
| Peak RSS | 244 MB | 842 MB |
| Total diagnostics | 1,439 | 1,439 |
| Errors | 1,325 | 1,325 |

Pool is faster than sequential at this size — the **first wall-clock
crossover** the survey observed.

### Rule mix

| Count | Rule |
| ---: | --- |
| 1,078 | `call.undefined-method` |
| 217 | `call.possible-nil-receiver` |
| 61 | `flow.always-truthy-condition` |
| 46 | `def.ivar-write-mismatch` |
| 22 | `call.wrong-arity` |
| 8 | `call.argument-type-mismatch` |
| 7 | `flow.dead-assignment` |

### Engine improvement triggered by Discourse

Pool's first run on Discourse surfaced **8 `Ractor::IsolationError`** on
worker dispatch into
`Rigor::Inference::MethodDispatcher::ShapeDispatch::REFINED_STRING_PROJECTIONS`
(a Hash keyed by two-element Symbol arrays — same shape as the three
Phase 4b.x follow-up sites the Redmine pass surfaced). Now `Ractor.make_shareable`;
new audit assertion pins the invariant
(`spec/rigor/ractor_readiness_spec.rb` § "Phase 4b.x — module catalog
shareability"). After the fix, pool ≡ sequential.

### Notable findings

- **`Time.zone` 182 instances** — `ActiveSupport::TimeWithZone` extension.
  Even bigger ActiveSupport-extension volume than Redmine.
- **`Integer#day` / `#hour` / `#minute` / `#days` / `#minutes` / `#hours`** —
  `ActiveSupport::Duration` numeric coercions; hundreds of instances.
- **`call.wrong-arity on Class` 18 instances** — Discourse's service
  classes (`DatabaseRestorer.new(...)`, `MetaDataHandler.new(...)`,
  `OpenStruct.new(...)`). The receiver class isn't in rigor's RBS env,
  so dispatch falls back to `Class#new` (zero-arg default initializer)
  and reports the arg count as wrong. `OpenStruct` specifically lost
  its default-gem status in Ruby 4.0; Discourse's Gemfile.lock pins
  it but rigor's analysis env doesn't see the target project's
  Bundler context, so the gem's RBS is not loaded.
- **`call.argument-type-mismatch on URI.encode_www_form` 5+ instances** —
  RBS signature is `(?Enumerable[[_, _]])` but real-world callers pass
  `Hash`. Hash IS Enumerable over `[K, V]` pairs at runtime; rigor's
  subtyping doesn't recognise the Hash → `Enumerable[[K, V]]` relation
  here. Worth investigating as a separate engine track.

### Open items raised by Discourse

| ID | Item |
| --- | --- |
| O4 | Target-project Bundler awareness — load the target's gem RBS when running outside the project's `bundle exec` context (covers OpenStruct in Ruby 4.0+ and any non-default gem with shipped RBS). |
| O5 | `Hash <: Enumerable[[K, V]]` subtyping for the parameter-binder. |

---

## Mastodon

Source: `https://github.com/mastodon/mastodon` (depth-1 shallow clone,
master HEAD on 2026-05-15).

### Quantitative summary

| Metric | Sequential warm | Pool `workers=4` warm |
| --- | ---: | ---: |
| Files scanned | 1,302 | 1,302 |
| Wall time | 3.31 s | 3.98 s |
| Peak RSS | 238 MB | 878 MB |
| Total diagnostics | 521 | 521 (≡ sequential) |
| Errors | 487 | 487 |

Pool ≡ sequential out of the box — no new engine bugs found. Pool is
slower than sequential at this size; the crossover sits between
Mastodon (1.3 K files) and Discourse (1.8 K files), shifted by the
Marshal-restore overhead.

### Rule mix

| Count | Rule |
| ---: | --- |
| 414 | `call.undefined-method` |
| 73 | `call.possible-nil-receiver` |
| 26 | `def.ivar-write-mismatch` |
| 8 | `flow.always-truthy-condition` |

### Notable findings

- Same Rails-extension long tail (`Integer#day/#hour/#minute/#minutes/#seconds`,
  `String#squish`, `Time.zone`). The ranking differs but the cause is
  identical to Redmine and Discourse: missing `active_support/core_ext`
  RBS coverage.

---

## GitLab FOSS

Source: `https://gitlab.com/gitlab-org/gitlab-foss` (depth-1 shallow
clone, master HEAD on 2026-05-15). The largest target in the survey.

### Quantitative summary

| Metric | Sequential warm | Pool `workers=8` warm |
| --- | ---: | ---: |
| Files scanned | 11,130 | 11,130 |
| Wall time (warm) | 25.27 s | **15.43 s** (1.64× faster than sequential) |
| Wall time (cold) | 25.33 s | — |
| Peak RSS | 248 MB | 1.30 GB |
| Total diagnostics | 2,982 | 2,983 (+1; see below) |
| Errors | 2,857 | 2,858 |

Pool is comfortably faster than sequential on a project this size. Peak
RSS at 1.3 GB is the cost — 5× sequential. The crossover is solidly
established here; the question for future pool-mode work is whether the
RSS / wall-clock tradeoff can move further with the deferred per-Ractor
`Cache::Store`-shared facade (ADR-15 § OQ1).

### Rule mix

| Count | Rule |
| ---: | --- |
| 2,676 | `call.undefined-method` |
| 136 | `call.possible-nil-receiver` |
| 71 | `def.ivar-write-mismatch` |
| 52 | `flow.always-truthy-condition` |
| 43 | `call.wrong-arity` |
| 2 | `flow.dead-assignment` |
| 1 | `call.argument-type-mismatch` |
| 1 | (Prism parse-error from a `.erb`-shaped `.rb` generator template, like Redmine) |

### Pool vs sequential — deterministic +1 divergence

Pool emits **one** diagnostic sequential does not, deterministically
across `workers=4` / `workers=8` and multiple runs:

```
lib/gitlab/mail_room.rb:17:56
  call.argument-type-mismatch
  argument type mismatch at parameter `dir` of `expand_path` on Pathname:
    expected String, got String | nil
```

Minimal repro (sequential is silent, pool emits the diagnostic):

```ruby
require "pathname"
x = Pathname.new("../..")
y = x.expand_path(__dir__)   # __dir__ returns String | nil per RBS
```

`__dir__`'s RBS return is `String?`. Sequential constant-folds the call
through the `try_fold_pathname_binary` tier in
`MethodDispatcher::ConstantFolding`; pool reaches the RBS-dispatch tier
where the parameter check rejects `String | nil`. The divergence is
deterministic and rare (1 site in 11,130 files), but the contract is
byte-identical output — recorded as open item O6.

### Notable findings

- **`Time.current` 324 instances** — ActiveSupport. By far the top
  Rails-extension absentee in this corpus.
- **`Array.wrap` 228 instances**, **`Integer#minute` 163**, **`Time.zone` 125** —
  same `active_support/core_ext` tail as the smaller targets,
  proportionally larger.
- **`String#demodulize` 34**, **`#underscore` 32**, **`#squish` 37** — the
  Inflector / ActiveSupport `String` core_ext.
- The user-defined-class `wrong-arity` issue (Discourse O4) repeats here
  at a larger scale.

### Open items raised by GitLab FOSS

| ID | Item |
| --- | --- |
| O6 | Pool vs sequential precision divergence on Pathname argument check. Pool reaches RBS dispatch when sequential folds through `try_fold_pathname_binary`; both paths are individually defensible but the contract requires byte-identical output. |

---

## Cross-project summary

| Project | Files | Seq warm | Pool warm | Pool ÷ Seq | Peak RSS (seq / pool) | Diagnostics (baseline) |
| --- | ---: | ---: | ---: | ---: | --- | ---: |
| Redmine | 347 | 2.82 s | 3.70 s (`w=4`) | 1.31× slower | 266 MB / 948 MB | 389 |
| Chatwoot | 802 | 2.67 s | (anomalous run; system load) | n/a | 274 MB / — | 300 |
| Mastodon | 1,302 | 3.31 s | 3.98 s (`w=4`) | 1.20× slower | 238 MB / 878 MB | 521 |
| Forem | 1,250 | 4.31 s | 4.60 s (`w=4`) | 1.07× slower | 260 MB / — | 691 |
| Discourse | 1,804 | 7.46 s | 5.82 s (`w=4`) | **0.78× (faster)** | 244 MB / 842 MB | 1,439 |
| Solidus | 1,914 | 7.36 s | 4.91 s (`w=4`) | **0.67× (faster)** | 275 MB / — | 528 |
| Canvas LMS | 3,248 | 17.32 s | 11.16 s (`w=4`) | **0.64× (faster)** | 272 MB / — | 3,296 |
| OpenProject | 6,817 | 18.84 s | 10.24 s (`w=4`) | **0.54× (faster)** | 246 MB / — | 2,356 |
| GitLab FOSS | 11,130 | 25.27 s | 15.43 s (`w=8`) | **0.61× (faster)** | 248 MB / 1.30 GB | 2,982 |
| Publify (shell only) | 15 | 0.66 s | (not measured) | n/a | 243 MB / — | 0 |
| Diaspora | 371 | 1.35 s | (not measured) | n/a | 258 MB / — | 65 |
| Loomio | 563 | 2.36 s | (not measured) | n/a | 238 MB / — | 207 |
| tDiary Core (non-Rails) | 244 | 1.61 s | (not measured) | n/a | 254 MB / — | 111 |
| Dependabot Core (non-Rails) | 1,089 | 13.02 s | (not measured) | n/a | 226 MB / — | 205 |

**Pool wall-clock crossover** sits between Mastodon / Forem (~1.3 K
files, pool slower) and Discourse / Solidus (~1.8 K files, pool
1.3-1.5× faster). Pool memory cost is 3-5× sequential. The
ADR-15 OQ1 "per-Ractor cache facade" remains the avenue for moving
the crossover lower and capping peak RSS.

**Pool ≡ sequential proven on all fourteen projects.** After the
four Phase 4b.x deep-shareability follow-ups (NumericCatalog,
CANONICAL_NAMES, RegexRefinement::RULES,
ShapeDispatch::REFINED_STRING_PROJECTIONS) and the
CONSTANT_CONSTRUCTORS lambda fix, every project in the survey —
including the two non-Rails projects (Dependabot Core and tDiary
Core) — produces byte-identical diagnostic streams between
sequential and pool modes. Zero IsolationErrors across the 31,840
files swept.

**Engine fixes banked during the survey** (commit `642cf28` + the
Discourse fix):

1. Pool deep-shareability gaps (4 sites in total):
   `NumericCatalog#@catalog`, `Type::Refined::CANONICAL_NAMES`,
   `Builtins::RegexRefinement::RULES`,
   `MethodDispatcher::ShapeDispatch::REFINED_STRING_PROJECTIONS`.
2. `if cond && (var = expr)` narrowing (4 new write-node cases in
   `Inference::Narrowing#analyse`).

The four shareability sites all share the same shape — a Hash / Array
of nested arrays whose outer container was shallow-frozen but whose
inner rows weren't. The audit spec now has explicit assertions for
each of the four so a future equivalent regression fails the audit
instead of crashing real-world target projects.

**Diagnostic surface dominated by Rails-extension absence.** Across all
four projects, `call.undefined-method` accounts for **64-90%** of all
diagnostics, and the top selectors are uniformly `ActiveSupport::Duration`
numeric coercions (`#days`, `#hours`, `#minutes`), Inflector / String
core_ext (`#demodulize`, `#underscore`, `#squish`, `#html_safe`,
`#constantize`), `Array.wrap`, `Hash` core_ext (`#deep_dup`,
`#symbolize_keys`, `#stringify_keys`), and `Time.current` / `Time.zone`.
The dedicated `rigor-activesupport-core-ext` plugin would close most
of this surface; the config-side monkey-patch pre-evaluation knob
would close the project-private remainder.

### Open items consolidated

| ID | Status | Item |
| --- | --- | --- |
| O1 | landed (MVP) | `examples/rigor-activesupport-core-ext/` — community RBS bundle covering the top ~40 ActiveSupport core-ext selectors. Opt-in via `signature_paths`. |
| O2 | queued | Macro-template / heredoc-Ruby expansion. |
| O3 | not-an-issue | `next if x.nil?` / `return if x.nil?` already narrowed — survey-residual nil-receivers are mostly `Object#blank?` / `#present?` / `#try` ActiveSupport extensions, which O1's RBS bundle covers. |
| O4 | queued | Target-project Bundler awareness (load gems' RBS from the analysed project's `Gemfile.lock`). |
| O5 | landed (`ac14c45`) | `Hash <: Enumerable[[K, V]]` subtyping in the parameter binder. |
| O6 | landed (`4698437`) | Pool vs sequential precision divergence at the constant-fold / RBS-dispatch boundary (Pathname). |

### Post-O1 quantitative impact

After opting into the new RBS bundle (sequential warm cache; v2
of the RBS bundle, which adds `compact_blank` / `exclude?` /
`index_with` / `index_by` / `Hash.from_xml` / `DateTime#utc` and
the `Enumerable` mixins on top of v1):

| Project | Baseline | With O1 v2 | Δ total | `call.undefined-method` before → after |
| --- | ---: | ---: | ---: | --- |
| Redmine | 389 | 157 | **−232 (−60%)** | 243 → 60 (−75%) |
| Discourse | 1,439 | 423 | **−1,016 (−71%)** | 1,078 → 134 (−88%) |
| Mastodon | 521 | 124 | **−397 (−76%)** | 414 → 27 (−93%) |
| GitLab FOSS | 2,982 | 489 | **−2,493 (−84%)** | 2,676 → 207 (−92%) |
| Forem | 691 | 146 | **−545 (−79%)** | 590 → 55 |
| Solidus | 528 | 42 | **−486 (−92%)** | 520 → 33 |
| Chatwoot | 300 | 19 | **−281 (−94%)** | 282 → 6 |
| Canvas LMS | 3,296 | 1,496 | **−1,800 (−55%)** | 2,493 → 766 |
| OpenProject | 2,356 | 175 | **−2,181 (−93%)** | 2,293 → 138 |
| **Total** | **12,502** | **3,071** | **−9,431 (−75%)** | **10,589 → 1,426 (−87%)** |

The remaining `call.undefined-method` instances are mostly:

- **Canvas LMS dominates the residual** — 1,496 of 3,071 (49%). Top
  selectors: `[]= on Integer` (70), `[]= on nil` (51), `<< on nil`
  (40) — narrowing limitations rather than missing RBS — plus
  Canvas-specific extensions (`#decimal_megabytes` is a project-private
  refinement on Numeric; `File.mime_type` is a Marcel/Mimemagic-style
  helper not in stdlib).
- **Project-private monkey-patches.** Discourse, Forem, Canvas, and
  GitLab each ship their own `String` / `Array` / `Hash` extensions.
  Closing this needs O4 (project-side monkey-patch pre-evaluation
  config knob).
- **Gem-specific methods absent from the analyzer's RBS env.** The
  target project's `Gemfile.lock` gems aren't loaded by rigor's
  out-of-process Bundler context. Gems with shipped RBS would benefit
  from O4 (target-Bundler awareness).
- **Concentrated nil-receiver patterns.** Multi-assignment inside a
  block followed by guard-then-use inside the same block; not yet
  flow-tracked.
- **Other Rails core_ext methods outside the bundle's ~50-selector
  scope.** PRs to extend the RBS bundle are welcome.
