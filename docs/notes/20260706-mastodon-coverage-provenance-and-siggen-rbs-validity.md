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
  新 cause）。本ノートが根拠。**WD1+WD2+WD3+WD6+WD7+WD8 LANDED 2026-07-06**（下記「実装」節）。
  WD7 = 正確 per-site メトリクス + param enrichment（ADR-67）、WD8 = unbound ivar enrichment
  （ADR-58）。累積 causeless 49%→26%、inferred 15倍。actionability レバーはほぼ出し切り。
- **sig-gen record-key 修正** — LANDED（`Type::HashShape#erase_key_prefix`、本セッション、CHANGELOG）。
- **env-build resilience** — 未着手（07-04 H2(b)/H3 と統合、demand-gated）。不正 sig ファイルの
  quarantine + 可視化。sig-gen block-param 修正はこれで頑健化されるまでの暫定でしかない。
- **sig-gen block-param レンダリング** — 未修正、characterize 済み。

## 実装（2026-07-06）: ADR-82 WD2+WD3 + re-bucketing 計測

ADR-82 の WD5（「WD2+WD3 を先に land して re-bucketing を測り、WD1 のコストを判断」）を実施。

- **WD3**: 新 cause `DynamicOrigin::INFERRED_RETURN_UNTYPED`（tractability = `engine_gap`）。
  「call は解決したが戻りを推論できない」= `unsupported_syntax`（未モデル構文）でも
  `explicit_untyped`（RBS で untyped 宣言）でもない、推論ギャップ。CLI は
  `DynamicOrigin.tractability` を中央参照するので renderer 変更不要。
- **WD2**: `MethodDispatcher` の `try_discovered_method` と `try_user_class_fallback` が
  Dynamic を返す時に call ノードへ `INFERRED_RETURN_UNTYPED` を記録（各1行の
  `record_dynamic_origin`）。連鎖 `a.b.c` で `.b` が解決済みユーザメソッドの時、`.c` の
  receiver（= `a.b` call ノード）が正しい cause を得る。

### 計測（mastodon app+lib, no-sig, cause 別 site 数）

| cause | baseline | WD2/3 | Δ |
| --- | --- | --- | --- |
| unsupported_syntax | 17,727 | 17,565 | −162 |
| (null) | 2,921 | 2,872 | −49 |
| **inferred_return_untyped** | 0 | **211** | +211 |
| explicit_untyped | 471 | 471 | 0 |
| protection ratio | 0.3148 | 0.3148 | 0（precision-additive 確認） |

**211 サイト（全体の ~1%）のみ再バケット。** adjudication（正しい帰属を確認）: 移動した
サイトは `<解決済みユーザメソッド>.foo` の連鎖 — `parsed_uri.path`（`def parsed_uri` あり）、
`media_attachment_file.path`（`def media_attachment_file`）等で、いずれも「戻りを推論できない
ユーザメソッド」= `inferred_return_untyped` が正当。少数派の `directory_url.path`
（`directory_url = Addressable::URI.parse(...)` のローカル）は group の dominant-origin 表示に
混ざるだけで、これこそ G1（local receiver は call-node 記録に届かない）の実例。

**結論（WD5 の解決）**: 小ささが G1 診断を実証した。残る 84% は local/ivar receiver で、
call ノードにいくら cause を記録しても receiver-node ルックアップが届かない。ゆえに
**WD1（ルックアップ伝播）は demand-gated でなく必須**。WD2+WD3 は「安価な診断確認」として
役目を果たし、次は WD1 の設計（flow-varying な `Scope` binding→origin-node アソシエーション、
`make bench-perf` + discovery/self-check ゲート）。

## 実装（2026-07-06）: ADR-82 WD1 + 計測（modest、次レバー = WD6 に redirect）

WD1（bare receiver への binding origin 伝播）を実装。`Scope#local_origins`/`#ivar_origins`
（name→cause 側テーブル、==/hash 除外、メソッド境界でリセット）を代入時に set
（`StatementEvaluator#eval_local_write/#eval_ivar_write`、rhs が origin 付き Dynamic の時）、
`ProtectionScanner#propagated_origin` が receiver 自身のノードに origin が無い時に辿る。

### 計測（mastodon app+lib, no-sig, cause 別 site 数、group-dominant 集計）

| cause | baseline | WD2/3 | WD1 |
| --- | --- | --- | --- |
| unsupported_syntax | 17,727 | 17,565 | 17,854 |
| (null) | 2,921 | 2,872 | **2,550** |
| explicit_untyped | 471 | 471 | 462 |
| inferred_return_untyped | 0 | 211 | 253 |
| ratio | 0.3148 | 0.3148 | 0.3148 |

**WD1 は null バケット（cause 無し）を ~322 サイト削減**（2,872→2,550、ratio 不変）。だが
**dominant な 84% unsupported_syntax はほぼ不変**（むしろ +289、null だった local が「未解決RHS」
由来 unsupported を伝播）。

### adjudication → 「primary lever」は誤り、次レバーは WD6

