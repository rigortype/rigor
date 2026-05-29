# rigor-survey project-init baseline sweep — 2026-05-29

Immediate post-`rigor-project-init` snapshot of every project in
`~/repo/ruby/rigor-survey/`, captured with `rigortype` **0.1.14**.

The goal is to see **what `rigor check` surfaces the moment a project is
onboarded, before any baseline or `pre_eval:` tuning** — i.e. the raw set
of `undefined-method` / `possible-nil-receiver` / flow problems Rigor can
"collect" (回収) on a cold project. This is deliberately the *un-reduced*
state: no `.rigor-baseline.yml` was generated, so nothing is suppressed.

## Method

A single driver (`_reports/init/run-init.sh`, run inside the Flake shell)
did, for each project:

1. **Reset** — remove any prior `.rigor.dist.yml` / `.rigor.yml` /
   `.rigor-baseline.yml` / `.rigor/` cache. (The previously tuned mastodon
   and redmine configs were backed up to `_reports/init/_backup/` first.)
2. **Write a fresh `.rigor.dist.yml`** per the project-init workflow:
   - `paths:` = `lib` for libraries (`ruby/lib` for protobuf, `app`+`lib`
     for the two Rails apps), `exclude: [vendor, tmp]`.
   - `target_ruby:` from `.ruby-version` where declared.
   - Local `sig/` wired via `signature_paths:` when present (herb, redmine).
   - **Plugins only for the two genuine Rails apps** (mastodon, redmine):
     the Rails set + `rigor-activesupport-core-ext`, `severity_profile:
     lenient`. Every other project is plain Ruby → no plugins, default
     (`balanced`) profile. This keeps the library signal raw rather than
     pre-filtering it through plugin RBS.
3. **Capture** raw `rigor check` (`_reports/init/<proj>.check.txt`) and
   `rigor triage --format json` (`_reports/init/<proj>.triage.json`).

Aggregated by `_reports/init/aggregate.rb`.

> **Note — no baseline / no `pre_eval:`.** A real onboarding (Phase 6a/7)
> would add `pre_eval:` for proven monkey-patch sites and snapshot the rest
> into a baseline. The redmine and mastodon numbers below are therefore the
> *inflated cold* numbers; the previously-tuned redmine config (with
> `pre_eval:` + baseline) brought its surfaced count to a small fraction of
> the 4101 shown here.

## Per-project results

