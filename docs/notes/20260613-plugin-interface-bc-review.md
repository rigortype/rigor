# プラグインインターフェイス最終レビュー — v1.0 凍結前の BC-break 機会監査

*2026-06-13. Status: pre-freeze interface review — informational, feeding the release
decision and any final plugin-API BC-break work. The spec and ADRs bind. Observations
against working tree @ `c1bddcc2` (v0.1.18 released), production plugins 31 +
examples 6 を全数調査（大型 8 プラグインは精読、残りは grep + 抜粋）。*

## Question

ADR-50 は v1.0.0 で公開プラグイン面（DSL 名・Manifest フィールド・`Services` /
`FactStore` / `Scope` 公開リーダー）を凍結する。**いまが互換性を壊せる最後の窓**。
ADR-37（インターフェイス分離）→ ADR-52（コンパイル済み貢献ディスパッチ、
`flow_contribution_for` 削除込み）→ ADR-53 Track B（walk 一本化）が着地した現在の
契約面を、(a) パフォーマンス、(b) プラグイン執筆体験の両面から評価し、
「凍結前に壊すべきもの」「追加で足せば済むもの」「壊さないと裁定するもの」を
仕分ける。

## 結論サマリ

**パフォーマンス面で BC break を要する構造問題はもう残っていない。** 2026-06-10
監査の所見 1–6 は ADR-52/53 で全て着地し、ホットパス（per-dispatch / per-node）は
すべてコンパイル済みインデックスでゲートされている。残る最適化はインターフェイス
形状と独立。

**執筆体験面の摩擦は実在するが、大半は追加的（additive）に解消できる。** 真に
BC break を要する候補は 3 件 — (1) 未配線 `external_files:` フィールドの凍結前撤去、
(2) マクロ value object 群の命名不統一の正規化、(3) `io_boundary` → `cache_for`
の順序依存契約の宣言化。いずれも ADR-52 slice 5b の先例（load 時エラー +
CHANGELOG 移行表 + bundled 全数同時移行 + corpus byte-identical ゲート）で安全に
実行できる。

## 1. パフォーマンス面 — 2026-06-10 監査からの差分

[前回監査](20260610-plugin-architecture-perf-audit.md)の所見ごとの現状:

| 所見 (2026-06-10) | 現状 (2026-06-13) |
| --- | --- |
| 1. `flow_contribution_for` がゲート不能 | **解消** — ADR-52 WD3 でフック削除（load 時 `ArgumentError`）。全 5 レガシーユーザーが `dynamic_return` の静的/`methods:` callable/`file_methods:` ゲートへ移行済み |
| 2. 同一コールノードへの二重問い合わせ | **解消** — 戻り値は `MethodDispatcher`、post-return facts は `StatementEvaluator` と関心ごとに 1 経路ずつ。各経路とも `ContributionIndex` の O(1) メソッド名ゲートが先に立つ |
| 3. メソッド名の横断インデックス不在 | **解消** — ADR-52 WD1 のコンパイル済みテーブル（`dispatch_candidate?` / `dynamic_candidate_for?` / verb-keyed `block_entries_for`） |
| 4. Registry 集約クエリの毎回再計算 | **解消** — `open_receivers` Set 化、`owns_receiver?` per-env 祖先メモ、`contracts_for_path` per-path メモ、`additional_initializers` 凍結配列 |
| 5. node_rule walk がプラグインごと | **解消** — `Plugin::NodeRuleWalk`（ADR-52 WD4）でファイルごと 1 walk、`is_a?` 照合は具象ノードクラスごとにメモ、`NodeContext` はノードごと遅延 1 個。ADR-53 B4 で built-in ルール walk とも収斂 |
| 6. `MacroBlockSelfType` 線形照合 | **解消** — verb キーの Hash 引き |

