# GitLab survey: type-coverage improvement plan

Synthesized 2026-07-08 from the GitLab (app+lib, 11,344 files) onboarding arc. Inputs, both audited
(one adjudication overturned on challenge and corrected against actionpack source):

- [`20260708-gitlab-protection-coverage-survey.md`](20260708-gitlab-protection-coverage-survey.md) —
  protection **0.2836** (59,554/209,974; Mastodon 0.3148, Redmine 0.339), per-site cause distribution,
  idiom sampling.
- [`20260708-gitlab-diagnostic-adjudication.md`](20260708-gitlab-diagnostic-adjudication.md) —
  289 errors + 238 warnings clustered and sampled: **2 genuine bugs**, the rest dominated by four
  systematic FP mechanisms.
- Onboarding facts: acknowledge mode, lenient, 10 plugins (0 load errors), baseline 1,255 buckets /
  3,909 diagnostics, final check clean. Artifacts in `~/repo/ruby/rigor-survey/gitlab` (untracked) +
  `_reports/init/gitlab.*`.

GitLab reproduces the Mastodon/Redmine structural picture (coverage is engine/plugin-bound, not
sig-closable; `tractability_summary` = 99.4 % engine_gap) and adds four NEW, actionable levers the
smaller corpora could not surface. Ranked below by (site impact × generality) / (cost × FP risk).

## P0 — cheap, FP-reducing, precision-additive (each a small corpus-gated slice)

1. **rigor-rails-routes: model Rails' route-name composition exactly.**
   The plugin computes helper names with member-style ordering + singularization; Rails'
   `name_for_action` / `Mapper.normalize_name` / `Scope#action_name` (actionpack
   `routing/mapper.rb:2070/407/2476`) produce different names for (a) multi-segment string paths in
   `collection do get 'granular/new' end` blocks and (b) `scope(as:)` + bare-`get` composition.
   Today this fires FP `unknown-helper` on working code — the two sites the adjudication initially
   mis-verdicted as genuine bugs are exactly this gap. ~91 of 159 `unknown-helper` firings are
   name-composition FPs (the other 68 are grape, P2). Fix = port the three mapper functions'
   naming logic; gate on GitLab + Redmine + Mastodon route corpora, zero new firings.
2. **rigor-actionpack: type `Parameters#require` / `#permit` returns.**
   `params` is protected (plugin verified working on GitLab), but `params.require(:x)` returns
   untyped so the chained `.permit` site leaks — 108 sites. Extend the existing `dynamic_return`
   to `require`/`permit` returning `ActionController::Parameters` (lenient-nominal, same
   FP-zero pattern as the landed request-context readers).
3. **activesupport-core-ext overlay gaps** (~18 residual sites/firings): `advance`, `titlecase`,
   `all_day`, `dasherize`, `Time#to_time(form)`, `ERB::Util#html_escape_once`. Additive RBS
   entries to the plugin bundle + the ADR-72 `data/gem_overlay/activesupport` twin.
4. **core_overlay entries** for stdlib RBS lag (ADR-79 mechanism): `Psych.parse`,
   `CSV::MalformedCSVError.new(message, line)` arity. Same shape as the landed
   `StringScanner#peek_byte` fix.

## P1 — the big single lever