| Project | Files | Total | Err | Warn | Info | Top rules | Triage hints |
| --- | --: | --: | --: | --: | --: | --- | --- |
| algorithms | 14 | 37 | 33 | 3 | 1 | possible-nil-receiver:33, always-truthy:3 | systemic-file-cluster, genuine-bugs×3 |
| concurrent-ruby | 178 | 13 | 10 | 3 | 0 | possible-nil-receiver:4, undefined-method:3, arg-type-mismatch:2 | genuine-bugs×13 |
| erubi | 3 | 3 | 3 | 0 | 0 | possible-nil-receiver:2, undefined-method:1 | genuine-bugs×3 |
| faraday | 33 | 8 | 8 | 0 | 0 | undefined-method:5, possible-nil-receiver:3 | genuine-bugs×8 |
| haml | 51 | 12 | 10 | 2 | 0 | possible-nil-receiver:5, undefined-method:5 | activesupport-core-ext, unresolved-toplevel, genuine-bugs×8 |
| hamlit | 61 | 14 | 13 | 1 | 0 | possible-nil-receiver:10, undefined-method:3 | activesupport-core-ext, genuine-bugs×1 |
| herb | 42 | 11 | 6 | 4 | 1 | undefined-method:5, unresolved-toplevel:2, return-type-mismatch:2 | gem-without-rbs, unresolved-toplevel, genuine-bugs×8 |
| jbuilder | 14 | 3 | 1 | 2 | 0 | ivar-write-mismatch:2, undefined-method:1 | activesupport-core-ext, genuine-bugs×2 |
| kramdown | 55 | 14 | 12 | 2 | 0 | undefined-method:8, possible-nil-receiver:4 | genuine-bugs×6 |
| liquid | 64 | 13 | 10 | 3 | 0 | undefined-method:7, possible-nil-receiver:3 | genuine-bugs×6 |
| mail | 111 | 20 | 5 | 15 | 0 | unreachable-branch:11, possible-nil-receiver:4 | genuine-bugs×9 |
| **mastodon** | 1219 | 1920 | **3** | 23 | 1894 | activerecord.model-call:555, actionpack.filter-call:527, routes.helper:350, i18n.translation:233 | systemic-file-cluster, genuine-bugs×10 |
| net-ssh | 97 | 27 | 13 | 14 | 0 | always-truthy:11, possible-nil-receiver:6, undefined-method:5 | genuine-bugs×10 |
| numo-narray | 2 | 6 | 5 | 1 | 0 | possible-nil-receiver:5, always-truthy:1 | genuine-bugs×6 |
| oj | 11 | 5 | 5 | 0 | 0 | undefined-method:3, possible-nil-receiver:2 | genuine-bugs×5 |
| ox | 15 | 12 | 12 | 0 | 0 | possible-nil-receiver:10, arg-type-mismatch:2 | systemic-file-cluster, genuine-bugs×2 |
| parser | 56 | 7 | 3 | 4 | 0 | always-truthy:4, possible-nil-receiver:3 | genuine-bugs×7 |
| protobuf | 24 | 16 | 16 | 0 | 0 | undefined-method:13, possible-nil-receiver:2, wrong-arity:1 | systemic-file-cluster, genuine-bugs×6 |
| pycall | 22 | 10 | 0 | 10 | 0 | unresolved-toplevel:10 | unresolved-toplevel×10 |
| **rbnacl** | 37 | **0** | 0 | 0 | 0 | — | (clean) |
| **redmine** | 331 | 4101 | **3352** | 31 | 718 | undefined-method:3319, routes.helper:313, actionpack.helper:180 | project-monkey-patch×1665, systemic-file-cluster×103 |
| **rgl** | 28 | **0** | 0 | 0 | 0 | — | (clean) |
| rubocop-ast | 99 | 4 | 1 | 3 | 0 | always-truthy:2, undefined-method:1, ivar-write:1 | genuine-bugs×4 |
| slim | 27 | 7 | 3 | 4 | 0 | undefined-method:2, ivar-write-mismatch:2 | genuine-bugs×7 |
| tdiary-core | 69 | 248 | 5 | 242 | 1 | unresolved-toplevel:234, possible-nil-receiver:4 | unresolved-toplevel×234, genuine-bugs×13 |

## Corpus-wide rule distribution

| Rule | Total |
| --- | --: |
| call.undefined-method | 3384 |
| plugin.actionpack.filter-call | 684 |
| plugin.rails-routes.helper | 663 |
| plugin.activerecord.model-call | 555 |
| plugin.actionpack.helper-call | 398 |
| plugin.rails-i18n.translation-call | 258 |
| call.unresolved-toplevel | 247 |
| call.possible-nil-receiver | 141 |
| flow.always-truthy-condition | 67 |
| call.wrong-arity | 28 |
| flow.dead-assignment | 24 |
| flow.unreachable-branch | 11 |
| plugin.rails-routes.unknown-helper | 11 |
| def.return-type-mismatch | 10 |
| call.argument-type-mismatch | 9 |
| def.ivar-write-mismatch | 8 |
| plugin.actionmailer.mailer-call | 7 |
| rbs.coverage.missing-gem | 4 |
| plugin.actionmailer.missing-view | 1 |
| plugin.activerecord.load-error | 1 |

The `call.undefined-method` total (3384) is **97% redmine** (3319). Strip
the two Rails apps and the library corpus is small and tractable: a couple
hundred diagnostics across 23 libraries, mostly `possible-nil-receiver`,
`undefined-method`, and flow warnings.

## What the numbers mean — signal vs. onboarding noise

The raw totals split cleanly into three buckets.

### 1. Onboarding noise that a real init would clear (the big numbers)

- **redmine — 3319 `undefined-method` / 1665 `project-monkey-patch`.**
  Almost entirely Redmine reopening core/stdlib/model classes and adding
  methods cross-file: `User.current`, `Mailer.deliver_*`,
  `Setting.lost_password?`, `Token.find_token`, `User.find_by_mail`, …
  These are exactly the sites the *previously tuned* redmine config listed
  in `pre_eval:` (and snapshotted into its baseline). Triage's
  `project-monkey-patch` hint (count 1665) flags this correctly. **This is
  the cold number; Phase 6a `pre_eval:` collapses it.**
- **mastodon — 1894 `info`, only 3 `error`.** The bulk is *informational*
  plugin recognition: `plugin.activerecord.model-call` (555),
  `plugin.actionpack.filter-call` (527), `plugin.rails-routes.helper`
  (350), `plugin.rails-i18n.translation-call` (233). These are Rigor
  *recognising* Rails DSL calls, not flagging bugs. **mastodon's actual
  error count is 3** (below).
