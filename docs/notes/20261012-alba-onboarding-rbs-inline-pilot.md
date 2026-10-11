# alba オンボーディングと rbs-inline パイロット — 手書き `sig/` プロジェクトでの sig-gen / inline 統合の実地観測

Date: 2026-10-12.

Status: **research note, no design commitments.** 観測対象の Rigor は **0.4.2**（mise
`gem:rigortype@0.4.2`）。対象は [alba](https://github.com/okuramasafumi/alba)（JSON シリア
ライザ gem、`required_ruby_version >= 3.0.0`、**手書き RBS `sig/` をコミット・Steep 用・gem に
同梱**）。本ノートは 2026-10-11〜12 のセッションで起きたことを時系列で記録する:
インストール → `rigor-project-init` オンボーディング → sig-gen 試行（失敗→復元）→ 手動型精密化
→ YARD→rbs-inline パイロット（方式 A で機械を検証し、方式 B を全体方針に決定）。コード本体の
変更は無い（コメントと RBS のみ）。

---

## 1. インストール（mise チャネル）で起きた 3 つのこと

実行環境: macOS arm64、Homebrew `ruby 4.0.7`（PATH 先頭）+ mise 管理 `ruby 4.0.6`
（`mise use -g ruby=4.0.6` 済み）。既存の rigor は mise 管理 `0.4.0`。

### 1a. 非対話シェルでは PATH が古いまま

`mise use --pin gem:rigortype@0.4.2` 直後、同一セッションの `rigor --version` は `0.4.0` の
まま。`mise which rigor` は `0.4.2` を解決しており、`eval "$(mise hook-env)"` で PATH 更新 →
`0.4.2`。install.md Step 3 の既知の王道ケース。

### 1b. `minimum_release_age` quarantine

RubyGems `latest.json` は `0.4.2`、`mise latest gem:rigortype` は `0.4.1`。`mise ls-remote`
が stderr に `1 newer gem:rigortype release hidden by minimum_release_age`。
`mise settings get minimum_release_age` は未設定（＝mise 既定値）だったため、install.md の
規定どおり `<LATEST>` を明示指定でインストール。ドキュメントされた挙動どおり。

### 1c. **rbs ネイティブ拡張の libruby 不一致**（主発見 1）

**症状**: `rigor --version` は動くが、分析コマンド（`rigor triage` / `rigor check`）が即クラッシュ。

```
dlopen(.../gem-rigortype/0.4.2/libexec/gems/rbs-4.2.0/lib/rbs_extension.bundle, 0x0009):
Library not loaded: /opt/homebrew/opt/ruby@4.0/lib/libruby.4.0.dylib (LoadError)
```

**原因**: `otool -L rbs_extension.bundle` が `/opt/homebrew/opt/ruby@4.0/lib/libruby.4.0.dylib`
（**現存しない Homebrew keg**）を指すことを確認。mise の gem バックエンドは `gem install` を
**実行時点の PATH 先頭の ruby**（＝ Homebrew 4.0.7）でネイティブ拡張をビルドするが、実行時は
`installs/ruby/4.0.6/bin/ruby`（mise ランタイム）が bundle を dlopen する。`--version` は RBS を
ロードしないので締め出しに気づかない。

**修復**: `eval "$(mise hook-env)"`（mise ruby が PATH 先頭）→ `mise install --force
gem:rigortype@0.4.2`。rbs を含む全 gem が mise ruby 4.0.6 向けに再コンパイルされ、
`otool -L` は `installs/ruby/4.0.6/lib/libruby.4.0.dylib` を指すようになり、triage が通った。

**位置づけ**: [20260717-install-channel-evaluation.md](20260717-install-channel-evaluation.md) §1
の「別の Ruby でビルドされたネイティブ拡張」クラス（脚注 `linked to incompatible libruby`）の
**新実例**。今回はグローバル gem 混在ではなく **mise gem バックエンド自身**が PATH 先頭の
Homebrew ruby でビルドしてしまうケース。install.md に「mise で再インストールする際は hook-env 後に
PATH 先頭を mise ruby にしてから」と書く価値がある。

## 2. オンボーディング結果 — 診断 0、baseline 空

- **スタック検出**: plain Ruby ライブラリ（`railties`/`activesupport` は `require: false` の
  テスト・任意連携用）。手書き `sig/` があるため Phase 5 の sig 生成はスキップ。
- **モード**: Acknowledge（`severity_profile` は既定 `balanced`）。**プラグイン**: なし
  （カタログに `rigor-alba` を発見したが、これは alba を*使う*アプリ向けで本 gem の開発では
  `sig/alba/*.rbs` と重複するため不使用）。
- **target_ruby**: `"3.3"`（gemspec `>= 3.0.0` → Prism 最小 3.3 判定表）。
- **triage / check**: `total: 0`。hints 無し、plugin `load-error` なし。`rigor sig-gen
  --format json` の `new_method: 0` から、手書き sig/ が全メソッドを宣言済みで診断 0 が本物と
  確認。
- **baseline**: 空（`ignored: []`）。未来の診断は全て新規＝リグレッションのゲート。
- **AGENTS.md**: `rigor-type-oracle` の canonical 断片（`references/02-agents-md-fragment.md`）
  を逐語追記。`CLAUDE.md` / `.cursorrules` は AGENTS.md への symlink のため 1 箇所で足りる。

## 3. sig-gen 試行 — 手書き `sig/` への `--write --overwrite` は非破壊でない（主発見 2）

ユーザー依頼で `rigor sig-gen --params=observed --write --overwrite lib` を実地試行（前提:
`sig/` はコミット済み・クリーンで復元可能）。**結果は失敗し `git checkout -- sig/` で復元。**

### 3a. classification

```
new_method: 0 / skipped: 37 (sig.skipped.untyped-return) / tighter_return: 20
```

### 3b. **跨ファイル重複宣言で RBS ビルドが壊れる**

生成物は `sig/alba/resource.rbs`（+13）と `sig/alba/association.rbs`（+6）。後者に
`Alba.resource_class` / `Alba.register_type` 等の module レベル `self.` メソッド一式が出力された
が、これらは既存 `sig/alba.rbs` に既に宣言されている。結果:

```
rbs.coverage.definition-build-failed: 3 RBS class definition(s) failed to build:
Alba, Alba::Resource::ClassMethods, Alba::Resource.
First failure: RBS::DuplicatedMethodDefinitionError on `::Alba.resource_class`.
Conflicting signature file(s): sig/alba.rbs, sig/alba/association.rbs, sig/alba/resource.rbs.
```

Rigor は壊れたクラスを KNOWN 扱いで `Dynamic[top]` に落とすため、**診断は 0 のまま「静かに
カバレッジが減る」**。sig-gen は module の `self.` メソッドを「生成時に最初に触れたファイル」へ
出力し、既存の宣言場所（`sig/alba.rbs`）を考慮しない。**upstream 報告候補**:
「既存 RBS が同一メソッドを別ファイルに宣言している場合の重複出力回避」。

### 3c. 生成署名の質 — 戻り値は厳密化、引数は緩む

生成 20 件は戻り値を具体化する一方、**引数を `untyped` に広げる**（例: `association:
(Symbol | String, ?instance_proc?, ?source: Proc?, ...)` → `(untyped, ?untyped, ...)`）。
かつ手書き側の精密 interface（`_ClassMethods`）をシャドウするモジュール内メソッドとして挿入される。
**ネットで精度が下がる**構成。

### 3d. artifact 戻り値（ノイズの見分け方）

| パターン | 例 | 判別法 |
| --- | --- | --- |
| 末尾の代入式が返す値 | `root_key! -> true` / `stringify_keys! -> false`（YARD は `@return [void]`） | 末尾が `@ivar = literal` |
| `alias_method` の戻り値 | `prefer_resource_method! -> Symbol` | `alias_method` は別名を返す |
| `each` の戻り値 | `register_default_types -> Array[singleton(Integer) \| singleton(String)]` | 末尾が `.each` |
| 巨大 union | `inherited -> Hash[Symbol, Array[...] \| ...]` | 複数 ivar 代入の合成 |

### 3e. 手動適用（5 件 → 4 件）と 2 つの追加教訓

`--diff` の 20 件から「戻り値が実質的な意味を持つ」5 件を手書き sig に適用（パラメータは手書きを
維持）。検証は `bundle exec rake typecheck`（この時点では bundle が壊れており実行不能）ではなく
`rigor check` + `rbs validate` のみだったが、**後日 bundle が直って Steep を回すと 2 件の事故が
発覚**した:

- **`reset_transform_keys -> Hash[untyped, untyped]` は撤回**: `inflector=` のような setter が
  `reset_transform_keys` を最終式にしているため、setter 本体型が宣言型と不一致になり
  `Ruby::SetterBodyTypeMismatch` を誘発。**「artifact 戻り値」は setter には無害ではない** —
  呼び出し側が戻り値を捨てていても、setter の本体フローには流入する。
- **RBS の union 戻り型は括弧必須**: `-> Alba::Association | Alba::ConditionalAttribute` は
  rigortype 同梱 rbs 4.2.0 の `rbs validate` は通るが、Steep のパーサーが
  `Syntax error: unexpected token for method type, token=Alba` と拒否。`-> (A | B)` にすると両方
  通る。**rbs バージョン間のパーサー差**（検証ツールを 2 本持つ価値）。

最終的に残った 4 件: `register_type -> Alba::Type`、`association -> (Alba::Association |
Alba::ConditionalAttribute)`、`nested_attribute -> (Alba::ConditionalAttribute |
Alba::NestedAttribute)`、`layout -> Alba::Layout`。**手書き sig/ を持つライブラリでは、sig-gen は
`--diff` / `--format json` のレビュー面として使い、`--write --overwrite` は一括適用にしか使わない。**

## 4. 環境の復旧とブロックの解消

オンボーディング時点では `bundle exec rake typecheck` / `test` が bundler の GitHub ソース gem
（`rubocop-gem_dev`）未チェックアウトで解決失敗していた。**`bundle install` で解消**（79 gems、
steep 2.1.0）。副次効果として **`Gemfile.lock` が生成され**（gitignored）、Rigor が新たに
`rbs.coverage.missing-gem`（info、dev 依存 60 gem が RBS 無し）を報告するようになった。
fail_on は error なのでゲートは無傷だが、ローカルで lock を持つ開発者にだけ出る騒音であり、
対応方針（`rbs collection install` / `dependencies.source_inference:` / info 許容）は未定。

## 5. rbs-inline パイロット（主発見 3）— `lib/alba/type.rb`

YARD→rbs-inline 移行の要望に対し、小さいファイルでパイプラインを検証。方式 A（inline を正とし
sig/ から該当メソッドを外す）で機械を確認した後、**全体方針は方式 B に決定**（下記 §6）。

### 5a. 実装

- `lib/alba/type.rb` に `# rbs_inline: enabled` + `# @rbs` メタ形式（`# @rbs name: T` /
  `# @rbs return: T`、属性は `attr_reader :name  #: T` の `#:` キャスト）。手書き sig の精密型
  （`name: Symbol | String | Class` 等）に忠実に書く。
- `.rigor.dist.yml` に `plugins: [rigor-rbs-inline]` と `sig_gen.inline_declared: skip`。
- rigortype 環境へ `rbs-inline 0.14.0` を導入（`mise exec gem:rigortype -- gem install rbs-inline`。

### 5b. 検証結果

| チェック | 結果 |
| --- | --- |
| `rigor plugins` | `rigor-rbs-inline` `[OK]`（`source_rbs_synthesizer: yes`） |
| inline 強制のポジティブコントロール | 注釈を誤った型に → `def.ivar-write-mismatch` が発火（注釈が ivar 推論を汚染し cross-method 矛盾を検出）。**注釈が契約として生きている**証明 |
| `bundle exec rake typecheck` | グリーン（rbs validate + Steep 2.1.0） |
| `bundle exec rake test` | 281 runs / 1400 assertions / 0 failures |

### 5c. Steep との統合の落とし穴

- **`check "lib", inline: true` を lib 全体に適用すると壊れる**: Steep の inline reader は
  **`# rbs_inline: enabled` マジックコメントを尊重せず**、対象の全ファイルの定数・メソッドを
  宣言する。手書き sig/ と定数が重複（`VERSION` / `INTERNAL_VARIABLES` / `REMOVE_KEY` で
  `RBS::DuplicatedDeclaration`）、さらに動的 `attr_reader(*INTERNAL_VARIABLES.keys)` が
  `RBS::InlineDiagnostic`（inline reader はスプラット attr を扱えない）。
- 対処（方式 A 時）: `check 'lib'` と `check 'lib/alba/type.rb', inline: true` の 2 行に分離し、
  `sig/alba/type.rbs` から該当メソッドを撤去して **ivar 宣言のみ残す**。→ グリーン。

## 6. 全体方針の決定と方式 B の実装結果

方式 A（inline を正とし sig/ から外す）はリポジトリ内では動くが、**alba は `sig/` を gem に
同梱**しているため、consumer 向け同梱 sig/ からメソッドが消える＝型が失われる。そのため全体展開
は **方式 B** とした。パイロットで実際に実装・検証した:

- **注釈を「執筆形式」の正とし、rbs-inline CLI で `sig/` を再生成**。プロジェクトはまだ Rigor 中心の
  構成ではないため、**`sig/generated/` の分離は採らず、`sig/` 直下にフラット展開**する
  （`bundle exec rbs-inline --output=sig lib`。注意: スペース形式 `--output sig` は既定で
  `sig/generated` に書くため、フラット化には `=` 形式が必須）。手書きの `sig/alba/type.rbs` は
  生成物へ置換。
- リポジトリ内の Steep は **`inline: false` で生成済み sig/ を読む**（Steepfile は
  `check 'lib'` のまま）。
- Gemfile の type group に `rbs-inline` を追加（生成ワークフローをプロジェクトに固定）。

検証結果: `rigor check` エラー 0・`bundle exec rake typecheck` グリーン・
`bundle exec rake test` 281 runs / 0 failures。

### 方式 B で見つけた新たな非対称性（主発見 4） — ivar はマージ対象外

パイロット中、inline の ivar 注釈（`# @rbs @name: T`）を入れた状態で `rigor check` が以下を報告:

```
rbs.coverage.definition-build-failed: RBS::InstanceVariableDuplicationError on `::Alba::Type`.
Conflicting signature file(s): virtual:rbs-inline:/.../lib/alba/type.rb
```

**原因**: `rigor-rbs-inline` プラグインは inline の `# @rbs @ivar` 注釈から ivar を合成し、生成済み
`sig/generated/` にも同じ ivar があるため二重宣言になる。**「同一なら静か」の precedence はメソッド
に対してのみ**で、ivar（非メソッドメンバー）は比較対象外のためビルドが壊れる。Steep（inline:
false）は sig/ しか読まないので気づかない、**Rigor だけに見える非対称性**。

対処（§6 想定の「手動マージ」運用が実際に必要になる最初の例）: inline から ivar 注釈を撤去し、
ivar 宣言は生成後の `sig/generated/alba/type.rbs` に手動マージ（生成にコメントで維持を明記）。
→ `rigor check` はクリーンに戻る。

## 7. 一括移行（type.rb 以外 9 ファイル）の結果 — 2026-10-12 後半

way B のパイロット後、`lib/alba/type.rb` 以外の**小〜中サイズ 9 ファイル**を一括移行した
（`version` / `constants` / `deprecation` / `default_inflector` / `typed_attribute` /
`nested_attribute` / `conditional_attribute` / `layout` / `association`）。手順:
1. 各ファイルに `# rbs_inline: enabled` + `# @rbs`（block 付きメソッドは `#:` 全体シグネチャ）を書き、
2. `bundle exec rbs-inline --output=sig lib` で一括再生成（magic comment のあるファイルのみ対象、
   `alba.rb` / `resource.rb` は未対象で手書き sig 維持）、
3. **手書き部分を手動マージ**、4. Steep / Rigor / test で検証。

検証結果: `rigor check` エラー 0・`bundle exec rake typecheck` グリーン・
`bundle exec rake test` 281 runs / 0 failures。diff: lib 10 + sig 10 ファイル、+299 / −160。

### 7a. マージで判明した rbs-inline の生成境界（主発見 5）

再生成後に人手で戻す必要があったもの（＝rbs-inline が生成しない・誤生成するもの）:

| パターン | 実例 | 対処 |
| --- | --- | --- |
| **ivar は生成しない** | 全クラス（`@name` 等） | 生成後に手動マージ（生成にコメントで維持を明記） |
| **`class << self` 内の attr cast をインスタンス attr に誤生成** | `attr_reader :const_cache`（`class << self` 内）→ `attr_reader const_cache:` がクラス本体に | `def self.const_cache: () -> Hash[...]` に手直し＋`self.@const_cache` をマージ |
| **`delegate` は生成しない** | `DefaultInflector` の 6 メソッド | 旧 sig から `def self.*` を手動マージ復元 |
| **Kernel 制限の上書き宣言は生成しない** | `def caller_locations: (Range[Integer]) -> Array[...]` | 手動マージ（無いと `| nil` で `.first` が NoMethod になる） |
| **定数の型は推論が緩い** | `REMOVE_KEY = Object.new.freeze` → `REMOVE_KEY: untyped` | 手書きの `Object` に手直し |
| **block の `[self: singleton(Resource)]` 束縛は表現不可**（`#:` に書けない） | `Association#initialize` の `?{ () [self: singleton(Resource)] -> void }` | `?{ () -> void }` に簡略化（精度微減、許容） |
| **`extend Forwardable` は正しく生成** | `Layout` | `def_delegators` の手書き宣言は不要になった（Forwardable から解決） |
| **`module_function` は正しく生成** | `def self?.warn` | — |
| **定数（`VERSION: ::String` 等）は正しく生成** | `version.rb` / `constants.rb` | — |

### 7b. 対象外・保留（判断の記録）

- `lib/alba/errors.rb` / `lib/alba/railtie.rb`: YARD 無し・メソッド無し（クラスシェルのみ）→ 移行対象外。
- **`lib/alba.rb` / `lib/alba/resource.rb` は保留**: 型エイリアス（`generic_hash`・`transform_type`
  等）・interface（`_ResourceClass` / `_Inflector` / `_ClassMethods` / `_InstanceMethods` /
  `_ClassContext`）・動的 `attr_reader(*INTERNAL_VARIABLES.keys)`・多数の `self.@*` / `@_*` ivar・
  self-binding block を持ち、rbs-inline 生成後に構造を再構築する必要がある。単純置換では完了しない
  ため、手書き sig を維持したままとした（アノテーションも未導入＝consumer の無いため）。

### 7c. Rigor／生成系ワークフローへの期待（ユーザー方針メモ）

**Rigor（および rbs-inline 生成経路）に期待する機能は、コードに書かれた rbs-inline 注釈を
丸写しして sig/ に写すことではない。** 期待するのは:

1. 注釈を **きちんとした RBS 形式のファイルとして再構築**すること（今回観測された
   `initialize -> untyped`、`REMOVE_KEY: untyped` のような「推論が丸いままの写し」ではなく、
   意味のある形に整える）。
2. **既存の RBS ファイルを反復的に堅牢にする用途**に使えること — 手書き sig/ を一度きりの
   置換で壊すのではなく、注釈・生成物・手書きの整合を繰り返し改善していく道具として機能する
   こと（§6 の方式 B と §7a の手動マージ運用は、その反復の一形態）。

裏付けとなる観測: `--write --overwrite` の一括生成は既存の精密引数を `untyped` に落とし
（§3c）、定数・initialize の戻り値は推論が緩いまま写る（§7a）。したがって生成物の質は
「写しの忠実度」ではなく「RBS としての正しさと、手書きとの差分をどう詰めるか」で評価する。

## 8. フォローアップ候補

1. **sig-gen の既存宣言重複出力**（§3b）— upstream issue 候補。再現手順: 手書き sig/ を持つ
   プロジェクトで `sig-gen --write --overwrite lib` → module `self.` メソッドが別ファイルに
   再出力され `RBS::DuplicatedMethodDefinitionError`。
2. **mise gem バックエンドのビルド Ruby 選択**（§1c）— install.md への注意書き追加余地
   （`mise install --force` 前に hook-env / PATH 先頭を mise ruby に）。
3. **rbs パーサーの union 戻り型差**（§3e）— 括弧の有無で rbs validate と Steep の判定が分か
   れる。sig-gen の出力が常に括弧付きなのはこのためと思われるが、ドキュメント化の価値あり。
4. **`Gemfile.lock` 生成由来の `rbs.coverage.missing-gem`（info）** — 対応方針の決定。
5. **保留 2 ファイル（alba.rb / resource.rb）の移行設計** — 「注釈→再生成→構造再構築」の手順を
   確立してから着手（§7b）。
6. **inline ivar 注釈の二重宣言**（§6・主発見 4）— プラグインの合成と生成 sig/ の両立可否を
   upstream で確認する価値（メソッドのみ precedence があり ivar に無い、という非対称性の文書化）。
7. **`class << self` 内 attr cast の誤生成**（§7a）— rbs-inline 側の報告候補（`self.@*` / 
   `def self.*` へのスコープ解決）。

---

## 9. 残存 `-> untyped` の体系的考察と `-> void` 判定規範 — 決定論的生成・SKILL 経験則への反映（主発見 6）

2026-10-12 の差分最小化リファクタリングにおいて、手書き `sig/` プロジェクトに残る `-> untyped` を網羅的に精査した。
「どこまでを型付けし、どこを `-> void` に倒し、どこを意図的に `-> untyped` のまま残すべきか」の境界線が完全に言語化されたため、Rigor の決定論的生成エンジン（`sig-gen` / `sig-refine`、ADR-122）およびエージェント向け SKILL（`rigor-sig-refine`）の経験則として記録する。

### 9a. 3 つの残存 `-> untyped` 分類

| 分類 | 代表例 | 理由と意味論 | `-> void` 化の可否 |
| :--- | :--- | :--- | :---: |
| **分類 1: ユーザーの任意ドメインデータ / 属性値** | `Resource#object`, `Layout#object`<br>`Association#object_from`<br>`fetch_attribute*`<br>`ConditionalAttribute#second_object`<br>`Type#convert`, `TypedAttribute#value`<br>`Resource#__send__` | ユーザーがシリアライズ対象として渡す PORO / ActiveRecord / Hash や、評価された属性値そのもの。非ジェネリックなライブラリ設計において必然的に `untyped`（または `top`）となる。呼び出し側がこの戻り値を受け取って JSON ハッシュに格納するため値を返さなければならない。 | ❌ **絶対不可**<br>（戻り値が使われるため、`void` にすると `void-value-used` 違反となる） |
| **分類 2: コールバック・属性定義ブロック引数** | `attribute` / `assign_attributes_with_types` の `?{ (untyped) -> untyped }`<br>`type attribute = ... ^(...) -> untyped`<br>`type instance_proc = ... -> untyped` | `attribute :name do \|u\| ... end` のブロック戻り値。ブロックの評価結果を Alba が受け取ってシリアライズ値とするため、ブロックの戻り値は「任意の型を許容する」という意味の `-> untyped` でなければならない。 | ❌ **絶対不可**<br>（ブロック戻り値を `-> void` にすると「呼び出し側が結果を捨てる」契約になり偽となる） |
| **分類 3: Steep の型推論制約・偽陽性回避のエスケープ弁** | `Alba.resolved_default_superclass` (実態は `Class`)<br>`Resource#transform_key` (実態は `Symbol \| String`)<br>`Resource#dup` / `transform_keys!` (実態は `self`) | 実装上は具体的な型を返すが、型をつけると Steep が偽陽性を報告する箇所:<br>・`Object.const_get` の戻り値が Steep で `Class` にナローイングされない（`MethodBodyTypeMismatch`）<br>・`key_type` が `nil` を含むため、キー変換メソッドに型をつけると `hash[key]` で `nil` キー警告が出る（`ArgumentTypeMismatch`）<br>・`dup.class_eval` 内のブロックコンテキストで `self` が特異メソッドを認識しない（`NoMethod`） | ❌ **不可**<br>（ダウンストリームの Steep 検証をグリーンに維持するための意図的境界） |

### 9b. `-> void` に置き換えるべき厳密な判定規範

`-> untyped` を `-> void` に置き換えるのは、以下の条件を満たす場合に限られる:
1. **呼び出し側が戻り値を破棄する**: 式として戻り値が代入・消費されず、純粋に副作用目的で呼ばれる。
2. **フックメソッド**: `included`, `extended`, `inherited` 等の言語仕様上のフック（戻り値は Ruby 処理系によって捨てられる）。
3. **セッターメソッド**: `def name=(val)` 構文。Ruby では構文上 `obj.name = x` は常に `x` を評価するため、メソッド本体の末尾式（内部の代入や `reset_transform_keys` などの副作用ヘルパー呼出）の戻り値型が漏れないよう `void` に正規化する（ADR-122 WD3）。
4. **コマンドメソッド**: 登録、初期化、エラーハンドリング、可視性変更など（`reset!`, `register_default_types`, `set_key_and_attribute_body_from`, `handle_error`, `private`）。

### 9c. 差分最小化（Minimal Diff）原則の実践成果

パイロット一括移行時に発生した 12ファイル479行の差分を、本知見に基づいて見直した:
- 実質的な型改善がない 6 ファイル（`constants`, `default_inflector`, `deprecation`, `nested_attribute`, `typed_attribute`, `version`）は完全に HEAD へリバート。
- 局所的な型付けが可能なファイル（`association`, `conditional_attribute`, `layout`, `type`）は 1〜4 行の最小限の差分のみを適用。
- 差分は **6ファイル80行** に圧縮され、Steep (`No type error detected. 🫖`)、Rigor (0 errors)、テスト (281 runs / 0 failures) すべてグリーンを維持した。
手書き RBS を持つ既存ライブラリに対するシグネチャ改善は、この「最小差分原則」を徹底することで初めて upstream に受け入れ可能な品質となる。