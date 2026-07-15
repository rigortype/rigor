# PHPStan `src/Rules` 全ルール分類と Rigor 再実装価値の再評価 (2026-07-15)

Status: research note, no design commitments — Tier 1/2 の各候補は個別に ADR / コーパスゲートを経てから着手する。

## 目的と位置づけ

`/Users/megurine/repo/php/phpstan-src/src/Rules`(約 600 ファイル・約 40 サブディレクトリ)に実装された
PHPStan の出荷ルールをルール単位で分類し、Rigor で再実装する価値を再評価した。

コーパス上の先行 PHPStan 比較は 2 件のみで、いずれも**ルール単位のサーベイではない**:

- `docs/notes/20260603-phpstan-type-algebra-comparison.md` — 型代数層(`TypeCombinator` 等)の比較。
  結論「PHPStan 同水準を目指す未実装で新しいプラグイン拡張点を要するものはゼロ」。G1c coerce 方向のみ
  ADR-42(demand-gated)へ。
- `docs/design/20260601-plugin-mechanism-pre-1.0-review.md` §7.1 — 拡張**インターフェース**(~50 種)の
  取捨選択マトリクス。`AdditionalConstructorsExtension` → ADR-38 採用、`AllowedSubTypes` → 推奨のまま未実装、
  dead-code / restricted-usage 系 → demand-driven で 1.x 後置。

本ノートが `src/Rules` のルール単位サーベイの初回となる。調査は 4 系統のサブエージェント
(ルール群 3 分割 + Rigor 側棚卸し)で実施し、本文はその統合・裁定である。

分類キー: **(a)** PHP 固有(Ruby に対応物なし) / **(b)** そのまま移植可能 / **(c)** Ruby 向け適応が必要 /
**(d)** ルールではなくエンジン内ヘルパ・インフラ。FP リスクは「動いている慣用的 Ruby コードに対して
発火するか」を Rigor の FP 規律(`feedback_false_positive_discipline`)で評価した low/medium/high。

## 全体観

- PHPStan のルール資産の**およそ 1/4 は PHP 固有の構文合法性・バージョンゲート**(cast、attributes、
  property hooks、参照渡し、goto、enum 構文、promoted properties 等)であり、Ruby には対象が存在しない。
- **最大の移植候補ブロックはすでに Rigor が保有している**: Comparison の constant-condition 族 ≈
  `flow.always-truthy-condition` + ADR-47、Methods のディスパッチ中核 ≈ `call.undefined-method` +
  arity/argument-mismatch、override 互換 ≈ ADR-35、Operators ≈ ADR-64 の coerce 障壁裁定(素朴な
  PHPStan 移植より**先行**している)、uninitialized property ≈ ADR-58 の provenance ゲート版。
- 残る正味の新規候補は (1) **注釈・宣言バリデーション族**(RBS/`%a{rigor:v1:}` の妥当性検査 — PhpDoc/
  Generics ディレクトリの丸ごとの対応物、両側とも作者が書いた宣言なので FP-free)、(2) **定数畳み込みが
  効く組込み関数の意味検査**(printf プレースホルダ、日時パース実行検査)、(3) **少数の構文的フットガン
  検出**(Hash リテラル重複キー、`ensure` 内 `return`、`raise` 非例外、rescue 節シャドーイング)。
- High-FP 側の帰結は一貫している: PHPStan が PHP でも動的性ゆえに諦めている箇所(`UnusedPrivateMethodRule`
  は動的メソッド名で bail する等)は、Ruby では `send` / シンボルコールバック / モンキーパッチにより
  さらに悪化する。純粋性推論・重複定義検出・可視性強制の素朴な移植は不採用。

## ディレクトリ別分類(圧縮版)

各サブエージェントの完全な表は長大なため、ここではルール/クラスタ単位の判定に圧縮する。
判定列 = 分類 / FP リスク / 裁定(採用候補◎・ゲート付き○・不採用×・PHP固有—・既存済み=)。

### Arrays

