# プラグイン機構 1.0 前最終レビュー — 過不足・ペインポイント・ボイラープレート

Status: Research / pre-1.0 optimization review. 非規範。受理された項目は個別 ADR
（主に [ADR-2](../adr/2-extension-api.md) の改訂）と internal-spec に graduate する。
本ノートは「正式リリース前に直すべきか/1.x に送るか」を仕分けるための棚卸し。

対象: `plugins/` 31 エントリ + `examples/` 6 ウォークスルー + コア
（`lib/rigor/plugin/`, `lib/rigor/source/`）のプラグイン向け表面。
2026-06-01 時点のツリーに対する横断調査。各指摘は file:line で裏取り済み。

---

## 0. エグゼクティブサマリ

プラグイン契約そのもの（ADR-2 が約束した Scope / Type / Reflection / FactStore /
IoBoundary / 各 manifest フィールド）は**実装されており機能している**。
`Scope#type_of` をはじめ ADR-2 が約束したエンジンクエリは plugin に渡る
`scope:` 経由で実際に露出している（gate されていない）。

問題は契約の有無ではなく、**契約と作者の間に「著者向けユーティリティ層」が無い**こと。
その結果、ほぼ全プラグインが同じ補助コードを再実装し、しかも再実装の過程で
微妙な差異（インフレクタ2種、camelize 2種、describe 判定2種…）と
**実害のあるキャッシュ不整合バグ**を生んでいる。

優先度の高い順に:

1. **【バグ・要修正】** factorybot / pundit / sidekiq が `cache_for` に
   `descriptor:` を渡さず、プロセス跨ぎで discovery index が無効化されない
   （ファイル編集してもウォームキャッシュが stale を返す）。
2. **【契約ギャップ】** コアに `Source::NodeWalker` 等が**存在するのに plugin に
   露出しておらず**、`diagnostics_for_file` の docstring は「自分で root を走査せよ」と
   明示。著者向けヘルパー層（walker / diagnostic ビルダ / リテラル抽出 / did-you-mean /
   config 既定値）の欠如が全ボイラープレートの根本原因。
3. **【契約ギャップ】** `Manifest#with(**overrides)` が無く、rbs-inline が
   manifest 20 フィールドを手書きコピーしている（フィールド追加で確実に腐る）。
4. **【1.0 前に判断】** produced-but-unconsumed な ADR-9 fact（graphql ×4 /
   dry-validation / dry-schema）と、docstring が約束するのに未実装の診断が複数。
   「公開契約として 1.0 に載せるか」を意図的に決める必要がある。
5. **【アーキテクチャ・1.0 前に判断】** 現行の fat `Plugin::Base`（多数の任意
   フックを持つ単一クラス）を PHPStan のように narrow interface へ分割すべきか
   → **§6**。結論を先取りすると、Rigor は既に manifest 宣言フィールド 10 個で
   PHPStan 型の分割を達成しており、残る imperative フック 2 個
   （`flow_contribution_for` / `diagnostics_for_file`）だけが「全員呼び出し・自前
   ゲート」の holdout。AI エージェントの把握しやすさ・テスト容易性の最終目標は、
   この 2 個を同じ宣言的・engine-gated パターンへ寄せることで最もよく満たせる。
   フックのシグネチャは 1.0 で公開契約として凍結されるため、**分割するなら今**。
6. **【拡張種別の選別取り込み】** PHPStan の拡張**種類**のうち Ruby で実需があり Rigor に
   **未実装**のものを選別 → **§7**。最有力は `AdditionalConstructors` の Ruby 版
   = **`additional_initializers:`**（ivar 型シードを `initialize` 以外の rspec `before` /
   minitest `setup` / Rails callback にも開く小機能、FP 規律に直撃）。次点が sealed /
   網羅性（`AllowedSubTypes` 版、ADR-36 を完遂）。`ResultCacheMeta` 等は**実装済みなので
   作らない**。

---

## 1. ボイラープレート（最大の発見）

### 1.1 重複の規模（機械計測）

| 再実装パターン | 件数 | 代表箇所 |
| --- | --- | --- |
| AST 再帰ウォーカー（`def walk` / `compact_child_nodes.each`） | **25 プラグイン** | statesman.rb:152, actionpack（4コピー/1ファイル） |
| `Rigor::Analysis::Diagnostic.new` 直接構築（`column: start_column+1`） | **23 プラグイン** | 全 diagnostic 系 |
| Prism ノードからリテラル Symbol/String 抽出 | **20 プラグイン** | statesman.rb:145, コア内でも 4 重複 |
| `config.fetch("x", DEFAULT_X)` + `DEFAULT_*` 定数 | **17 プラグイン** | statesman.rb:59-67 |
| `rescue StandardError → @load_error` 一回限り発行 | **10 プラグイン** | pundit.rb:102-118 |
| `levenshtein` / `did_you_mean` 自前実装 | **4 プラグイン** | statesman.rb:159-192, routes ↔ activerecord は逐語コピー |
| 定数パス serializer（`constant_path_name`/`qualified_name_for`） | **~12 箇所**（pundit/sidekiq/rspec は 1 ファイル内 2 コピー） | sorbet ×4, lisp-eval, units |
| discoverer 骨格（`walk_for_X`+`visit_class`+`read_safely`+`ruby_files_under`） | activejob/actioncable/activestorage/actionmailer ほぼ逐語 | job_discoverer.rb |
| index クラス（frozen `@by_name` + `find/known?/empty?/size/names`） | JobIndex/ChannelIndex/MailerIndex/WorkerIndex/PolicyIndex/FactoryIndex | worker_index.rb:12 が「同じ封筒形」と自認 |

