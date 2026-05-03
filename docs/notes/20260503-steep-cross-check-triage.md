# Steep 2.0 cross-check triage (2026-05-03)

Steep 2.0.0 を `tool/steep/` に独立 bundle として追加し、`make steep-check`
で `lib/` を `sig/` に対して走らせた結果のトリアージ。Rigor 自身の `make
check` は引き続きクリーンに保つ前提で、外部チェッカーの観点からどの警告が
**Rigor でも検知すべき真の不一致** で、どれが **Rigor では拾わないのが
正しい (= Steep 側の限界)** で、どれが **より精密な型付けで偽陽性として
解消できる** ものかを切り分ける。

## サマリ

- 入力: `make steep-check`
- 集計: **17 ファイル / 54 件** (`Ruby::MethodBodyTypeMismatch` 42 件、
  `Ruby::MethodParameterMismatch` 9 件、`RBS::DuplicatedMethodDefinition`
  3 件)
- 分類:

| カテゴリ | 件数 | 概要 |
| --- | --- | --- |
| A. Rigor も検知すべき (真の sig drift) | 48 | 戻り値型の宣言誤り、引数欠落、宣言重複。`sig/` 修正で解消できる。 |
| B. Rigor では検知しないのが適切 (Steep 固有の偽陽性) | 0 | 該当なし。今回の警告は全て事実に根拠がある。 |
| C. 適切な型付けで偽陽性として解消可能 (Rigor の精密化で消える) | 6 | `Array()` 強制変換と `Data.define` のキーワード合成を追えていないことに起因。 |

以下、カテゴリ別に内訳と推奨アクションをまとめる。

---

## カテゴリ A — Rigor も検知すべき (真の sig drift)

`sig/` 側の手書き宣言が `lib/` の実装に追従できていない。Robustness
Principle ([docs/type-specification/robustness-principle.md](../type-specification/robustness-principle.md))
の「strict on returns」を素直に適用すれば検出されるべき類のもの。

### A-1. 述語メソッド `top` / `bot` / `dynamic` の戻り値型 (39 件)

各タイプキャリア (`Top`, `Bot`, `Dynamic`, `Constant`, `IntegerRange`,
`Nominal`, `Singleton`, `Union`, `Difference`, `Refined`, `Intersection`,
`Tuple`, `HashShape`) が公開している述語メソッド `top` / `bot` / `dynamic`
は実装上 `Trinary.yes/no/maybe` を返す ([lib/rigor/type/top.rb:26-36](../../lib/rigor/type/top.rb))
が、[sig/rigor/type.rbs:11-13](../../sig/rigor/type.rbs) は

```rbs
def top: () -> Top
def bot: () -> Bot
def dynamic: () -> Dynamic
```

と宣言している。**戻り値型の意味そのものが取り違えられている**:
sig は「`top` と呼ぶと `Top` 型インスタンスが返る」と読めるが、実際は
「この型は top か?」という述語であり Trinary を返す。

- 検知すべきか: **Yes** — strict on returns の素直な違反。Rigor が完成
  すれば自動で検出可能。
- 修正: sig 側を `def top: () -> Trinary` 等に揃える。13 ファイル × 3
  メソッド = 39 箇所。
- 影響範囲: `sig/rigor/type.rbs` のみ。`lib/` 側は変更不要。

注: `Refined#dynamic` と `Difference#dynamic` の警告は body 推定が
`(Type::Dynamic | Trinary)` になっているが、これも上記と同一原因
(継承先 / 委譲先で誤って `Type::Dynamic` を返している経路を Steep が
拾った副次効果) なので同じ修正で消える。

### A-2. `IntegerRange#lower` / `upper` の戻り値 (2 件)

[lib/rigor/type/integer_range.rb:67-71](../../lib/rigor/type/integer_range.rb) は
`NEG_INFINITY` / `POS_INFINITY` を Symbol 番兵で表現しており、`lower` /
`upper` は `Integer | Float | Symbol` を返し得る。一方
[sig/rigor/type.rbs:71-72](../../sig/rigor/type.rbs) は `() -> Numeric`。
Symbol は `Numeric` の部分型ではないので不整合。

