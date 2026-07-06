# Mastodon 型カバレッジ穴の provenance 分析 + sig-gen の RBS 妥当性クラッシュ

Status: real-project triage + バグ発見/一部修正 + ADR 提案の根拠メモ。2026-07-06、Rigor
v0.2.7 (`[Unreleased]`) 時点で `~/repo/ruby/rigor-survey/mastodon`（Rails 8.1.3,
v4.6.0-rc.1+186）に対して実施。非normative（設計コミットメントは [ADR-82](../adr/82-dynamic-provenance-wiring.md)
が持つ）。

Grounding: 直接の先行ノートは [2026-07-04 Rails カバレッジ強化オンボーディング](20260704-rails-coverage-onboarding-carrier-trap.md)
（以下「07-04 ノート」）。本ノートはその O5（provenance catch-all）と H3（sig env-crash の
silent 化）を、mastodon app+lib フルスコープで再確認・深掘りし、うち sig-gen の RBS 妥当性バグ
1クラスを engine で修正し、残る provenance-wiring を [ADR-82](../adr/82-dynamic-provenance-wiring.md)
に切り出す。ラベルは [ADR-75](../adr/75-dynamic-provenance.md)（Dynamic provenance）/
[ADR-63](../adr/63-type-protection-coverage.md)（protection coverage）。

## 初期状態

mastodon は 07-04 ノートで既に `rigor-project-init`（acknowledge モード / `severity_profile:
lenient`）済み。`.rigor.dist.yml`（Rails プラグイン9本）+ `.rigor-baseline.yml`（1,138 バケット）
あり・未コミット、`sig/` なし。本セッションはこの状態から `coverage --protection` を再取得した
（07-04 の plugin-aware + discovery-seed 修正が landed 済みなので、数値は check 忠実）。

## 1. カバレッジ全体像（`coverage --protection`, app+lib, ~53s, 1,312 ファイル）

| 指標 | 値 |
| --- | --- |
| protection ratio | **0.3148 (31.5%)** |
| protected / total | 9,703 / 30,822 |
| parse errors | 0 |

31.5% は 07-04 ノートの「plugin-blind + discovery-unseeded の2バグを修正した後の check 忠実な
真の保護率 ~33%」と整合。coverage scope 修正は landed 済みで、本測定はその上での再確認。

未保護のディレクトリ分布（count 加重）:

```
app/lib 4138 / app/models 3889 / app/services 3583 / app/controllers 2655
app/serializers 1793 / lib/mastodon 1566 / app/helpers 835 / app/workers 624
```

最悪ファイル: `app/lib/feed_manager.rb`(435穴/19.6%)、`activitypub/process_account_service.rb`
(323/18.4%)、`post_status_service.rb`(194/13.4%)、`app/models/account.rb`(173/26.7%)。

Dynamic 受信者上のトップメソッド: `[]`(2145) `id`(754) `present?`(545) `nil?`(501) `==`(453)
`!`(423) `account`(338) `to_s`(298) `map`(259) `blank?`(244) `where`(201)… — いずれも
AR モデル / ActionController params / Devise ヘルパの untyped レシーバ上のイディオムの下流。
サンプル: `Tag.find_normalized(...).id`（カスタム AR ファインダ→untyped）、
`current_user&.account&.unavailable?`、`params[:limit].present?`。

## 2. provenance は catch-all で tractability を誤誘導（O5 の再確認・深掘り）

`add_a_type_here` の site を tractability 別に集計:

| tractability (cause) | sites | 割合 |
| --- | --- | --- |
| `engine_gap` (`unsupported_syntax`) | 17,727 | 84.0% |
| （cause 未記録 / null） | 2,921 | 13.8% |
| `add_rbs` (`explicit_untyped`) | 471 | 2.2% |
| `enable_plugin` (`framework_dsl_boundary`) | **0** | 0% |
| `add_rbs` (`external_gem_without_rbs`) | **0** | 0% |

**98% が catch-all（`unsupported_syntax` + null）に落ちる。** Rails アプリなら本来
`framework_dsl_boundary`（Devise `current_user` / ActionController）や `external_gem_without_rbs`
（RBS 欠落 gem）に分類されるべき受信者が **1件も**その cause を持たない。ADR-75 の tractability
誘導（「plugin 有効化 vs 手書き RBS vs engine 限界」の切り分け）は実在の Rails アプリ上で機能して
いない。