### 1.2 根本原因 — コアにあるのに露出していない

| ヘルパー | コアに存在? | plugin に公開? |
| --- | --- | --- |
| AST ウォーカー | **あり** `Rigor::Source::NodeWalker`（node_walker.rb:17-35、`.each(root)` Enumerator） | ❌ `Services` 非注入・drift spec 非掲載。`base.rb:168-171` が「自分で走査せよ」と明示 |
| ノード→Diagnostic 行 | 部分的（`Analysis::Diagnostic` はあるが `from_node` 無し。コアも `check_rules.rb` で 15+ 箇所インライン `start_column+1`） | ❌ ヘルパー無し |
| リテラル Symbol/String 抽出 | ロジックは**コア内で 4 重複**（observation_collector.rb:310, generator.rb:895, return_type_heuristic.rb:78, synthetic_method_scanner.rb:544） | ❌ 抽出されていない |
| levenshtein / did-you-mean | **無し**（Ruby 標準 `DidYouMean::SpellChecker` はある） | ❌ net-new |
| config 既定値 | **無し**（`config_schema` は kind 検証のみ、default スロット無し） | ❌ |

→ コアが既に持つ #1（walker）・#3（リテラル抽出）を露出するだけで、plugin 側の
コピペ表面の大半が消える。しかも #3 はコア内の 4 重複も同時に解消できる
（双方向で元が取れる、最高 ROI）。

### 1.3 提案する著者向け層

ADR-2 改訂として、以下を `Rigor::Plugin::Base` のインスタンスヘルパー
（または `Plugin::AstSupport` mixin / `services.` アクセサ）で提供:

- `walk(root) { |node| }` / `each_node(root)` ← `Source::NodeWalker` を再エクスポート
- `diagnostic(node, rule:, severity:, message:)` ← `start_column+1` 規約を内包。
  併せて `Diagnostic.from_node(...)` をコアにも入れて `check_rules.rb` のインラインを統一
- `literal_symbol(node)` / `literal_string(node)` / `symbol_arguments(call)`
  ← `Rigor::Source::Literals` を新設、コア 4 重複も巻き取り
- `suggest(name, candidates)` ← `DidYouMean::SpellChecker` ラップ。
  statesman/routes/activerecord の自前 levenshtein を全廃
- config 既定値: `config_schema` のエントリ形を `{kind:, default:}` に拡張し、
  `Base#config` が construct 時に既定値をマージ。`DEFAULT_*` 定数イディオムを撤廃
  （`Manifest` スキーマ変更 → ADR ノート必須）

### 1.4 抽出すべき共通抽象（より大きな単位）

著者向けヘルパーの上に、繰り返される「プラグインの型」を基底クラス化:

- **`ProtocolContractChecker` 基底**（ADR-28 系）— hanami `ActionChecker` と
  web `ProtocolChecker` は `path_matches?` / `class_nodes` / `direct_defs` /
  `collect_direct_defs` / `singleton_def?` / `walk` / `class_name` が**逐語一致**。
  ADR-28 プラグインが増えるほど線形に重複。arity チェック有無も揃う。
- **`ClassDiscoverer` 基底 + `NameKeyedIndex`** — Rails discovery 系
  （activejob/actioncable/activestorage/actionmailer）の discoverer + index を
  base + 小さな抽出ブロックに圧縮。約 4 ファイル分の AST 走査が消え、
  将来の Prism ノードバグを 4 重に直す必要がなくなる。
- **`SourceScanner` mixin**（宣言収集系）— dry-types/dry-schema/dry-validation/
  graphql/statesman が `scannable_paths` / `scan_file`-rescue / `tree_walk` /
  `constant_name_for` を再実装。しかも nil 返し / `::`前置 / tail-match と
  **挙動が割れており、それ自体が correctness リスク**。1 つの正規実装に統一。
- **`Plugin::Testing::Narrowing`** — rspec `MatcherAnalyzer` と minitest
  `AssertionAnalyzer` が `literal_value_for` / `nominal_type_for` /
  `FlowContribution::Fact` 構築を逐語重複（ソースコメントが重複を自認）。