| ルール/クラスタ | 検出内容 | 判定 |
|---|---|---|
| `DuplicateKeysInLiteralArraysRule` | リテラル配列の重複キー | (b) / low / **◎** Hash リテラル重複キー(last-wins が沈黙する実バグ; リテラル限定で FP-free) |
| `NonexistentOffsetInArrayDimFetchRule` | 存在しないオフセット参照 | (c) / low(HashShape/Tuple 限定)/ ○ shape キャリア限定なら健全。素の `Hash[K,V]` は `h[:absent]` が慣用(nil 既定)なので対象外に固定 |
| `DeadForeachRule` | 空配列の foreach | (b) / medium / ○ 証明可能な空コレクションの `each` — 価値小 |
| `ArrayDestructuringRule` | 非配列の分解 | (c) / medium / × `to_ary`/`deconstruct` プロトコルの存在検査に還元され、既存 dispatch 検査で十分 |
| `IterableInForeachRule` | 非 iterable の foreach | (c) / low / **=** `each` の `call.undefined-method` に還元 |
| `OffsetAccessAssignment*` 3 種 | `[]=` の型検査 | (c) / low / **=** `[]=` ディスパッチ + argument-mismatch に還元 |
| `InvalidKeyInArrayDimFetch/Item`, `ArrayUnpackingRule`, `OffsetAccessWithoutDimForReadingRule` | PHP のキー型制約・splat 制約 | (a) / — |
| `UnpackIterableInArrayRule` | 非 iterable の unpack | × Ruby の splat は非配列を包むだけで合法 |

### Cast

7 ルール中 5 が (a)(cast 構文のバージョンゲート)。`InvalidCastRule` / `EchoRule` / `PrintRule` /
`InvalidPartOfEncapsedStringRule` の to-string 変換検査は Ruby では `Object#to_s` が全オブジェクトに
あるためほぼ空虚 — × 不採用。唯一の残滓(`to_str`/`to_int` 暗黙変換サイト)は ADR-64 の
`param_accepts_arg_class?` がすでに占有している。

### Classes