residual を実サンプルすると、dominant なホール receiver は **bare 変数読みではなく中間式/チェーン**:
- `signed_request_account.uri[…]`（`[]` の receiver は call チェーン）
- `account_id_param.present?`（receiver は method call）
- `Status.tagged_with(tag.id)`

チェーンの `.foo` が **Dynamic receiver 上でディスパッチされると結果に汎用 `unsupported_syntax` を
記録し、上流の cause を失う**。WD1（local/ivar 読みのみ）はこれに届かない。制御ケースで伝播自体は
発火確認済み（`y = helper; y.save` で `y.save` receiver が binding origin を継承）。

→ **次レバー = WD6 チェーン origin 継承**（Dynamic receiver 上の呼び出し結果が receiver の origin を
継承）。84% の大半がここ。ただし最ホットな dispatch 経路に触れ FP/perf リスクが高いため、独立した
measured/adjudicated/bench-perf-gated スライスに defer（WD2/3→WD1 と同じ規律）。WD1 は保持
（正しい・perf-neutral・null 削減・WD6 の基盤）。

### perf

`make bench-perf` は FAIL するが、**master 自身も FAIL**: committed baseline（19.77M alloc / 16.6s
wall）が stale で、master 27.51M/7.2s・WD1 27.54M/7.2s（**+0.1%、perf-neutral**）。baseline
再取得（CI Linux 計測）は別 follow-up。

## 実装（2026-07-06）: ADR-82 WD6 チェーン origin 継承

WD1 の計測が示した「dominant はチェーン receiver」を受け、WD6 を実装。`call_type_for` の
**既存コメント**（「Dynamic receiver の結果は dynamic origin を継承する」— 未実装だった）を実装:
`ExpressionTyper#inherit_receiver_origin` が Dynamic receiver の呼び出し結果 call ノードに
receiver の実効 origin を記録（`return dynamic_top` は不変）。実効 origin は共有
`Inference::OriginLookup.origin_for`（`dynamic_origins[node] || local/ivar 伝播`）で、WD1 の
ルックアップと統一（`ProtectionScanner` も同ヘルパへ）。

### 計測（mastodon app+lib, no-sig, cause 別 site 数、group-dominant 集計）

| cause | WD1 | WD6 |
| --- | --- | --- |
| unsupported_syntax | 17,854 | 19,405 |
| **(null)** | 2,550 | **1,356** |
| explicit_untyped | 462 | 217 |
| inferred_return_untyped | 253 | 141 |
| ratio | 0.3148 | 0.3148 |

**WD6 は null（causeless）バケットを 2,550 → 1,356（−1,194）削減** — WD1(−322) の約4倍。累積
baseline 2,921 → 1,356（null の半分超をラベル化）。probe で3ホップ伝播確認（`y.foo.bar.baz` の
全ホップが `y` の binding origin を継承）。ratio 不変（precision-additive）。

### 正直な読み: 完全性↑、actionability は限定的 → 次レバー = root cause 充実

ラベルは **unsupported_syntax 支配**（null→unsupported +1,551）。理由: チェーンの **root** が
unsupported を記録する — implicit-self の memoized reader、`params[:x]` の index、metaprog accessor。
`unsupported_syntax` も null も tractability は engine_gap なので、WD6 は **provenance 完全性**
（causeless ホール半減）を買うが **actionability**（enable_plugin/add_rbs へのルーティング）は
あまり動かさない。inferred/explicit の group-dominant 減は集計ノイズ（root が unsupported 化した
チェーンが group を flip）。

→ **次レバー = chain root の cause 充実**: implicit-self 解決経路が `inferred_return_untyped` を
記録（WD2 の explicit-receiver tier と同様）、framework index read（`params`/`session`）に framework
cause。これらを WD1/WD6 の伝播が chain 全体に無料で広げる。demand-gated follow-up。

### perf

`make bench-perf` は stale baseline で FAIL するが A/B は perf-neutral: master 27,540,795 alloc /
7.77s、WD6 27,548,368 / 7.83s（**+0.03%、+7,573 alloc**）。record は Dynamic-receiver 呼び出し
毎の O(1) hash write。self-check `lib` は Dynamic チェーンが少なく影響最小。

## 実装（2026-07-06）: ADR-82 WD7 — 正確 per-site メトリクス + param root-enrichment

WD6 まで group-dominant 集計で測っていたが、それが lossy と判明。2つの結合した変更。

### 正確メトリクス（+ WD1/WD6 計測の訂正）

`coverage --protection` は holes を method でグループ化し各 group の **dominant** cause を報告、
`tractability_summary` もそれを group count で加重していた。mixed group の少数派 cause（特に
causeless サイト）が消える。per-site 正確な `cause_site_counts`（`"none"` 含む、tractability_summary
もこれ由来に修正）を追加すると **真の状態**が判明:

| cause | per-site 正確（WD1+2+3+6 後） |
| --- | --- |
| **none（causeless）** | **10,390（49%）** |
| unsupported_syntax | 10,126（48%） |
| inferred_return_untyped | 351 |
| explicit_untyped | 252 |