- **`Plugin::Inflector`** — routes が 2 つ・activerecord が 1 つ・
  actionmailer/actionpack が `underscore` を計 4 コピー。
  routes_parser.rb:1498-1534 は「片方が他方を採用できるまで同期」と自認。

---

## 2. キャッシュ・I/O・信頼境界

### 2.1 【バグ】descriptor 無し discovery キャッシュ（要修正）

factorybot / pundit / sidekiq は `cache_for(:index, params: {})` を
**`descriptor:` 無し**で呼ぶ（factorybot.rb:142, pundit.rb:105, sidekiq.rb:99）。
すると cache key は「同プロセス内で IoBoundary が既に読んだファイル」だけに依存し、
フレッシュプロセスでは空 → policy/worker/factory ファイルを編集してもウォーム
`rigor check` が **stale を返す**。`base.rb:298-310` の docstring 自身がこれを
「discovery 系は必ず `glob_descriptor` を渡せ」と警告している。

修正: `cache_for(:index, descriptor: glob_descriptor(@search_paths, "**/*.rb"))`。
factorybot の自前 `prime_io_boundary_for_index`（glob_descriptor の劣化再発明）は削除。

### 2.2 信頼境界バイパス

- rbs-inline の `Synthesizer#call` が `File.read` を**直接**使用
  （rbs_inline.rb:62-67）。他プラグインが守る `io_boundary` / `TrustPolicy` を
  経由しない契約ギャップ。
- 一方 examples/rigor-routes（routes.rb:98-106）は「read_file → digest 記録 →
  cache_for」の順序依存を**正しく**教えるが、順序を崩すとサイレントに無効化が
  壊れる脆さ。コアに「この producer が依存するファイル群」を宣言的に渡す API が
  あれば順序依存自体が消える。

### 2.3 2 つのキャッシュ起動イディオム

`glob_descriptor(...)` 渡し（i18n/actionmailer/actioncable）と
read-then-`cache_for`（routes/activejob/activerecord/actionpack）が混在。
同じ「初回 descriptor 空」問題を別々に解いている。1 つに標準化すべき。

---

## 3. Manifest / 契約面

### 3.1 Manifest フィールドの肥大と `with` の欠如

`Manifest` は 21 フィールド・各 `validate_*!` を持つまで成長
（manifest.rb:43-83）。これ自体は段階的拡張の結果で妥当だが、**コピー手段が無い**。

rbs-inline は synthesizer を後付けするため manifest 20 フィールドを
**手書きで逐語コピー**している（rbs_inline.rb:136-158）。新フィールド追加で確実に腐る。
→ `Manifest#with(**overrides)` をコアに追加（最優先の小修正）。
併せて rbs-inline は唯一 `init` でなく `initialize` を override しており
（rbs_inline.rb:111-122）テンプレとして悪い前例 — `init` 規約へ寄せる。

### 3.2 RBS-only プラグインのセレモニー

activesupport-core-ext は「`signature_paths: ["sig"]` だけの空 `Base` サブクラス +
`register`」（activesupport_core_ext.rb:23-33）。ADR-25 の正規形ではあるが、
analyzer コード皆無の純 RBS バンドルに約 12 行の定型クラスを強制している。
`.rigor.yml` の gem 列挙だけで signature_paths を取り込める**宣言的経路**を検討。

### 3.3 ADR-2 が約束して未提供の表面

- **`ContextInfo` companion（ADR-2 §Scope Object）が未実装**。plugin は
  `path`/`scope`/`root` のみ受け取り、lexical context（現在クラス/メソッド/
  可視性/assertion 文脈）は自分で root を走査して導出するしかない。
- logger サービスは deferred 明記（services.rb:24-26）。許容。

---

## 4. 機能の過不足

### 4.1 produced-but-unconsumed な ADR-9 fact（1.0 前に判断）

- graphql の 4 fact（`:graphql_type_table` ほか）は**現状すべて読者なし**
  （graphql.rb:30-39 が将来の demand-driven 消費者を挙げるのみ）。
- dry-validation の `:dry_validation_contracts` も produced-but-unconsumed
  （消費する slice 2 自体が deferred、dry_validation.rb:29-40）。
- dry-schema の `:dry_schema_table` も実消費者は dry-validation slice 2 待ち。

→ 「1.0 の公開契約として fact を載せるか、消費者が来るまで internal に留めるか」を
意図的に決める。produced-but-unconsumed のまま公開すると後方互換負債になる。

### 4.2 docstring が約束して未実装の診断（drift）

- sorbet: `dynamic.sorbet.unsupported` / `degraded` が未実装で、`T.proc`/`T::Struct`/
  `T::Enum`/`type_parameters` の `Dynamic[top]` 降格が**完全にサイレント**
  （type_translator.rb:43-48）— ユーザーは型が落ちた事実を知れない。
