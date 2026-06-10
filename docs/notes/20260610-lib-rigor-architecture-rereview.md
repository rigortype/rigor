# lib/rigor 内部アーキテクチャ再検討 — 正式リリース前の構造監査

*2026-06-10. Status: structural audit feeding ROADMAP entries + an ADR — informational,
not normative. The spec binds. Observations taken against the working tree @
`75484162` (post-v0.1.17, pre-v0.1.18 cut). 4 サブシステムを並列調査し、影響の
大きい指摘は本体 grep で裏取りした。*

## Question

正式リリース(ADR-50: v0.2.0 評価リリース → v1.0 契約凍結)前に、`lib/rigor` の
内部アーキテクチャを **(a) 論理的な役割分担の明確さ** と **(b) 冗長なボイラー
プレート・無駄なメソッドコールの削減** の 2 軸で再点検する。先行監査
([builtin boilerplate](20260603-builtin-typing-boilerplate-audit.md) /
[structural repetition](20260604-structural-repetition-audit.md) /
[plugin architecture](20260610-plugin-architecture-perf-audit.md)) が消化済みの
領域を再掲せず、**残っている構造課題だけ**を棚卸しする。

## 前提 — 消化済みの領域

- ボイラープレート: Theme A (ValueSemantics/AcceptanceRouter) / C (CLI::Command) /
  D (Diagnostic ファクトリ + RbsCacheProducer + LSP mixin)、builtin Finding 1–4
  (SingletonFolding / CallContext 単一インターフェイス / `MethodCatalog.for_topic`)
  はすべて DONE(各ノートの progress log 参照)。
- アロケーション: ADR-44 (body-scope collapse、−42% allocs) LANDED。
- プラグイン消費経路: ADR-52 が**提案済み・未実装**。本監査の A-1 がその実装を
  最優先に置く根拠を再確認した。

## 全体評価 — 土台は健全

- **依存方向に循環なし**: `cli → analysis → inference → type` の一方向。
  逆流は 2 件のみで、いずれも許容範囲 — `type/combinator.rb:19` の
  `Inference::BudgetTrace`(計測のみ)と、`Scope` が `Analysis::FactStore` を
  運ぶ名前空間のねじれ(機能上問題なし、低優先の改名候補)。
- Scope 不変規律・fail-soft・`try_dispatch(CallContext)` tier 統一は
  internal-spec の宣言どおり機能している。
- `ExpressionTyper`(型値)/ `StatementEvaluator`(スコープ遷移)/
  `Narrowing`(狭窄)/ `MethodDispatcher`(解決)の四役分担は概ね成立。
  循環参照なし。

## 所見 A — 無駄なメソッドコール(性能軸)

### A-1. プラグイン貢献ディスパッチ(ADR-52、本丸)

レガシー `flow_contribution_for` は全コールノード × 2 経路で無条件に呼ばれ、
node_rule はプラグインごとにファイル全 walk。
[ADR-52](../adr/52-compiled-plugin-contribution-dispatch.md) の WD1–WD6 実装が
このテーマ最大の一手。詳細は
[プラグインアーキテクチャ監査](20260610-plugin-architecture-perf-audit.md)。

### A-2. 組み込み tier も「全 tier 試行」をしている

`String#+` のような典型コールでも `PRECISE_TIERS` の 14 tier 全部が
`CallContext` を受けて nil を返してから RbsDispatch に到達する
(`method_dispatcher.rb:738` 周辺、1 コールあたり 50–70 マイクロ操作の空振り)。
singleton folder 群は receiver が `Singleton[Math]` 等でなければ絶対に当たらない
ので、**ADR-52 と同じ「エンジンが既に持っているキーで 1 回引く」思想を組み込み
tier にも適用できる**(receiver クラス / メソッド名キーの前置フィルタ)。
ADR-52 の WD 追補ないし姉妹スライスが自然。計測ゲートは ADR-52 WD6 と同一
(診断 byte-identical + stackprof + `make bench-perf`)。

### A-3. CallContext の重複構築

1 dispatch で最大 3 個生成される — 入口 `method_dispatcher.rb:86` に加え、
Tier B 昇格 `:476` とユーザークラス落下 `:791` が `CallContext.build` を
やり直す。`Data#with` の差分コピーで機械的に削減可能。ADR-44 メモの
「CallContext per-dispatch (intrinsic) still open」の実態はこれで、
intrinsic な 1 個以外は削れる。

### A-4. ファイルあたりの AST walk 回数

1 ファイルにつき ScopeIndexer 1 回 + CheckRules の `NodeWalker.each` 1 回
(`check_rules.rb:167`)+ 独立 collector 4 回(`:228` IvarWrite / `:242`
DeadAssignment / `:255` AlwaysTruthyCondition / `:265` UnreachableClause)
+ node_rule を持つプラグイン数 = **最低 6 + N 回**。プラグイン分は ADR-52 WD4
(エンジン所有の単一 walk)が解消する。CheckRules の 4 collector 統合は
**走査順が正しさに効く**ため、shadow-run 等価性ハーネスなしに触らない
(structural-repetition ノートの Theme B と同じ判断)。→ 所見 B-4 / ADR 行き。

### A-5. OverloadSelector の acceptance 呼び出し回数

`overload_selector.rb:259` で全 overload × 全 param の `accepts` が走り、
Union receiver では member 数が乗じる(例: 3-member Union × 5 overload ×
3 param = 45 回)。`Acceptance` 自体は TYPE_HANDLERS テーブル + 構造等値
short-circuit 済みで 1 回は軽い。**計測してから**の最適化候補(現プロファイル
では支配項ではない)。