- 検知すべきか: **Yes** — 戻り値の集合が宣言より広い、明確な strict-on-returns 違反。
- 修正パスは 2 通り:
  1. sig を `() -> (Integer | Float | Symbol)` (実体に合わせる)
  2. impl を `Float::INFINITY` 番兵に置換し sig の `Numeric` を維持
- どちらが望ましいかは ADR 3 (型表現) と擦り合わせる必要があるが、現状
  Symbol 番兵を採用している以上、当面は sig 側更新が現実的。

### A-3. `record_declarations` の引数欠落 (1 件)

[lib/rigor/inference/scope_indexer.rb:473](../../lib/rigor/inference/scope_indexer.rb)
は 4 引数:

```ruby
def record_declarations(node, qualified_prefix, identity_table, discovered)
```

[sig/rigor/inference.rbs:135](../../sig/rigor/inference.rbs) は 3 引数:

```rbs
def self?.record_declarations: (untyped node, Array[String] qualified_prefix, Hash[untyped, Type::t] table) -> void
```

第 4 引数 `discovered` が sig から落ちている、典型的な sig drift。

- 修正: sig に `Array[untyped] discovered` (実型は要確認) を追加。

### A-4. `RbsLoader#instance_definition` / `singleton_definition` の重複宣言 (3 件)

[sig/rigor/environment.rbs:41,48](../../sig/rigor/environment.rbs) と
[同:43,49](../../sig/rigor/environment.rbs) で同名メソッドが二度宣言され、
戻り値型が `untyped` と `untyped?` で食い違う:

```rbs
def instance_definition: (String | Symbol class_name) -> untyped
...
def instance_definition: (String | Symbol class_name) -> untyped?
```

RBS 仕様ではオーバーロード以外の重複は許されない。`instance_definition`
/ `singleton_definition` の各 1 行を削除して `untyped?` 側に統一するの
が妥当 (実装が `nil` を返し得るかは要確認のうえ確定)。

- 検知すべきか: **Yes** — RBS 仕様レベルのエラー、Rigor が RBS パーサ経由
  で読む段階で同様にエラーになる (なるべき)。

### A-5. `CLI#initialize` の必須キーワード (3 件)

[lib/rigor/cli.rb:31](../../lib/rigor/cli.rb):

```ruby
def initialize(argv, out:, err:)
```

[sig/rigor.rbs:23](../../sig/rigor.rbs):

```rbs
def initialize: (?Array[String] argv, ?out: untyped, ?err: untyped) -> void
```

sig は `argv` も `out:` も `err:` も全て optional だが、impl は全て
required (`out:` には既定値が無い)。caller が sig を信じて `CLI.new`
を引数なしで呼ぶと `ArgumentError` で落ちる。

- 検知すべきか: **Yes** — 契約上の lenience が impl で守られていない。
- 解消方向: ADR 5 (Robustness Principle) に従えば impl 側を寛容化、
  すなわち `def initialize(argv = [], out: $stdout, err: $stderr)` に
  揃えるのが筋。これで `self.start` の挙動も維持される。

---

## カテゴリ B — Rigor では検知しないのが適切 (Steep 固有の偽陽性)

**今回は該当ゼロ**。Steep 2.0 が出した警告はすべて何らかの実体的な
不一致を反映していた。Rigor が独自の寛容性ポリシーで意図的に「検出
しない」と決めた領域が今回ヒットしなかったのは、`sig/` 側がそもそも
かなり手書きで実装と乖離していて、寛容性の議論に到達するより先に基本
契約違反が露出したため。今後 sig を修正したあと再走させると、本カテ
ゴリに分類すべきケースが現れる可能性は高い (例: `untyped` 経由の
gradual 受け入れを Steep が拒む等)。

---

## カテゴリ C — 適切な型付けで偽陽性として解消可能

Steep 側のフローセンシティブ性または核ライブラリのモデリングが粗いた
めに発生している警告。Rigor の robustness principle と control-flow
analysis ([docs/type-specification/control-flow-analysis.md](../type-specification/control-flow-analysis.md))
が完成すれば自然に消えるはず、という意味で偽陽性扱い。