- dry-types: `dry-types.unknown-alias` / `alias-shadow`（dry_types.rb:46-58）未実装。
- dry-schema: `unknown-predicate` / `unknown-type`（dry_schema.rb:69-76）未実装。
- statesman: docstring 表に `event :sym` 検証があるが実装は `state`/`transition_to`
  のみ（statesman.rb:43 vs collect/validate）。
- graphql: alias 解決を docstring が示唆するが未実装（`BaseObject = …; class X < BaseObject` は素通り）。

→ 各 docstring を実装に合わせて下方修正するか、診断を実装する。1.0 で
docstring=契約と読まれると約束違反になる。

### 4.3 lossy な `bool/Boolean → TrueClass` 写像

dry-types（alias_scanner）/ dry-schema（schema_scanner.rb:24）/ graphql
（type_scanner.rb:23）が bool を `TrueClass` に写像。**`false` を誤型付け**する
プロジェクト横断の精度床。適切な bool キャリアに統一すべき。

### 4.4 常時 `:info` ノイズ

factorybot / pundit / sidekiq / statesman が正しい呼び出し**全件**に `:info`
診断を出す（factory-call / policy-call / worker-call / known-state）。実プロジェクトで
出力を埋める。verbosity ノブ裏に隠すか既定オフに。

### 4.5 個別の過不足（多くは scoped deferral、優先度中〜低）

- devise: 合成メソッドが全て `Dynamic[T]` 返し（return 精度なし、slice 6 待ち）。
  かつ `current_user` 等コントローラヘルパーは scope 外 — Devise プラグインに
  ユーザーが最も期待する箇所が未提供（ADR 通りの割り切りだが期待ギャップ最大）。
- activestorage: manifest が `consumes: model_index` を宣言するが**実際には読まない**
  （常に standalone discovery、activerecord と同じ `app/models` を二重パース）。
  誤解を招く宣言 → 削除 or 実消費。
- pundit: 名前空間モデル（`Blog::Post`）のポリシ名解決が完全修飾形を仮定し、
  flat policy 名のアプリで誤検知しうる（analyzer.rb:91-99）。
- actionpack: `unknown_helper_diagnostic`/`wrong_arity_diagnostic` が定義のみ未使用
  （~20 行 dead code）、`STRONG_PARAMS_RECEIVER_NAMES` の 2 名が dead config。
- dead data: i18n `value_kinds`、activejob `keyword_required`、actioncable
  `action_methods` が収集されるが未参照（キャッシュスライスに無駄に載る）。
- vendored テーブルの drift リスク: rspec-rails の Rack ステータス表、
  devise の modules 表 — gem バージョンに対し検証なし。

### 4.6 examples（テンプレ）の anti-pattern 教育

examples は「プラグインの書き方」正典なので、ここのボイラープレートが実プラグインに
コピーされる。特に:

- deprecations が `receiver:` 照合を**ソース文字列等価**で教える（deprecations.rb:97-101）
  — `::User` / 改行 / 空白で取りこぼす。型ベースでないことを README 明示すべき。
- lisp-eval/units/routes のコメントが「return-type contribution は v0.1.x 待ち」と
  書くが**実コードは実装済み** — ドキュメントが実装に追いついていない。
- contract surface のカバレッジが例間で不均一（web は return-type conformance まで
  あるが arity 無し、hanami は arity あり）。

---

## 5. 推奨アクション（優先度順）

### 1.0 前に入れるべき（小さく・高 ROI）

1. **factorybot/pundit/sidekiq の cache descriptor バグ修正**（§2.1）— correctness。
2. **`Manifest#with(**overrides)` 追加**（§3.1）— rbs-inline の 20 フィールド手写し撤去。
3. **著者向けヘルパー層の最小セット露出**（§1.3）— `Source::NodeWalker` 再エクスポート、
   `Diagnostic.from_node` / `Base#diagnostic`、`Source::Literals` 新設（コア 4 重複も解消）。
   ADR-2 改訂 1 本で済む。これだけで 25 プラグインのコピペが消え、テンプレも健全化。
4. **docstring drift の一掃**（§4.2, §4.6）— 未実装診断の約束を下方修正、
   examples のコメント/実装の齟齬を解消。コード変更ほぼ無しで契約の正直さが上がる。
5. **produced-but-unconsumed fact の去就を決定**（§4.1）— 公開 or internal 留保。

### 1.0 直後（中規模リファクタ）

6. **共通基底の抽出**（§1.4）— `ProtocolContractChecker` / `ClassDiscoverer`+
   `NameKeyedIndex` / `SourceScanner` / `Testing::Narrowing` / `Inflector`。
7. **config 既定値スキーマ**（§1.3 末尾）— `DEFAULT_*` イディオム撤廃。
8. **bool キャリア統一**（§4.3）、**info ノイズ既定オフ**（§4.4）、dead code/data 除去（§4.5）。

### 1.x 以降（要追加設計）