残るコールドパス（per-file fnmatch の `protocol_contracts`（per-path メモ済み）、
`type_node_resolvers` チェーン（`%a{rigor:v1:…}` payload 解析時のみ）、
`source_rbs_synthesizer`（env 構築時 per-file 1 回））はいずれも頻度・コストとも
許容域で、ゲート化しても観測可能な差は出ない。**インターフェイスの形がボトルネックを
強制する箇所は無くなった** — これが ADR-37→52 アークの完成形であり、凍結に耐える。

唯一の将来リスクは「新しい貢献形が増えるたびに ContributionIndex へのゲート追加が
必要」という規律の維持だが、これは ADR-52 の criterion（*キーを宣言できない
capability は DSL 語彙の欠落であって、アンゲートフックの免罪符ではない*）として
既に規範化されている。凍結対象はこの criterion ごと、と確認しておけばよい。

## 2. 執筆体験面 — 実測した摩擦

37 プラグイン（production 31 + examples 6）の利用実態。

### 2.1 採用頻度の偏り（実測値）

| 面 | 利用数 | 備考 |
| --- | --- | --- |
| `manifest` / `init` | 37 / ~32 | 全数 |
| `node_rule` | ~23 | 診断系の標準路。定着 |
| `config_schema:`（default 込み） | ~20 | ADR-40 で定着 |
| `producer` + `cache_for` | ~14–16 | Rails 系ディスカバリの標準路 |
| `diagnostics_for_file` | **15** | file-level 診断（load error 報告・クロスファイル検証）の正当用途が主 |
| `dynamic_return` | 11 | ADR-52 移行完了後の唯一の戻り値寄与面 |
| `type_specifier` | **3**（rspec / sorbet / minitest） | 設計上は健全、周知が弱い |
| `protocol_contracts:` | 3 | ADR-28。Hanami 系のみ |
| `block_as_methods` / `heredoc_templates` / `trait_registries` | 2 / 2 / 1 | ADR-16 基盤。少数だが配線済み・稼働中 |
| `TypeNodeResolver` | **1**（typescript-utility-types） | ADR-13。ニッチか発見性不足か要切り分け |
| `additional_initializers:` | 1 | ADR-38 |
| `external_files:` | **0（かつエンジン消費者ゼロ）** | § 3.1 参照 |

少数利用そのものは欠陥ではない（ADR-16/13/28 はいずれも特定形状向けの基盤で、
node_rule が診断系のデフォルトであることはむしろ意図どおり）。問題は **0 利用かつ
0 配線のまま凍結に向かうフィールド**（external_files）と、**存在が
ドキュメント/SKILL から見えない面**（type_specifier / TypeNodeResolver）の 2 種。

### 2.2 ボイラープレートの再発パターン（実測値）

1. **fact-store / producer 読み出しの手書き遅延メモ化** — `*_index_or_nil` 私的
   ヘルパーが **12 プラグイン**（13 個）、うち 4 つは「nil 結果と未照会を区別する」
   `@x_resolved` フラグ持ち。`consumes:` の宣言は declarative なのに、読み出し側は
   毎回 8–15 行の同型コードという非対称。
2. **`io_boundary` → `cache_for` の順序契約** — FileEntry digest の蓄積が副作用で、
   `cache_for` のスナップショット**前**に読みを済ませないと **サイレントに stale な
   キャッシュ**になる。rigor-actionpack / rigor-rails-routes は警告コメントで人間に
   順序を念押ししている（actionpack.rb:191, rails_routes.rb:218）。静的にも実行時にも
   強制されない、契約面で最も危うい箇所。
3. **violation → `diagnostic()` の詰め替え** — node_rule 利用 ~23 プラグインが
   ほぼ同型の 3–8 行 `.map { diagnostic(node, path:, location:, message:, …) }` を持つ。
4. **同名私的ヘルパーの分散** — `canonical_path` / `controller_file?` 系のパス判定 /
   `load_error_diagnostic` / `scannable_paths`（runner の `expand_paths` 再実装、
   dry-types / graphql / mangrove の 3 か所）など、計 ~80–100 行。

