# GitLab protection-coverage survey (2026-07-08)

Type-protection coverage (ADR-63 Tier 1, provenance-wired per ADR-75/82) measured on the freshly onboarded
GitLab survey checkout (`~/repo/ruby/rigor-survey/gitlab`, FOSS tree, config `.rigor.dist.yml`: paths
`[app, lib]`, `ee/` excluded, 10 plugins, lenient profile). Run: `rigor coverage --protection --format json
app lib`, warm `.rigor/cache`, wall clock **~2 h 17 m** (12:20:46 → ~14:37 JST), peak RSS observed ~14.6 GB.
stderr clean — no "RBS environment build failed", no plugin errors, 0 parse errors. Raw JSON:
`~/repo/ruby/rigor-survey/_reports/init/gitlab.coverage.json` (4.9 MB, 11,344 files, 11,959 distinct
unprotected method-name clusters).

Purpose: the DATA for an engine-improvement plan — where the holes are, what causes them, which are
tractable. Companion to the Mastodon/Redmine measurements in
`20260706-mastodon-coverage-provenance-and-siggen-rbs-validity.md`.

## 1. Overall protection ratio

| Scope | Protected | Unprotected | Total | Ratio |
| --- | ---: | ---: | ---: | ---: |
| **app + lib** | 59,554 | 150,420 | 209,974 | **0.2836** |
| app only | 33,160 | 83,018 | 116,178 | 0.2854 |
| lib only | 26,394 | 67,402 | 93,796 | 0.2814 |

Comparators (same metric, post coverage-fidelity fixes): **Mastodon app+lib = 0.3148, Redmine app+lib =
0.339**. GitLab lands **3.1–5.5 pp below** both.

Per top-level directory (sorted by total dispatch sites):

| Directory | Protected | Unprotected | Total | Ratio |
| --- | ---: | ---: | ---: | ---: |
| lib/gitlab | 18,331 | 46,359 | 64,690 | 0.2834 |
| app/services | 9,778 | 24,762 | 34,540 | 0.2831 |
| app/models | 8,717 | 22,059 | 30,776 | 0.2832 |
| lib/(other) | 4,865 | 11,623 | 16,488 | 0.2951 |
| app/controllers | 4,746 | 8,228 | 12,974 | **0.3658** |
| lib/api | 3,198 | 9,420 | 12,618 | 0.2534 |
| app/graphql | 2,976 | 5,948 | 8,924 | 0.3335 |
| app/workers | 2,882 | 4,343 | 7,225 | **0.3989** |
| app/helpers | 1,304 | 5,626 | 6,930 | 0.1882 |
| app/finders | 1,106 | 4,379 | 5,485 | 0.2016 |
| app/(other) | 979 | 2,661 | 3,640 | 0.2690 |
| app/serializers | 236 | 1,935 | 2,171 | 0.1087 |
| app/presenters | 348 | 1,460 | 1,808 | 0.1925 |
| **app/policies** | 88 | 1,617 | 1,705 | **0.0516** |

Spread is instructive: controllers (0.366) and workers (0.399) — the two tiers with dedicated plugin
support (rigor-actionpack, rigor-sidekiq) — are the BEST-protected; the pure-DSL tiers (policies 0.052,
serializers 0.109) are the worst. Plugin coverage visibly moves the number.

## 2. Per-site cause distribution (`cause_site_counts`, exact per-site tally)

| Cause | Sites | % of unprotected |
| --- | ---: | ---: |
| unsupported_syntax | 59,791 | 39.7% |
| inferred_return_untyped | 50,625 | 33.7% |
| none (causeless) | 39,346 | 26.2% |
| explicit_untyped | 655 | 0.4% |
| analyzer_budget_cutoff | 3 | 0.0% |
| external_gem_without_rbs | 0 | 0% |
| framework_dsl_boundary | 0 | 0% |

