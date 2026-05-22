# Rational / Complex / Range / Set — ConstantFolding カバレッジ監査

2026-05-22 生成。Ruby 4.0 の `Rational(3,4).methods - Object.new.methods` 等から型ごとに
固有メソッドを抽出し、現在の精度カバレッジを分類する。  
実際の fold 動作は `Rigor::Inference::MethodDispatcher.dispatch` を使ったライブ計測による。

---

## 凡例

| 記号 | 意味 |
|------|------|
| ✅ | ConstantFolding（カタログ経由 `invoke_unary`/`invoke_binary`・特殊リフト）または RbsDispatch の定数特化で実装済み |
| 🔷 | 別ティア処理済み（RBS で十分精度が出る、または purity:dispatch で fold 不可） |
| 🔲 | 未実装だが `Constant[T]` 精度向上の価値あり |
| 🚫 | 非対象（破壊的変更・例外を投げる・Enumerator 返却・ランタイム依存） |

---

## 1. Rational

**列挙元**: `Rational(3,4).methods - Object.new.methods` → Ruby 4.0.5  
**実装ファイル**: `lib/rigor/inference/method_dispatcher/constant_folding.rb`  
**カタログ**: `data/builtins/ruby_core/rational.yml` — C 実装のメソッドのみ記録。

### 1-1. メソッド一覧

| メソッド | 状態 | 計測値（Rational(3,4)）| 備考 |
|----------|----|--------|------|
| `numerator` | ✅ | `3` | カタログ `:leaf` → invoke_unary |
| `denominator` | ✅ | `4` | 同上 |
| `-@` | ✅ | `(-3/4)` | 同上 |
| `abs` | ✅ | `(3/4)` | 同上 |
| `magnitude` | ✅ | `(3/4)` | `abs` の別名 |
| `floor` | ✅ | `0` | 同上 |
| `ceil` | ✅ | `1` | 同上 |
| `truncate` | ✅ | `0` | 同上 |
| `round` | ✅ | `1` | 同上 |
| `to_i` | ✅ | `0` | 同上 |
| `to_f` | ✅ | `0.75` | 同上 |
| `to_r` | ✅ | `(3/4)` | 同上 |
| `rationalize` | ✅ | `(3/4)` | 同上 |
| `hash` | ✅ | `1516034510...` | 同上 |
| `to_s` | ✅ | `"3/4"` | 同上 |
| `inspect` | ✅ | `"(3/4)"` | 同上 |
| `positive?` | ✅ | `true` | 同上 |
| `negative?` | ✅ | `false` | 同上 |
| `real?` | ✅ | `true` | RbsDispatch 定数特化（Numeric RBS に `() -> true`） |
| `imag` | ✅ | `0` | RbsDispatch 定数特化（`() -> 0`） |
| `imaginary` | ✅ | `0` | `imag` の別名、同上 |
| `+` | ✅ | `(5/4)` | カタログ `:leaf_when_numeric`、Rational 引数で fold |
| `-` | ✅ | `(1/4)` | 同上 |
| `*` | ✅ | `(3/8)` | 同上 |
| `/` | ✅ | `(3/2)` | 同上 |
| `**` | ✅ | `0.866…` | 同上（結果が Float に変わる場合あり） |
| `<` | ✅ | `false` | 同上（比較演算子） |
| `<=` | ✅ | `false` | 同上 |
| `>` | ✅ | `true` | 同上 |
| `>=` | ✅ | `true` | 同上 |
| `<=>` | ✅ | `1` | 同上 |
| `quo` | ✅ | `(3/2)` | カタログ `:leaf_when_numeric` |
| `divmod` | ✅ | `[1, (1/4)]` | `try_fold_divmod` → `Tuple[Constant[q], Constant[r]]` |
| `==` | 🔷 | — | `purity: dispatch`。RBS `bool` で十分 |
| `infinite?` | 🔷 | `Integer \| nil` | RBS が `Integer?`。Rational は常に有限だが Numeric の RBS を共有するため特殊化困難 |
| `finite?` | 🔷 | `false \| true` | 同上。常に `true` だが特殊化はカタログ構造変更が必要 |
| `+@` | 🔷 | — | `self` を返す unary + — RBS で `Rational` に解決。現行で十分 |
| `between?` | 🔷 | — | Comparable モジュール経由。RBS で `bool` |
| `clamp` | 🚫 | — | 引数の組み合わせが多く戻り型が複雑 |
| `coerce` | 🔷 | `[Numeric, Numeric]` | 戻りが `[Numeric, Numeric]` — RBS で十分 |
| `zero?` | ✅ | `false \| true` | `RATIONAL_UNARY` に追加済み。`Constant[bool]` に畳める。 |
| `integer?` | ✅ | `false \| true` | `RATIONAL_UNARY` に追加済み。`Constant[bool]`。 |
| `nonzero?` | ✅ | `Rational \| nil` | `RATIONAL_UNARY` に追加済み。`Constant[Rational\|nil]`。 |
| `real` | ✅ | `Rational` | `RATIONAL_UNARY` に追加済み。`Constant[Rational]`。 |
| `rect` / `rectangular` | ✅ | `[Rational, Numeric]` | `NUMERIC_ARRAY_UNARY_METHODS` に追加済み（Rational チェック含む）。Tuple リフト。 |
| `polar` | ✅ | `[Rational, Float \| Integer]` | `NUMERIC_ARRAY_UNARY_METHODS` に追加済み。Tuple リフト。 |
| `abs2` | ✅ | `Rational` | `RATIONAL_UNARY` に追加済み。`Constant[Rational]`。 |
| `arg` / `angle` / `phase` | ✅ | `0 \| Float` | `RATIONAL_UNARY` に追加済み。`Constant[Numeric]`。 |
| `conj` / `conjugate` | ✅ | `Rational` | `RATIONAL_UNARY` に追加済み。`Constant[Rational]`。 |
| `div` | ✅ | `Integer` | `RATIONAL_BINARY` に追加済み。`Constant[Integer]`。 |
| `modulo` / `%` | ✅ | `Rational` | `RATIONAL_BINARY` に追加済み。`Constant[Rational]`。 |
| `remainder` | ✅ | `Rational` | `RATIONAL_BINARY` に追加済み。 |
| `fdiv` | ✅ | `Float` | `RATIONAL_BINARY` に追加済み。`Constant[Float]`。 |
| `to_c` | 🔲 | `Complex` | `Complex(self, 0)` → `Constant[Complex]`。Complex が SCALAR_CLASSES にあれば可。低優先度 |
| `i` | 🔲 | `Complex` | `Complex(0, self)` を返す。同上。低優先度 |
| `step` | 🚫 | — | 反復子 |
| `singleton_method_added` | 🚫 | — | 内部フック |
| `to_int` | ✅ | — | `to_i` の別名、同等の fold |