- **tdiary-core / pycall — `unresolved-toplevel` (234 / 10).** tdiary's
  plugin system defines helpers (`h`, `to_native`, `bot?`) as toplevel /
  Kernel methods consumed across plugin files; pycall's `iruby_helper`
  calls `register_python_object_formatter`. ADR-34's diagnostic fires
  exactly as designed and the message already points at the fix
  (`pre_eval:` per ADR-17). All warnings under `balanced`.

### 2. The "genuine-bugs" hint — the library review pile

Every library got a `genuine-bugs` hint (low-count, scattered rules). The
recurring shapes:

- **`call.possible-nil-receiver`** — the single most common *library*
  finding (algorithms 33, ox 10, hamlit 10, numo-narray 5). Per
  [`feedback_false_positive_discipline`], most are worst-case-sound `T |
  nil` reads on code the test suite proves safe — baseline material, not
  forced fixes. A minority (e.g. `ox/element.rb` comparison chain on a
  nilable index) are worth a human look.
- **`call.undefined-method` on stdlib / native receivers** — largely **RBS
  coverage gaps**, not bugs:
  - `oj`: `from_state` on `singleton(JSON::Ext::Generator::State)` (native).
  - `faraday`: `find_proxy` on `URI`, `options_for` / `member_set` on `Class`.
  - `protobuf`: `to_i` / `to_f` on `Numeric` (×13 — the abstract `Numeric`
    has no `to_i`; the value is concretely Integer/Float at runtime).
  - `erubi`: `escapeHTML` on `Object` (CGI mixed in).
  - `rubocop-ast`: `union_bind` on `Binding`.
  - `mastodon`: `exchange` on `Resolv::DNS::Resource`.
  These point at missing built-in/stdlib RBS coverage or native-ext
  methods — candidates for `rigor-builtin-import` work, not project bugs.
- **flow warnings** (`always-truthy/falsey`, `dead-assignment`,
  `unreachable-branch`) — mail's 11 `unreachable-branch`, net-ssh's 11
  `always-truthy`. Usually redundant guards / defensive dead code; low
  severity, occasionally a real logic smell.
- **`def.ivar-write-mismatch`** (concurrent-ruby `@backend`
  Concurrent::Hash→Hash; rubocop-ast `@cur_index` Symbol→Integer) — ivar
  reassigned with a different type; mild consistency findings.

### 3. The genuinely clean projects

**rbnacl, rgl** report **zero** diagnostics; **pycall** has zero errors
(only toplevel warnings). Notably rgl previously (May-19 survey, pre-0.1.14)
reported 2 `undefined-method on Object` for implicit-self calls — those are
now silenced by ADR-24 self-method-call resolution. A concrete precision
win visible in the corpus.

## Highest-value follow-ups (actionable "undefined" findings)

After discarding onboarding noise, the diagnostics most worth a human pass:

1. **mastodon's 3 real errors** — `medium_player_url` route helper unknown
   (×2, `plugin.rails-routes.unknown-helper`) and `Resolv::DNS::Resource#exchange`
   (RBS gap). The route-helper one is the only thing in 1219 files that
   looks like a possible app-level issue (dynamic/removed route).
2. **herb** — `undefined-method` for `Herb.diff` / `Herb.leak_check` /
   `Herb.arena_stats` (singleton(Herb)) and `Herb::AST::Node#tag_opening`;
   plus 2 `def.return-type-mismatch`. herb ships its own `sig/`, so these
   are sig-completeness gaps in the project's own RBS — a `rigor sig-gen`
   pass would close them.
3. **Library `possible-nil-receiver` clusters** (ox, numo-narray,
   algorithms) — review the nilable-index/`shape` chains; most baseline,
   some may be real.
4. **RBS-coverage `undefined-method`** (oj, faraday, protobuf, erubi,
   rubocop-ast) — feed into core/stdlib RBS coverage (`Numeric#to_i`,
   `URI#find_proxy`, `Binding`, CGI `escapeHTML`), not project fixes.

## Cold vs. `pre_eval:`-tuned init — the two Rails apps

Following up on the cold numbers: what does the *proper* Phase-6a init
(act on the `project-monkey-patch` hint by adding the named def sites to
`pre_eval:`) actually buy? Captured as `_reports/init/<proj>.tuned.*` via
`run-tuned-rails.sh`.

