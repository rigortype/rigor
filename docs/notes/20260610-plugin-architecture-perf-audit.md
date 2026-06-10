# プラグインアーキテクチャ構造監査 — per-call 消費経路の最適化余地

*2026-06-10. Status: structural audit feeding an ADR — informational, not normative. The
spec binds. Observations taken against Rigor v0.1.17 (working tree @ `54062b0a`).*

## Question

[Mastodon](20260604-mastodon-allocation-profile.md) /
[GitLab](20260604-gitlab-plugin-contribution-allocation.md) のアロケーション・プロファイル
と ADR-44 の対処で、プラグイン消費経路の *症状*（per-dispatch の `dup` 連打、全プラグイン
線形走査）は大きく削れた。本監査の問いはその先 — **アーキテクチャ自体を、この種の最適化が
構造的に不要になる形へ変えられるか**。コードを読んだ静的監査であり、新規プロファイルは
取っていない（プロファイル手法と数値は上記 2 ノートが基準）。

## 現状の到達点（再掲・前提）

- `Registry::ContributionIndex`（`lib/rigor/plugin/registry.rb`）が「per-call 経路を
  構造的に実装するプラグイン」を registry 構築時に 1 回だけ分類し、
  `MethodDispatcher` / `StatementEvaluator` 両方の `collect_plugin_contributions` は
  その部分集合だけを訪問する（GitLab: 11 → 2）。
- `Plugin::Base.dynamic_returns` / `.type_specifiers` のスナップショットはメモ化済み。
  貢献の収集は遅延割り当て + 共有凍結空配列。

つまり「どのプラグインを見るか」の枝刈りは済んでいる。残るコストは
**(a) 見ると決めた後の per-call 処理**と、**(b) インデックス化できない不透明経路**にある。

## 所見（影響順）

### 1. レガシー `flow_contribution_for` がゲート不能 — 最大の構造問題

オーバーライドしているプラグインは**全コールノード × 2 経路**（dispatcher の戻り値収集 +
statement evaluator の assertion 収集）で無条件に呼ばれる。ゲート条件はプラグイン内部の
コードに埋まっており、エンジン側からインデックス化できない。

残存ユーザーは production の最大手 4 つ + examples 3 つ:

| プラグイン | 実際のゲート条件 | 宣言化に必要な語彙 |
| --- | --- | --- |
| rigor-activerecord | receiver がモデルクラス／Relation（`prepare` で構築する `model_index` のキー集合） | **run 時解決の receiver 集合**（callable、`prepare` 後に 1 回評価） |
| rigor-activestorage | 同上（attachment 宣言インデックス） | 同上 |
| rigor-sorbet | `T.*` アサーション（静的名）**+ catalog 経路（ingest した sig を持つ任意の def メソッド）** | **run 時解決のメソッド名集合**（catalog キー、`prepare` 後評価） |
| rigor-rspec | ファイルごとの let 名（per-file 動的） | **per-file 名前集合**フック |
| examples/rigor-units | receiver の*次元*（refinement carrier、nominal class なし）+ 静的メソッド名集合 | **静的メソッド名ゲート（receiver 不問）** |
| examples/rigor-lisp-eval / -pattern | config 由来の単一メソッド名 | run 時メソッド名（config 由来） |

> **2026-06-10 訂正**: 当初この表は「rigor-activesupport-core-ext = メソッド名集合」
> を 5 番目に挙げ、sorbet を「静的メソッド名ゲート」に分類していた。実装時の精査で
> 両方とも誤りと判明した — **activesupport-core-ext は `flow_contribution_for` を
> 持たない純 RBS バンドル**（移行対象ですらない。grep はコメント言及にヒットした）、
> **sorbet は catalog 経路で任意 def メソッドにマッチする**ため静的名前集合に収まらず
> run 時集合が必要。結果、**静的メソッド名ゲートに収まる実プラグインは存在せず**、
> その最初の消費者は examples/rigor-units だった（ADR-52 slice 2 で移行済み）。

`dynamic_return` DSL（ADR-37 slice 2）は当初 receiver を**静的なクラス名 Array**でしか
宣言できなかった。ADR-52 WD2 slice 2 で **receiver 不問（`methods:` のみ）の静的ゲート**
を追加し units を移行。残る production 4 + config 由来 examples 2 は run 時集合
（receiver / メソッド名 / per-file）が必要で、slice 3 以降で対応する。

### 2. 同一コールノードへの二重問い合わせ

`MethodDispatcher#collect_plugin_contributions`（戻り値）と
`StatementEvaluator#collect_plugin_contributions`（post-return facts、
`apply_plugin_assertions` 経由で**全コール文**に対して走る）が独立に収集する。
レガシープラグインは 1 コールにつき内部判定をフルに 2 回支払う。
GitLab プロファイルで `StatementEvaluator` 側だけで 3.5 % のアロケーションが
これに相当する。

### 3. メソッド名の横断インデックスがない

- `type_specifiers` は**純粋にメソッド名ゲート**なのに、照合は
  プラグインごと・ルールごとの線形 `rule[:methods].include?(name)`
  （`Plugin::Base#type_specifier_facts`）。
- `dynamic_return_type` はルールごとに receiver 祖先照合
  （`class_matches_receiver?` → `environment.class_ordering`）を per-dispatch で
  やり直す。`methods:` ゲートがあるルールでも receiver 照合が先に走る。