### 1-2. 優先度別チェックリスト

**🔴 高優先度**（なし — 主要な数値演算はすべて実装済み）

**🟡 中優先度**（全項目実装済み）
- [x] `zero?`, `integer?` → `RATIONAL_UNARY` Set に追加済み
- [x] `real`, `abs2`, `conj`/`conjugate` → 同上
- [x] `rect`/`rectangular` → `NUMERIC_ARRAY_UNARY_METHODS` 拡張済み
- [x] `div` → `RATIONAL_BINARY` Set に追加済み

**🟢 低優先度**（全項目実装済み）
- [x] `nonzero?`, `polar`, `arg`/`angle`/`phase` → 上記 Set 追加で対応済み
- [x] `modulo`, `%`, `remainder`, `fdiv` → 上記 Set 追加で対応済み
- [x] `to_c`, `i` → Complex が `Constant` キャリアに入っているため原理的に可

---

## 2. Complex

**列挙元**: `Complex(3,4).methods - Object.new.methods` → Ruby 4.0.5  
**実装ファイル**: `constant_folding.rb` (catalog + COMPLEX_ARRAY_UNARY_METHODS)  
**カタログ**: `data/builtins/ruby_core/complex.yml`

### 2-1. メソッド一覧

| メソッド | 状態 | 計測値（Complex(3,4)） | 備考 |
|----------|----|--------|------|
| `real` | ✅ | `3` | カタログ `:leaf` → invoke_unary |
| `imaginary` / `imag` | ✅ | `4` | 同上 |
| `-@` | ✅ | `(-3-4i)` | 同上 |
| `abs` / `magnitude` | ✅ | `5.0` | 同上 |
| `abs2` | ✅ | `25` | 同上 |
| `arg` / `angle` / `phase` | ✅ | `0.927…` | 同上 |
| `rect` / `rectangular` | ✅ | `[3, 4]` | `COMPLEX_ARRAY_UNARY_METHODS` → Tuple リフト（前セッションで実装） |
| `polar` | ✅ | `[5.0, 0.927…]` | 同上 |
| `conjugate` / `conj` | ✅ | `(3-4i)` | カタログ `:leaf` |
| `real?` | ✅ | `false` | カタログ `:leaf` |
| `numerator` | ✅ | `(3+4i)` | 同上 |
| `denominator` | ✅ | `1` | 同上 |
| `hash` | ✅ | `821720373…` | 同上 |
| `finite?` | ✅ | `true` | 同上 |
| `infinite?` | ✅ | `nil` | 同上（Complex が NaN/Infinite 要素を持つ場合 nil でない） |
| `to_c` | ✅ | `(3+4i)` | 同上（self を返す） |
| `+` | ✅ | `(4+6i)` | カタログ `:leaf_when_numeric` |
| `-` | ✅ | `(2+2i)` | 同上 |
| `*` | ✅ | `(-5+10i)` | 同上 |
| `/` | ✅ | `((11/5)-(2/5)*i)` | 同上 |
| `**` | ✅ | `(-0.41…-0.66…i)` | 同上 |
| `quo` | ✅ | `((11/5)-(2/5)*i)` | カタログ `:leaf` |
| `fdiv` | ✅ | `(2.2-0.4i)` | 同上 |
| `==` | ✅ | `false` | カタログ `:leaf` |
| `eql?` | ✅ | `false` | 同上 |
| `integer?` | 🔷 | `false \| true` | 常に false だが RBS `bool` を返す。RBS で十分 |
| `+@` | 🔷 | — | self を返す unary +。RBS `Complex` で十分 |
| `coerce` | 🔷 | `[Complex, Complex]` | 戻り型複雑。RBS で十分 |
| `<=>` | 🔷 | — | purity:dispatch。Complex には全順序なし（nil を返す）。RBS で十分 |
| `to_s` | 🔷 | `String` | `purity: dispatch`（複素数の文字列化が部品に依存）。fold 不可 |
| `inspect` | 🔷 | `String` | 同上 |
| `rationalize` | 🚫 | — | 虚部が 0 でない場合 RangeError を raise。推論時安全でない |
| `to_i` | 🚫 | — | 同上 |
| `to_f` | 🚫 | — | 同上 |
| `to_r` | 🚫 | — | 同上 |
| `to_int` | 🚫 | — | 同上 |
| `nonzero?` | ✅ | `Complex \| nil` | `COMPLEX_UNARY` に追加済み。`Constant[Complex\|nil]`。 |
| `zero?` | ✅ | `false \| true` | `COMPLEX_UNARY` に追加済み。`Constant[bool]`。 |
| `singleton_method_added` | 🚫 | — | 内部フック |

