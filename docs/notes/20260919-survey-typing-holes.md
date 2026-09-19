# Survey-corpus typing-hole census — per-node `Dynamic[top]` locations on 32 targets (2026-09-19)

Status: measurement note. Master `7836b2e7` (post-v0.4.x), worktree branch
`survey-typing-holes`. Sequel to
[`20260901-corpus-opacity-attribution.md`](20260901-corpus-opacity-attribution.md) and
[`20260901-post-campaign-opacity-recheck.md`](20260901-post-campaign-opacity-recheck.md):
the same lens, re-run on current master, extended to the five survey checkouts that had
no shared config until now (gitlab, rails, dependabot-core, mangrove, strap).

## Method

Every non-`_`-prefixed directory under `~/repo/ruby/rigor-survey/` was onboarded to the
`rigor-project-init` shape (acknowledge/non-strict mode: `severity_profile: lenient`,
plugins matched to the detected stack — the nine that lacked `.rigor.dist.yml` got fresh
ones; the pre-existing configs, including the frozen sweep configs, were kept verbatim).
Three targets keep a leftover experiment `.rigor.yml` that shadows `.rigor.dist.yml` in
discovery order (dependabot-core, mangrove, strap); those runs passed the dist config
explicitly (`--config` / `PROBE_CONFIG`).

Three instruments, all run against the worktree's `exe/rigor` / `lib` inside the Flake:

- `rigor check --no-baseline --format json` — raw diagnostic stream (baselines on
  gitlab/mastodon/redmine/textbringer deliberately bypassed).
- `hole_scan.rb` — PrecisionScanner walk + classifier over the check-path file set
  (`PathExpansion` + `exclude_patterns`, plugin-aware `ProjectContext` environment,
  `discovery_seeded_scope`), recording file:line / node class / snippet for every
  `dynamic_top` and `top` node.
- `probe_attrib.rb` — the preserved 2026-09-01 attribution probe
  (`origin/opacity-sweep-harness-20260901`), byte-identical except for the `PROBE_CONFIG`
  override. Its file glob ignores `exclude:` (same as `rigor coverage`), so counts on
  `.`-rooted targets differ from hole_scan's at the margin.

Artifacts: `rigor-survey/_reports/typing-holes/` (`<proj>.check.json`,
`<proj>.holes.jsonl`, `<proj>.attrib.json`, drivers, `baseline-20260901/` comparison
copies). No per-site verification agents this time — pair-level claims below are
instrument output, spot-checked by reading the named source.

## Headline

Corpus: **3,231,851 expressions across 32 targets, 63.7% precise, 1,170,398 opaque sites**
(`dynamic_top` + `top`). Excluding mail's ragel-table constant inflation (422k exprs at
98%): **58.5% precise** — against 56.6% for the same lens on the 9/1 rerun's non-mail
targets.

| project | files | exprs | precision | opaque | check err/warn/info |
| --- | --: | --: | --: | --: | --: |
| gitlab | 11,688 | 1,472,166 | 59.7% | 592,385 | 157/235/4,372 |
| dependabot-core | 896 | 401,688 | 57.2% | 171,831 | 5/14/1 |
| mail | 111 | 422,090 | 98.0% | 8,421 | 5/13/1 |
| rails | 1,453 | 284,798 | 52.8% | 133,779 | 361/66/64 |
| mastodon | 1,328 | 150,532 | 56.9% | 64,797 | 10/21/2,517 |
| redmine | 351 | 130,004 | 54.4% | 59,029 | 90/21/1,610 |
| herb | 146 | 62,763 | 72.9% | 16,947 | 20/18/2,492 |
| Data-Structures-and-Algorithms-in-Ruby | 113 | 49,743 | 61.3% | 18,952 | 14/0/9 |
| textbringer | 77 | 32,923 | 66.5% | 10,682 | 57/64/5 |
| concurrent-ruby | 178 | 23,761 | 58.3% | 9,853 | 7/17/1 |
| kramdown | 55 | 21,329 | 65.6% | 7,297 | 26/15/0 |
| net-ssh | 97 | 20,716 | 58.6% | 8,511 | 9/6/2 |
| tdiary-core | 71 | 20,352 | 57.4% | 8,661 | 5/239/1 |
| Algorithms-and-Data-Structures-in-Ruby | 256 | 18,755 | 53.1% | 8,574 | 11/2/8 |
| Ruby | 188 | 17,755 | 64.2% | 6,267 | 21/0/3 |
| parser | 56 | 12,831 | 52.8% | 6,048 | 0/0/5 |
| rubocop-ast | 101 | 11,732 | 65.9% | 3,992 | 7/3/1 |
| liquid | 63 | 10,701 | 56.3% | 4,592 | 1/1/3 |
| protobuf | 24 | 10,091 | 60.2% | 4,010 | 3/0/0 |
| hamlit | 61 | 10,000 | 57.1% | 4,276 | 6/1/1 |
| haml | 52 | 8,513 | 60.3% | 3,369 | 16/3/1 |
| faraday | 33 | 5,853 | 50.7% | 2,874 | 0/0/1 |
| slim | 27 | 4,864 | 58.8% | 2,003 | 1/5/1 |
| rbnacl | 37 | 4,286 | 69.7% | 1,299 | 0/0/1 |
| mangrove | 14 | 4,054 | 37.6% | 2,528 | 0/1/1 |
| algorithms | 14 | 4,076 | 38.8% | 2,485 | 0/3/1 |
| rgl | 28 | 3,938 | 52.2% | 1,881 | 5/16/1 |
| pycall | 22 | 3,103 | 63.3% | 1,133 | 0/10/1 |
| oj | 11 | 1,650 | 69.6% | 496 | 1/0/1 |
| jbuilder | 12 | 1,481 | 48.9% | 757 | 2/2/1 |
| ox | 15 | 1,752 | 54.5% | 798 | 2/0/1 |
| numo-narray | 2 | 2,324 | 40.0% | 1,280 | 0/1/1 |
| erubi | 3 | 866 | 48.8% | 431 | 1/2/0 |
| strap | 6 | 361 | 55.7% | 160 | 0/0/4 |