**本ノート/ADR の WD1/WD6 の「null 2,921→1,356」は group-dominant アーティファクトだった。** 真の
causeless は WD6 後も **10,390（49%）**。WD1/WD6 は実仕事をした（ラベル済みは維持）が、その規模は
lossy メトリクスで過大表示されていた。provenance 完全性は ~51%（~94% ではない）。

### param enrichment（causeless の最大 actionable スライス）

49% causeless の最大 actionable 部分は **未宣言 param**（`def f(x); x.foo` は `x` を untyped に
bind、bare param receiver は cause 無し）。`build_method_entry_scope` が untyped param の
`local_origins` を `inferred_return_untyped` で seed（untyped param は ADR-67 の典型ギャップ）→
WD1 ルックアップが `x.foo` をラベル、WD6 が `x.foo.bar` へ伝播。seed-time のみ（hot read path 不変）。

| cause | before | param-enrich |
| --- | --- | --- |
| none | 10,390 | **7,305** |
| inferred_return_untyped | 351 | **3,460** |
| unsupported_syntax | 10,126 | 10,102 |

**~3,100 サイトが causeless → inferred_return_untyped（ADR-67 ルーティング）** = 本物の
actionability 利得。ratio 不変（precision-additive）、perf-neutral（A/B +0.15% alloc）。残る
causeless 7,305 は主に unbound ivar read（ADR-58）+ dynamic_top ノード種（yield/super/block）。

### WD8 = unbound ivar enrichment（ADR-58 ルーティング）

`type_of_instance_variable_read` が unbound ivar（`scope.ivar` nil）で `inferred_return_untyped` を
記録（untyped field = ADR-58 の典型ギャップ）→ WD6 が `@x.foo.bar` へ伝播。param と違い method
entry で seed 不可（read 地点で unbound が判明）なので read 時記録だが、already-`dynamic_top` 分岐
のみ・perf-neutral（A/B +0.03%）。

| cause | param(WD7) | ivar(WD8) |
| --- | --- | --- |
| none | 7,305 | **5,405** |
| inferred_return_untyped | 3,460 | **5,399** |
| unsupported_syntax | 10,102 | 10,063 |

**~1,900 サイト causeless→inferred。累積 WD7+WD8: causeless 10,390(49%)→5,405(26%)、actionable
inferred 351→5,399（15倍）。** ratio 不変。残る causeless は dynamic_top ノード種（yield/super/
block）+ cvar/gvar で概ね真に未モデル → actionability レバーはほぼ出し切り。unsupported 10,063
（48%）は未解決 call 根のチェーン = honest な engine-gap floor。

## 検証（2026-07-06）: redmine で provenance-wiring が一般化する

ADR-82 の全スライスは mastodon 駆動だったので、redmine（同オンボード、6プラグイン、AR は inert
＝ `db/schema.rb` 未コミット）で正確 per-site メトリクスを取り一般化を確認。

| cause | mastodon (18,695→21,119 unprot) | redmine (18,695 unprot) |
| --- | --- | --- |
| none（causeless） | 5,405（26%） | 6,913（37%） |
| unsupported_syntax | 10,063（48%） | 6,019（32%） |
| **inferred_return_untyped** | **5,399（26%）** | **5,634（30%）** |
| explicit_untyped | 252 | 127 |
| analyzer_budget_cutoff | 0 | 2 |

**両アプリで actionable な `inferred_return_untyped`（param+ivar → ADR-67/58）が 26-30%** を占め、
provenance-wiring が mastodon 専用でないことを実証。redmine の inert AR で causeless がやや多い
（37% vs 26%）が構造は一致。redmine では `analyzer_budget_cutoff`(2) も捕捉（budget 由来 Dynamic も
provenance が拾う）。ratio redmine 0.3386 / mastodon 0.3148。

**結論: provenance-wiring アークは完了・一般化検証済み。** 残る actionability レバーは provenance 配線
ではなく**実 inference**（ADR-67 param inference / ADR-58 ivar typing = untyped param/ivar を
*concrete* に型付けて実際に保護 → ratio を上げる大型 feature）。provenance 作業はその穴マップを
正確に描いた: 保護天井は両アプリで param/ivar inference + 未解決 call が支配。

## GOTCHAs（再実行者向け）

- `coverage --protection` の with-sig 数値は **env-build 成否を必ず確認**すること（stderr の
  `RBS environment build failed`）。env が落ちると sig が「害」に見える偽の低下が出る。
- 生成 sig の RBS 妥当性は `RBS::Parser.parse_signature` で個別検査（env は最初の1件で abort する
  ため、env-crash だけでは何ファイルが不正かは分からない）。
- `coverage` に `--no-cache` は無い → `rm -rf .rigor/cache` でバスト。
- 生成物（`sig/`, `.rigor/cache/`）は survey チェックアウト内で untracked。計測後は破棄して
  clean baseline 状態（sig なし）に戻す。