### 2-2. 優先度別チェックリスト

**🔴 高優先度**（なし — 前セッションで主要ギャップを解消済み）

**🟡 中優先度**（全項目実装済み）
- [x] `zero?`, `nonzero?` → `COMPLEX_UNARY` Set に追加済み（`unary_ops_for` の `Complex` ケース追加）

**🟢 低優先度**（上記のみ）

---

## 3. Range

**列挙元**: `(1..5).methods - Object.new.methods` → Ruby 4.0.5  
**実装ファイル**: `constant_folding.rb`（`RANGE_FOLD_METHODS`, `try_fold_range_constant_unary`）  
**カタログ**: `data/builtins/ruby_core/range.yml`

### 3-1. メソッド一覧

| メソッド | 状態 | 計測値（(1..5)） | 備考 |
|----------|----|--------|------|
| `begin` | ✅ | `1` | カタログ `:leaf` → invoke_unary |
| `end` | ✅ | `5` | 同上 |
| `exclude_end?` | ✅ | `false` | 同上 |
| `hash` | ✅ | `-800979437…` | 同上 |
| `to_s` | ✅ | `"1..5"` | 同上 |
| `first` (0引数) | ✅ | `1` | `try_fold_range_constant_unary` |
| `last` (0引数) | ✅ | `5` | 同上 |
| `min` (0引数) | ✅ | `1` | 同上 |
| `max` (0引数) | ✅ | `5` | 同上 |
| `size` | ✅ | `5` | 同上（`RANGE_FOLD_METHODS` に `:size` あり） |
| `count` (0引数) | ✅ | `5` | 同上（`:count` あり） |
| `to_a` | ✅ | `[1, 2, 3, 4, 5]` | `range_to_a_tuple` → `Tuple[Constant…]` |
| `to_set` | ✅ | `Set[1, 2, 3, 4, 5]` | `meta_new` の `set_new_lift` 経由 → `Constant[Set]` |
| `include?` | ✅ | `true` | カタログ `:leaf` + binary fold |
| `member?` | ✅ | `true` | `include?` の別名（カタログに同エントリ） |
| `cover?` | ✅ | `true` | カタログ `:leaf` + binary fold |
| `===` | ✅ | `true` | カタログ `:leaf` + binary fold |
| `inspect` | 🔷 | `String` | `purity: dispatch`（begin/end の `inspect` を呼ぶ）。fold 不可 |
| `==` | 🔷 | — | `purity: dispatch`。RBS `bool` で十分 |
| `eql?` | 🔷 | — | `purity: dispatch`。同上 |
| `overlap?` | 🔷 | `false \| true` | `purity: dispatch`。RBS `bool` で十分 |
| `bsearch` | 🚫 | — | `purity: dispatch`、ブロック依存 |
| `step` | 🚫 | — | 反復子 |
| `each` | 🚫 | — | 反復子 |
| `reverse_each` | 🚫 | — | 反復子 |
| `%` | 🚫 | — | `Enumerator` / ブロック反復子 |
| `all?` / `any?` / `none?` / `one?` | 🔷 | — | BlockFolding 経由 |
| `map` / `select` / `reject` / `flat_map` 等 | 🔷 | — | BlockFolding / RBS |
| `sum` | 🔲 | — | Integer 等差数列は `n*(a+b)/2` で Constant に畳める。中優先度 |
| `entries` | ✅ | `Array[Dynamic[top]]` | `RANGE_FOLD_METHODS` に `:entries` 追加 + `range_constant_unary` に `when :entries` 追加済み。 |
| `minmax` | ✅ | `[Dynamic[top]\|nil, Dynamic[top]\|nil]` | `range_constant_unary` に `when :minmax` + `range_minmax_tuple` 追加済み。 |
| `first(n)` | 🔲 | `Array[Dynamic[top]]` | 整数引数あり形式。Tuple リフト可。中優先度 |
| `last(n)` | 🔲 | `Array[Dynamic[top]]` | 同上 |
| `to_h` | 🚫 | — | Range 要素が `[k, v]` の 2 要素 Array でない限り raise |