## 所見 B — 役割分担(構造軸)

### B-1. `Analysis::Runner`(2011 行)が最大のモノリス

ファイル列挙 / 7 つのプロジェクト事前パス(`runner.rb:448-514`)/
Ractor・fork プール調整(約 400 行、`:747-1163`)/ run-result キャッシュキー /
12+ 系統の診断源集約(`:297-338`, `:613-628`)/ severity 適用 / reporter drain /
プラグイン実行が 1 クラスに同居。**`PoolCoordinator` / `ProjectPrePasses` /
`DiagnosticAggregator` の 3 分割**で orchestrator 本体は ~600 行に収まる。
挙動不変のコンテナ分割でリスク低。ADR-46 後続スライスや LSP の
「pre-built Environment を受ける Runner」要望(ROADMAP § LSP Ractor pool)の
足場としても効く。

### B-2. 確定性(certainty)判定の二重実装

`case/when` の枝確定性(`:yes/:no/:maybe`)を `expression_typer.rb:791-862`
(`case_when_branch_certainty` / `case_when_pattern_certainty`)が独自実装して
おり、同じパターン解析が `narrowing.rb:365`(`case_when_scopes`)にもある。
`StatementEvaluator` は `Narrowing.case_when_scopes` 委譲済み
(`statement_evaluator.rb:560-584`)なので**二重**(三重ではない)。
`if/unless` の truthy/falsey 確定性も `expression_typer.rb:678`
(`constant_predicate_polarity`)と `statement_evaluator.rb:492`
(`predicate_certainty`)が同じ `Narrowing.narrow_truthy → Bot?` イディオムを
別々に書いている。**「確定性判定は Narrowing が唯一の所有者、Typer / Evaluator
は問い合わせる側」への一本化**が役割分担として正しい形。ただし推論ホットパスの
正しさ中枢なので、機械的リファクタではなく専用スライス + 全 suite + 診断不変
ゲートで。

### B-3. `cli.rb` の `run_check` 残留

他 14 コマンドは `CLI::Command` 委譲済みなのに check だけ本体に残る
(`cli.rb:83-287` 約 200 行 + `parse_check_options` 256 行)。`CheckCommand`
への移譲で対称性が完成。低リスク。

### B-4. Scope のメタテーブル過多(設計判断案件 → ADR)

`scope.rb` は「束縛 + facts + narrowing 状態」という flow-sensitive な本務に
加え、`discovered_*` 系 ~10 個の**プロジェクト全体索引**(クラス / def /
可視性 / superclass / includes / class_sources / `data_member_layouts` …)を
運んでいる。後者は run 中不変であり、スコープ遷移のたびに `rebuild` で運搬する
必要は本来ない。`ProjectIndex` 的分離は役割分担として最も筋が良い一方:

- ADR-44 で類似の `ProjectScope` 再編成が「Ruby 4.0 object-shape では
  アロケーション削減にならない」と降格された経緯がある(動機を性能でなく
  **境界明確化**に置き直して判断する必要がある)。
- プラグインが `Scope` 経由で索引を読む public 面(`user_def_for` 等)に触る。
- A-4 の CheckRules collector 統合・structural-repetition Theme B
  (scope_indexer walker 統一)と同じく**等価性ハーネスが前提**。

性能ではなく境界の問題として ADR で決める。→ ADR-53 起票。

## 所見 C — v1.0 凍結前に塞ぐ public API 境界違反

[rigor-sorbet](../../plugins/rigor-sorbet/lib/rigor/plugin/sorbet.rb) `:585` が
`Rigor::Inference::Acceptance.accepts` を直接呼んでいる。`public-api.md` は
`Inference::*` を internal と宣言しており、ADR-50 の凍結前に解消必須。
`Type#accepts` は public surface なので `asserted.accepts(inferred)` への
書き換えでほぼ一行修正(AcceptanceRouter が同じ実装へ委譲)。
ほか: `rigor-sinatra:27` はコメント言及のみ(無害)、各プラグインの
`Diagnostic.new` 直呼びは public 面なので違反ではない(`Plugin::Base#diagnostic`
ラッパー推奨に寄せる余地はある)。

## 提案 — 4 フェーズ

| Phase | 内容 | リスク | ゲート |
| --- | --- | --- | --- |
| 1(機械的) | C sorbet 境界修正 / A-3 CallContext `with` 化 / B-3 `run_check` → CheckCommand | 低 | `make verify` + 診断不変 |
| 2(本丸) | ADR-52 実装 WD1→WD6(+ A-2 組み込み tier 前置フィルタを WD 追補) | 中 | ADR-52 WD6(byte-identical + stackprof + bench-perf) |
| 3(構造) | B-1 Runner 3 分割 / B-2 certainty 判定の Narrowing 一本化 | 中 | 全 suite + 診断不変 |
| 4(要 ADR) | B-4 Scope プロジェクト索引分離 / A-4 collector 統合(shadow-run 前提) | 高 | ADR-53 + 等価性ハーネス |

## Follow-up

- 全フェーズを `docs/ROADMAP.md` § Future cycles に作業対象として登録する。
- Phase 4 の設計判断を ADR-53 として起票する(deliberative / high stakes)。
- Phase 1 は ADR 不要で即着手可能。