### 原因（engine を読んで特定した2つのギャップ）

`DynamicOrigin::UNSUPPORTED_SYNTAX` は定義上「未モデル構文への推論フォールバック」＝**キャッチ
オール**（`lib/rigor/inference/dynamic_origin.rb:22`）。具体 cause が付かない全てがここに落ちる。

- **G1 ルックアップのギャップ.** `ProtectionScanner#scan` は provenance を dispatch の
  **直接 receiver ノード**で引く（`protection_scanner.rb:49`, `scope.dynamic_origins[node.receiver]`）。
  一方 `MethodDispatcher` が具体 cause を記録するのは **Dynamic 値を生んだ call ノード**
  （`method_dispatcher.rb:113/141/166/178`）。`tag.id` の receiver は `tag`（ローカル読み）で、
  真の出所 `Tag.find_normalized(...)` call ノードとは別。ローカル/ivar 読みの receiver ノードには
  記録が無く nil（→ null 13.8%）か、`ExpressionTyper#fallback_for` の汎用 `UNSUPPORTED_SYNTAX`
  （`expression_typer.rb:911-912`）に落ちる（→ 84%）。伝播は連鎖呼び出し `a.b.c` で `.c` の
  receiver が call ノード `a.b` の時にしか効かない。

- **G2 記録条件のギャップ.** `FRAMEWORK_DSL_BOUNDARY` はプラグインが `dynamic_return` で
  **Dynamic を返した時のみ**記録（`method_dispatcher.rb:112`）だが、プラグインは大半で**具体型**を
  返す（＝そのサイトは保護済みで穴でない）ので、穴として残るサイトにこの cause はほぼ付かない。
  `EXTERNAL_GEM_WITHOUT_RBS` は ADR-10 dependency-source / `pre_eval:` の opt-in が前提で、
  stock Rails 構成では発火しない。加えて `try_discovered_method`（`method_dispatcher.rb:246`）と
  `try_user_class_fallback`（`:210`）は Dynamic を返すが cause を**一切記録しない**。

→ provenance-wiring の拡充（G1 の伝播 + G2 の記録追加 + 新 cause の tractability 割当）を
[ADR-82](../adr/82-dynamic-provenance-wiring.md) に切り出した。precision-additive（型・診断・severity
不変）なので本体は安全だが、G1 の binding→origin 伝播は join 下での side-table 健全性・perf を
要設計で、拙速に landしない。

## 3. sig-gen 再計測 — env-crash が sig を「有害」に見せる（H3 の再実演）

07-04 ノート R1 は env-crash バグ A（superclass 欠落）修正後に「sig はカバレッジを +5〜10pp
上げる」と訂正した。本セッションで mastodon **app+lib フル**に対し sig-gen 再計測すると、**別の**
env-crash が再発した。

### 素の再計測（sig 生成 → coverage）

| 構成 | ratio | protected | tract |
| --- | --- | --- | --- |
| sig なし | 0.3148 | 9,703 | engine_gap 17727, add_rbs 471 |
| sig あり（素） | **0.2627** | 8,098 | engine_gap 19473, **add_rbs 0** |

−5.2pp。**しかしこれは env-crash アーティファクト**。stderr:

```
RBS environment build failed: RBS::ParsingError:
  sig/helpers/application_helper.rbs:4: unexpected record key token, token=`data`
```

sig-gen が **不正な RBS を生成**し env ビルドが丸ごと落ち、「Rigor will continue analyzing with
no RBS env in scope, so most type-of queries will return Dynamic[top]」= 全 type-of が Dynamic に
劣化 → 保護が消えて **sig が害に見えた**（add_rbs=0 は RBS dispatch が一切効いていない証拠）。
07-04 ノート H3「診断減少が env 崩壊を意味しうる」の再実演で、今度は coverage 側で顕在化。

### sig-gen の RBS 妥当性バグ（2クラス）

生成 333 ファイルを個別に `RBS::Parser.parse_signature` にかけると **330 valid / 3 invalid**。
不正は2クラス:

