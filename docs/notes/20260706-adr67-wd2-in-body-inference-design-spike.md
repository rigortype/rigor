# ADR-67 WD2（in-body 構造パラメータ推論）設計スパイク — 測定付き見送り判断

Status: design spike / 測定に基づく判断メモ。2026-07-06、Rigor v0.2.7（`[Unreleased]`）。
非normative（設計コミットメントは [ADR-67](../adr/67-parameter-type-inference.md) が持つ）。本メモは
その WD2 を本実装に踏み込む前に de-risk するための測定と結論。

Grounding: 直接の親は [2026-07-06 Mastodon provenance ノート](20260706-mastodon-coverage-provenance-and-siggen-rbs-validity.md)
（provenance-wiring アークが「残る actionability レバー = 実 inference（ADR-67 param / ADR-58 ivar）」
と結論した）。本スパイクはその「ADR-67 の唯一残るレバー = WD2 in-body 推論」に絞り、測定で payoff を
検証する。

## 問い

provenance アークは protection 天井の地図を描いた（mastodon app+lib、unprotected 21,119、ratio
0.3148）。actionable な `inferred_return_untyped` バケツは **per-site 正確値で 5,399（26%）**、うち
param 由来が ~3,100・unbound ivar 由来が ~1,900（WD7/WD8 の enrichment 差分）。call-site 推論（WD3、
実装済み）は param の call-site が解決するものを既に型付け、残った ~3,100 param サイトは
**「call-site が解決しない（動的ディスパッチ / framework コールバックで呼ばれる）untyped param」** —
これが WD2 in-body 推論の対象母集団。

WD2 は body 内で param に対して呼ばれるメソッド集合から **structural lower bound**（responds-to
セット）を導く。ADR-67 の 2026-06-26 implementation finding は「型 zoo に structural-interface
carrier が無い → 新 carrier が必要、これは『cheapest』の枠を超える大改修」と記録した。

**スパイクの検証点**: その carrier を作る価値があるか。具体的には「untyped param の body 内メソッド
集合は、実 protection を生む nominal を一意に固定できるか、それとも structural bound 止まりか」。

## 測定（純 AST probe、`scratchpad/wd2_probe.rb`）

req+opt param ごとに body 内で「その param を bare receiver に呼ぶメソッド名集合」を収集し分類:
- **no-calls**: param が body 内で一度も receiver にならない → WD2 は原理的に無力
- **all-universal**: 集合が全て universal/duck メソッド（`to_s`/`==`/`nil?`/`present?`/`[]`/`each`/
  `map`/`id`…、Object+top-Dynamic-receiver メソッド由来の寛大なリスト）→ nominal を何も固定しない
- **has-distinctive**: universal でないメソッドを1つ以上含む → WD2 が効きうる候補の上限

| corpus | params(req+opt) | no-calls | all-universal | has-distinctive |
| --- | ---: | ---: | ---: | ---: |
| mastodon app+lib | 2,318 | 1,344 (58.0%) | 435 (18.8%) | **539 (23.3%)** |
| redmine app+lib | — | — | — | ~29% |
| rigor lib（sanity） | 5,785 | 2,551 (44.1%) | 1,568 (27.1%) | **1,666 (28.8%)** |

**has-distinctive の内訳（mastodon 539）**: distinctive メソッド数 1 が 317（59%）、2+ が 222（41%）。
distinctive-1 の大半は core-duck で nominal を固定しない（`clamp`→Comparable、`merge!`→Hash/Relation、
`group_by`/`zero?`→Enumerable/Numeric）。2+（222 = 全 param の **~10%**）だけが domain 固有で nominal
を固定しうる（`account -> display_name, username, emojis`、`keypair -> revoked?, expired?`、
`log -> target_type, human_identifier, permalink`…）。

## 判断に効く3つの事実

1. **天井が小さい.** WD2 が効きうる上限は has-distinctive の 23-29%。実 nominal を固定しうるのは 2+
   distinctive の **~10%（mastodon 222 param）** のみ。残り 44-58% の no-calls は WD2 の領域ですらない
   （param が ivar 保存 / 戻り値 / 別メソッド引数に流れる = WD3 or ADR-58）。しかも probe は WD3 で
   既に型付く param を除外していないので、真の増分上限はこれより更に小さい。