### 2.3 流儀が割れている箇所

- **fact 公開の 2 流儀**: `prepare` 内で `fact_store.publish` 明示（dry 系 /
  graphql / mangrove）vs `producer` ブロック経由（Rails 系）。どちらも正当だが
  使い分け基準が文書化されていない。
- **エラー処理の 3 流儀**: rescue して `@load_error` に積み
  `diagnostics_for_file` で報告 / rescue して黙って nil / rescue せず分離ハーネスに
  任せる。ガイドライン不在。
- **型寄与の 3 面**（`dynamic_return` / `type_specifier` / `TypeNodeResolver`）の
  使い分けはコードを読まないと分からない。役割分担自体は原理的（§ 4.1）。

## 3. BC break 候補の裁定

### 3.1 Tier 1 — 凍結前に壊すべき（要 BC break）

**(a) `external_files:` Manifest フィールドの撤去（または experimental 隔離）。**
ADR-16 Tier D の宣言だけが先行し、エンジン消費者は CLI の件数表示のみ
（`plugins_command.rb` のカウント）。grep で確認したとおり analysis 側の配線はゼロ。
**配線されないフィールドを v1.0 で凍結すると「永久に空約束の公開面」になる** —
これは ADR-50 の凍結 criterion（enumerated surface は動作を伴う）に正面から反する。
demand が来た時に value object ごと再導入するのが正しく、撤去は今しかできない。
他の ADR-16 value object（heredoc / trait / block_as / nested_class）は
`SyntheticMethodScanner` / `MacroBlockSelfType` に配線済み・稼働中で、撤去対象では
ない。

**(b) マクロ value object 群の命名正規化。** 同じ「DSL メソッド名」概念が
`block_as_methods` では `verbs:`、heredoc / trait / nested_class では
`method_name:`。シンボル引数位置が `symbol_arg_position`（heredoc / trait）と
`name_arg_position`（nested_class）。利用 2–3 プラグインの今なら一括リネームは
機械的だが、凍結後は別名併存を永久に背負う。`method_names:` / `symbol_arg_position`
への統一を推奨。

**(c) producer / `cache_for` / `io_boundary` 契約の宣言化。** § 2.2-2 の順序依存は
「正しく書けたかをサイレント stale cache でしか検知できない」契約であり、凍結に
耐えない。方向性は 2 案:

- 案 1（小）: `producer :x, watch: [roots, patterns…]` で glob descriptor を
  エンジン側が合成し、`glob_descriptor` 手動合成 + 順序責任を retire する。
- 案 2（大）: `cache_for` のスナップショットを呼び出し時でなくブロック**実行後**に
  取る（producer ブロック内の `io_boundary` 読みを自動キャプチャ）。

どちらも `cache_for` の意味論変更を含むため BC break。現行 16 利用すべてが
bundled なので一斉移行可能（actionmailer の 25 行ケースは ~5 行になる見込み）。
**3 候補の中で最も価値が高い** — 正しさの罠を仕組みで塞ぐ変更であり、Rigor の
FP 規律（動くコードを脅かさない）のキャッシュ版に相当する。

### 3.2 Tier 2 — 追加で足せば済む（BC break 不要、ただし凍結前に入れて
「最初から正しい形」を公開面にするのが得策）

1. **`Plugin::Base#read_fact(plugin_id:, name:)`** — nil 結果込みのメモ化を内蔵した
   読み出しヘルパー。12 プラグインの `*_or_nil` + `_resolved` 群を置換。さらに進めて
   `consumes:` 宣言からの getter 自動合成も可能だが、まずはヘルパーで足りる。
2. **violation 配列の自動ラップ** — `node_rule` ブロックの戻り値に
   `#to_diagnostic` 可能なオブジェクトを許す、もしくは `diagnostic` のバルク版。
   ~23 プラグイン × 3–8 行を畳む。