`tractability_summary`: `{engine_gap: 110,419, add_rbs: 655}` — i.e. **99.4% of classified holes route to
engine_gap**, 0.6% to add_rbs, none to enable_plugin. Provenance completeness = 73.8% (causeless 26.2%,
vs Mastodon's post-WD8 26%). The two user-actionable causes fire on ZERO sites, exactly the ADR-82 G2
pattern: `framework_dsl_boundary` is only recorded when a plugin returns Dynamic (plugins return concrete
or nothing), and `external_gem_without_rbs` needs opt-in ADR-10 — with 806 locked gems and no
rbs_collection, none of the gem-sourced dynamism is attributed to gems. The `add_rbs` axis is bought
entirely by `explicit_untyped` (Sorbet-style `T.untyped` regions via rigor-sorbet, presumably).

## 3. Top unprotected method-name clusters (top 25 = 57,952 sites = 38.5% of holes)

| # | Method | Sites | Dominant origin |
| ---: | --- | ---: | --- |
| 1 | `[]` | 18,404 | unsupported_syntax |
| 2 | `id` | 4,075 | inferred_return_untyped |
| 3 | `==` | 3,589 | inferred_return_untyped |
| 4 | `present?` | 3,209 | inferred_return_untyped |
| 5 | `to_s` | 2,232 | inferred_return_untyped |
| 6 | `map` | 2,124 | inferred_return_untyped |
| 7 | `!` | 1,988 | unsupported_syntax |
| 8 | `[]=` | 1,863 | inferred_return_untyped |
| 9 | `each` | 1,721 | inferred_return_untyped |
| 10 | `is_a?` | 1,634 | inferred_return_untyped |
| 11 | `project` | 1,624 | inferred_return_untyped |
| 12 | `name` | 1,525 | inferred_return_untyped |
| 13 | `where` | 1,427 | unsupported_syntax |
| 14 | `nil?` | 1,392 | inferred_return_untyped |
| 15 | `new` | 1,385 | unsupported_syntax |
| 16 | `blank?` | 1,210 | inferred_return_untyped |
| 17 | `select` | 1,126 | unsupported_syntax |
| 18 | `merge` | 1,039 | unsupported_syntax |
| 19 | `to_i` | 966 | inferred_return_untyped |
| 20 | `first` | 961 | unsupported_syntax |
| 21 | `include?` | 924 | unsupported_syntax |
| 22 | `empty?` | 921 | inferred_return_untyped |
| 23 | `+` | 913 | unsupported_syntax |
| 24 | `any?` | 854 | unsupported_syntax |
| 25 | `fetch` | 846 | inferred_return_untyped |

Shape matches Mastodon: universal-vocabulary methods on Dynamic receivers, dominated by `[]` (12.2% of
ALL holes by itself — options-hash / params / config-subscript idioms). AR-vocabulary clusters (`where`
1,427, `find` 423, `exists?` 341, `find_by` 133, `includes` 104, `find_each` 105, `preload` 92, `not` 268)
sum to ~3,000 directly attributable to the inert AR plugin (§4.5). Domain readers `project` (1,624), `id`
(4,075), `name` (1,525), `user` (413), `group` (522), `current_user` (202) are the cross-model-boundary
holes ADR-58/67 target.

## 4. GitLab-idiom sampling (12 sites, verdicts)

1. **`Feature.enabled?`** — `app/controllers/activity_pub/application_controller.rb:26`
   `::Feature.enabled?(:activity_pub)`. `Feature` IS in the analyzed tree (`lib/feature.rb`), the method
   is defined under `class << self` (line 95, `def enabled?` line 141). Unprotected, unsupported_syntax.
   **Verdict: module-singleton (`class << self` / `def self.x`) resolution gap — the ADR-57 named future
   slice.** The `enabled?` cluster alone is 619 sites (+ `disabled?` 76); this one engine slice would
   protect GitLab's single most pervasive idiom.
2. **`declarative_policy` conditions** — `app/policies/project_policy.rb` (ratio **0.039**, 319/332
   unprotected; app/policies overall 0.0516). `condition(:guest) { team_member? }`,
   `user&.project_bot?`, `project.public_builds?` — everything inside `condition`/`rule` blocks runs
   against DSL-provided `user`/`project`/`subject` readers from the DeclarativePolicy gem (no RBS).
   **Verdict: pure DSL boundary, zero `framework_dsl_boundary` attribution (ADR-82 G2/WD4). Needs a
   rigor-declarative-policy plugin (or ADR-16 substrate declaration) to type `user`/`subject`.**
3. **`can?` ability checks** — `app/controllers/concerns/authenticates_with_two_factor.rb:22`
   `user.can?(:log_in)`: `user` is an untyped method param. **Verdict: ADR-67 param inference gap
   (call-site seeding), not a policy-DSL gap per se; 343 unprotected `can?` sites.**
4. **AR relations on params** — `app/controllers/concerns/group_tree.rb:40`
   `groups.where(parent_id: safe_params[:parent_id])`: `groups` is an untyped param; even with a typed
   param the relation vocabulary needs the AR plugin. **Verdict: compound ADR-67 + AR-inert hole.**
5. **AR model constants** — `app/controllers/abuse_reports_controller.rb:60` `User.find_by(id: …)`,
   worker sample `User.where(id: range).find_each` — project model constants type Dynamic (the known
   ADR-52 blocker: discovered classes lack Singleton typing) AND the AR plugin is **inert**: stderr
   confirms `plugin.activerecord.load-error: schema file db/schema.rb not found; AR call checks skipped`
   (GitLab ships only `db/structure.sql`). **Verdict: AR plugin inert as expected — supporting
   structure.sql (or a schema-dump fallback) is a prerequisite for any AR-tier win on GitLab.**
6. **Strong params chain** — `app/controllers/abuse_reports_controller.rb:54`
   `params.require(:abuse_report).permit(…)`. rigor-actionpack types `params →
   ActionController::Parameters` and the `params`/`require` dispatches ARE protected (`require` cluster:
   only 2 unprotected sites project-wide; the 70 unprotected `params` sites are all ActionCable
   channels/route constraints where the plugin doesn't apply). But `require`'s RETURN is untyped (no
   Parameters RBS), so `.permit` is unprotected (108 sites). **Verdict: rigor-actionpack verified working
   one link deep; the chain-return gap is a one-line plugin `dynamic_return` for `require`→Parameters.**
7. **`Gitlab::Utils.to_boolean`** — `app/controllers/chaos_controller.rb:90`. `Gitlab::Utils` lives in
   the monorepo-local gem `gems/gitlab-utils/` — OUTSIDE the analyzed `[app, lib]` paths. 144
   unprotected `to_boolean` sites. **Verdict: monorepo-local gems (`gems/*`, 30+ of them) are invisible;
   they are project code that paths-scoping excludes. Cheap config fix: add `gems/*/lib` to paths (or an
   ADR-10 dependency-source entry); no engine work needed.**
8. **`strong_memoize`** — `app/models/merge_request.rb:1176` `strong_memoize(:discussions_diffs) do …`.
   Defined in `gems/gitlab-utils` (same hole as #7): the block-form call is unresolved → its return
   untyped → consumers untyped. The `strong_memoize_attr :name` post-hoc form is benign (the plain `def`
   above it still resolves and infers). **Verdict: block form = real hole, attr form = already fine;
   fixed for free by #7's paths fix (implicit-self resolution through an included module then applies).**
9. **ActionCable channels** — `app/channels/application_cable/connection.rb:29`
   `cookies[Gitlab::Application.config.session_options[:key]]`: `cookies`, `request`, `params` in
   channels/connections have no plugin coverage (rigor-actionpack covers controllers). **Verdict:
   ActionCable is an uncovered Rails surface; small site count, low priority.**
10. **Service-object `execute`** — `app/controllers/concerns/boards_actions.rb:16`
    `board_create_service.execute.payload[:board]`: receiver is an implicit-self reader returning a
    service instance; 417 unprotected `execute` sites. **Verdict: chain-origin case — the receiver
    resolves but its inferred return goes Dynamic (ctor param flow, ADR-67); GitLab's
    ServiceResponse-based idiom would reward `execute → ServiceResponse` typing (plugin or ADR-67 WD3).**
11. **Sidekiq perform args** — `app/workers/authorized_project_update/user_refresh_over_user_range_worker.rb:26`
    `def perform(start_user_id, end_user_id)` — untyped params, but workers are the BEST-protected
    directory (0.3989) and only 13 `perform_async` + 3 `perform_in` sites are unprotected. **Verdict:
    rigor-sidekiq protects the enqueue side well; perform-arg typing is ordinary ADR-67 territory.**
12. **ViewComponent helpers** — `app/components/pajamas/avatar_component.rb:49` `helpers.current_user`:
    `helpers` returns untyped (ViewComponent gem, no RBS); 202 unprotected `current_user` sites cluster
    in components. **Verdict: external-gem hole mislabeled unsupported_syntax (the zero-firing
    `external_gem_without_rbs` again).**

## 5. Delta vs Mastodon (0.3148) / Redmine (0.339): ranked drivers

GitLab at 0.2836 is 3.1 pp under Mastodon. Grounded in the samples above, ranked by evidenced weight:

1. **AR plugin inert** (structure.sql-only, `plugin.activerecord.load-error`): ~3,000 direct
   AR-vocabulary holes (§3) plus every downstream chain rooted on a relation/model read. Mastodon and
   Redmine both had a live schema.rb → live AR plugin. Largest single delta driver.
2. **Model constants Dynamic + `class << self` singletons**: `Feature.enabled?` (619+76),
   `Gitlab::Utils.*`, model `.find/.where` — GitLab's house style routes far more traffic through
   module-singleton facades than Mastodon does (samples 1, 5, 7).
3. **DSL-heavy tiers with no plugin**: policies 0.0516 (1,617 holes), serializers 0.1087 (1,935),
   finders 0.2016 (4,379), GraphQL 0.3335 — declarative_policy / grape-entity-style serializers /
   finder framework are all GitLab-specific frameworks Rigor has no plugin for (sample 2). Redmine's
   plainer Rails style has no equivalent mass.
4. **Monorepo-local `gems/*` excluded from paths**: strong_memoize, Gitlab::Utils, and 30+ sibling gems
   are first-party code the `[app, lib]` scoping hides (samples 7, 8). Unique to GitLab's layout;
   cheapest fix available (config, not engine).
5. **806 locked gems, no RBS collection**: grape (lib/api at 0.2534), ViewComponent (sample 12),
   gitaly-client protobufs — plain external-gem dynamism, invisible in attribution because
   `external_gem_without_rbs` never fires. Mastodon shares this driver but with a smaller gem surface.
6. **`prepend_mod` EE injection**: present (e.g. `Project.prepend_mod_with('Project')`) but on this FOSS
   checkout the EE modules don't exist, so it is an unresolved-call root, not a mass mislabeler — NOT a
   major driver at this scoping (no sampled chain rooted on it).

## 6. Engine-plan implications (data, not commitments)

- **Module-singleton resolution (ADR-57 future slice)** has a named, countable GitLab payoff:
  `Feature.enabled?/disabled?` 695 sites + the `Gitlab::Utils`/facade family; likely the highest
  engine-work-to-sites ratio observed on this corpus.
- **AR-plugin structure.sql support** is the top plugin-work item; without it every AR comparison with
  Mastodon/Redmine is structurally unfair to GitLab.
- **ADR-82 G2 stands unfixed on a second corpus**: both user-actionable causes fired zero on 150k holes.
  Tractability labels remain uninformative for real-app users until gem/DSL attribution is recorded
  (ADR-82 WD4 per-plugin follow-up + an `external_gem_without_rbs` recording tier that doesn't require
  opt-in ADR-10).
- **Onboarding guidance**: for monorepos with local `gems/*`, `rigor-project-init` should propose adding
  them to `paths` — pure config, immediately recovers first-party utility typing.
- Provenance completeness (73.8%) matches Mastodon post-WD8 (~74%) — ADR-82's wiring generalizes; the
  residual causeless bucket is the same yield/super/block + cvar/gvar floor.

## Appendix: top-10 files by unprotected sites

| Unprotected | Total | Ratio | File |
| ---: | ---: | ---: | --- |
| 1,157 | 1,504 | 0.231 | app/models/project.rb |
| 924 | 1,200 | 0.230 | app/models/merge_request.rb |
| 783 | 1,104 | 0.291 | app/models/user.rb |
| 596 | 807 | 0.262 | app/models/ci/pipeline.rb |
| 493 | 638 | 0.227 | app/models/ci/build.rb |
| 440 | 542 | 0.188 | app/services/notification_service.rb |
| 370 | 470 | 0.213 | lib/gitlab/gitaly_client/commit_service.rb |
| 355 | 449 | 0.209 | app/models/repository.rb |
| 350 | 461 | 0.241 | app/models/group.rb |
| 343 | 473 | 0.275 | app/models/merge_request_diff.rb |

Run metadata: rigor branch `cache/schema-marker-and-compaction-hardening` @ 0f566a87; GitLab checkout as
onboarded 2026-07-08; command `rigor coverage --protection --format json app lib`, warm cache, single
process. `analyzer_budget_cutoff` fired on exactly 3 sites project-wide.
