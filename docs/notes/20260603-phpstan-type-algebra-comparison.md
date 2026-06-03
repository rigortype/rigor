# PHPStan 内部型演算（TypeCombinator / TypeUtils / 二項演算評価）と Rigor の比較

**Status:** research note, no design commitments. プラグインレベルでの型演算ギャップ調査。
**Date:** 2026-06-03.
**Rigor version:** working tree（v0.1.x 系、master @ `7d8000e6`）に対する観察。
**PHPStan version:** 配布 phar は `references/phpstan`（`2.1.39-767`）に vendor 済みだが**ソースは入っていない**（phar のみ）。内部クラスの引用は upstream
[`phpstan/phpstan-src`](https://github.com/phpstan/phpstan-src) の `2.1.x` ブランチを直接参照した。`references/phpstan` を再 grep しても `TypeCombinator.php` 等は見つからない点に注意。

**Why:** 「プラグインレベルで PHPStan と同水準の型演算をしたい」という要求に対し、両者の型代数（type algebra）サーフェスを突き合わせ、Rigor 側に不足している実装とテストカバレッジを特定するための土台。後続の移植検討／ADR 起票はこのノートを根拠にする。

**読み順.** §1 が PHPStan 側のサーフェス棚卸し、§2 が Rigor 側マッピング表、§3 がギャップ分析（プラグイン視点）、§4 がテストカバレッジ観点、§5 が ADR 要否の判断。`file:line` 引用は Rigor 作業ツリー / phpstan-src 2.1.x に対するもので、±数行ずれうる。引用前に再 grep すること。

---

## 0. 一段落オリエンテーション

PHPStan の型演算は **3 層**に分かれる。(1) 型オブジェクトの代数を扱う静的ファサード `TypeCombinator`（union/intersect/remove）と `TypeUtils`（抽出ヘルパ群）、(2) 各型が実装する `Type` インターフェース本体のメソッド群（`isSuperTypeOf` / `accepts` / `is*()` 述語 / `get*()` 抽出 / `to*()` 強制変換 / offset アクセス）、(3) AST 上の二項演算を `MutatingScope` が評価するロジック（定数スカラの実評価＋ `IntegerRangeType` の抽象範囲算術＋ union 直積分配）。プラグインはこの 3 層すべてを呼べるうえ、**二項演算の結果型を宣言する専用拡張点 `OperatorTypeSpecifyingExtension`** を持つ。

Rigor も対応する 3 層を持つ — `Type::Combinator`（[`lib/rigor/type/combinator.rb`](../../lib/rigor/type/combinator.rb)）、各キャリアの `accepts` / capability predicate / projection（[`docs/internal-spec/internal-type-api.md`](../internal-spec/internal-type-api.md)）、`ConstantFolding` の二項演算評価（[`lib/rigor/inference/method_dispatcher/constant_folding.rb`](../../lib/rigor/inference/method_dispatcher/constant_folding.rb)）。代数ファサードと関係演算はほぼ同水準だが、**プラグインから二項演算の結果型を差し込む拡張点が存在しない**点が最大の構造的ギャップである。

---

## 1. PHPStan 側のサーフェス棚卸し

### 1.1 `TypeCombinator`（正規化付き型代数ファサード）

`PHPStan\Type\TypeCombinator` の public static メソッド：

| メソッド | 役割 |
| --- | --- |
| `union(Type ...$types): Type` | 正規化 union。重複除去・subtype 吸収（supertype が勝つ）・定数スカラの集約（`true|false → bool`）・`string[]|int[] → (string|int)[]` の iterable マージ・定数配列の併合と過剰時の generalize |
| `intersect(Type ...$types): Type` | 正規化 intersect。union 上に分配（`A & (B|C) → (A&B)|(A&C)`）、矛盾は `NeverType`、subtype が勝つ |
| `remove(Type $from, Type $toRemove): Type` | 型差分。全消去で `NeverType` |
| `removeNull` / `addNull` / `containsNull` | null 専用の便宜ラッパ |
| `removeTruthy` / `removeFalsey` | 真偽値による narrowing 補助 |
| `countConstantArrayValueTypes` | 定数配列の値エントリ総数（generalize 閾値判定用） |

正規化の要点：implicit-never 除去 → benevolent union 展開 → ネスト union 平坦化 → スカラ集約 → enum case 分離 → iterable マージ → subtype 吸収 → 配列処理（`processArrayTypes`、値数が上限超で generalize）。

### 1.2 `TypeUtils`（抽出ヘルパ群）

2.x では多くが `Type` 本体のメソッドへ移管され、`TypeUtils` 側は縮小済み。現存する主なもの：`getConstantIntegers`, `getIntegerRanges`, `toBenevolentUnion`, `toStrictUnion`, `flattenTypes`（power-set 展開、巨大時に最適化）, `findThisType`, `findCallableType`, `getHasPropertyTypes`, `getAccessoryTypes`, `containsTemplateType`, `resolveLateResolvableTypes`。`getConstantStrings` 等の素朴な抽出はインターフェースの `getConstantStrings(): list<ConstantStringType>` に移った。

### 1.3 `Type` インターフェース本体の演算サーフェス

これが「型演算」の本体。プラグインは `Scope->getType($expr)` で得た `Type` に対し直接呼ぶ。

- **関係演算**：`isSuperTypeOf(Type): IsSuperTypeOfResult`（**プラグインが型問い合わせに使う推奨 API** —「`$this` の値集合が引数を包含するか」）、`accepts(Type, bool $strictTypes): AcceptsResult`（PHP の暗黙強制を加味した代入可否。`FloatType` が `IntegerType` を accept する等、意味が複雑なので型判定には不向き）、`equals(Type): bool`。
- **3 値述語（`TrinaryLogic` を返す）**：`isString` / `isInteger` / `isFloat` / `isBoolean` / `isArray` / `isList` / `isCallable` / `isObject` / `isEnum` / `isNull` / `isScalar` / `isOffsetAccessible` … および `isNumericString` / `isNonEmptyString` / `isNonFalsyString` / `isLiteralString` / `isLowercaseString` / `isClassString` のような**精密 string 述語**。
- **定数抽出**：`getConstantScalarTypes` / `getConstantScalarValues` / `getConstantStrings` / `getConstantArrays` / `isConstantScalarValue`。
- **強制変換 `to*()`**：`toBoolean` / `toNumber` / `toInteger` / `toFloat` / `toString` / `toArray` / `toArrayKey` / `toBitwiseNotType` / `toAbsoluteNumber` / `toCoercedArgumentType`。**これらは型→型の純関数**で、二項演算評価や `(string)$x` 等のキャスト解決に使われる。
- **offset アクセス**：`hasOffsetValueType(Type): TrinaryLogic`, `getOffsetValueType(Type): Type`, `setOffsetValueType(?Type,Type,bool): Type`, `setExistingOffsetValueType`, `unsetOffset`。配列操作 `getKeysArray` / `getValuesArray` / `sliceArray` / `popArray` / `flipArray` … が型レベルで多数。
- **精度管理**：`generalize(GeneralizePrecision): Type`（型が複雑化しすぎたとき定数情報を落とす）。

`TrinaryLogic`（`yes`/`no`/`maybe`、`createYes` 等）が述語・関係演算の共通戻り値で、union/intersection に内在する不確実性を表現する。

### 1.4 二項演算の評価（`MutatingScope`）

AST の `Expr\BinaryOp\*`（`Plus` / `Minus` / `Mul` / `Div` / `Mod` / `Pow` / `Concat` / 比較 / ビット演算）を `MutatingScope::getType()` 内で評価する。要点：

1. **定数スカラの実評価**：両辺が定数スカラなら、PHP の演算子で実際に計算して `ConstantIntegerType` / `ConstantFloatType` / `ConstantStringType` を生む。`int` オーバーフロー時は `float` に昇格。
2. **`IntegerRangeType` の抽象範囲算術**：`int<1,5> + int<10,20> → int<11,25>` のように、定数でなくても範囲同士で加減乗除・比較を計算する。`IntegerRangeType` 自体が範囲演算メソッドを持つ。
3. **union 直積分配**：オペランドが union なら各メンバの直積で評価して union に畳む。
4. **文字列連結 `Concat`**：定数なら定数文字列、そうでなければ `numeric-string` / `non-empty-string` 等の精密 string 型へ。
5. これらの結果は最終的に `TypeCombinator::union` で正規化される。

### 1.5 `OperatorTypeSpecifyingExtension`（**プラグイン向け二項演算フック**）

```php
interface OperatorTypeSpecifyingExtension
{
    public function isOperatorSupported(string $operatorSigil, Type $leftSide, Type $rightSide): bool;
    public function specifyType(string $operatorSigil, Type $leftSide, Type $rightSide): Type;
}
```

GMP / BCMath / Money など**演算子をオーバーロード（あるいは演算子的に振る舞う）オブジェクト型**に対し、二項演算の結果型をプラグインが宣言できる。config の `phpstan.neon` で
`tags: [phpstan.broker.operatorTypeSpecifyingExtension]` として登録する。**これが「プラグインレベルの二項演算型演算」の中核**であり、Rigor に直接対応物がない。

### 1.6 プラグインの型構築イディオム

`new ObjectType(...)` / `new ConstantStringType('x')` / `new UnionType([...])` を直接 `new` できるが、公式ガイドは「非正準形は単純化すべき」として **構築後は必ず `TypeCombinator::union/intersect` で正規化する**ことを推奨（直接 `new UnionType` だと `string&int` のような不正型を作りうる）。カスタム型を作る場合は `describe` / `equals` / `isSuperTypeOf` / `accepts` の実装が必須で、`isSuperTypeOf` を `TypeCombinator` 経由で厳密にテストせよ、とされる。

---

## 2. Rigor 側マッピング

| PHPStan | Rigor 対応 | 所在 | 状態 |
| --- | --- | --- | --- |
| `TypeCombinator::union` | `Type::Combinator.union` | [`combinator.rb:363`](../../lib/rigor/type/combinator.rb) | ✅ 同等（決定論的正規化 + lattice 恒等則） |
| `TypeCombinator::intersect` | `Type::Combinator.intersection` | [`combinator.rb:325`](../../lib/rigor/type/combinator.rb) | ✅ 同等 |
| `TypeCombinator::remove` | `Type::Combinator.difference`（`T - U` 演算子） | [`combinator.rb:123`](../../lib/rigor/type/combinator.rb) | ✅ Rigor は明示的差分演算子を持ち、診断表示も `D - U` 形を持つ（[type-operators.md](../type-specification/type-operators.md)）。むしろ PHPStan より表現が厚い |
| `removeNull`/`addNull`/`containsNull` | `difference(t, nil)` / `union(t, nil)` / `nil_value` 述語 | combinator + 述語 | ⚠️ 導出可能だが**専用便宜メソッドは未提供** |
| `removeTruthy`/`removeFalsey` | （narrowing は CFA 側） | [control-flow-analysis.md](../type-specification/control-flow-analysis.md) | ⚠️ 型代数ファサードとしては未公開 |
| `Type::isSuperTypeOf` | `Type#accepts(other, mode:)` → `AcceptsResult` | 各キャリア `accepts`（例 [`constant.rb:114`](../../lib/rigor/type/constant.rb)） | ✅ gradual consistency として実装。厳密 subtype（`subtype_of`）は slice 5+ で `SubtypeResult` 予定 |
| `Type::accepts` | `Type#accepts` | 同上 | ✅ gradual mode 実装、strict mode 予約 |
| `TrinaryLogic` | `Rigor::Trinary`（yes/no/maybe） | — | ✅ 同等 |
| `is*()` 述語群 | capability predicates（`string` / `integer` / `array` / `callable` …） | [internal-type-api.md](../internal-spec/internal-type-api.md) | ✅ 概ね同等。ただし PHPStan の精密 string 述語（`isNumericString` / `isLowercaseString` 等）は Rigor では Refined キャリア + 述語 ID 側に分散 |
| `getConstant*` 抽出 | projections（`constant_strings` / `constant_integers` …） | internal-type-api.md | ✅ 同等 |
| `IntegerRangeType` 範囲算術 | `try_fold_binary_range` ほか（additive / multiply / divide / comparison、corner 計算 + `0×∞=0` 等の代数的配慮） | [`constant_folding.rb:800`](../../lib/rigor/inference/method_dispatcher/constant_folding.rb) | ✅ **同等水準**。範囲 × 範囲の四隅積・除算ガード・無限端処理まで実装済み |
| 定数スカラ実評価（二項演算） | `ConstantFolding`（NUMERIC_BINARY / STRING_BINARY 等の許可リスト + 実 `send`） | constant_folding.rb | ✅ 同等。受け手/引数が `Constant` か `Union[Constant]` で許可リスト内なら実評価、外れたら `Dynamic[top]` に fail-soft |
| union 直積分配（二項演算） | ConstantFolding の Cartesian fold（`UNION_FOLD_INPUT/OUTPUT_LIMIT`） | constant_folding.rb | ✅ 同等（入出力上限あり） |
| `to*()` 強制変換（型→型純関数） | — | — | ❌ **型オブジェクトメソッドとして未公開**。キャスト/coerce は ConstantFolding 内部に閉じている |
| offset アクセス（`getOffsetValueType` 等） | `indexed_access` 型関数 + ShapeDispatch（Tuple/HashShape の `[]`/`fetch`/`dig`） | [`shape_dispatch.rb`](../../lib/rigor/inference/method_dispatcher/shape_dispatch.rb), [type-operators.md](../type-specification/type-operators.md) | ⚠️ エンジン内部では精密。**プラグインから呼べる offset ファサードは `indexed_access` 程度に限定** |
| `generalize(precision)` | `normalize`（冪等正規化）のみ | normalization.md | ⚠️ 精度を**意図的に落とす** generalize は未提供（union/出力上限による暗黙 widen はある） |
| **`OperatorTypeSpecifyingExtension`** | — | — | ❌ **対応物なし**。プラグインの二項演算フックが存在しない |
| プラグインの型構築 facade | `services.type`（= `Type::Combinator`） | [`services.rb:43`](../../lib/rigor/plugin/services.rb) | ✅ 正規化必須の facade を注入（PHPStan の「`new` より `TypeCombinator`」方針と一致） |

プラグイン拡張点（[`plugin/base.rb`](../../lib/rigor/plugin/base.rb)）は `node_rule`（86, 137 行）/ `dynamic_return`（210 行）/ `type_specifier`（239 行）/ `producer`（86 行）。PHPStan の `DynamicMethodReturnTypeExtension` ≈ Rigor `dynamic_return`、`TypeSpecifierExtension` ≈ `type_specifier`。**`OperatorTypeSpecifyingExtension` に対応するフックだけが欠けている**（`grep -i operator lib/rigor/plugin/` は空）。

---

## 3. ギャップ分析（プラグイン視点）

PHPStan「同水準」に向けた不足を、影響度順に。

### G1（要検証→**スパイク済み・解決**）— 二項演算プラグインフック

当初「Rigor にはプラグインの二項演算フックがない」と仮説したが、**2026-06-03 のコード・スパイクで反証された**。Ruby の `a + b` は Prism では `name: :+` の `Prism::CallNode` であり、通常の呼び出しと同じく `call_type_for` → `MethodDispatcher.dispatch` に `call_node: node` / `method_name: :+` / `scope:` 付きで流れる（[`expression_typer.rb:1233`](../../lib/rigor/inference/expression_typer.rb)）。dispatch の優先順位は **`ConstantFolding`（precise tiers）→ `try_plugin_contribution`（`dynamic_return`）→ RBS**（[`method_dispatcher.rb:74-97`](../../lib/rigor/inference/method_dispatcher.rb)）。プラグイン所有のレシーバは `Nominal[CustomType]` であって `Constant` / `IntegerRange` ではないため ConstantFolding は `nil` を返し、**dispatch は plugin tier に落ちる**。`dynamic_return_type` は receiver クラスのみでゲートし method 名は一切問わない（[`base.rb:382`](../../lib/rigor/plugin/base.rb)）。

結論：**PHPStan の `OperatorTypeSpecifyingExtension` 相当はすでに既存契約で実現できる**。

```ruby
dynamic_return receivers: ["Money"] do |call_node, scope|
  next nil unless %i[+ - * /].include?(call_node.name)
  right = scope.type_of(call_node.arguments&.arguments&.first)
  # ... Money 同士なら Money、Money×Integer なら Money など
  services.type.nominal_of("Money")
end
```

つまり **新フックは不要**。ギャップは「契約の不在」ではなく以下の 3 点に縮小する：

- **G1a（ドキュメント）**：`dynamic_return` が演算子糖衣も捕捉できることがどこにも明記されていない。ADR-37 / examples いずれも演算子ユースケースを示していない。
- **G1b（エルゴノミクス）**：receiver-only ゲートのため、ブロックが手動で `call_node.name` を分岐し、`scope.type_of` で右辺型を取り出す必要がある。PHPStan の `specifyType(sigil, left, right)` のような (演算子記号, 左型, 右型) を直接渡す糖衣がない。`operator_return operators: %i[+ -], receivers: [...]` のような薄い宣言糖衣は検討余地。
- **G1c（coerce 方向、設計上の真のギャップ）**：Ruby は `a + b` を `a` に対してディスパッチする。`1 + money` のように**左辺が組み込み型**のケースは Integer がレシーバになり、`coerce` を経由する。プラグインが Integer を所有しないと左辺起点の演算に介入できない。PHPStan は `isOperatorSupported($left, $right)` が**双方向**で左右どちらの型からでも判定できる点で構造的に勝る。Rigor で coerce 方向を扱うには、(i) `coerce` 呼び出し自体を `dynamic_return receivers: ["Integer"]` …は所有衝突で不可、(ii) エンジン側で「右辺がプラグイン所有型なら左辺組み込み型の算術をプラグインに委譲」する新経路、のいずれかが要る。**ここだけは ADR 級の設計判断が残る**。

ユースケース（Ruby 生態系での実需）：

- `BigDecimal` / `Rational` / `Complex` の算術結果型（既に [oss-library-survey](20260519-oss-library-survey.md) で BigDecimal-coerce の FP 修正実績あり — 演算子経路の需要は実在。これらは coerce 方向 G1c の典型）。
- `Money`/`Unit` 系（`examples/rigor-units` が単位付き数値を扱う — 演算子オーバーロードの典型。同型同士なら G1 既存契約で対応可）。
- ベクトル/行列、`Set` の `|`/`&`/`-`、`Pathname#/` 等（同型／自型レシーバが多く G1 既存契約でカバー可）。

### G2 — 強制変換 `to*()` サーフェスの不在

PHPStan の `toNumber`/`toString`/`toBoolean`/`toArray` は**型→型の純関数**としてプラグインから呼べる。Rigor では同等のロジックが `ConstantFolding` の内部に閉じ、プラグインが「この型を boolish/integer に coerce したら何になるか」を型代数として問えない。`boolish` の扱い（[special-types.md](../type-specification/special-types.md)）はあるが、汎用 coercion facade ではない。

### G3 — `generalize` の不在

PHPStan は精度を意図的に落とす `generalize` を持つ。Rigor は `normalize`（冪等・情報保存）＋ fold 出力上限による暗黙 widen のみで、プラグインが「複雑になりすぎたので定数情報を捨てて `Integer` に上げる」を明示要求できない。ADR-41（inference budget）の widen-and-diagnose 方針と隣接するため、**budget 側に寄せるか型代数側に出すかは設計判断**。

### G4 — null/truthy 便宜メソッドの不在

`removeNull` / `addNull` / `containsNull` / `removeTruthy` / `removeFalsey` 相当が facade に無い。`difference`/`union` + 述語で導出できるので**純粋に DX（便宜）の問題**。プラグインコードの冗長さに直結する。

### G5 — offset アクセス facade の限定

ShapeDispatch はエンジン内部で Tuple/HashShape の offset を精密に解くが、プラグインに公開された型代数 API は `indexed_access` 型関数程度。PHPStan の `getOffsetValueType` / `setOffsetValueType` のような**型レベル offset 操作の純関数群**は plugin facade に揃っていない。

### 同等で問題ない領域（移植不要）

union/intersect/difference、accepts（gradual）、capability predicates、定数抽出、定数スカラ実評価、**IntegerRange 抽象算術**、union 直積分配、正規化必須 facade の注入方針。これらは PHPStan と同水準かそれ以上（差分演算子と診断表示は Rigor が厚い）。

---

## 4. テストカバレッジ観点

PHPStan は `isSuperTypeOf` を `TypeCombinator` 経由で網羅テストするのが規範。Rigor 側で強化したい軸：

1. **二項演算 × union 直積**：`Union[Constant]` 同士の算術が直積で正しく畳まれ、上限超で fail-soft する境界テスト（`UNION_FOLD_INPUT/OUTPUT_LIMIT` 直近）。
2. **IntegerRange 算術の代数的エッジ**：`0×∞`、除数が 0 を跨ぐ範囲、片側無限、減算での端入れ替え（`range_additive` の `:-` 分岐）。既に実装は配慮済みだが回帰テストの明示化。
3. **accepts の gradual 非推移性**：`relations-and-certainty.md` の「consistent は推移的でない」を突くケース表。
4. **差分演算子の正規化**：`String - "" - "x"` の平坦化、`Refined` との相互作用、診断表示の `D - (U|V)` 形。
5. **プラグイン facade の正規化保証**：`services.type.union(...)` が直接 `Union.new` を許さず常に正規化を通すことの契約テスト（PHPStan の「`new` 回避」方針の Rigor 版）。
6. **演算子糖衣 → dynamic_return** の回帰スペック（スパイクで動作確認済み・テストは未整備）：`Nominal[Custom] + Custom` が `dynamic_return receivers: ["Custom"]` のブロックに `:+` の `call_node` として届き、結果型が plugin tier で確定すること。`examples/rigor-units` あたりに演算子ケースを追加して契約を固定するのが自然。

---

## 5. ADR 要否の判断

スパイク（§3 G1）で前提が一つ崩れた：**自型／同型レシーバの二項演算は新フックなしで既に対応できる**。これにより ADR の必要範囲は当初想定より小さい。

- **G1a/G1b（ドキュメント + エルゴノミクス）は ADR 不要**。`dynamic_return` の演算子捕捉を examples（`rigor-units`）と manual に明記し、回帰スペックで固定すれば足りる。薄い宣言糖衣 `operator_return` は欲しければ後続の小改善（ADR 不要、CHANGELOG レベル）。
- **G1c（coerce 方向）だけが ADR 級**。`1 + money` のように左辺が組み込み型のケースでプラグインが介入する経路は現契約に存在せず、エンジン dispatch への新経路（右辺がプラグイン所有型のとき左辺組み込み算術を委譲）か `coerce` 対応の設計判断を要する。PHPStan の双方向 `isOperatorSupported(left, right)` との構造差はここに集約される。**rejected/deferred 代替を記録する価値があるのはこの一点**。ただし実需（BigDecimal-coerce 系）は既に survey で出ているので、ADR を起こす意義はある。
- **G2/G3/G5** は型代数 facade の拡張で、ADR-37 の延長として**まとめて 1 つの「plugin type-algebra facade 拡充」ADR**にできる。ただし需要ドリブン（実プラグインが詰まってから）でよい。ADR-41 の budget 方針と G3 の調停は要メモ。
- **G4** は ADR 不要。`Type::Combinator` に便宜メソッドを足すだけの DX 改善で、CHANGELOG レベル。

**推奨**：

1. **即時・ADR 不要**：G1a/G1b（演算子糖衣の文書化 + `rigor-units` への演算子ケース追加 + 回帰スペック、§4-6）と G4（null 便宜メソッド）。これで「自型同士の演算子型演算」は PHPStan と同水準に並ぶ。
2. **ADR 起票推奨**：G1c（coerce 方向／左辺組み込み型からの演算子委譲）。タイトル案「Plugin-contributed binary-operator return types（coerce-direction）」。主題は coerce 経路、従属節で G1a/G1b の既存契約活用と facade 拡充（G2/G3/G5）を将来作業として言及。ADR-2 / ADR-37 / ADR-39（プラグインがターゲットライブラリを叩く）の系譜。
3. **テスト軸（§4）**は ADR と独立に着手可能。

→ ADR を起こすとすれば**範囲は G1c に絞った 1 本**が妥当。G1 全体を ADR にする当初案は過大だった。

---

## 付録：一次ソース

- PHPStan: [`TypeCombinator.php`](https://github.com/phpstan/phpstan-src/blob/2.1.x/src/Type/TypeCombinator.php), [`TypeUtils.php`](https://github.com/phpstan/phpstan-src/blob/2.1.x/src/Type/TypeUtils.php), [`Type.php`](https://github.com/phpstan/phpstan-src/blob/2.1.x/src/Type/Type.php), [`OperatorTypeSpecifyingExtension.php`](https://github.com/phpstan/phpstan-src/blob/2.1.x/src/Type/OperatorTypeSpecifyingExtension.php), [`MutatingScope.php`](https://github.com/phpstan/phpstan-src/blob/2.1.x/src/Analyser/MutatingScope.php), 公式ガイド [Type System](https://phpstan.org/developing-extensions/type-system) / [Extension Types](https://phpstan.org/developing-extensions/extension-types)。
- Rigor: [`combinator.rb`](../../lib/rigor/type/combinator.rb), [`constant_folding.rb`](../../lib/rigor/inference/method_dispatcher/constant_folding.rb), [`shape_dispatch.rb`](../../lib/rigor/inference/method_dispatcher/shape_dispatch.rb), [`plugin/base.rb`](../../lib/rigor/plugin/base.rb), [`plugin/services.rb`](../../lib/rigor/plugin/services.rb), [internal-type-api.md](../internal-spec/internal-type-api.md), [type-operators.md](../type-specification/type-operators.md), [value-lattice.md](../type-specification/value-lattice.md), [relations-and-certainty.md](../type-specification/relations-and-certainty.md)。
