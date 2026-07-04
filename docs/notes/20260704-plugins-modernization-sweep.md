# `plugins/` 近代化スイープ — SKILL 適用による本番プラグインのドリフト監査

Status: 内部監査ノート、authored 2026-07-04（Rigor は release/0.2.x ライン）。`examples/` 近代化
（[`20260704-examples-plugin-modernization-survey.md`](20260704-examples-plugin-modernization-survey.md)、
PR #35 で master マージ済み）で新設した `rigor-plugin-review` スキル
（[`skills/rigor-plugin-review/`](../../skills/rigor-plugin-review/SKILL.md)）を、今度は本番 31
プラグイン（`plugins/`）に適用した記録。ブランチ `plugins-modernization` の実装 PR を駆動。設計コミットメントなし。

## 要旨 — 本番プラグインは概ね近代化済み、ドリフトは外科的

本番プラグインは ADR-60 WD4 オーサリングヘルパ移行の *corpus* だったため、examples ほどの
ドリフトはない、という事前仮説はスキャンで裏付けられた。スキルの9観点で全 31 プラグインを
スキャンした結果：

| 観点 | 結果 |
| --- | --- |
| 1. ADR-40 config デフォルト | **ドリフトなし**（`DEFAULT_*` を持つ playground/sorbet は config 非該当 — CLI ポート・sigil レベル内部定数） |
| 3. `type_specifier`（→`narrowing_facts`）/ `flow_contribution_for` | **全移行済み**（author verb 使用 0、`flow_contribution_for` はコメントのみ） |
| 4. 手書き Levenshtein | **なし**（全プラグイン `Base.suggest` 使用済み） |
| 7. manifest 衛生（`external_files:`/`verbs:`/`name_arg_position:`） | **クリーン** |
| 2. AST 走査の所有権 | genuine smell **1件**（hanami）— 他の `class_nodes`/`def walk` は discovery/collect パス（`#prepare`/`node_file_context` 由来で正当） |
| 4. `Diagnostic.new` node-level | genuine smell **候補1件が誤検出**（rspec、下記） |
| 8. doc 鮮度 | 微修正2件（activerecord コメント・sorbet README の `flow_contribution_for` 考古学） |

## 実施した変更（外科的、各々 spec バイト同一ゲート）

1. **rigor-hanami — ActionChecker を `node_rule(Prism::ClassNode)` へ**（観点2）。
   ADR-28 protocol-contract の check 半分が `diagnostics_for_file` + 手書き `class_nodes`/`walk`
   だった（web example と完全同型）。`ActionChecker#check_class` に分解し `class_nodes`/`walk` を削除。
   本番の canonical な per-class 検査形へ。hanami spec 12/12 緑。examples の web 修正の本番版。
2. **rigor-sorbet — 3つの `walk_for_*` を `node_rule(Prism::CallNode)` へ**（観点2）。
   `T.absurd` 到達・`T.reveal_type`・`T.assert_type!` の各診断が `diagnostics_for_file` +
   3本の手書き全走査だった。各々、推論フェーズ（`dynamic_return`/`narrowing_facts`）で
   **object identity で記録**された集合（`@reachable_absurd_nodes` 等）への membership 照合。
   node_rule は診断フェーズ（推論後）に発火するので集合は populate 済み、同一 parse tree で
   identity 一致、membership が gate。`diagnostics_for_file` は parse-error 専用に縮小、6メソッド削除。
   sorbet spec 68/68 緑。最複雑プラグインだが健全性の事前分析どおり。
3. **doc 鮮度** — activerecord のコメントと sorbet README 表から `flow_contribution_for` の
   考古学的言及を除去し、現行機構を直接記述（観点8）。

## 教訓 — スキルの「オラクル規律」が誤検出を捕捉

観点4の初期トリアージで **rspec/analyzer の `Diagnostic.new` を node-level smell と誤判定**し、
`Diagnostic.from_location` へ置換したところ spec が 4 例失敗（診断が nil 化）。原因は
`Diagnostic` が `Rigor::Analysis::Diagnostic` ではなく**プラグインローカルの `Struct`**（中間値
オブジェクト）で、`from_location` を持たなかったこと（rspec.rb が後段で本物へ変換する二層構造）。
即座に revert（47/47 緑に復帰）。**教訓**: `Diagnostic.new` の grep は engine の Diagnostic と
プラグインローカルの値オブジェクトを区別できない → 置換前に `Diagnostic` の実体を確認せよ。
スキルの「各ステップ後に spec をオラクルにする」規律が、複雑プラグインでの誤った近代化を
コスト最小で捕捉した実例。

## 触れなかったもの（churn 回避）

- **discovery/collect ウォーカー**（activerecord/analyzer, activestorage/attachment_discoverer,
  rails-routes/helper_discoverer, sorbet/catalog_walker 等）— `#prepare`/`node_file_context` の
  collect 半分で、走査は必須（スキル観点2の明示的除外）。
- **file-level `Diagnostic.new(line: 1)`**（各プラグインの load-error）— 位置すべき node が無く正当。
- **rspec/analyzer のローカル `Diagnostic` Struct** — 中間値オブジェクトで smell でない（上記）。
- ADR-40 / `narrowing_facts` / `suggest` / WD4 ヘルパ — 本番は既に採用済みで対象なし。

## 参照

- [`20260704-examples-plugin-modernization-survey.md`](20260704-examples-plugin-modernization-survey.md) — 姉妹作業（examples、PR #35）
- [`skills/rigor-plugin-review/`](../../skills/rigor-plugin-review/SKILL.md) — 適用したスキル（同 PR で新設）
- ADR-37（`node_rule` engine-owned walk）・ADR-52（`dynamic_return`）・ADR-60 WD4（オーサリングヘルパ）