## Delta vs the 2026-09-01 rerun (28 paired targets)

Shared targets only; `rigor-lib` from the 9/1 rerun is out of scope here, and the five
newly-configured targets have no baseline row.

| target | files 9/1→now | precision Δ | named-receiver-opaque sites |
| --- | --- | --: | --: |
| mastodon | 1,325→1,328 | 54.8→56.9% (+2.1) | 2,067→1,374 |
| redmine | 346→351 | 50.2→54.4% (+4.3) | 2,719→1,756 |
| herb | 42→146 | 63.4→72.9% (+9.5) | 171→609 |
| haml | 51→52 | +0.8 | 89→92 |
| Data-Structures-and-Algorithms-in-Ruby | 113→113 | +0.7 | 1,614→1,333 |
| concurrent-ruby | 178→178 | +0.5 | 446→438 |
| jbuilder | 12→12 | +0.5 | 15→17 |
| algorithms | 14→14 | **−0.7** | 46→46 |
| rubocop-ast | 101→101 | **−0.5** | 54→56 |
| 19 others | | ±0.4 | mixed ±30 |

- **The `Parameters#[]` wall is gone**: mastodon 496→0, redmine 581→0 named-pair sites —
  the 9/1 ranking's #534 headline item landed. `singleton(Rails)#configuration/cache/logger`
  (mastodon, ~200 sites) and the redmine `singleton(*)#table_name` family (~470 sites)
  likewise disappeared.
- **redmine's AR coverage unlocked**: the #569 schema-less gate is fixed — the plugin now
  falls back to `db/structure.sql` (`StructureSqlParser`) and a reduced model index; gitlab
  (structure.sql-only, 11.7k files) gets working `model-call` recognitions and column
  types for free. Confirmed live: `ProjectFeature.where` resolves to its table.
- **New named pairs are downstream exposure, not regressions.** Receiver typing improved
  enough that calls that used to sit in the dynamic-receiver bucket now name their
  receiver: `ActionController::Parameters?#present?/==/to_s` (the `T − nil` Difference
  receiver), `ActiveSupport::BroadcastLogger#debug/error/warn`,
  `ActiveSupport::Cache::Store#fetch/delete`, `Rails::Application::Configuration#x`
  (`config.x.*`, 102 sites on mastodon). Each is the next lever layer surfacing.
- **Small negative drifts (−0.3…−0.7pp)** on algorithms, Algorithms-and-DS, pycall,
  rubocop-ast: single-digit-tier shuffles (constant→dynamic_top ~20–30 sites each), the
  same honest-widening family the 9/1 rerun attributed to #537 — plausible but not
  site-verified here.
- **Target drift:** several checkouts moved since 9/1 — herb 42→146 files (and its
  precision gain is mostly *that*, not engine), haml 51→52, redmine 346→351,
  mastodon 1,325→1,328, tdiary-core 69→71. Paired numbers hold; herb's +9.5pp does not.

## Corpus hole anatomy (probe lens)