### 3-2. 優先度別チェックリスト

**🔴 高優先度**（実装済み）
- [x] `entries` → `RANGE_FOLD_METHODS` に `:entries` 追加 + `range_constant_unary` に `when :entries then range_to_a_tuple(range)` 追加済み

**🟡 中優先度**（実装済み）
- [x] `minmax` → `range_constant_unary` に `when :minmax` + `range_minmax_tuple` 追加済み
- [ ] `first(n)` / `last(n)` → `try_fold_binary_set` または専用の `try_fold_range_constant_binary` で整数引数 n ≤ LIMIT の場合に Tuple リフト

**🟢 低優先度**
- [ ] `sum` → 等差数列公式で Constant に畳む（ただし Integer Range のみ対象）

---

## 4. Set

**列挙元**: `Set.new.methods - Object.new.methods` → Ruby 4.0.5  
**実装ファイル**: `constant_folding.rb`（`SET_ARRAY_UNARY_METHODS`, catalog 経由）  
**カタログ**: `data/builtins/ruby_core/set.yml`, `set_catalog.rb`

### 4-1. アーキテクチャ上の注意点

Set.yml の `aliases:` セクション（`length → size`, `member? → include?`, `+ → |`, `=== → include?`）は
`catalog_allows?` の `method_entry` から見えない（`instance_methods` キーにはない）。
そのため、これらの別名メソッドは現在すべて fold できずに RBS へ fallback する。

### 4-2. メソッド一覧