2. **AR-attribute トラップが最有望層を潰す.** 2+ distinctive の domain param は Rails ヘルパの
   `account`/`status` 等で、その distinctive メソッド（`username`/`display_name`/`following_count`）は
   **AR 動的アクセサ（カラム/association）= 静的 `discovered_methods`（def スキャン）に存在しない**。
   method-set→nominal 解決を discovery index 上に組んでも、まさに pin できそうな AR モデル param で
   マッチが 0 になり untyped へ落ちる。mastodon は `schema.rb` を commit するが、それを知るのは
   rigor-activerecord プラグインの schema 知識で、汎用 method-set リゾルバが引く def-index ではない。
   redmine は `schema.rb` 未 commit（AR inert）で更に不利。→ 07-04 carrier-trap ノートの系。

3. **structural bound は protection メトリクスに対して循環的.** carrier を作って no-nominal 層に credit
   を与えても、bound は body 自身の呼び出しから導くので **同じ body の site を trivially protected と
   マークするだけ**（`concrete_receiver?` は非 Dynamic を全て protected と数える）。同一 body の typo
   （`x.fooo`）は bound 集合に自分自身が入るので bite できない。実 protection（mutation を殺す、
   ADR-63 の本旨）を得るには carrier を check-walk の undefined-method ディスパッチに載せる必要があり、
   それは CURRENT_WORK が警告する FP-risky 経路（param 使用箇所に `call.undefined-method` 誤発火）。

## 結論と推奨

**WD2 を仕様どおり（structural-interface carrier）実装するのは payoff が cost に見合わない。見送りを維持。**
- carrier 経路: 高 stakes な型 zoo 拡張（value-lattice / ADR-3 internal-type-api 契約に波及）を、循環的で
  意味の薄いメトリクス膨張のために払うことになる。ADR-67 自身の「メトリクスの意味を劣化させる」懸念の実証。
- 新 carrier 不要の nominal-resolution 経路: FP-safe（0 or 複数マッチ時 untyped）だが対象は ~10% param、
  かつ最有望の AR モデル層が事実2で潰れる。増分は僅少と予測。

これは provenance ノート §4 のレバー順位（1 provenance-wiring[済] → 2 env-build resilience →
3 sig-gen RBS validity → 4 ADR-67/58 大型 feature）とも整合する。WD2 は #4 の中でも最も割の悪い部分。

**次レバーの推奨（本スパイクの含意）**: protection 天井を直接押すのは大型 feature でしか動かず割が悪い。
より高ROIの近接レバーは (a) **env-build resilience**（不正 sig 1ファイルが env 全体を落とす不均衡の
quarantine + 可視化 — sig-gen を実用化し、07-04 H3 の silent failure を塞ぐ、bounded）、(b) `0.2.x`
評価ラインの consolidation / 外部フィードバック収集（v1.0 freeze への本来目的）。WD2/ADR-67 大型化は
外部から M3 が top `add_a_type_here` として繰り返し来る具体需要が出るまで defer（ADR-67 re-eval
trigger のまま）。

## 再評価トリガ（更新なし、ADR-67 のまま）

- 外部プロジェクトで M3（untyped param）が top `add_a_type_here` として反復surfaced、**かつ**
  AR-attribute トラップの影響が薄いコードベース（schema+plugin 完備 or 非 Rails の domain-object 中心）
  であること。本スパイクは「Rails app では AR 動的アクセサが最有望層を潰す」を新たな反証条件として追加。
- ADR-46 incremental が WD3 call-site パスを per-file model 内で affordable にする（in-body より先に
  call-site の天井を上げる方が高ROI）。

## 成果物 / 再現

測定は純 Prism の使い捨て probe（env 不要、リポジトリ未コミット）。上の「測定」節のアルゴリズム
（req+opt param → body 内 bare-receiver 呼び出し集合 → no-calls / all-universal / has-distinctive
分類、universal リストは Object+top-Dynamic-receiver メソッド）で再現可能。3 corpus
（mastodon/redmine/rigor-lib）で分類分布が一致。