9. **`ContextInfo` の提供**（§3.3）、信頼境界の宣言的ファイル依存 API（§2.2）、
   RBS-only プラグインの宣言的経路（§3.2）。

---

## 6. インターフェイス分割の検討 — PHPStan 型 vs 現行 fat `Plugin::Base`

> 最終目標: **AI エージェントが規則と機能を把握しやすく、テスト・検証しやすい**
> プラグインアーキテクチャ。パフォーマンス低減は副次（キャッシュで緩和可、非クリティカル）。

### 6.1 現状の正確な再構成 — Rigor は既に「2/3」分割済み

「現行インターフェイスのままで十分か」を論じる前に、現状を正確に分類する。
Rigor のプラグイン拡張点は**2つのスタイルが併存**している:

| スタイル | 拡張点 | エンジンの扱い | ゲート | PHPStan 型か |
| --- | --- | --- | --- | --- |
| **A. 宣言的 manifest フィールド**（10個） | `block_as_methods` / `trait_registries` / `heredoc_templates` / `nested_class_templates` / `type_node_resolvers` / `protocol_contracts` / `hkt_registrations` / `hkt_definitions` / `source_rbs_synthesizer` / `owns_receivers` / `open_receivers` | 各フィールドを `registry.plugins` から `flat_map` で集約し、**エンジンが index 化**（`SyntheticMethodScanner`・`ResolverChain`・`Registry#contracts_for_path` 等）。verb/receiver/class/path で**エンジンがゲート** | エンジン側 | ✅ **既に PHPStan 型** |
| **B. imperative フック**（2個） | `flow_contribution_for(call_node:, scope:)` / `diagnostics_for_file(path:, scope:, root:)` | **全 plugin を全 node/file に対して呼ぶ**。`registry.plugins.filter_map { … }`（`method_dispatcher.rb:663` と `statement_evaluator.rb:1379` に**逐語2重コピー**） | **plugin 内の自前 `if`** | ❌ fan-out + self-gate |

→ **論点の正しい立て方**: 「PHPStan の思想を採用すべきか」ではない。Rigor は
拡張点 12 個中 10 個で既に採用済み。問うべきは「残る 2 個の imperative フックも
同じ宣言的・engine-gated パターンに揃えるか（= 分割を**完遂**するか）」である。

### 6.2 PHPStan から移植すべき不変条件（1点だけ）

PHPStan は ~50 の narrow interface を持つが、本質は 1 つの不変条件:

> **cheap な gate 述語**（bool/`nil`-decline）と **expensive な payload**（`Type`/error/
> data を返す）を分離し、エンジンが gate 値（`getClass()` / `getNodeType()`）で
> 拡張を **index 化**して、payload は一致 node/receiver にだけ呼ぶ。

- 型推論3兄弟: `getClass()` + `isMethodSupported()` でゲート → `getTypeFromMethodCall()` は通過後のみ。
- ルール: `getNodeType()` で AST node クラス別に index → 一致 node にだけ `processNode()`。
- magic member: built-in reflection の **miss 時のみ** `hasMethod()` ゲート → `getMethod()`。
- 唯一の catch-all（`ExpressionTypeResolverExtension`、ゲート無し）は**明示的に非推奨**の
  最終手段。
- **1クラス1インターフェイス**が支配的。framework パッケージは多数の narrow 拡張を登録する。
- per-interface のテスト基底（`RuleTestCase` = fixture+期待エラー集合、
  `TypeInferenceTestCase` = fixture 中 `assertType()` で推論型を文字列一致検証）。

現行 Rigor の B は、この不変条件を**唯一満たせていない**部分。

### 6.3 提案 — 残る2フックを narrow interface 化

B の 2 フックを、A と同じ「manifest 登録・エンジン index・gate/payload 分離」型へ割る。
PHPStan の対応関係を Ruby に写すと:

**`flow_contribution_for` を2つに分割:**

```ruby
# (1) 戻り値変更（PHPStan DynamicMethodReturnTypeExtension 相当）
class DynamicReturnExtension
  def supported_receivers = ["ActiveRecord::Base"]   # gate: エンジンが receiver で index
  def supports?(method_name) = method_name == :find  # gate: cheap
  def return_type_for(call, scope) = ...             # payload: 一致時のみ
end

# (2) 述語/表明による narrowing（PHPStan TypeSpecifyingExtension 相当）
class TypeSpecifyingExtension
  def supported_methods = [:present?, :blank?]        # gate
  def specify(call, scope, edge) = ...               # payload → truthy/falsey/post_return facts
end
```

エンジンは receiver クラスで index（**既存の `owns_receivers` index 機構を再利用可**）。
現行の「全 plugin を全 unresolved CallNode に呼び、`FlowContribution::Merger` を毎回走らせる」
が消える。

**`diagnostics_for_file` を2つに分割:**