| ルール/クラスタ | 検出内容 | 判定 |
|---|---|---|
| 存在検査クラスタ(`ExistingClassIn*` 6 種) | extends/implements/instanceof の未解決クラス + 種別不一致 | (c) / 未解決側 medium(autoload・`const_missing`)、**種別不一致側 low** / ○ `class Foo < SomeModule`・`include SomeClass` は実 TypeError — 解決済み定数に限れば FP-safe |
| `ImpossibleInstanceOfRule` | `instanceof` 恒真/恒偽 | (b) / low / **=** narrowing + always-truthy の既存射程(下記「impossible-check」参照) |
| `InstantiationRule` | 未解決/インスタンス化不能クラスの `new`、ctor 引数 | (c) / module-`new`・arity は low、"abstract" 推定は high / ○ module に対する `.new` のみ |
| PHPDoc タグ妥当性クラスタ(`MethodTagRule`/`PropertyTagRule`/`MixinRule`/`LocalTypeAliases*` 等) | 注釈内の未知クラス・不正型・壊れた alias | (c) / **low** / **◎** RBS/注釈宣言バリデーションとして(PR #96/#97 隔離アークの延長) |
| `AllowedSubTypesRule` | sealed 階層の逸脱 | (c) / low / ○ §7.1 の ADOPT 判定のまま未実装(ADR-36/47 WD3b と接続) |
| `RequireExtendsRule` / `RequireImplementsRule` | モジュールが includer に要求する契約 | (c) / low / ○ `conforms-to` + ADR-28 と同形 — 需要駆動 |
| `ClassConstantRule` | 未定義クラス定数参照 | (c) / medium / ○ ADR-43 相当の許可リスト規律が前提 |
| 重複宣言クラスタ(`Duplicate*` 3 種) | クラス/メソッド/trait の再宣言 | (c) / **high**(再オープンは Ruby の中核的慣用)/ × 唯一の低リスク断片 = 同一ファイル同一クラス本体内の重複 `def`(コピペバグ) |
| `UnusedConstructorParametersRule` | ctor の未使用引数 | (b) / medium / ○ `_` 接頭辞規約 + ADR-35 階層認識が前提 |
| `NewStaticRule` | `new static()` の安全性 | (c) / **high** / × `self.new` ファクトリは Ruby の主要慣用 |
| attributes / promoted properties / readonly class / enum sanity | PHP 構文 | (a) / — |

### Comparison

| ルール/クラスタ | 検出内容 | 判定 |
|---|---|---|
| constant-condition 族(if/elsif/ternary/while/do-while/not, 7 種) | 恒真恒偽条件 | (b) / low / **=** `flow.always-truthy-condition` そのもの。差分は構文別カバレッジとメッセージ精度(左/右オペランド帰属)のみ |
| `BooleanAnd/Or/XorConstantConditionRule` | `&&`/`||` オペランド極性 | (b) / low-medium / **=** `constant_value_polarity` 済み。`||=` メモ化イディオムの除外が生命線(ADR-56/58 の知見どおり) |
| impossible-check クラスタ(`ImpossibleCheckType*` 3 種) | `is_string()` 等の型述語呼び出しが恒真/恒偽 | (b) / low(コア述語)/ **◎** 既存 predicate-fact 機構で安価に実装可能な「常真 predicate *呼び出し*」拡張。`PossiblyImpureTipHelper`(レシーバが不純かもしれない場合にメッセージを和らげる)は盗む価値のあるメッセージ品質装置 |
| `ConstantLooseComparisonRule` / `StrictComparisonOfDifferentTypesRule` | 型非交差の `==`/`===` 恒偽 | (c) / medium / ○ `==` オーバーライドがあるため value-pinned・final 級クラス限定(ADR-57 の union-arm 極性と同系の健全部分集合)。PHP `===` と Ruby `===` は別物である点に注意 |
| `NumberComparisonOperatorsConstantConditionRule` | 整数範囲型による比較の恒真恒偽 | (b) / medium / ○ 範囲算術の保有量次第。coerce 演算子は ADR-64 除外リストと同じゲート |
| `MatchExpressionRule` | match の死アーム + 網羅漏れ | (c) / 死アーム low・網羅性 medium / **=**(死アーム: ADR-47 出荷済み)+ ○(網羅性: `case/in` 限定で ADR-47 WD3b そのもの — `case/when` の else なし nil 返しは慣用なので対象外) |
| `UsageOfVoidMatchExpressionRule` | void 値の使用 | (c) / low / **◎** RBS 宣言 `void` の戻り値使用は作者意図への違反(Steep 同等) |
| `ConstantConditionInTraitRule` | trait 内の定数条件を「全 using class で同値のときのみ」報告 | (d) / — / メカニズムとして記録: モジュール本体を includer ごとに再解析する日が来たら同じ複数文脈 dedup が必要 |

### Constants

`ValueAssignedToClassConstantRule`(RBS 宣言型 vs 代入リテラルの畳み込み型、両側作者、low)が ○。
`OverridingConstantRule` の型共変性断片も RBS 宣言限定で ○(サブクラスの定数シャドーイング自体は
慣用なので型衝突のみ)。残り(final/typed const、magic constants、`define()` 等)は (a)。
`AlwaysUsedClassConstantsExtension` は dead-code ルールの FP 包絡を**プラグイン化**する seam であり、
§7.1 の「検出と抑制フックはペアでのみ出荷」判定を再確認する材料。

### DeadCode

| ルール/クラスタ | 検出内容 | 判定 |
|---|---|---|
| `UnreachableStatementRule` | 終端文の後の到達不能文 | (b) / **low** / **◎** `return`/`raise` 後の文は構文的に頑健。ADR-47 の隣接兄弟で、フローエンジンの exit-point 追跡で実装可能 |
| `NoopRule` | 文位置の純粋式(`x == 1` 単独行等) | (c) / medium / ○ リテラル・変数参照・比較演算子の部分集合に限れば low(`=`/`==` 取り違えは実バグ)。「任意の純粋式」への拡大が危険域 |
| 純粋性クラスタ(`CallTo*WithoutImpurePoints*` 4 種 + collectors + 推移的 resolver) | 副作用なし呼び出しの文位置使用 | (c) / **high** / × Ruby の純粋性は静的にほぼ不可知(メモ化 ivar 書き込み・モンキーパッチ・C 実装)。唯一の narrow 変種 = fold カタログ(既知純粋メソッド列挙を既に保有)由来の `x.dup`・`x.map{}` 結果破棄 — 需要が出たときの low 断片 |
| `UnusedPrivateMethodRule` | 未使用 private メソッド | (c) / **high** / × `send(:name)`・`before_action :check` 等のシンボル参照が Rails の背骨。プラグインの「シンボル経由で使用」fact 供給なしには medium にすら達しない(§7.1 判定の再確認) |
| `UnusedPrivateConstantRule` | 未使用 `private_constant` | (c) / medium / × 同上(`const_get`) |
| `UnusedPrivatePropertyRule` | 書くだけ/読むだけ ivar | (c) / medium / ○ 読み側は ADR-58 が別角度で占有。書き込み専用 ivar はシリアライザ/DI が `instance_variable_get` するため保留 |

### Exceptions

| ルール/クラスタ | 検出内容 | 判定 |
|---|---|---|
| `OverwrittenExitPointByFinallyRule` | finally 内 return による return の上書き | (b) / **low** / **◎** `ensure` 内 `return`(戻り値も進行中例外も飲み込む古典フットガン)。RuboCop `Lint/EnsureReturn` が低 FP の先例。純構文検出 |
| `ThrowExprTypeRule` | 非 Throwable の throw | (b) / low / **◎** `raise x` の x が Exception 系/String/`#exception` 応答のいずれでもない → ほぼ確実な TypeError |
| `CatchWithUnthrownExceptionRule`(シャドー節半分) | 先行する広い rescue に隠される後続 rescue | (c) / **low** / **◎** `rescue StandardError; rescue ArgumentError` は階層比較のみで証明可能な実バグ |
| `CatchWithUnthrownExceptionRule`(never-thrown 半分) | try 本体が投げ得ない例外の catch | (c) / **high** / × Ruby に throws 宣言はなく任意の呼び出しが任意に raise し得る |
| `CaughtExceptionExistenceRule` | 未解決/非例外クラスの rescue | (c) / low-medium / ○ 解決済みで非 Exception のみ。ただし `rescue MyGem::Error`(モジュール tag ミックスインパターン)を許容しないと動くコードに発火 |
| checked-throws / too-wide-throws / throws-void クラスタ(10 ファイル) | `@throws` 注釈の網羅・過剰・共変性 | (c) / medium-high / × RBS に throws 語彙がない。仮に `%a{rigor:v1:throws}` を導入しても raise 集合の推論は非有界。「本体内のリテラル `raise X` が宣言に含まれない」断片のみ将来の low |
| `ThrowExpressionRule` 等バージョンゲート | PHP 8.0 ゲート | (a) / — |

### Functions / Methods / Properties(ディスパッチ中核系)

| ルール/クラスタ | 検出内容 | 判定 |
|---|---|---|
| `CallMethodsRule` / `CallStaticMethodsRule` / `CallToFunctionParametersRule`(+ 898 行の `FunctionCallParametersCheck`) | 未定義メソッド・arity・引数型・generics 解決 | (c) / — / **=** Rigor の存在意義そのもの。PHPStan は引数型を無条件検査するが、その素朴移植が Ruby で high-FP になることは ADR-64 が既に裁定済み(coerce 障壁)。残滓 2 点: 可視性強制(`send` が private を貫通する慣用ゆえ medium — send-aware ゲートなしでは不採用)/ kwarg リネーム越し override(下記) |
| `MethodCallWithPossiblyRenamedNamedArgumentRule` | override が kwarg 名を変える | (c) / **low** / **◎** Ruby の kwargs は実名(PHP の位置・名前二重性なし)なので PHP 版より強い: kwarg リネームは端的な LSP 破壊で ADR-35 に吸収可能 |
| `OverridingMethodRule` + helpers / `MethodSignatureRule` | Liskov 署名互換 | (c) / low / **=** ADR-35 出荷済み。`final` は (a)。`#[\Override]` 注釈規律は注釈駆動で low — 需要待ち |
| `ReturnTypeRule` 族(function/closure/arrow) | 宣言戻り値 vs 実体 | (b) / low / **=** `def.return-type-mismatch` |
| `IncompatibleDefaultParameterTypeRule` 3 種 | 引数デフォルト値 vs 宣言引数型 | (b) / **low** / **◎** デフォルト値はその場で畳める。ADR-5 により発火は*宣言済み*引数型限定 |
| printf クラスタ(`PrintfParametersRule` 等 3 種) | フォーマット文字列のプレースホルダ数・型 | (b) / **low** / **◎** `format`/`sprintf`/`String#%` のリテラルフォーマット検査 — 定数畳み込みの得意領域ど真ん中 |
| `RandomIntParametersRule` | min > max | (b) / low / ○ `rand(a..b)` 系。値域型があれば安価 |
| sort/implode castability クラスタ | 要素が to-string/比較可能か | (c) / medium-low / ○ 移植価値があるのは *sort* 側: `<=>` 非互換要素 union の `sort` は実 ArgumentError 族 |
| `ArrayFilterRule` / `ArrayValuesRule` | no-op になるコレクション呼び出し | (c) / medium / × always-truthy 包絡を継承する割に収量が薄い |
| NoDiscard クラスタ(`CallTo*WithNoDiscardRule`) | `#[\NoDiscard]` の戻り値破棄 | (c) / **low** / ○ must-use 注釈(`%a{rigor:v1:}` 候補)— 作者が要求した所でのみ発火。需要駆動 |
| 副作用なし文クラスタ(`CallTo*StatementWithoutSideEffectsRule`) | 純粋呼び出しの文位置 | (c) / high / ×(DeadCode 純粋性クラスタと同判定)。例外: ctor 変種の narrow 移植 — ADR-48 Data クラスの `.new` 文位置放置は medium で検討可 |
| `NullsafeMethodCallRule` / `NullsafePropertyFetchRule` | 非 nullable への `?->` | (b) / medium / ○ 「非 nil レシーバへの `&.`」— 動いている防御コードに発火する族なので always-truthy と同じ棚(`:info`/strict)でのみ |
| `MissingFunctionParameter/ReturnTypehintRule` 族 / `MissingTypehintCheck` | 型注釈の欠落・要素型なしコレクション | (c) / default-on なら medium / × 診断ではなく **coverage 面**の素材(`coverage --protection` が既に占有する軸) |
| `AccessPropertiesRule` 族 | 未定義プロパティアクセス | (c) / medium / **=** Ruby では ivar は自オブジェクト内のみ可視。クラス内の未書き込み `@ivar` 読みは ADR-58 が provenance ゲート付きで既に正しい適応形 |
| `TypesAssignedToPropertiesRule` / `DefaultValue…` | 宣言フィールド型 vs 代入 | (c) / RBS 宣言限定 low / ○ 推論フィールド型への発火は high(慣用的な widen)なので宣言限定に固定 |
| `UninitializedPropertyRule` | 未初期化プロパティ | (c) / — / **=** ADR-58 WD3(定義的代入)+ ADR-38 で意識的に分岐済み。`||=` 遅延メモ化が Ruby 固有の罠 |
| readonly 規律クラスタ(native + `@readonly` phpdoc の 8 種) | readonly 逸脱 | (c) / medium / ○ 注釈駆動 `@readonly` 対応物(両側作者で FP-safe)は将来案。readonly 性の*推定*は high で不採用 |
| `ConsistentConstructorRule` | `self.class.new` 系のための ctor 互換 | (c) / low-medium / ○ 注釈ゲート付きで `Class[T]` ファクトリパターンに有用 |
| `MissingReturnRule` | return 欠落 | (a) 主に / — / Ruby は最終式暗黙 return。残滓(`-> bot` 宣言で本体が完走し得る)は low だが微小 |
| PHP 固有群: closures `use()`、参照渡し、superglobals、attributes、LSB `static::`、property hooks、first-class callable ゲート | — | (a) / — |

### Generics(ディレクトリ丸ごと)

`@template` 境界・default・シャドーイング(G1)、generic 祖先のインスタンス化整合(G2)、変位位置検査(G3)
の全 15 ルール — **(c) / low / ◎ 一括採用候補**。RBS の型引数(境界 `< T`、`out`/`in` 変位)に対する
注釈リンティングであり、両側作者・構築的に FP-free。rbs gem 自身の検査との重複範囲を確認の上、
エンジン内バリデーションとして PR #96/#97 隔離アークに接続するのが自然。

### PhpDoc(ディレクトリ丸ごと)

注釈-vs-実体の整合検査ファミリ — **(c) / low / ◎ ジャンルとして最大の未採掘領域**。対応物:

- 不整合注釈クラスタ(`IncompatiblePhpDocTypeRule` 等 4 種)→ RBS/インライン RBS vs 推論の矛盾検査
- `@phpstan-assert` 検証 → `%a{rigor:v1:predicate/assertion}` が実在パラメータを参照し実際に狭めるかの検証
- 条件付き戻り値検証 → ADR-20 conditional 文法の検証層
- 不正タグ構文(`InvalidPhpDocTagValueRule` 等)→ 未知 `rigor:v1:` ディレクティブ・壊れたインライン RBS
- `@var` hygiene → インライン型表明が推論と矛盾(ADR-59 の `spec.impossible-assertion` 弱形の親戚)
- require-extends / require-implements / sealed → `conforms-to`・ADR-28・ADR-36/47 WD3b に接続

### 残りのディレクトリ(要点のみ)

- **Generators**: `yield` 値 vs 宣言ブロックシグネチャ検査は (c)/low で既存射程の拡張。`YieldInGeneratorRule` は (a)。
- **Keywords**: `ContinueBreakInLoopRule` は Ruby ではブロック内 `break`/`next` が合法なので medium — 不採用。`RequireFileExistsRule` は `require_relative` リテラル限定なら low だが解析中 IO が ADR-45 記述子と絡む — 保留。goto/strict_types は (a)。
- **Names / Namespaces**: `use` 文検査は (a)。基底の未解決定数参照は Rigor の discovery + Dynamic fallback が既に慎重版を体現。
- **Operators**: `InvalidBinaryOperationRule` は ADR-64/42/78 が既に裁定済み(=)。`InvalidComparisonOperationRule` の `<=>`/Comparable 欠落断片は sort-castability と同じ ○。inc/dec・pipe・backtick は (a)。
- **Missing**: 上記 `MissingReturnRule` のみ。
- **Pure**: 純粋性契約強制は high(メモ化・ロギングで Ruby はほぼ全て技術的に不純)— ×。逆向き「impure 宣言なのに副作用なし」は medium だが語彙自体が未導入。
- **Regexp**: `RegularExpressionPatternRule` — (b)/low/**◎**。文字列組み立てされたパターンが定数に畳めたとき `Regexp.new` を rescue ハーネスで実行検証(ADR-39 が正にこの技法を政策承認済み)。リテラル正規表現は Ruby がパース時に検査するため、価値は string-built パターンにある。
- **RestrictedUsage / InternalTag**: ハードコードされたルールではなく**プラグイン seam**(拡張がメッセージを供給)。Rigor では ADR-52 のコンパイル済みディスパッチ表に `restricted_usage` 動詞を載せれば deprecation(examples/rigor-deprecations)・internal-API・API-freeze 消費者を統一的に載せられる — ○ 需要駆動(§7.1 判定を維持)。
- **TooWideTypehints**: 戻り値過広検査は **ADR-5 robustness principle(strict returns)の執行アーム** — (b)/medium。Dynamic を含む本体では抑制、override 階層(ADR-35)考慮、意図的 API 幅は存在するため **`bleeding_edge:` 機能としての出荷が自然**(ADR-50 WD2 の第 2 消費者候補)。param-out 系は (a)(参照渡し)。
- **Traits**: ほぼ (a)(PHP の trait インライン化モデルの産物)。`ConflictingTraitConstantsRule` のモジュール-vs-includer 定数シャドーイングだけ薄い (c)/low。
- **Variables**: `DefinedVariableRule` は Ruby では nil-flow に変換され既存 possible-nil の領域(=)。isset/empty/?? 族は冗長ガード検出として always-truthy と同じ棚の ○。`$this`・unset・compact・by-ref は (a)。
- **Whitespace**: (a) — RuboCop の領分。
- **Api / Debug / Playground / Ignore**: Api はツール自身の BC-promise 執行(ADR-50 の凍結面をプラグインに強制する発想として参照価値、実装は RestrictedUsage に還元)。Debug の `assertType` 魔法関数は Rigor の spec fixture・ADR-62 oracle と同型 (d)。Playground の `PromoteParameterRule`(「この設定を有効にすればこのエラーが出ます」広告)は `show-bleedingedge` UX の親戚として記録。**`IgnoreParseErrorRule` は ◎**: 壊れた抑制コメントが黙って無効化されるのは baseline ワークフロー最悪の結末 — `# rigor:disable` のパースエラーを診断すべき。

## 再評価: 優先度付き裁定

### Tier 1 — 採用候補(low FP・既存機構で安価)

| # | 候補 | PHPStan 出典 | 根拠 |
|---|---|---|---|
| 1 | **RBS/注釈宣言バリデーション族**(未知クラス・不正型・壊れた alias・`%a{}` が実在パラメータを参照し実際に狭めるか・変位位置・generic 境界とインスタンス化整合) | PhpDoc/ + Generics/ + Classes のタグ妥当性クラスタ | 両側作者で構築的に FP-free。PR #96/#97 隔離アークの直接延長。ジャンルとして最大の未採掘領域 |
| 2 | **抑制コメントのパースエラー診断** | `IgnoreParseErrorRule` | 壊れた `# rigor:disable` の黙殺は抑制系の最悪故障モード。実装コストは既存パーサへのエラー経路のみ |
| 3 | **`ensure` 内 `return`** | `OverwrittenExitPointByFinallyRule` | 戻り値と進行中例外を飲む古典フットガン。純構文・RuboCop 先例で低 FP 実証済み |
| 4 | **`raise` 非例外オペランド** | `ThrowExprTypeRule` | Exception 系/String/`#exception` 応答のいずれでもなければほぼ確実な TypeError |
| 5 | **rescue 節シャドーイング** | `CatchWithUnthrownExceptionRule` の一部 | 階層比較のみで証明可能。never-thrown 半分は不採用 |
| 6 | **Hash リテラル重複キー** | `DuplicateKeysInLiteralArraysRule` | last-wins の黙殺は実バグ。リテラル+値ピン限定 |
| 7 | **フォーマット文字列プレースホルダ検査** | printf クラスタ | `format`/`sprintf`/`String#%` のリテラルフォーマット — 定数畳み込みの得意領域 |
| 8 | **引数デフォルト値 vs 宣言型** | `IncompatibleDefaultParameterTypeRule` | デフォルト値はその場で畳める。宣言済み引数型限定(ADR-5 整合) |
| 9 | **kwarg リネーム越し override** | `MethodCallWithPossiblyRenamedNamedArgumentRule` | Ruby では PHP 版より強い LSP 破壊。ADR-35 に吸収 |
| 10 | **文字列組み立て正規表現の実行検証** | `RegularExpressionPatternRule` | ADR-39 承認済み技法(rescue ハーネス内 `Regexp.new`)。日時パース検証(`DateTimeInstantiationRule` → `Time.parse` 系)も同型 |
| 11 | **impossible-check(型述語呼び出しの恒真恒偽)** | `ImpossibleCheckType*` | 既存 predicate-fact 機構の安価な消費者。`PossiblyImpureTipHelper` のメッセージ緩和も併取 |
| 12 | **`void` 値の使用** | `UsageOfVoidMatchExpressionRule` | RBS 宣言 `void` は作者意図。Steep 同等 |

### Tier 2 — ゲート付き・需要駆動(medium、または機構待ち)

- **too-wide return**(ADR-5 執行アーム)— `bleeding_edge:` 機能として。Dynamic 含有本体で抑制、ADR-35 階層考慮。
- **`&.` on 非 nil / 冗長ガード検出**(Nullsafe 系・isset 族)— always-truthy と同じ `:info`/strict 棚でのみ。
- **`restricted_usage` プラグイン動詞**(RestrictedUsage/InternalTag/Api の seam 統一)— §7.1 の demand-driven 判定を維持。deprecation・internal-API・凍結面執行の 3 消費者が既に見えている。
- **sealed / AllowedSubTypes + `case/in` 網羅性** — §7.1 ADOPT 判定と ADR-47 WD3b の合流点。依然 demand-gated。
- **`<=>` 非互換 union の `sort`/比較** — 実 ArgumentError 族だが coerce/monkey-patch ゲートが要る。
- **未使用 ctor 引数 / 注釈駆動 readonly / ConsistentConstructor / NoDiscard 注釈 / モジュールへの `.new`** — いずれも注釈または規約ゲート付きで low に落ちるが、需要が未観測。
- **範囲算術による比較恒真恒偽** — 値域型の保有量次第。

### Tier 3 — 不採用(Ruby では high FP、または既裁定)

- **純粋性ベースの no-effect 文**(DeadCode 純粋性クラスタ・Pure/)— メモ化 ivar 書き込み・モンキーパッチで Ruby 純粋性は不可知。fold カタログ限定の narrow 断片のみ将来枠。
- **未使用 private メソッド/定数** — `send`・シンボルコールバックが Rails の背骨。§7.1「抑制フックとペアでのみ、1.x 後置」を再確認。
- **重複宣言・再オープン検出** — Ruby の中核的動的性そのもの。
- **可視性強制(send-aware ゲートなし)/ abstract 推定 / readonly 推定 / `new static` 安全性** — 慣用パターンに発火。
- **naive binary-operation / 引数型の無条件検査** — ADR-64 coerce 障壁が既に正しい形へ削っている。
- **checked-throws 系** — throws 語彙が存在せず raise 集合は非有界。
- **missing-typehint 系** — 診断ではなく coverage 面の素材(既占有)。

### Tier 4 — PHP 固有(対象消滅)

参照渡し全般(ParameterOut・by-ref foreach)、closures `use()`、superglobals・`$this` 代入、goto/label、
`declare(strict_types)`、attributes、property hooks(PHP 8.4)、promoted properties、readonly class、
enum 構文、cast 構文とバージョンゲート、`use` import、LSB `static::`、inc/dec・pipe・backtick、
配列キー int|string 制約、BOM/whitespace。体感でルール資産の約 1/4。

## アーキテクチャ観察(ルール以外の持ち帰り)

1. **FP 制御の設計対比**: PHPStan は `RuleLevelHelper` の**レベル**で制御する — 低レベルでは nullable/mixed
   アームをルールから*見えなくする*型可視性フィルタ。Rigor は完全な型を保持し発火ポリシー
   (severity プロファイル・evidence tier・provenance ゲート)で制御する。Rigor 方式の方が誠実だが、
   PHPStan 方式は「導入ランプ」として機能している — onboarding 文脈(ADR-22/23)で参照価値。
2. **エラーオブジェクトの語彙**: PHPStan の `NonIgnorableRuleError`(抑制コメントで消せないエラー)と
   `FixableNodeRuleError`(auto-fix 添付、`--fix` の基盤)は Rigor に対応物がない。前者は
   configuration-error 系の抑制不能性として、後者は将来の `rigor fix` として記録。
3. **collector パターン**(2 パス cross-file 集計)は ADR-7 で据え置いた後、Rigor では discovery index +
   ADR-9 fact store が代替している。PHPStan の推移的純粋性 resolver はこのパターンの最重量消費者。
4. **trait 文脈 dedup**(`ConstantConditionInTraitRule`: 全 using class で同値のときのみ報告)は、
   モジュール本体を includer ごとに再解析する将来が来た場合の必須 FP 抑制機構。
5. **ツール自己保護ルール**(Api/ が第三者に BC-promise を執行、`make check-plugins` ≈ ADR-43 と同発想)
   と **Debug/ の `assertType` 自己ホスト型テストオラクル**(≈ spec fixture + ADR-62)は、設計が独立に
   収斂している確認材料。

## 手法と限界

- 調査は 4 系統のサブエージェント(ルール群 3 分割 + Rigor 側ルール棚卸し・先行判定収集)で実施し、
  本文はその統合。各ルールの error message 文字列を証拠として読んだが、**全 600 ファイルの実装を
  行単位で精読してはいない** — クラスタ化(Function/Method/StaticMethod 変種の同一視等)を含む。
- FP リスク評価は実測ではなく、Rigor の既裁定(ADR-64 coerce、ADR-78 reflective send、ADR-58
  provenance、ADR-47 コーパス掃引)への類推。Tier 1 候補の実装時は通常どおりコーパスゲートが必要。
- phpstan-strict-rules / phpstan-deprecation-rules 等の**別パッケージは対象外**(本体 `src/Rules` のみ)。
- 頭対頭の診断出力比較(同一コードベースへの両ツール実行)は依然として存在しない。
