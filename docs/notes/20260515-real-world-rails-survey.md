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

| Project | Status | Files (`app/` + `lib/`) | Notes |
| --- | --- | ---: | --- |
| [Redmine](https://github.com/redmine/redmine) | landed | 347 | Smallest of the four — used as the engine-bug shakedown. |
| [Discourse](https://github.com/discourse/discourse) | landed | 1,804 | Forum platform; heavy plugin / hook surface. |
| [Mastodon](https://github.com/mastodon/mastodon) | landed | 1,302 | ActivityPub social server; ActiveJob / Sidekiq heavy. |
| [GitLab FOSS](https://gitlab.com/gitlab-org/gitlab-foss) | landed | 11,130 | Largest — Rails monolith with deep metaprogramming. |

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

| Project | Files | Seq warm | Pool warm | Pool ÷ Seq | Peak RSS (seq / pool) | Diagnostics |
| --- | ---: | ---: | ---: | ---: | --- | ---: |
| Redmine | 347 | 2.82 s | 3.70 s (`w=4`) | 1.31× slower | 266 MB / 948 MB | 343 |
| Mastodon | 1,302 | 3.31 s | 3.98 s (`w=4`) | 1.20× slower | 238 MB / 878 MB | 521 |
| Discourse | 1,804 | 7.46 s | 5.82 s (`w=4`) | **0.78× (faster)** | 244 MB / 842 MB | 1,439 |
| GitLab FOSS | 11,130 | 25.27 s | 15.43 s (`w=8`) | **0.61× (faster)** | 248 MB / 1.30 GB | 2,982 |

**Pool wall-clock crossover** sits between Mastodon (1.3 K files) and
Discourse (1.8 K files). Pool memory cost is 3–5× sequential. The
ADR-15 OQ1 "per-Ractor cache facade" remains the avenue for moving
the crossover lower and capping peak RSS.

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

After opting into the new RBS bundle (sequential warm cache):

| Project | Before O1 | After O1 | Δ total | `call.undefined-method` before → after |
| --- | ---: | ---: | ---: | --- |
| Redmine | 343 | 160 | **−183 (−53%)** | 243 → 62 (−74%) |
| Discourse | 1,435 | 452 | **−983 (−68%)** | 1,078 → 148 (−86%) |
| Mastodon | 521 | 142 | **−379 (−73%)** | 414 → 40 (−90%) |
| GitLab FOSS | 2,982 | 579 | **−2,403 (−81%)** | 2,676 → 286 (−89%) |
| **Total** | **5,281** | **1,333** | **−3,948 (−75%)** | **4,411 → 536 (−88%)** |

The remaining `call.undefined-method` instances are mostly:

- Project-private monkey-patches (Discourse / GitLab ship their own
  `String` / `Array` extensions).
- Gem-specific methods absent from the analyzer's RBS env (the
  target's `Gemfile.lock` gems aren't loaded — open item O4).
- Concentrated nil-receiver patterns the survey already noted.
- Other Rails core_ext methods outside the bundle's ~40-selector
  scope.