```ruby
# (3) node 単位ルール（PHPStan Rule<TNode> 相当）— これが要石
class NodeRule
  def node_type = Prism::CallNode                     # gate: エンジンが node クラス別に index
  def check(node, scope) = [...diagnostics]           # payload: 一致 node にだけ
end

# (4) ファイル単位ルール（escape valve, ExpressionTypeResolverExtension 相当）
class FileRule
  def check(path, root, scope) = [...]                # 真にクロスファイル/index 検証が要る時だけ
end
```

**(3) NodeRule が要石**: エンジンが AST を**1回だけ**walk し、各 node を
その node クラスに登録された rule にだけ配る。現状フックが raw `root` を渡して
「自分で walk せよ」（`base.rb:168-171`）と言うからこそ §1 の **25 個の自前 walker** が
存在する。エンジンが walk を所有すれば、その存在理由ごと消える。
(4) は真に全ファイルを要するケース（cross-file index 照合）の最終手段として残すが、
「最後の手段」と明示し既定の表面にはしない。

`prepare` / `produces` / `consumes`（FactProvider）は既に半宣言的 + topo 順
（`loader.rb:230` Kahn ソート、missing-producer/cycle を LoadError 化）で、PHPStan の
Collector に近い。名前付き interface として整える程度でよい。

### 6.4 3つの目標をどう満たすか

- **AI エージェントの把握しやすさ** ← 最重要。manifest が**機械可読な capability 宣言**に
  なる。「この plugin は `ActiveRecord::Base#find` の戻り値を変え、`CallNode` に rule を
  出す」が grep / 列挙可能になり、self-gating の `if` に埋もれない。さらに
  `rigor plugins --capabilities` 型の **catalogue を生成可能**で、これは PHPStan が
  持たない「interface → gate → test harness の機械可読インデックス」を提供できる
  （PHPStan を**上回れる**差別化点 — 調査で「PHPStan に interface↔tag の機械可読
  レジストリは無い」と確認済み）。
- **テスト・検証容易性** ← interface 分割と不可分。各 narrow interface に専用ハーネス:
  NodeRule → node+scope を与え diagnostics を assert（`RuleTestCase` 相当）、
  DynamicReturnExtension → call+scope を与え `Type` を assert（`TypeInferenceTestCase`
  相当）。現状は唯一の harness が `run_plugin`（demo dir に書いて**フル Runner** を回し、
  downstream の `call.undefined-method` 文字列で**間接**検証 — `plugin_helpers.rb:109`、
  lisp-eval spec が実例）。per-hook の単体検証手段が**存在しない**のが今の最大の弱点。
- **ボイラープレート低減**（§1 と直結）— 25 walker が消え、dispatch loop の2重コピーも
  単一 indexed registry に集約。§1 の著者向けヘルパー層は「分割しない場合の緩和策」、
  §6 の分割は「ヘルパーが要る理由自体を消す」上位の解。
- **パフォーマンス**（副次）— エンジンが index して非該当 plugin を skip。現状の
  `plugins × files × nodes` fan-out（pre-filter 皆無）が解消。ユーザー言及の通り
  クリティカルではないが、分割すれば**追加コストなしで**付いてくる。

### 6.5 やり過ぎない規律

PHPStan の ~50 interface を全移植しない。今 Rigor に要るのは **3〜4 の新 narrow
interface**（DynamicReturn / TypeSpecifying / NodeRule + FileRule escape valve）だけ。

- magic-member / dynamic reflection 系 → **macro substrate（ADR-16）が既にカバー**。新設不要。
- dead-code（always-used）/ restricted-usage 系 → demand-driven で 1.x に後置。
- catch-all（現 `diagnostics_for_file` 相当の FileRule）は残すが**非推奨の最終手段**と明示。

### 6.6 移行とタイミング

- **対象 31 plugins だが大半は機械変換可能**。「単一 walk → name 一致で diagnostic」型
  （statesman / pundit / sidekiq / factorybot / 多くの Rails 系）は NodeRule にほぼ
  そのまま落ちる。A の宣言系（sinatra / devise / dry-struct / typescript-utility-types /
  hanami・web の一部）は**既に分割済みで無改修**。
- **後方互換**: 旧 fat フックを deprecated-but-supported な FileRule（catch-all）として
  残せば一括移行は不要。新 interface を推奨経路にし、旧 `diagnostics_for_file` は
  FileRule にリネーム + 非推奨マーク。
- **タイミングが決定的論点**: フックのシグネチャは 1.0 で**公開契約として凍結**される。
  1.x で fat フックを割るのは破壊的変更。**やるなら今（pre-1.0）**。これが
  「現行のままで十分か」への最大の答え — *機能的には十分だが、分割の窓は今しか開いていない*。

### 6.7 推奨

1. **1.0 前**: (a) **NodeRule + engine-owned walk** を導入（boilerplate/テスト両面で最大
   効果、§1 と直結）、(b) `flow_contribution_for` を **DynamicReturn + TypeSpecifying** に
   分割、(c) 旧 `diagnostics_for_file` を **FileRule**（非推奨 catch-all）として残す。
