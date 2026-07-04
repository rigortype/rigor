# Research & Survey Notes

Empirical **working notes** — library surveys, coverage audits, regression sweeps,
real-project triage, and considerations of outside research. They record *what was
observed* (and when), the analysis it prompted, and any follow-up that landed.

These notes are **non-normative and time-stamped to authorship** — they reflect what
was true when written, against the Rigor version named inside. Most carry a
`Status:` line; survey / essay-review notes are explicitly *"research note, no design
commitments."* A note may feed an [ADR](../adr/README.md), a
[design note](../design/README.md), or engine work — but the spec and ADRs bind, not
the note. Verify any named file / method / flag still exists before acting on it.

Filenames are `YYYYMMDD-<slug>.md`, dated to authorship.

## Library & ecosystem surveys

| Date | Note |
| --- | --- |
| 2026-05-15 | [Macro / DSL Expansion — Per-Library Survey](20260515-macro-expansion-library-survey.md) |
| 2026-05-15 | [Real-world Rails project survey](20260515-real-world-rails-survey.md) |
| 2026-05-19 | [22-library OSS survey — recurring false-positive clusters + BigDecimal-coerce fix](20260519-oss-library-survey.md) |
| 2026-05-25 | [FFI library usage survey — feeding `rigor-ffi` design](20260525-ffi-library-survey.md) |
| 2026-05-30 | [Mangrove (Result / Option / Enum) — library survey + `rigor-mangrove` shape](20260530-mangrove-library-survey.md) |
| 2026-05-30 | [Real Sorbet/Tapioca app survey — strap + dependabot-core](20260530-sorbet-real-app-survey.md) |
| 2026-05-31 | [TypeProf internals survey — inference logic + internal type representation](20260531-typeprof-internals-survey.md) |
| 2026-06-03 | [PHPStan 内部型演算（TypeCombinator / TypeUtils / 二項演算評価）と Rigor の比較](20260603-phpstan-type-algebra-comparison.md) |

## Type-coverage audits

| Date | Note |
| --- | --- |
| 2026-05-22 | [Hash method coverage — ShapeDispatch & block-fold audit](20260522-hash-method-coverage.md) |
| 2026-05-22 | [Rational / Complex / Range / Set — ConstantFolding カバレッジ監査](20260522-rational-complex-range-set-method-coverage.md) |
| 2026-05-22 | [標準ライブラリ決定論的モジュール関数カバレッジ](20260522-stdlib-deterministic-module-coverage.md) |
| 2026-05-22 | [標準ライブラリ非決定論的・除外対象モジュール カバレッジ](20260522-stdlib-nondeterministic-module-coverage.md) |
| 2026-05-22 | [型別メソッドカバレッジ — ConstantFolding / ShapeDispatch / ExpressionTyper 監査](20260522-type-method-coverage.md) |
| 2026-05-23 | [Date / Time / DateTime method coverage audit](20260523-date-time-method-coverage.md) |
| 2026-05-23 | [Struct / Encoding coverage audit](20260523-struct-encoding-coverage.md) |
| 2026-06-01 | [textbringer type-coverage survey — invalid bundled `sig/`, namespace-synthesis fix](20260601-textbringer-coverage-survey.md) |

## Regression sweeps & real-project triage

| Date | Note |
| --- | --- |
| 2026-05-03 | [Steep 2.0 cross-check triage](20260503-steep-cross-check-triage.md) |
| 2026-05-21 | [Mastodon survey — Cluster 4 (flow-folding warnings) triage](20260521-mastodon-cluster4-flow-folding-triage.md) |
| 2026-05-21 | [Mastodon v4.5.x regression sweep — baseline-drift over a release line](20260521-mastodon-v4.5-regression-sweep.md) |
| 2026-05-21 | [Redmine 6.x regression sweep — baseline-drift over a release line](20260521-redmine-6.x-regression-sweep.md) |
| 2026-05-21 | [Redmine per-commit detection probe — does Rigor catch real bugs?](20260521-redmine-per-commit-detection-probe.md) |
| 2026-05-23 | [Mastodon regression sweeps — re-run on Rigor v0.1.9](20260523-mastodon-v4.5-regression-sweep-v0.1.9.md) |
| 2026-05-29 | [ADR-35 override-rules — Mastodon false-positive verification](20260529-adr35-mastodon-fp-verification.md) |
| 2026-05-29 | [rigor-survey project-init baseline sweep](20260529-rigor-survey-project-init-baseline.md) |
| 2026-06-05 | [ADR-47 `flow.unreachable-clause` — corpus FP sweep (WD4)](20260605-adr47-unreachable-clause-corpus-sweep.md) |
| 2026-06-20 | [SKILL-driven onboarding (`rigor-next-steps`) — conference-app dogfood + rigor-survey field trial](20260620-skill-driven-onboarding-dogfood.md) |
| 2026-06-20 | [OpenCode (ACP) cross-model validation — driving `rigor-next-steps` across 13 models](20260620-opencode-acp-cross-model-validation.md) |