5. **rigor-activerecord: accept `db/structure.sql` as a schema source.**
   GitLab commits structure.sql (+ `ci_structure.sql`, `sec_structure.sql`) and no `schema.rb`
   → the plugin is INERT (`plugin.activerecord.load-error`), zeroing all model-column typing:
   ~3,000 direct AR-vocabulary holes (`where`/`find`/`exists?`…), the downstream Dynamic chains
   behind them, AND a ~42-site FP cascade (relations misinferred to `Array[String]`, producing
   `activerecord-relation-misinference` hint noise, `Array#from`/`#with` collisions,
   `use_unnested_filters! for Integer`). Any Rails app with `schema_format = :sql` is inert today —
   this is the redmine-O1 class generalized, and unlike Redmine (no committed schema at all) the
   data IS in the repo. Implementation: parse `CREATE TABLE` column/type pairs from the PG DDL
   (line-oriented, no SQL parser dependency); accept multiple `db/*structure.sql`. Gate: GitLab
   corpus diff (expect the 42-FP cascade to vanish + coverage re-measure), Mastodon/Redmine
   byte-identical (they don't use structure.sql).

## P2 — engine slices (bigger, sequenced after P0/P1 re-measure)

6. **Module-singleton facade resolution** (`class << self` / `def self.x` on modules).
   ADR-57 explicitly deferred this as an independent slice; GitLab quantifies the demand:
   `Feature.enabled?` alone = 695 unprotected sites (`module Feature` + `class << self` at
   `lib/feature.rb:95`), plus the `Gitlab::Utils.*` family. Engine-general — benefits every
   corpus. Follow the ADR-57 adoption-gate protocol (open per adjudicated firing class).
7. **Provenance: label external-gem holes at the RBS-coverage boundary** (ADR-82 follow-up).
   Second corpus reproducing `external_gem_without_rbs = 0` / `framework_dsl_boundary = 0`
   while 806 lockfile gems ship no RBS. When a dispatch's receiver class is owned by an
   RBS-less locked gem (`RbsCoverageReport` already knows the set), record the external-gem
   cause instead of the generic fallback — turns some of the 39.7 % `unsupported_syntax` +
   26.2 % `none` into the one bucket users can act on (`add_rbs`), on a corpus where that
   answer is actually true. Honesty criterion per ADR-82: record only when ownership is sound.
8. **grape-path-helpers support** (68 sites, 43 % of unknown-helper): model the gem's
   `api_v4_*` helper-name generation over grape route files. Public-gem coverage (not
   GitLab-private), but grape-specific walker work — demand-gated behind P0 item 1.

## P3 — survey-config + tooling follow-ups

9. **Survey config: include GitLab's monorepo-local `gems/*`** (source of `Gitlab::Utils`,
   `strong_memoize` block form misses) and re-measure; fold "detect path-sourced local gems in
   the Gemfile and offer their `lib/` into `paths:`" into the rigor-project-init skill.
10. **`rigor coverage` operational fixes**: (a) requires explicit PATH args where `check`
    defaults to config `paths:` — align; (b) wall 2 h 17 m / 14.6 GB RSS vs check's 39 min /
    7.3 GB on the same tree — the protection scan lacks check's fork-pool parallelism; (c)
    `baseline generate` appeared to re-run cold despite a warm run cache (init-agent
    observation, possibly self-inflicted by a concurrent double-launch — verify cache
    participation before treating as a bug).
11. **Triage `genuine-bugs` hint recalibration** (ADR-23 follow-up): measured precision 2/11
    (18 %) — all signal from `def.ivar-write-mismatch` (2/2), zero from
    `argument-type-mismatch` / `rails-routes.wrong-arity` sub-populations whose FP mechanisms
    are systematic (P0 items 1–2 fix the causes; re-measure after).

## Deferred (recorded, not planned)

- **DSL-tier plugins** (declarative_policy 0.052, serializers 0.109, GraphQL types): public
  gems, but heavy walker work; revisit after P1/P2 re-measure shows the residual.
- **`ee/` slice** and the `prepend_mod` EE-injection pattern (present but not a major driver
  at app+lib scoping).
- **`Hash#[] → V?` mass** (18,404 `[]` holes + ~200 possible-nil diagnostics): inherent to the
  RBS element type; concrete-shape key-presence narrowing is already landed; the residual
  rides on ADR-58/67, and ADR-67 WD2 stays deferred per the 2026-07-06 spike.
- **Two genuine GitLab bugs** (upstream-reportable, not Rigor work):
  `lib/system_check/incoming_email/imap_authentication_check.rb:39` — `@error` carries a
  String on the config-missing path but the reporter calls `@error.message`, so the diagnostic
  crashes exactly when needed; `lib/uploaded_file.rb:42` — `@upload_duration` Integer/Float
  inconsistency (cosmetic).

## Sequencing & gates

P0 items are independent small slices, each gated on zero-new-firings across the standing
corpus set (GitLab now joins it — warm re-check is 12.7 s over the baseline). P1 lands next
and triggers a full GitLab coverage re-measure (expect: 42-FP cascade gone, AR vocabulary
clusters shrink, protection > 0.30). P2 items 6–7 are engine slices with their own
ADR-protocol gates; 8–11 ride demand. The plan deliberately front-loads FP *removal* (P0-1,
P1's cascade) before precision *addition* — same ordering discipline as ADR-58/78.