2. 同時に **per-interface テスト基底**（NodeRule 用・DynamicReturn 用）を出す
   — テスト容易性の目標は interface 分割と同時にしか達成できない。
3. **機械可読 capability catalogue**（manifest 集約の dump / `rigor plugins --capabilities`）
   を出し、AI エージェントが拡張種別と各 gate を列挙できるようにする。
4. dead-code / restricted-usage / 追加 magic-member 系は **demand-driven で 1.x**。

→ これは ADR-2 の改訂 1 本（「imperative フック2個の narrow-interface 化と FactProvider
の名前付け」）として起票するのが収まりがよい。§1 の著者向けヘルパー層は、この分割を
**段階導入する間の橋渡し**として先行投入できる（NodeRule 化が済んだ plugin から
walker ヘルパー依存が落ちていく）。

---

## 7. PHPStan 拡張型の選別取り込み（型分割とは別軸）

§6 は「フックの**形**を PHPStan 化するか」。本節は「PHPStan が持つ**拡張の種類**のうち、
Ruby で実需があり Rigor に**まだ無い**ものはどれか」。全 ~50 interface のうち、Rigor の
現状を file:line で裏取りした結果、取り込み価値があるのは少数に絞られた。
**ユーザー言及の `AdditionalConstructorsExtension` がまさに最有力**だった。

### 7.1 選別マトリクス

| PHPStan 拡張型 | Rigor 現状（裏取り） | 取込価値 | FP規律との整合 | 判断 |
| --- | --- | --- | --- | --- |
| **AdditionalConstructors** → Ruby「追加 initializer」 | **PARTIAL**: ivar 型シードが `initialize` **のみ**（scope_indexer.rb:79, :214-220, :411） | **高** | ◎ | **取り込み推奨（小・先行）** |
| **AllowedSubTypes** → sealed / 網羅性 | **ABSENT**: `case/in` 網羅性なし（statement_evaluator.rb:539-541）。ADR-36 WD3 で sealed-parent fact は既に spec 済・`is_a?` 網羅 narrowing は deferred（nested_class_template.rb:61-69） | **高** | ◎（網羅漏れを正しく検出） | **取り込み推奨（中・ADR-36 と統合）** |
| **Collector<TNode,TValue>** | **PARTIAL**: FactStore+`prepare` はあるが per-node 収集 primitive 無し、各 plugin が自前 re-walk（base.rb:166-178） | 中 | ○ | **§6 の NodeRule に統合**（cross-file 集約版） |
| **MethodParameterClosureType**（yield 引数型） | **PARTIAL**: `block_as_methods` は **self 型のみ**（block_as_method.rb:47-51）。yield 引数型は builtin+RBS のみ、plugin field 無し | 中 | ○ | **manifest に `yields:` 追加を検討（demand-driven）** |
| **AlwaysUsed* / ReadWriteProperties**（dead-code FP 抑制） | **PARTIAL**: dead-code は局所変数/分岐のみ（check_rules.rb:74, :1058）。メンバ単位の未使用検出は**無い** | 中（条件付き） | ◎（**抑制側**が要） | **メンバ dead-code を入れる時に抑制 hook を同梱**（単体では入れない） |
| **RestrictedUsage 系**（内部 API / test-only） | **PARTIAL**: Ruby の private + Liskov override のみ（check_rules.rb:69-70）。呼出元制約は無し | 低〜中 | ○ | demand-driven で 1.x |
| **DiagnoseExtension**（`-vvv` troubleshooting） | **ABSENT**（plugin 寄与なし）。`rigor triage`（ADR-23）は consumer 側で別形 | 低 | — | §6.4 の capability catalogue と抱き合わせで小さく |
| **ResultCacheMetaExtension** | **EXISTS**: `Cache::Descriptor::ConfigEntry` + `cache_for(descriptor:)` で任意外部状態を hash 可能（descriptor.rb:120-141, base.rb:249-260） | — | — | **作らない（実装済）** |
| ExpressionType / Operator catch-all | N/A（§6.2 の通り非推奨） | 低 | — | 見送り |
| magic-member reflection 系 | macro substrate（ADR-16）でカバー | — | — | 作らない |

### 7.2 最有力 — 「追加 initializer」拡張（AdditionalConstructors の Ruby 版）

PHPStan の `additional-constructors` は「`setUp()` 等も constructor 扱いして
未初期化プロパティの**誤検知を消す**」小さな拡張。Rigor には PHP の未初期化
プロパティ検査そのものは無い（Ruby の ivar は既定 nil）が、**同じ構造のハードコード境界が
既にある**:

- `scope_indexer.rb:79` `build_class_ivar_index` が ivar 型を **`def_node.name == :initialize` の
  本体からのみ**シードし、read-before-write→nil 寄与もそこに gate（:223-234）。