## Analyzer self-testing (teeth / false-negatives)

| Date | Note |
| --- | --- |
| 2026-06-13 | [Mutation-testing the analyzer — a teeth / false-negative harness + `lib/rigor` sweep backlog](20260613-mutation-teeth-harness.md) |
| 2026-06-17 | [Type-guided mutation testing — internal teeth vs. an external test-suite tool (strategy)](20260617-type-guided-mutation-testing-strategy.md) |
| 2026-06-17 | [Fused protection (`--with-tests`) — broad survey sweep across 12 OSS targets](20260617-fused-protection-survey-sweep.md) |
| 2026-06-18 | [Mutation-testing Rigor's own codebase — plan (RSpec ∪ self-check, independent type oracle)](20260618-self-mutation-testing-plan.md) |

## Outside research & essay reviews

| Date | Note |
| --- | --- |
| 2026-05-18 | [Matsumoto & Minamide 2008 (多相レコード型 Ruby 型推論) — Rigor 観点考察](20260518-matsumoto-2008-poly-records-rigor-review.md) |
| 2026-05-18 | [Matsumoto & Minamide 2010 (Ruby CFA) — Rigor 観点考察](20260518-matsumoto-2010-cfa-rigor-review.md) |
| 2026-06-01 | [「漸進的型付け言語の時代に必要なもの」(mizchi) — Rigor / TypeScript 観点考察](20260601-gradual-typing-era-mizchi-rigor-ts-review.md) |
| 2026-06-01 | [「Revenge of the Types」(Armin Ronacher) — ランタイム × 型チェッカー横断考察](20260601-revenge-of-the-types-runtime-checker-survey.md) |
| 2026-06-01 | [「型システムポエム」(myuon) — Rigor 観点考察](20260601-type-system-poem-rigor-review.md) |
| 2026-06-04 | [Elixir v1.20 の漸進的集合論型システム — Rigor 観点考察](20260604-elixir-v1.20-type-system-rigor-review.md) |

## Infrastructure & upstream

| Date | Note |
| --- | --- |
| 2026-05-20 | [Ractor worker pool crash — CRuby concurrent-Ractor use-after-free](20260520-ractor-pool-cruby-uaf.md) |
| 2026-05-28 | [Upstream `ruby/rbs` PR — `Resolv::DNS` typeclass-narrowed return](20260528-rbs-upstream-pr-resolv-typeclass.md) |
| 2026-06-03 | [Typing plugin files against the `Plugin::Base` contract — spike findings](20260603-plugin-contract-self-typing-spike.md) |
| 2026-06-03 | [Session report — typing the plugin contract (the 6-commit landing)](20260603-plugin-contract-typing-session-report.md) |

## Performance & profiling

| Date | Note |
| --- | --- |
| 2026-06-04 | [Profiling `rigor check` on Mastodon — allocation-bound analysis](20260604-mastodon-allocation-profile.md) |
| 2026-06-04 | [Profiling `rigor check` on GitLab — plugin-contribution churn](20260604-gitlab-plugin-contribution-allocation.md) |
| 2026-06-10 | [プラグインアーキテクチャ構造監査 — per-call 消費経路の最適化余地](20260610-plugin-architecture-perf-audit.md) |
| 2026-06-10 | [lib/rigor 内部アーキテクチャ再検討 — 正式リリース前の構造監査](20260610-lib-rigor-architecture-rereview.md) |
| 2026-06-10 | [キャッシュ機構監査 — ディスク使用量と warm-run ロードコスト](20260610-cache-disk-runtime-audit.md) |
| 2026-06-13 | [プラグインインターフェイス最終レビュー — v1.0 凍結前の BC-break 機会監査](20260613-plugin-interface-bc-review.md) |
| 2026-06-27 | [Corpus cold/warm re-profile — v0.2.6 new-bottleneck check](20260627-corpus-cold-warm-reprofile.md) |

## Process & meta

| Date | Note |
| --- | --- |
| 2026-06-05 | [ADR corpus rubric audit — scoring ADR-0…49 against ADR-49](20260605-adr-corpus-rubric-audit.md) |
| 2026-06-10 | [ユーザー向けドキュメント レビュー・バッテリー設計 — chibirigor-review の移植検討](20260610-user-docs-review-battery-design.md) |
| 2026-06-22 | [Rigor 0.2.x problem survey — type theory and Ruby runtime type model](20260622-rigor-0.2.x-problem-survey.md) |
| 2026-06-22 | [Rigor 0.2.x compatibility-safe strengthening survey](20260622-rigor-0.2.x-compatibility-safe-strengthening-survey.md) |
| 2026-07-04 | [`examples/` プラグイン近代化調査 — 最初期プラグインと現行契約面のギャップ](20260704-examples-plugin-modernization-survey.md) |

## Adding a note

1. Name the file `YYYYMMDD-<slug>.md` using the authorship date.
2. Open with a `Status:` line (e.g. *"research note, no design commitments."*) and
   name the Rigor version the observations were taken against.
3. Add a row to the matching section above (or start a new section).