| App | | total | error | warn | info | undefined-method |
| --- | --- | --: | --: | --: | --: | --: |
| redmine | cold | 4101 | 3352 | 31 | 718 | 3319 |
| redmine | **+pre_eval** | **3488** | **2739** | 31 | 718 | **2706** |
| mastodon | cold | 1920 | 3 | 23 | 1894 | 1 |
| mastodon | **+pre_eval** | 1920 | 3 | 23 | 1894 | 1 |

### redmine — `pre_eval:` clears the *statically-defined* patches only (−613)

`pre_eval:` listed the six files triage's hint pointed at
(`app/models/{user,setting,mailer,token}.rb`,
`lib/redmine/{configuration,twofa}.rb`). Result: **−613 `undefined-method`**
(3319 → 2706), and the `project-monkey-patch` hint shrank 1665 → 1108.

What cleared vs. what stayed, by receiver:

- **Cleared — `User.current` (486 → 0).** Defined as a literal
  `def self.current` in `user.rb`; the `pre_eval:` walker sees it and every
  caller resolves. This single cluster is ~80% of the reduction. Same for
  `Mailer.deliver_*`, `Token.find_*`, `Redmine::Configuration[]`.
- **Did NOT clear — `Setting.default_language` / `app_title` / … (still
  ~20/18 each).** `Setting` exposes its accessors through `method_missing`,
  not static `def`s — so walking the file pre-pass finds nothing to
  register. **This is the escalation-path-A boundary:** `method_missing`
  DSLs need a *project plugin*, not `pre_eval:`.
- **Did NOT clear — `table_name` / `where` / `visible` / scopes on model
  singletons (`table_name` alone ≈ 470 across Issue/Project/TimeEntry/…).**
  These are ActiveRecord *class* methods; `rigor-activerecord` does not
  currently supply them on `singleton(Model)`. Not a monkey-patch — a
  plugin/RBS coverage gap. **This is the dominant residue** and the real
  reason redmine stays four-figure after `pre_eval:`.
- **Did NOT clear — `SetFontStyle` / `RDMCell` / `ln` on
  `Redmine::Export::PDF::ITCPDF`.** A subclass of the RBS-less `rbpdf`/TCPDF
  gem → `gem-without-rbs`.

So the honest reading: `pre_eval:` is the right tool for the **proven,
statically-defined** monkey-patch cluster (and removes it cleanly), but on
redmine that is a *minority* of the cold count. The majority is
ActiveRecord class-method coverage + a `method_missing` DSL + an RBS-less
PDF gem — which the acknowledge-mode workflow routes into the **baseline**
(the prior tuned redmine config did exactly that: `pre_eval:` + a ~37 KB
baseline drove the *surfaced* count to near zero). `pre_eval:` shrinks the
baseline; it does not replace it.

### mastodon — `pre_eval:` is a no-op (already at the floor)

Identical before and after, to the diagnostic. Triage reported **no**
`project-monkey-patch` hint for mastodon, so there were no def sites to
register. Its 1894 `info` are `plugin.*` Rails-DSL *recognitions* (not
errors), and the real surface is 3 errors + 23 warnings — already minimal.
A faithful init for mastodon adds no `pre_eval:`; the lever there would be
`rbs collection install` for the 325 RBS-less gems (shrinks the `info`
recognition noise), not monkey-patch registration.

### Takeaway

The `pre_eval:` step pays off **in proportion to how much of a project's
"undefined" surface is statically-defined in-project reopening** — large
for redmine's `User.current`-style patches, zero for mastodon. It does not
touch `method_missing` DSLs (→ project plugin), ActiveRecord class-method
gaps (→ plugin/RBS coverage), or RBS-less gems (→ `rbs collection install`
/ `source_inference:`). In acknowledge mode the residue is baseline
material; `pre_eval:` simply makes that baseline smaller and more honest.

## Caveats

- **Cold numbers.** No `pre_eval:` and no baseline. redmine/mastodon totals
  reflect un-onboarded state; the per-family analysis above is the honest
  signal once that's accounted for.
- **Library plugins intentionally omitted.** Several libraries depend on
  ActiveSupport (jbuilder, haml, hamlit, mail) and triage flagged
  `activesupport-core-ext` for them; adding that plugin would shrink a few
  `undefined-method` counts. Left off here to keep the raw-core signal.
- **0.1.14 snapshot.** Re-running on a later engine will drift (cf. the rgl
  ADR-24 win). The captures live under `_reports/init/` for diffing.
- Backups of the prior tuned configs: `_reports/init/_backup/`.