3. **`type_specifier` / `TypeNodeResolver` / fact 公開 2 流儀 / エラー処理流儀の
   文書化** — `rigor-plugin-author` SKILL とプラグイン契約ドキュメントへ。コード
   変更ゼロで § 2.3 の大半が解ける。external-author SKILL（v0.2.0 予定）にも反映。

### 3.3 Tier 3 — 検討の上「壊さない」と裁定

- **`dynamic_return` / `type_specifier` の統合**: 表面上は「型寄与 DSL が 2 つ」だが、
  役割（戻り値型 vs post-return narrowing facts）も消費フェーズ（dispatcher vs
  statement evaluator）もゲートのコンパイル形も異なる。統合 DSL は内部で結局
  分岐し、リネームコストだけ残る。**現状維持 + 文書化**（Tier 2-3）が正。
- **`diagnostics_for_file` の削除**: 15 プラグインが利用。主用途はノード walk では
  表現できない file-level 診断（discovery の load error 報告、クロスファイル検証
  の集約）。`node_rule` の劣化版としてではなく **file-rule として正当な面**。
  ContributionIndex でゲート済みでコストも無い。維持。
- **`config_schema` の二重文法**（bare kind vs `{kind:, default:}`）: ADR-40 が
  意図的 superset として採用済み。bare 形の禁止は移行コストに見合う利得がない。維持。
- **fact 公開 2 流儀の片寄せ**: `prepare`+`publish` は「キャッシュ不要の軽量
  スキャン」、`producer` は「IoBoundary 込みのキャッシュ対象ディスカバリ」と
  使い分けに実質がある。強制統一より基準の文書化（Tier 2-3）。

## 4. 凍結面そのものへの確認事項（ADR-50 WD1 向け）

1. **凍結リストから外すもの**: `external_files:`（§ 3.1-a で撤去するなら自動的に
   外れる）。
2. **凍結リストに criterion ごと載せるもの**: ADR-52 の「全貢献はエンジンが既に
   持つキーでゲートされる」規律。新フック追加時の受け入れ条件として明文化。
3. **`Scope` 公開リーダー**（`type_of` / `has_member?` / `has_key?` / `equals?`）は
   プラグインが直接呼ぶ面なので、internal-spec の implementation-expectations と
   凍結リストの両方で同一の列挙になっているか release 前に突合する。
4. ADR-2 由来の一方通行ゲート（プラグインはアプリケーションコードを実行しない /
   Scope 不変 / FactStore は plugin_id 名前空間 / fat hook は導入しない）は再確認
   済み — 本レビューでも反例なし。

## 検証プロトコル

Tier 1 の各 BC break は ADR-52 slice 5b の確立済み先例に従う: (1) load 時の明示
エラー（サイレント劣化禁止）、(2) CHANGELOG `### Removed` / `### Changed` に移行表、
(3) bundled 全プラグインを同一チェンジセットで移行、(4) Mastodon / GitLab corpus
byte-identical + `make verify`（`check-plugins` 込み）+ `make bench-perf` 中立。
(c) はキャッシュ意味論に触れるため、加えて cross-process の plugin-spec 回帰
（ADR-45 の `pundit_plugin_spec` 型）で stale-cache 不在を確認する。

## Follow-up

- Tier 1 (a)(b)(c) を 1 本の ADR（「凍結前プラグイン契約最終整理」）として起票し、
  ADR-50 WD1 の凍結列挙と同じチェンジセットで突合する。(c) は単独 ADR に切り出す
  選択肢もある（キャッシュ意味論の変更で stakes が一段高い）。
- Tier 2-1/2-2 のヘルパー追加 + 2-3 の文書化は ADR 不要、通常スライスで。
- 本ノートの採用頻度・ボイラープレート実測値は v0.2.0 の external-author SKILL
  設計の入力にもなる。