- rspec `before`/`let`、minitest `setup`、Rails のコールバック（`after_initialize` 等）で
  ivar を確立するコードは**シード対象外** → 「`initialize` で代入していない ivar」を
  nil 含みと推論し、テスト/Rails コードで FP を生む温床。

→ **manifest 宣言フィールド** `additional_initializers:`（PHPStan の宣言的
`additionalConstructors:` パラメータに対応）を追加し、`receiver_constraint` + メソッド名
集合で「このクラスではこれらも型シード源」と宣言できるようにする。§6.1 の A スタイル
（宣言的・engine-gated）にそのまま乗る小機能で、§0 の **false-positive discipline** に最も
直接効く。rigor-rspec / rigor-minitest / rigor-rails が即座に恩恵を受ける。
動的ロジックが要る稀なケース用に、`scope_indexer` 側の seeding-site 解決を
plugin が拡張できる hook も残せる（PHPStan が「単純例は config、動的例は extension」と
二段にしているのと同じ割り方）。

### 7.3 高価値 — sealed / 網羅性（AllowedSubTypes の Ruby 版）

`case/in` / `case/when` の網羅性検査は現状 ABSENT（statement_evaluator.rb:539-541 が
「no exhaustiveness tracking yet」と自認）。ADR-36 WD3 が既に **sealed-parent fact** を
spec 済みで、`is_a?` 横断の網羅 narrowing は `Environment#class_ordering` 配線待ちで
deferred（nested_class_template.rb:61-69）。

→ PHPStan の `AllowedSubTypesClassReflectionExtension`（`supports?` + `getAllowedSubTypes`）
に対応する **fact channel**（plugin が「この親型の許容サブ型は {A,B,C}」を宣言）を入れれば、
union 減算の精度向上 + 網羅漏れ検出が両取りでき、**rigor-mangrove の Enum / dry-struct /
ADR-36** のペンディングが一気に解ける。FP 規律とも整合（網羅していれば黙り、漏れだけ
報告）。engine 側作業はやや重いが、既に spec 済みの線を plugin 契約に出すだけで設計の
新規性は低い。

### 7.4 統合・demand-driven・作らない

- **Collector**（cross-file per-node 収集）は §6 の **NodeRule の cross-file 集約版**として
  自然に入る（engine が1回 walk して node を配る基盤の上に「集めてから消費」を足す）。
  独立機能にせず §6 に畳む。
- **`yields:` manifest field**（block 引数型）は、静的 RBS で書けない context 依存の
  yield 型を持つ DSL 向け。`block_as_methods` の self 型と対になる。demand-driven。
- **メンバ dead-code + AlwaysUsed 抑制**は**ペアで**のみ価値がある。Ruby は
  メタプログラミングで FP リスクが極端に高いので、検出だけ入れて抑制 hook を欠くと
  §0 の規律に反する。入れるなら「Rails callback / DSL 登録メソッドを常時使用扱い」する
  抑制拡張を**同時に**出す前提。優先度は 7.2/7.3 の後。
- **RestrictedUsage / Diagnose** は demand-driven（1.x）。
- **ResultCacheMeta は実装済み**（`ConfigEntry`）— 再実装しない。唯一の差は
  「専用コールバックが無く `ConfigEntry` を手組みする」ergonomics のみ。

### 7.5 推奨（§6 との関係）

§6（フックの**形**＝narrow-interface 化）と §7（拡張の**種類**）は独立に進められる。
1.0 前の取り込み候補を优先度順に:

1. **`additional_initializers:`（7.2）** — 小・宣言的・FP 規律直撃。最優先。
2. **sealed/AllowedSubTypes fact（7.3）** — ADR-36 を完遂し Mangrove/dry enum を解放。中。
3. Collector は §6 に統合、`yields:` とメンバ dead-code+抑制は demand-driven。

7.2 は単独の小 PR、7.3 は ADR-36 の続き、両者とも §6 の ADR-2 改訂とは別チケットに割ける。

---

## 付録: 健全なお手本（増やすべき形）

- **rigor-sinatra** — 最もクリーンな manifest（BlockAsMethod 1 つ + 9 verb）。
  walker/Diagnostic/index コード皆無。substrate に荷を預けた理想形。
- **rigor-pattern**（example）— `services.type.literal_string_compatible?` /
  `scope.type_of` でエンジン協調し「文字列伝播を自前再実装しない」最良テンプレ。
  `literal-unknown` info の false-positive discipline も見本。
- **rigor-devise** — 宣言的 TraitRegistry でアナライザコードゼロ
  （return 精度の床は別途課題だが、構造としては他が目指すべき形）。

これらの共通点は「substrate / エンジンクエリに荷を預け、自前 AST コードを書かない」。
§1 の著者向け層と §1.4 の基底クラスが揃えば、walker 系プラグインも
この水準のコード量に近づける。