Opaque expression node classes (1.17M sites): `CallNode` 579k, `LocalVariableReadNode`
275k, `BlockNode` 54k, `LocalVariableWriteNode` 39k, `ConstantReadNode` 37k,
`ConstantPathNode` 34k, `InstanceVariableReadNode` 27k, `IfNode` 23k,
`EmbeddedStatementsNode` 21k — the container/conditional classes are mostly mirror
propagation (category G of the 9/1 note), not independent holes.

Opaque calls by receiver tier: **implicit-self 236k · dynamic receiver 285k · precise
receiver still opaque 56k**. Local reads: `def_param` 150k · `assigned_local` 78k ·
`block_param` 46k.

### The families

1. **The parameter lane remains the single biggest bucket** — 150k opaque local reads of
   `def` params (plus its arithmetic/ivar cascade through `assigned_local`). Every survey
   config leaves `parameter_inference:` off (the ADR-67 gate); the lane is measured, not
   re-litigated.

2. **Implicit-self framework DSL** — 236k opaque implicit sends. The top names are a
   map of which framework owns the hole:
   - Rails app surface: `params` 11.7k, `current_user` 6.0k, `before_action` 1.7k,
     `render` 1.4k, `can?` 1.1k — #534 territory, partially drained (Parameters#[] fixed;
     `params` itself still opaque).
   - **Grape** (gitlab `lib/api`): `expose` 3.9k, `desc` 1.4k, `requires` 1.4k,
     `optional` 2.2k, `route_setting` 1.5k, `params` overlap — no plugin exists.
   - **GraphQL** (gitlab `app/graphql`): `field` 3.4k, `argument` 1.7k — `rigor-graphql`
     exists but only records ADR-9 fact tables; it types no DSL call site, and gitlab's
     survey config did not enable it anyway.
   - AR class macros: `scope` 2.5k, `validates` 2.2k, `belongs_to` 1.3k.
   - i18n `_`/`s_` 4.4k combined.
   - Rails-the-framework internals (the `rails` target): `class_attribute` 170,
     `initializer` 151, `delegate` 159, `ActiveSupport.on_load` 109 — the framework's own
     DSL layer is itself largely opaque.
   - GitLab-specific: `strong_memoize` 805, `feature_category` 1.3k, `not_found!` 390 —
     project-DSL territory (escalation path A: project plugin).

3. **The Sorbet sig DSL is a hole on Sorbet-typed projects.** `sig`, `params`, `returns`,
   `void`, `abstract`, `override`, `type_member`, `T.*` calls type as `Dynamic[top]`
   because sorbet-runtime ships RBI, not RBS, and `rigor-sorbet` consumes the sig into
   its catalog without typing the sig *expression*. Share of each target's opaque sites:
   **mangrove 47%** (29% of *all* its expressions), **dependabot-core 33%** (~56k sites),
   **strap 21%**. Options: ship a minimal `T`/`T::Sig`/`DeclBuilder` RBS bundle inside
   rigor-sorbet, or teach the precision lens to discount the annotation surface.

4. **Named-receiver-but-opaque pairs — the actionable lane** (56k sites corpus-wide,
   top-80 pairs per target preserved in `*.attrib.json`):
   - **GitLab utility singletons**: `Feature.enabled?` 549, `Gitlab.config` 542,
     `Ability.allowed?` 393, `ServiceResponse#success?/message/payload/error?/[]` ~900
     combined, `Gitlab::ErrorTracking.track_exception` 257, `CurrentSettings` 162,
     `Metrics.counter` 143, `Json.dump` 132, `Redis::SharedState.with` 126.
     Spot check: `Feature.enabled?` IS a literal `def self.enabled?` in
     `lib/feature.rb` — dispatch resolves (no `undefined-method` diagnostic); the call
     lands opaque because the inferred *return* is untyped (the body bottoms out in
     Flipper, an RBS-less gem). Most of this cluster is the same
     "resolved method, Dynamic return" shape, not missing dispatch — the #522 lane.
   - **Container-of-Dynamic**: `Hash#[]` 632 + `Hash[Dynamic]#[]`/`[]=` ~700 more —
     `Hash[K, Dynamic]#[]` propagation; origin is one hop up (param/ivar lanes), the
     known #560/#531 territory.
   - `singleton(User)#current` (redmine) 510 — CurrentAttributes macro; still the
     declined lever from 9/1.
   - **`singleton(Mangrove::Result)#[]` 97** (+ `Option#[]`, `Ok/Err#[]` ~30): Sorbet
     generic application syntax `Result[Ok, Err]` on the carrier singleton — rigor-mangrove
     covers unwrap, not `[]` application. A small concrete plugin gap.
   - `singleton(Arel)#sql` 247, `Time.zone` 155, `Rails.application/env/root` ~180 on the
     `rails` target — the framework's own RBS thin spots.
   - `FileUtils.mkdir_p` 116 — stdlib, but FileUtils RBS only loads when the project
     requires it; honest missing-load on several targets.
   - `Proc#call` 151 — precise `Proc` receivers whose `call` still reads opaque. Core RBS
     declares `Proc#call` as `(*untyped) -> untyped`, so this is the honest-untyped lane,
     not a dispatch defect.
   - kata-corpus accessors (`Heap#arr` 147, `TreeNode#*`…) — the ADR-67 lane by another
     name.