1. **非識別子 record キー（2→本セッションで engine 修正済み）.** mastodon の `html_attributes` が
   `{ lang:, class:, :"data-contrast" => …, :"data-color-scheme" => … }` を返し、`HashShape` が
   symbol キー `:"data-contrast"` を **bare `data-contrast:`** と出力 → RBS パース不能。RBS 文法は
   bare 非識別子キーも `"data-contrast":`（引用符+コロン）も拒否し、`"data-contrast" =>`
   （引用符+ファットアロー）のみ受理する。**修正**: `Type::HashShape#erase_key_prefix` が bare 識別子
   symbol は `key:`、それ以外は `"key" =>` を出力（`describe` は表示専用なので従来の `"a":` を維持し
   blast radius 最小化）。回帰テスト追加、`hash_shape_spec` 27/27 green。

2. **ブロックパラメータの誤レンダリング（3ファイル、未修正）.**
   `def initialize: (**untyped, ?{ (?) -> void }) -> void` — optional block を括弧内にカンマ付きで
   出力し（正しくは括弧の外）、`(?)` も不正なブロック引数。`connection_pool/*`,
   `elasticsearch/client_extensions` の3件。sig_gen の writer 領域の別欠陥で、本セッションでは
   characterize のみ（whack-a-mole を避ける）。

### 健全 env での genuine な数字（不正3ファイル除外, 330 files）

| 構成 | ratio | protected | env |
| --- | --- | --- | --- |
| sig なし | 0.3148 | 9,703 | — |
| sig あり（330 valid, env HEALTHY） | **0.3195** | 9,848 | healthy |

**genuine な sig 効果は +0.47pp（protected +145）に過ぎない。** 素の −5.2pp と genuine +0.47pp の
**5.7pp スイングは、たった1つの不正 sig ファイルが env 全体を落とした**ことに起因する。07-04 の
app/models 単独 +5.4pp と違い、app+lib フルは controllers/services/lib が支配的で sig の寄与が薄い。
加えて 07-04 R2 の carrier-trap（クラス再宣言でメンバ脱落 → sig-quality FP +150）は健在。
**結論: app+lib スケールでは sig-gen は保護カバレッジの有効レバーでない**（微増 vs FP・crash リスク）。

## 4. 障害の真因ランキング（レバーの大きさ順、mastodon app+lib）

1. **provenance-wiring（計測の信頼性）— [ADR-82](../adr/82-dynamic-provenance-wiring.md).**
   84% catch-all を actionable に割る。engine 変更だが precision-additive。
2. **env-build resilience（sig 実用化の前提）.** 不正 sig ファイル1つが env 全体を落とす
   不均衡（07-04 H2(b)/H3）。quarantine/skip すれば sig-gen の残バグに対しても頑健になり、
   「診断減 = env 崩壊」の silent failure も塞げる。専用診断 / 非ゼロ exit も要（07-04 H3、未着手）。
3. **sig-gen の RBS 妥当性（block-param クラス）.** 上記 3.2、writer 修正。
4. **ADR-67 parameter inference / ADR-58 ivar typing.** 残る素の Dynamic ivar/param/association。
   protection 天井の本丸（07-04 H4/§境界）。config/plugin/sig では動かない。

## Follow-up

- **[ADR-82](../adr/82-dynamic-provenance-wiring.md)** — provenance-wiring（G1 伝播 + G2 記録 +
  新 cause）。本ノートが根拠。proposed。
- **sig-gen record-key 修正** — LANDED（`Type::HashShape#erase_key_prefix`、本セッション、CHANGELOG）。
- **env-build resilience** — 未着手（07-04 H2(b)/H3 と統合、demand-gated）。不正 sig ファイルの
  quarantine + 可視化。sig-gen block-param 修正はこれで頑健化されるまでの暫定でしかない。
- **sig-gen block-param レンダリング** — 未修正、characterize 済み。

## GOTCHAs（再実行者向け）

- `coverage --protection` の with-sig 数値は **env-build 成否を必ず確認**すること（stderr の
  `RBS environment build failed`）。env が落ちると sig が「害」に見える偽の低下が出る。
- 生成 sig の RBS 妥当性は `RBS::Parser.parse_signature` で個別検査（env は最初の1件で abort する
  ため、env-crash だけでは何ファイルが不正かは分からない）。
- `coverage` に `--no-cache` は無い → `rm -rf .rigor/cache` でバスト。
- 生成物（`sig/`, `.rigor/cache/`）は survey チェックアウト内で untracked。計測後は破棄して
  clean baseline 状態（sig なし）に戻す。