圧倒的多数のコール（`each` / `map` / `+` …）はどのプラグインも関知しないのに、
「関知しない」ことの確認が O(対象プラグイン × ルール) かかる。registry 構築時に
`Hash[Symbol → [(plugin, rule)]]` の逆引きを作れば典型パスは Hash 1 引きで終わる。

### 4. Registry 集約クエリが毎回 flat_map 再計算

Registry は構築時に freeze されるのに、以下は呼び出しごとにその場で集約する:

| クエリ | 呼び出し頻度 | 現状コスト |
| --- | --- | --- |
| `Registry#open_receiver?` | `call.undefined-method` 候補ごと（`Analysis::CheckRules`） | flat_map + Array#include? |
| `Registry#additional_initializers` | def ノードごと ×2 箇所（`ScopeIndexer`） | flat_map |
| `Registry#contracts_for_path` | def ごと（`MethodParameterBinder#apply_protocol_contract`） | flat_map + 全 contract fnmatch |
| `MethodDispatcher#plugin_owns_receiver?` | user-class fallback に届いた dispatch ごと | 全プラグイン × owns_receivers × `class_ordering` |

すべて ContributionIndex と同様の「構築時 1 回の前計算」に置き換え可能
（Set 化・union 凍結・per-path / per-class メモ）。クラスグラフは run 中不変なので
`(class_name, constraint) → bool` のメモ化は健全。

### 5. node_rule の AST walk がプラグインごと

`Plugin::Base#node_rule_diagnostics` は各プラグインが自分用に
`Source::NodeWalker.each_with_ancestors` をフル実行する。node_rule を持つプラグインが
N 個あればファイルごと N 回の全ノード走査。加えて `NodeContext` が
**マッチするルールごと**に割り当てられる（ノードごと 1 回で足りる）。
ADR-37 の「エンジンが walk を所有する」原則は per-plugin 単位でしか実現されておらず、
エンジンが**ファイルごと 1 回**の walk に全プラグインのルールを
`node_type → [(plugin, rule)]` でマージ消費する形が自然な完成形。

### 6. `MacroBlockSelfType` の線形照合

ブロック付きコールサイトごとに 全プラグイン × `block_as_methods` を線形照合
（`lib/rigor/inference/macro_block_self_type.rb`）。verb（メソッド名 Symbol）で
Hash 引きできる形をしている。

### 補遺（小粒）

- `Environment#class_ordering` の `normalize_class_name` は `delete_prefix` で毎回
  文字列を新規割り当てする（prefix が無くても）。
- runner の `plugin_emitted_diagnostics` は全プラグインに `diagnostics_for_file` を
  毎ファイル呼ぶが、デフォルト実装（`[]`）かどうかは構築時に判別できる
  （ContributionIndex の `flow_overridden?` と同じ `Method#owner` 判定）。

## 提案 — 3 段階

### 短期: Registry 構築時前計算の徹底（機械的、診断不変が自明）

所見 3・4・6・補遺を ContributionIndex の拡張（ないし後継の単一テーブル）として実装:
type_specifier / dynamic_return(methods: 付き) / block_as_methods のメソッド名逆引き
Hash、open_receivers の Set 化、additional_initializers / owns_receivers の union
凍結、contracts_for_path の per-path メモ、`(class, constraint)` 祖先判定メモ、
NodeContext のノードごと 1 回割り当て。ADR-44 と同種の純アロケーション削減で FP リスクなし。

### 中期: DSL 語彙の拡張 → レガシーフック廃止（本丸、要 ADR）

所見 1 の右列 3 語彙 — (a) run 時解決 receiver 集合（callable）、(b) メソッド名のみ
ゲート、(c) per-file 名前集合フック — を `dynamic_return` / `type_specifier` 系 DSL に
追加し、5 プラグインを移行。完了後 `flow_contribution_for` を deprecate。
正式リリース前（ADR-50 の freeze は v1.0）なので BC 制約はない。
PHPStan の `DynamicMethodReturnTypeExtension`（クラス名キーの registry）と同型の着地。

### 長期: コンパイル済み貢献テーブルへの一本化

宣言化された全貢献を run 開始時に 1 つの凍結ディスパッチテーブルにコンパイルし、
エンジンのホットサイトは「手元の値（メソッド名 Symbol / receiver クラス名）で Hash を
引くだけ」にする。所見 2 の二重問い合わせもテーブル経由で per-call-node 1 回の収集に
統合。凍結テーブルは Ractor-shareable なので ADR-15 Phase 4 の Blueprint 再構築コスト
低減にも効く。

## 検証プロトコル

各段階とも既存手法で測る: stackprof（throwaway GEM_HOME）+ alloc カウントを
Mastodon `app/models`（6 プラグイン）/ GitLab 構成サブセット（11 プラグイン）で取得し、
**診断 byte-identical** を合格条件にする。cwd=target + 当該プロジェクトの
`.rigor.yml` で実行（cwd=rigor だと plugin 相対パス探索が壊れる —
[Mastodon ノート](20260604-mastodon-allocation-profile.md)の方法論）。

## Follow-up

- この監査を入力として ADR（プラグイン貢献の宣言化完遂 + 単一ディスパッチテーブル）を
  起票する。