5. **Unresolved constants**: `ConstantReadNode`+`ConstantPathNode` ~71k opaque —
   Zeitwerk implicit namespaces, undeclared gem constants, and (on mangrove/dependabot)
   `T`/`T::Sig` themselves.

## New-target spotlights

- **gitlab 59.7%** — the largest target ever swept. Precision is mid-pack despite Grape
  having no plugin and rigor-graphql being neither enabled nor typing DSL call sites; the AR plugin works end-to-end via `structure.sql`. The
  hole mass is the DSL trio (Grape `expose`/`params`, GraphQL `field`/`argument`,
  controller `params`/`current_user`) + the GitLab-internal singleton cluster. 49 project
  `.rbs` files were auto-detected (gems/*/sig subtrees).
- **rails 52.8%** — framework source analysed as plain Ruby (no app-facing plugins apply).
  Its own DSL layer (`class_attribute`, `initializer`, `on_load`) and its own public API
  (`Rails.application`, `Rails.env`, `Mime.[]`) are the recurring opaque shapes.
- **dependabot-core 57.2%** — cleanest `check` run of the big targets (20 diagnostics):
  Sorbet-typed code onboards well; its opaque mass is one-third the sig DSL itself.
- **mangrove 37.6%** — the corpus's lowest precision, and nearly half of it is the sig
  annotation DSL (the typed code's own ceremony). Removing that surface puts mangrove
  mid-pack.
- **strap 55.7%** — six files; `rigor-activerecord` correctly degraded with a load-error
  warning (no `db/schema.rb`/`structure.sql` — the app has no DB).

## Issues / lever candidates this sweep suggests

Filed 2026-09-19 (all independent):

- **#1097 (area:plugins)** — rigor-sorbet: type the `sig {…}` DSL calls themselves
  (bundled `T`/`T::Sig` RBS) or exclude them from the precision lens — ~58k opaque sites
  corpus-wide, and the dominant artifact on every Sorbet-typed target.
- **#1098 (area:plugins)** — rigor-mangrove: `Result[…]`/`Option[…]` singleton-subscription
  generic application (~130 mangrove sites).
- **#1099 (area:plugins)** — rigor-grape: new plugin for the Grape endpoint DSL; ~10k
  gitlab implicit-self sites (`expose`/`requires`/`optional`/`route_setting`/`desc`/`params`).
- **#1100 (area:plugins)** — rigor-graphql: type `field`/`argument` DSL call sites (~5k
  gitlab sites); the plugin publishes fact tables but no expression typing, and gitlab's
  config did not enable it. Adjacent to #136 (resolver checks).
- **#1101 (area:engine)** — `Parameters?` (Difference-receiver) dispatch: `present?`/`==`/
  `blank?`/`to_s` on `Parameters − nil` read opaque on mastodon/redmine/gitlab; the next
  layer under the fixed `Parameters#[]`.
- **#1102 (area:plugins)** — `BroadcastLogger#debug/error/warn` + `Cache::Store#fetch/
  delete` RBS surface gaps newly visible on mastodon/redmine.

Deliberately not filed: `Proc#call` opacity (core RBS `(*untyped) -> untyped` — honest
untyped, not a defect), the `Hash[Dynamic]#[]` family (already #531/#542 territory),
`singleton(User)#current` (declined lever), and the GitLab utility-singleton cluster
(mostly resolved-method-untyped-return propagation, the #522 lane).

## What this note does not claim

- Site-level cause assignments were not re-verified with same-file controls this round
  (the 9/1 sweep's verified mechanism map still stands); treat family buckets as
  instrument output.
- hole_scan applies `exclude:` (check semantics); probe_attrib does not (coverage
  semantics) — the two file sets differ marginally on `.`-rooted targets.
- The probe records at most 80 pairs / 3 examples per pair per target — tails beyond
  that live in `*.holes.jsonl` only.
- Parse errors are the targets' own: 15 files corpus-wide (kata repos' Ruby-2.x-era
  syntax, two jbuilder files, one redmine migration).
- Instrument preservation: this report's scripts and raw outputs live in
  `rigor-survey/_reports/typing-holes/`; the scan ran on worktree branch
  `survey-typing-holes` (master `7836b2e7`), provenance recorded per artifact.