### C-1. `Array(union)` 強制変換 (1 件)

[lib/rigor/analysis/fact_store.rb:128](../../lib/rigor/analysis/fact_store.rb):

```ruby
def fact_targets(fact)
  Array(fact.target)
end
```

`fact.target` は `Target | Array[Target]`。Ruby の `Array()` カーネル
メソッドは「`Array[T]` ならそのまま、`T` なら `[T]` でラップ」する規約
なので、戻り値は当然 `Array[Target]`。Steep は `Array()` の戻り値を
`[T | Array[T]]` (要素 1 のタプル) と推論しており、ユニオン分岐越しの
specialization に踏み込めていない。

- Rigor 視点: `Kernel#Array` の組み込みカタログ (
  [data/builtins/](../../data/builtins/)) に「ユニオン引数の場合は
  各メンバを正規化して unify」という仕様を入れれば消せる。
- 当面の workaround は不要 — 偽陽性として lenient 設定下で
  warning に留まる。

### C-2. `Data.define` 派生クラスの `initialize` オーバーライド (5 件)

[lib/rigor/analysis/fact_store.rb:26,32](../../lib/rigor/analysis/fact_store.rb)
の `Target` / `Fact` は `Data.define(:kind, :name)` 等で生成されたクラ
スに `def initialize(kind:, name:) ...` で前処理を被せている。Steep は
`Data.define` の自動生成シグネチャと手書きオーバーライドのキーワード
合致を解析しきれず、`MethodParameterMismatch` を 5 箇所で出している。

- Rigor 視点: `Data.define(*members)` の特化推論
  ([docs/type-specification/structural-interfaces-and-object-shapes.md](../type-specification/structural-interfaces-and-object-shapes.md))
  に加え、明示的に書かれた `initialize` シグネチャを優先する規則を入れ
  れば消える。これは v0.0.4 / v0.1.0 のロードマップに直接乗りそうな
  特徴量。
- 暫定: sig 側で `Target` / `Fact` の `initialize` が `Data` 由来の
  自動生成シグネチャと矛盾しないよう **明示的に書ききる** ことで Steep
  も黙る (現状の sig 側はすでに手書きしてある)。Steep が拾えていないの
  は `Data` 由来の合成シグネチャ側で、Rigor が `Data.define` 専用の
  認識器を持てば優位に立てる領域。

---

## アクション提案

優先度順:

1. **`sig/rigor/type.rbs` の述語メソッド戻り値型修正** (A-1, 39 件)
   - 機械的置換に近い。`def (top|bot|dynamic): () -> Trinary` に揃える。
   - これだけで全 54 件中 39 件が消える。
2. **`environment.rbs` の重複宣言整理** (A-4, 3 件)
   - 余分な行を削除し `untyped?` 側に統一。
3. **`scope_indexer` の sig に第 4 引数を追加** (A-3, 1 件)
4. **`IntegerRange#lower/upper` の sig 修正** (A-2, 2 件)
   - 短期: sig を `Integer | Float | Symbol` に。長期: ADR 3 で番兵
     表現を再検討。
5. **`CLI#initialize` の寛容化** (A-5, 3 件)
   - `def initialize(argv = [], out: $stdout, err: $stderr)` に修正。
6. **カテゴリ C 系は当面 lenient warning として放置**。Rigor 側の
   `Kernel#Array` モデリング / `Data.define` 認識器が入った時点で再走
   させ、消えたことを確認する。

---

## 再現手順

```sh
# 一回限り (依存解決)
nix develop --command make steep-install

# 走らせる
nix develop --command make steep-check

# 個別ターゲット (オプション渡し)
nix develop --command make steep ARGS="check --severity-level=error"
```

`Steepfile` は現状 `D::Ruby.lenient` 構成。互換性チェック目的で warning
を網羅的に拾うため (= strict より広く検出するため) この設定にしている。
将来 `make verify` チェーンに組み込むかどうかは、A-1〜A-5 を解消した後
の残件を見て判断する。