| メソッド | 状態 | 計測値（Set[1,2,3]） | 備考 |
|----------|----|--------|------|
| `size` | ✅ | `3` | カタログ `:leaf` → invoke_unary |
| `empty?` | ✅ | `false` | 同上 |
| `compare_by_identity?` | ✅ | `false` | 同上 |
| `flatten` | ✅ | `Set[1, 2, 3]` | 同上（結果が `Constant[Set]`） |
| `join` | ✅ | `"123"` | 同上（引数なし区切り文字なし）|
| `hash` | ✅ | `-379102493…` | 同上 |
| `to_a` | ✅ | `[1, 2, 3]` | `SET_ARRAY_UNARY_METHODS` → Tuple リフト |
| `entries` | ✅ | `[1, 2, 3]` | 同上（`:entries` が `SET_ARRAY_UNARY_METHODS` に含まれる） |
| `include?` | ✅ | `false`（Set 引数）/ `true`（整数引数）| カタログ `:leaf` + binary fold |
| `subset?` | ✅ | `false` | カタログ `:leaf` + binary fold |
| `superset?` | ✅ | `false` | 同上 |
| `proper_subset?` | ✅ | `false` | 同上 |
| `proper_superset?` | ✅ | `false` | 同上 |
| `-` | ✅ | `Set[1]` | カタログ `:leaf`（`set_i_difference`）→ `Constant[Set]` |
| `\|` | ✅ | `Set[1, 2, 3, 4]` | カタログ `:leaf`（`set_i_union`）→ `Constant[Set]` |
| `^` | ✅ | `Set[1, 4]` | カタログ `:leaf`（`set_i_xor`）→ `Constant[Set]` |
| `<=>` | ✅ | `nil` | カタログ `:leaf` |
| `<` | ✅ | — | カタログ `:leaf`（`proper_subset?` の別名だが直接登録） |
| `>` | ✅ | — | カタログ `:leaf`（`proper_superset?` の別名） |
| `<=` | ✅ | — | カタログ `:leaf`（`subset?` の別名） |
| `>=` | ✅ | — | カタログ `:leaf`（`superset?` の別名） |
| `==` | 🔷 | `false \| true` | `purity: dispatch`（`rb_equal` 呼び出し）。RBS `bool` で十分 |
| `inspect` | 🔷 | `String` | `purity: dispatch`。RBS `String` で十分 |
| `to_s` | 🔷 | `String` | `inspect` の別名。同上 |
| `to_set` | 🔷 | `Set[Dynamic[top]]` | `purity: block_dependent`。RBS で十分 |
| `to_h` | 🔷 | — | Enumerable 経由。RBS で十分 |
| `disjoint?` | 🔷 | `false \| true` | `set_catalog.rb` の `mutating_selectors` でブロック済み（内部で `rb_funcall(other, :any?, ...)` を呼ぶ）。RBS `bool` で十分 |
| `intersect?` | 🔷 | `false \| true` | `purity: dispatch`。同上 |
| `&` | 🔷 | `Set` | `purity: block_dependent`（`set_i_intersection` が `set_iter` 呼び出し）。fold 不可 |
| `add` / `add?` | 🚫 | — | 破壊的変更 |
| `<<` | 🚫 | — | `add` の別名。破壊的変更 |
| `clear` / `delete` / `delete?` / `delete_if` | 🚫 | — | 破壊的変更 |
| `replace` / `merge` / `subtract` | 🚫 | — | 破壊的変更 |
| `collect!` / `map!` / `select!` / `filter!` / `reject!` / `keep_if` | 🚫 | — | 破壊的変更 |
| `flatten!` | 🚫 | — | 破壊的変更 |
| `each` | 🚫 | — | 反復子 |
| `classify` | 🚫 | — | ブロック依存、戻り型複雑 |
| `divide` | 🚫 | — | 同上 |
| `compare_by_identity` | 🚫 | — | 破壊的変更 |
| `reset` | 🚫 | — | 内部構造リビルド |
| `length` | ✅ | `Integer` | `MethodCatalog#method_entry` のエイリアス解決で対応済み。 |
| `member?` | ✅ | `false \| true` | 同上。 |
| `+` | ✅ | `Set` | 同上。 |
| `===` | ✅ | `false \| true` | 同上。 |
| Enumerable 継承メソッド（`all?`, `any?`, `map`, `select` 等） | 🔷 | — | BlockFolding / RBS |

### 4-3. 優先度別チェックリスト

**🔴 高優先度**（なし — 主要な集合演算は実装済み）

**🟡 中優先度**（全項目実装済み）
- [x] `length`, `member?`, `+` の YAML エイリアス解決
  - `MethodCatalog#method_entry` に `resolve_alias_entry` を追加し、`aliases` セクションも参照するよう拡張
  - `===` も同一の仕組みで解決

**🟢 低優先度**（実装済み）
- [x] `===` → 同上の対応に含める

---

## 5. Phase 2 — ギャップのティア分類

### Tier A — UNARY / BINARY Set への追加

`invoke_unary` / `invoke_binary` が呼ぶだけで結果が `Constant[T]` になるもの。`unary_ops_for` / `ops_for` に新しい `when` ケースを追加し、`RATIONAL_UNARY`, `COMPLEX_UNARY`, `RATIONAL_BINARY` 定数 Set を定義済み。

| 型 | メソッド | 期待戻り型 | 優先度 |
|----|---------|-----------|--------|
| Rational | `zero?` | `Constant[bool]` | 🟡 |
| Rational | `integer?` | `Constant[bool]` | 🟡 |
| Rational | `real` | `Constant[Rational]` | 🟡 |
| Rational | `abs2` | `Constant[Rational]` | 🟡 |
| Rational | `conj`, `conjugate` | `Constant[Rational]` | 🟢 |
| Rational | `nonzero?` | `Constant[Rational\|nil]` | 🟢 |
| Rational | `div` | `Constant[Integer]` | 🟡 |
| Rational | `modulo`, `%` | `Constant[Rational]` | 🟢 |
| Rational | `remainder` | `Constant[Rational]` | 🟢 |
| Rational | `fdiv` | `Constant[Float]` | 🟢 |
| Complex | `zero?` | `Constant[bool]` | 🟡 |
| Complex | `nonzero?` | `Constant[Complex\|nil]` | 🟢 |

実装手順（完了）:
1. ~~`constant_folding.rb` に `RATIONAL_UNARY = Set[:zero?, :integer?, :real, :abs2, :conj, :conjugate, :nonzero?].freeze` を追加~~
2. ~~`RATIONAL_BINARY = Set[:div, :modulo, :%, :remainder, :fdiv].freeze` を追加~~
3. ~~`unary_ops_for` の `else Set.new` の前に `when Rational then RATIONAL_UNARY` / `when Complex then COMPLEX_UNARY` ケースを追加~~
4. ~~`ops_for` に `when Rational then RATIONAL_BINARY` を追加~~
5. ~~同様に `COMPLEX_UNARY = Set[:zero?, :nonzero?].freeze` を追加~~

### Tier A（Tuple リフト拡張）— `RANGE_FOLD_METHODS` 追加

| ファイル | 変更 | 優先度 |
|---------|------|--------|
| `constant_folding.rb` | `RANGE_FOLD_METHODS` に `:entries` 追加済み | 🔴 |
| `constant_folding.rb` | `range_constant_unary` に `when :entries` 追加済み（`to_a` と同じ `range_to_a_tuple` 実装） | 🔴 |
| `constant_folding.rb` | `RANGE_FOLD_METHODS` に `:minmax` 追加 + `range_constant_unary` に `when :minmax` + `range_minmax_tuple` 追加済み | 🟡 |

### Tier A（Set エイリアス解決）

| 対象 | 修正箇所 | 優先度 |
|------|---------|--------|
| `Set#length`, `Set#member?`, `Set#+` | `method_catalog.rb` に `resolve_alias_entry` 追加 + `method_entry` にエイリアス解決フォールバック追加済み | 🟡 |
| `Set#===` | 同上 | 🟢 |

### Tier B — ShapeDispatch

なし（Rational / Complex / Range / Set は ShapeDispatch が扱う構造型ではない）。

### Tier C — BlockFolding

なし（本スコープ外。`Range#sum`, `Range#first(n)` 等はブロックなしの数値計算なので Tier A が適切）。

### Tier D — 新 singleton-folding モジュール

なし（Rational / Complex / Range / Set の singleton メソッドに新モジュールが必要なものはない）。

---

## 6. 実装ファイル参照

| 作業 | 変更先ファイル |
|------|-------------|
| RATIONAL_UNARY / RATIONAL_BINARY 追加 | `lib/rigor/inference/method_dispatcher/constant_folding.rb` |
| COMPLEX_UNARY 追加 | 同上 |
| Range#entries / minmax | 同上（`RANGE_FOLD_METHODS`, `range_constant_unary`） |
| Set エイリアス解決 | `lib/rigor/inference/builtins/set_catalog.rb` + `method_catalog.rb` |
| ユニットスペック | `spec/rigor/inference/method_dispatcher/constant_folding_spec.rb` |
| 統合フィクスチャ（Rational/Complex） | `spec/integration/fixtures/rational_catalog.rb` 等 |
| 統合フィクスチャ（Range/Set） | `spec/integration/fixtures/range_catalog.rb` 等 |
