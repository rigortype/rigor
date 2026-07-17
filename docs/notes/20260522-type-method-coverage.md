# 型別メソッドカバレッジ — ConstantFolding / ShapeDispatch / ExpressionTyper 監査

2026-05-22 生成。Ruby 4.0 の `"".methods - Object.new.methods` 等から型ごとに固有メソッドを抽出し、現在の精度カバレッジを分類する。

> **2026-07-18 監査パス（#121 P3 スライス）。** 本表の多くの 🔲 は 2026-05-22 以降に実装済み
> （`String#[]`/`slice`、`Tuple#drop`/`rotate`/`flatten`/`join`、CGI/URI/Regexp/Math シングルトン
> フォールド等）。空きの主因は「フォールドが存在しないこと」ではなく、**先行ティアによる遮蔽**だった。
> 本スライスで閉じたのは `Array#join`：全要素が `Constant[String]`（セパレータが Constant/省略）の
> ときだけ、`ShapeDispatch.tuple_join` の精密 `Constant[String]` を `LiteralStringFolding` が
> 汎用 `literal-string` で覆い隠していた（整数・混在要素の tuple は既に精密フォールド済み）。
>
> **本スライスで対象外と判断した項目（P0 側／FP リスク）:**
> - `String#to_r` / `Integer#to_r` / `Float#to_r` / `#to_c` の一部 — `Rational`/`Complex` の同値・
>   算術は演算子 `==` がオペランド `==` に委譲し得るため、フォールドの一部が **ユーザ再定義可能な経路**
>   を通る（本表 `RATIONAL_BINARY`/`COMPLEX_BINARY` が `==` を除外している理由と同じ）。単純な `to_r`
>   自体は純粋だが、下流の同値比較で新規診断（`flow.*`）を誘発し得るため、別途評価とする。
> - `String#%` の Hash 形式（`"%{k}" % {…}`）— HashShape 経由の精密化は可能だが、フォーマット文字列の
>   検証で新規診断を生む可能性があり、P3 の「新規診断ゼロ」制約に抵触し得る。

---

## 凡例

| 記号 | 意味 |
|------|------|
| ✅ | ConstantFolding (`invoke_unary`/`invoke_binary`) または ShapeDispatch / ExpressionTyper ブロックフォールドで実装済み |
| 🔷 | 別ティア処理済み（BlockFolding / LiteralStringFolding / RBS で十分精度が出る） |
| 🔲 | 未実装だが精度向上の価値あり |
| 🚫 | 非対象（破壊的変更・Enumerator 生成・精度向上が negligible） |

---

## 1. String

`Constant[String]` は `STRING_UNARY` / `STRING_BINARY` で処理。  
特殊ケース: `%` → `try_fold_string_format`、`chars`/`bytes`/`lines`/`split` → `try_fold_string_array_unary`/`_binary`。  
`<<`/`concat` / `+`（リテラル文字列連結）→ `LiteralStringFolding`。

### 1-1. メソッド一覧

| メソッド | 状態 | 備考 |
|----------|------|------|
| `%` | ✅ | `try_fold_string_format` — Tuple / HashShape 引数対応。 |
| `*` | ✅ | STRING_BINARY — `Constant["ab"] * 3` → `Constant["ababab"]`。 |
| `+` | ✅ | STRING_BINARY。リテラル連結は LiteralStringFolding も担当。 |
| `<<` | 🔷 | LiteralStringFolding で `literal-string` 精度維持。破壊的変更。 |
| `<=>` | ✅ | STRING_BINARY → `Constant[Integer]`。 |
| `<`, `<=`, `>`, `>=`, `==`, `!=` | ✅ | STRING_BINARY → `Constant[bool]`。 |
| `[]` / `slice` | 🔲 | 整数インデックスまたは Range 引数で `Constant[String\|nil]` にたためる。中優先度。 |
| `ascii_only?` | 🔲 | STRING_UNARY 追加で `Constant[bool]`。低優先度。 |
| `b` | 🚫 | BINARY エンコーディングで複製。精度向上なし。 |
| `bytesize` | ✅ | STRING_UNARY → `Constant[Integer]`。 |
| `bytes` | ✅ | `try_fold_string_array_unary` → `Tuple[Constant[Integer]…]`。 |
| `capitalize` | ✅ | STRING_UNARY → `Constant[String]`。 |
| `codepoints` | ✅ | `try_fold_string_array_unary` → `Tuple[Constant[Integer]…]`（`bytes` の兄弟、コードポイント単位）。 |
| `capitalize!` | 🚫 | 破壊的変更。 |
| `casecmp` | 🔲 | STRING_BINARY 追加で `Constant[Integer\|nil]`。低優先度。 |
| `casecmp?` | 🔲 | STRING_BINARY 追加で `Constant[bool\|nil]`。低優先度。 |
| `center` | 🔲 | STRING_BINARY 追加で `Constant[String]`。中優先度。 |
| `chars` | ✅ | `try_fold_string_array_unary` → `Tuple[Constant[String]…]`。 |
| `chomp` | ✅ | STRING_UNARY → `Constant[String]`。 |
| `chomp!` | 🚫 | 破壊的変更。 |
| `chop` | 🔲 | STRING_UNARY 追加で `Constant[String]`。中優先度。 |
| `chop!` | 🚫 | 破壊的変更。 |
| `chr` | 🔲 | STRING_UNARY 追加で `Constant[String]`（最初の 1 文字）。中優先度。 |
| `clear` | 🚫 | 破壊的変更。 |
| `concat` | 🔷 | LiteralStringFolding で `literal-string` 精度維持。 |
| `count` | 🔲 | STRING_BINARY 追加で `Constant[Integer]`（文字数カウント）。低優先度。 |
| `delete` | 🔲 | STRING_BINARY 追加で `Constant[String]`。低優先度。 |
| `delete!` | 🚫 | 破壊的変更。 |
| `delete_prefix` | ✅ | STRING_BINARY 追加で `Constant[String]`。**高優先度。** |
| `delete_prefix!` | 🚫 | 破壊的変更。 |
| `delete_suffix` | ✅ | STRING_BINARY 追加で `Constant[String]`。**高優先度。** |
| `delete_suffix!` | 🚫 | 破壊的変更。 |
| `downcase` | ✅ | STRING_UNARY → `Constant[String]`。 |
| `downcase!` | 🚫 | 破壊的変更。 |
| `dump` | 🔲 | STRING_UNARY 追加で `Constant[String]`。低優先度。 |
| `each_byte` / `each_char` / `each_line` / `each_codepoint` | 🚫 | 反復子 / Enumerator。 |
| `empty?` | ✅ | STRING_UNARY → `Constant[bool]`。 |
| `encode` | 🔲 | エンコーディング引数あり。中優先度。 |
| `encode!` | 🚫 | 破壊的変更。 |
| `encoding` | 🔲 | STRING_UNARY 追加で `Constant[Encoding]`。低優先度。 |
| `end_with?` | ✅ | STRING_BINARY 追加で `Constant[bool]`。**高優先度。** |
| `force_encoding` | 🚫 | 破壊的変更（エンコーディング変更）。 |
| `gsub` | 🔲 | Regexp 引数で複雑。低優先度。 |
| `gsub!` | 🚫 | 破壊的変更。 |
| `hash` | ✅ | STRING_UNARY → `Constant[Integer]`。 |
| `hex` | 🔲 | STRING_UNARY 追加で `Constant[Integer]`。中優先度。 |
| `include?` | ✅ | STRING_BINARY 追加で `Constant[bool]`。**高優先度。** |
| `index` | 🔲 | STRING_BINARY 追加で `Constant[Integer\|nil]`。中優先度。 |
| `insert` | 🚫 | 破壊的変更。 |
| `inspect` | ✅ | STRING_UNARY → `Constant[String]`。 |
| `intern` / `to_sym` | ✅ | STRING_UNARY → `Constant[Symbol]`。 |
| `length` / `size` | ✅ | STRING_UNARY → `Constant[Integer]`。 |
| `lines` | ✅ | `try_fold_string_array_unary` → `Tuple[Constant[String]…]`。 |
| `ljust` | 🔲 | STRING_BINARY 追加で `Constant[String]`。中優先度。 |
| `lstrip` | ✅ | STRING_UNARY → `Constant[String]`。 |
| `lstrip!` | 🚫 | 破壊的変更。 |
| `match` | 🔲 | Regexp 引数、`MatchData\|nil` 返却。低優先度。 |
| `match?` | 🔲 | STRING_BINARY 追加で `Constant[bool]`。中優先度。 |
| `next` / `succ` | 🔲 | STRING_UNARY 追加で `Constant[String]`。中優先度。 |
| `next!` / `succ!` | 🚫 | 破壊的変更。 |
| `oct` | 🔲 | STRING_UNARY 追加で `Constant[Integer]`。中優先度。 |
| `ord` | ✅ | STRING_UNARY 追加で `Constant[Integer]`（最初のコードポイント）。**高優先度。** |
| `prepend` | 🚫 | 破壊的変更。 |
| `replace` | 🚫 | 破壊的変更。 |
| `reverse` | ✅ | STRING_UNARY → `Constant[String]`。 |
| `reverse!` | 🚫 | 破壊的変更。 |
| `rindex` | 🔲 | STRING_BINARY 追加で `Constant[Integer\|nil]`。中優先度。 |
| `rjust` | 🔲 | STRING_BINARY 追加で `Constant[String]`。中優先度。 |
| `rstrip` | ✅ | STRING_UNARY → `Constant[String]`。 |
| `rstrip!` | 🚫 | 破壊的変更。 |
| `scan` | ✅ | `try_fold_string_array_binary` → `Tuple[Constant[String]…]`。 |
| `scrub` | 🔲 | STRING_UNARY 追加で `Constant[String]`。低優先度。 |
| `split` | ✅ | `try_fold_string_array_unary` / `_binary` 対応。 |
| `squeeze` | 🔲 | STRING_UNARY 追加で `Constant[String]`。低優先度。 |
| `start_with?` | ✅ | STRING_BINARY 追加で `Constant[bool]`。**高優先度。** |
| `strip` | ✅ | STRING_UNARY → `Constant[String]`。 |
| `strip!` | 🚫 | 破壊的変更。 |
| `sub` | 🔲 | Regexp 引数で複雑。低優先度。 |
| `sub!` | 🚫 | 破壊的変更。 |
| `swapcase` | ✅ | STRING_UNARY → `Constant[String]`。 |
| `swapcase!` | 🚫 | 破壊的変更。 |
| `to_c` | 🔲 | STRING_UNARY 追加で `Constant[Complex]`。低優先度。 |
| `to_f` | ✅ | STRING_UNARY 追加で `Constant[Float]`。**高優先度。** |
| `to_i` | ✅ | STRING_UNARY 追加で `Constant[Integer]`。**高優先度。** |
| `to_r` | 🔲 | STRING_UNARY 追加で `Constant[Rational]`。低優先度。 |
| `to_s` / `to_str` | ✅ | STRING_UNARY → `Constant[String]`。 |
| `tr` | 🔲 | 文字置換。低優先度。 |
| `tr!` | 🚫 | 破壊的変更。 |
| `undump` | 🔲 | STRING_UNARY 追加で `Constant[String]`。低優先度。 |
| `unicode_normalize` | 🔲 | STRING_UNARY 追加で `Constant[String]`。低優先度。 |
| `upcase` | ✅ | STRING_UNARY → `Constant[String]`。 |
| `upcase!` | 🚫 | 破壊的変更。 |
| `upto` | 🚫 | Enumerator。 |
| `valid_encoding?` | 🔲 | STRING_UNARY 追加で `Constant[bool]`。低優先度。 |

### 1-2. 実装チェックリスト（優先度順）

```
高優先度（Constant[String] / Constant[bool] への折りたたみで頻用パターンをカバー）:
[x] start_with?    → STRING_BINARY に追加 → Constant[bool]
[x] end_with?      → STRING_BINARY に追加 → Constant[bool]
[x] include?       → STRING_BINARY に追加 → Constant[bool]
[x] delete_prefix  → STRING_BINARY に追加 → Constant[String]
[x] delete_suffix  → STRING_BINARY に追加 → Constant[String]
[x] to_i           → STRING_UNARY に追加  → Constant[Integer]
[x] to_f           → STRING_UNARY に追加  → Constant[Float]
[x] ord            → STRING_UNARY に追加  → Constant[Integer]

中優先度:
[x] chr            → STRING_UNARY に追加  → Constant[String]
[x] hex            → STRING_UNARY に追加  → Constant[Integer]
[x] oct            → STRING_UNARY に追加  → Constant[Integer]
[x] next / succ    → STRING_UNARY に追加  → Constant[String]
[x] chop           → STRING_UNARY に追加  → Constant[String]
[x] match?         → STRING_BINARY に追加 → Constant[bool]
[x] index          → STRING_BINARY に追加 → Constant[Integer|nil]
[x] rindex         → STRING_BINARY に追加 → Constant[Integer|nil]
[x] center         → STRING_BINARY に追加 → Constant[String]（幅ブローアップガード付き）
[x] ljust / rjust  → STRING_BINARY に追加 → Constant[String]（同上）

低優先度:
[ ] casecmp / casecmp?   → STRING_BINARY
[ ] count (文字カウント) → STRING_BINARY
[ ] delete             → STRING_BINARY
[ ] ascii_only?        → STRING_UNARY
[ ] encoding           → STRING_UNARY
[ ] squeeze            → STRING_UNARY
[ ] valid_encoding?    → STRING_UNARY
[ ] []  / slice        → 専用ハンドラ（整数インデックス / Range 引数）
```

実装ファイル: `lib/rigor/inference/method_dispatcher/constant_folding.rb` の `STRING_UNARY` / `STRING_BINARY`。

---

## 2. Integer

`Constant[Integer]` は `INTEGER_UNARY` / `NUMERIC_BINARY` で処理。  
IntegerRange 向け専用ハンドラ群は別途 `shape_dispatch.rb` に存在。

### 2-1. メソッド一覧

| メソッド | 状態 | 備考 |
|----------|------|------|
| `+`, `-`, `*`, `/`, `%` | ✅ | NUMERIC_BINARY → `Constant[Integer\|Float]`（型推論済み）。 |
| `**` | ✅ | NUMERIC_BINARY 追加で `Constant[Integer\|Float]`。カタログでもカバー済みだが明示的に追加。 |
| `&`, `\|`, `^` | ✅ | NUMERIC_BINARY 追加で `Constant[Integer]`。カタログでもカバー済み。 |
| `<<`, `>>` | ✅ | NUMERIC_BINARY 追加で `Constant[Integer]`。カタログでもカバー済み。 |
| `~` | ✅ | INTEGER_UNARY → `Constant[Integer]`。 |
| `<=>`, `<`, `<=`, `>`, `>=`, `==`, `!=` | ✅ | NUMERIC_BINARY → `Constant[Integer\|bool]`。 |
| `-@`, `+@` | ✅ | INTEGER_UNARY。 |
| `abs` / `magnitude` | ✅ | INTEGER_UNARY → `Constant[Integer]`。 |
| `bit_length` | ✅ | INTEGER_UNARY → `Constant[Integer]`。 |
| `allbits?` / `anybits?` / `nobits?` | ✅ | NUMERIC_BINARY 追加 → `Constant[bool]`（具体整数マスクに対して純粋）。 |
| `between?` | ✅ | `try_fold_ternary`（catalog 経由）→ `Constant[bool]`。 |
| `ceil` | ✅ | INTEGER_UNARY（引数なし）→ `Constant[Integer]`。 |
| `chr` | ✅ | INTEGER_UNARY → `Constant[String]`。 |
| `clamp` | ✅ | `try_fold_ternary`（catalog 経由）→ `Constant[Integer]`。 |
| `coerce` | 🚫 | 内部用。精度向上なし。 |
| `digits` | ✅ | `try_fold_integer_array_unary` → `Tuple[Constant[Integer]…]`。 |
| `divmod` | ✅ | `try_fold_divmod` → `Tuple[Constant[Integer], Constant[Integer]]`。 |
| `even?` | ✅ | INTEGER_UNARY → `Constant[bool]`。 |
| `fdiv` | ✅ | NUMERIC_BINARY → `Constant[Float]`。 |
| `floor` | ✅ | INTEGER_UNARY（引数なし）→ `Constant[Integer]`。 |
| `gcd` | ✅ | NUMERIC_BINARY → `Constant[Integer]`。 |
| `gcdlcm` | ✅ | `try_fold_integer_array_binary` → `Tuple[Constant[Integer], Constant[Integer]]`。 |
| `hash` | ✅ | INTEGER_UNARY → `Constant[Integer]`。 |
| `inspect` / `to_s` | ✅ | INTEGER_UNARY → `Constant[String]`。 |
| `integer?` | 🔲 | INTEGER_UNARY 追加で `Constant[true]`。低優先度（常に true）。 |
| `lcm` | ✅ | NUMERIC_BINARY → `Constant[Integer]`。 |
| `negative?` / `positive?` / `zero?` | ✅ | INTEGER_UNARY → `Constant[bool]`。 |
| `next` / `succ` | ✅ | INTEGER_UNARY → `Constant[Integer]`。 |
| `odd?` | ✅ | INTEGER_UNARY → `Constant[bool]`。 |
| `pow` | 🔲 | `**` の別名（ただし `pow(exp, mod)` は剰余乗算）。低優先度。 |
| `pred` | ✅ | INTEGER_UNARY → `Constant[Integer]`。 |
| `rationalize` / `to_r` | 🔲 | INTEGER_UNARY 追加で `Constant[Rational]`。低優先度。 |
| `round` | ✅ | INTEGER_UNARY（引数なし）→ `Constant[Integer]`。 |
| `size` | 🔲 | プラットフォーム依存バイト幅。低優先度。 |
| `to_c` | 🔲 | INTEGER_UNARY 追加で `Constant[Complex]`。低優先度。 |
| `to_f` | ✅ | INTEGER_UNARY → `Constant[Float]`。 |
| `to_i` / `to_int` | ✅ | INTEGER_UNARY → `Constant[Integer]`。 |
| `truncate` | ✅ | INTEGER_UNARY（引数なし）→ `Constant[Integer]`。 |
| `upto` / `downto` / `times` | 🚫 | 反復子。 |

### 2-2. 実装チェックリスト（優先度順）

```
高優先度（式で多用・Constant[Integer] 精度の核心）:
[x] **   → NUMERIC_BINARY  → Constant[Integer|Float]
[x] &    → NUMERIC_BINARY  → Constant[Integer]
[x] |    → NUMERIC_BINARY  → Constant[Integer]
[x] ^    → NUMERIC_BINARY  → Constant[Integer]
[x] <<   → NUMERIC_BINARY  → Constant[Integer]
[x] >>   → NUMERIC_BINARY  → Constant[Integer]

中優先度:
[x] floor / ceil / round / truncate (引数なし) → INTEGER_UNARY → Constant[Integer]
[x] chr           → INTEGER_UNARY  → Constant[String]
[x] digits (引数なし) → try_fold_integer_array_unary → Tuple[Constant[Integer]…]
[x] gcd / lcm     → NUMERIC_BINARY → Constant[Integer]
[x] divmod        → try_fold_divmod → Tuple[Constant[Integer], Constant[Integer]]
[x] fdiv          → NUMERIC_BINARY → Constant[Float]
[x] between?      → try_fold_ternary（catalog 経由）→ Constant[bool]
[x] clamp         → try_fold_ternary（catalog 経由）→ Constant[Integer]
[x] allbits? / anybits? / nobits? → NUMERIC_BINARY → Constant[bool]

低優先度:
[ ] rationalize / to_r  → INTEGER_UNARY
[x] gcdlcm              → try_fold_integer_array_binary → Tuple[Constant[Integer], Constant[Integer]]
[ ] pow(exp, mod)       → 専用ハンドラ（3 引数形式）
```

実装ファイル: `constant_folding.rb` の `INTEGER_UNARY` 拡張、または `NUMERIC_BINARY` へのキー追加。  
`invoke_binary` は `Constant[Integer] op Constant[Integer]` のとき自動評価するので **定数に追加するだけで折りたたみが機能する**。

---

## 3. Float

`Constant[Float]` は `FLOAT_UNARY` / `NUMERIC_BINARY` で処理。

### 3-1. メソッド一覧

| メソッド | 状態 | 備考 |
|----------|------|------|
| `+`, `-`, `*`, `/`, `%` | ✅ | NUMERIC_BINARY。 |
| `**` | ✅ | NUMERIC_BINARY 追加で `Constant[Float]`。**高優先度。** |
| `<=>`, `<`, `<=`, `>`, `>=`, `==`, `!=` | ✅ | NUMERIC_BINARY → `Constant[bool\|Integer]`。 |
| `-@`, `+@` | ✅ | FLOAT_UNARY。 |
| `abs` / `magnitude` | ✅ | FLOAT_UNARY → `Constant[Float]`。 |
| `between?` | ✅ | `try_fold_ternary`（catalog 経由）→ `Constant[bool]`。 |
| `ceil` | ✅ | FLOAT_UNARY（引数なし）→ `Constant[Integer]`。 |
| `ceil(n)` | 🔲 | 小数点指定形式の専用ハンドラ → `Constant[Float]`。低優先度。 |
| `clamp` | ✅ | `try_fold_ternary`（catalog 経由）→ `Constant[Float]`。 |
| `coerce` | 🚫 | 内部用。 |
| `divmod` | ✅ | `try_fold_divmod` → `Tuple[Constant[Integer], Constant[Float]]`。 |
| `fdiv` | ✅ | NUMERIC_BINARY → `Constant[Float]`。 |
| `finite?` | ✅ | FLOAT_UNARY → `Constant[bool]`。 |
| `floor` | ✅ | FLOAT_UNARY（引数なし）→ `Constant[Integer]`。 |
| `floor(n)` | 🔲 | 小数点指定形式 → `Constant[Float]`。低優先度。 |
| `hash` | ✅ | FLOAT_UNARY → `Constant[Integer]`。 |
| `infinite?` | ✅ | FLOAT_UNARY → `Constant[Integer]`（-1/0/1）。 |
| `inspect` / `to_s` | ✅ | FLOAT_UNARY → `Constant[String]`。 |
| `modulo` | 🔷 | `%` の別名 → NUMERIC_BINARY で処理。 |
| `nan?` | ✅ | FLOAT_UNARY → `Constant[bool]`。 |
| `negative?` / `positive?` / `zero?` | ✅ | FLOAT_UNARY → `Constant[bool]`。 |
| `next_float` | ✅ | FLOAT_UNARY → `Constant[Float]`。 |
| `prev_float` | ✅ | FLOAT_UNARY → `Constant[Float]`。 |
| `rationalize` / `to_r` | 🔲 | FLOAT_UNARY 追加で `Constant[Rational]`。低優先度。 |
| `round` | ✅ | FLOAT_UNARY（引数なし）→ `Constant[Integer]`。 |
| `round(n)` | 🔲 | 小数点指定形式 → `Constant[Float]`。低優先度。 |
| `to_c` | 🔲 | FLOAT_UNARY 追加で `Constant[Complex]`。低優先度。 |
| `to_f` | ✅ | FLOAT_UNARY → `Constant[Float]`。 |
| `to_i` / `to_int` / `truncate` | ✅ | FLOAT_UNARY → `Constant[Integer]`。 |

### 3-2. 実装チェックリスト（優先度順）

```
高優先度:
[x] **  → NUMERIC_BINARY → Constant[Float]

中優先度:
[x] divmod   → try_fold_divmod → Tuple[Constant[Integer], Constant[Float]]
[x] between? → try_fold_ternary（catalog 経由）→ Constant[bool]
[x] clamp    → try_fold_ternary（catalog 経由）→ Constant[Float]

低優先度:
[ ] ceil(n) / floor(n) / round(n) → 小数点 n 指定形式専用ハンドラ
[x] next_float / prev_float       → FLOAT_UNARY
[x] fdiv                          → NUMERIC_BINARY
[ ] rationalize / to_r / to_c    → FLOAT_UNARY
```

実装ファイル: `constant_folding.rb` の `FLOAT_UNARY` 拡張 / `NUMERIC_BINARY` 追加。

---

## 4. bool（TrueClass / FalseClass）

`Constant[true]` / `Constant[false]` は `BOOL_UNARY` / `BOOL_BINARY` で処理。  
カバレッジはほぼ完全。

### 4-1. メソッド一覧

`(true.methods - Object.new.methods).sort` → `[:&, :^, :|]`（TrueClass / FalseClass 共通）。

| メソッド | 状態 | 備考 |
|----------|------|------|
| `&` | ✅ | BOOL_UNARY（引数なし形式）・BOOL_BINARY → `Constant[bool]`。 |
| `\|` | ✅ | 同上。 |
| `^` | ✅ | 同上。 |
| `!` | ✅ | BOOL_UNARY → `Constant[bool]`（論理反転）。 |
| `==`, `!=` | ✅ | BOOL_BINARY → `Constant[bool]`。 |
| `to_s` / `inspect` / `hash` | ✅ | BOOL_UNARY → 各 `Constant` 型。 |
| `===` | ✅ | BOOL_BINARY 追加で `Constant[bool]`。低優先度（`==` と等価な場面がほとんど）。 |

### 4-2. 実装チェックリスト

```
低優先度（現状カバレッジほぼ完全）:
[x] === → BOOL_BINARY に追加 → Constant[bool]
```

---

## 5. Array（Tuple キャリア）

`Type::Tuple` は `shape_dispatch.rb` の `TUPLE_HANDLERS` と `expression_typer.rb` の `PER_ELEMENT_TUPLE_METHODS` で処理。

### 5-1. メソッド一覧

| メソッド | 状態 | 備考 |
|----------|------|------|
| `[]` / `fetch` | ✅ | `tuple_lookup` / `tuple_fetch` — 整数インデックスで位置別型を返す。 |
| `+` (連結) | ✅ | `Tuple + Tuple` → 新しい Tuple。**高優先度。** `tuple_concat` 実装。 |
| `-` (差集合) | 🔲 | 差集合 → 型が複雑。低優先度。 |
| `*` (繰り返し) | 🔲 | `Tuple * n` → 繰り返し Tuple。低優先度。 |
| `<<` / `push` / `append` | 🚫 | 破壊的変更（形状変化）。 |
| `<=>` | 🔷 | RBS `Integer?` で十分。 |
| `all?` | ✅ | `tuple_all?` — ブロックなしで要素型確認。BlockFolding でブロックあり対応。 |
| `any?` | ✅ | `tuple_any?` — ブロックなしで要素型確認。 |
| `assoc` | 🔲 | 先頭要素マッチ。低優先度。 |
| `bsearch` | 🚫 | 複雑な二分探索。 |
| `chain` | 🚫 | Enumerator。 |
| `chunk` / `chunk_while` | 🚫 | Enumerable。 |
| `collect` / `map` | ✅ | `PER_ELEMENT_TUPLE_METHODS` — ブロック毎要素適用で新 Tuple。 |
| `combination` / `permutation` | 🚫 | Enumerable。 |
| `compact` | ✅ | `Constant[nil]` エントリを除去した Tuple。**高優先度。** `tuple_compact` 実装。 |
| `count` | ✅ | `tuple_count` — ブロックなしで `Constant[Integer]`。 |
| `cycle` | 🚫 | Enumerable。 |
| `deconstruct` | 🔲 | パターンマッチ用 — `to_a` と等価。低優先度。 |
| `delete` / `delete_at` / `delete_if` | 🚫 | 破壊的変更。 |
| `detect` / `find` | ✅ | `PER_ELEMENT_TUPLE_METHODS` — ブロック毎要素で要素型を返す。 |
| `dig` | ✅ | `tuple_dig` — 入れ子 Tuple / HashShape を掘る。 |
| `drop` | 🔲 | `drop(n)` → n 要素以降の部分 Tuple。中優先度。 |
| `drop_while` | 🔷 | BlockFolding `FILTER_KEEP_ON_FALSEY`。 |
| `each` / `each_with_index` / `each_with_object` | 🚫 | 反復子。 |
| `empty?` | ✅ | `tuple_empty?` → `Constant[bool]`。 |
| `entries` | 🔷 | `to_a` の別名 → RBS 経由。 |
| `fetch` | ✅ | `tuple_fetch` → 位置別型。 |
| `fill` | 🚫 | 破壊的変更。 |
| `filter` / `select` | 🔷 | BlockFolding `FILTER_KEEP_ON_TRUTHY / FALSEY`。 |
| `filter_map` | ✅ | `PER_ELEMENT_TUPLE_METHODS` → `nil` 除去後の Union Tuple。 |
| `first` | ✅ | `tuple_first` → 先頭 n 要素 (Tuple または単一型)。 |
| `flat_map` / `collect_concat` | ✅ | `PER_ELEMENT_TUPLE_METHODS` — 単一ネスト除去。 |
| `flatten` | 🔲 | 入れ子 Tuple を再帰展開。中優先度。 |
| `include?` | ✅ | `tuple_include?` → `Constant[bool]`（Constant 引数のとき）。 |
| `index` / `find_index` | ✅ | `PER_ELEMENT_TUPLE_METHODS` → `Constant[Integer\|nil]`。 |
| `insert` | 🚫 | 破壊的変更。 |
| `intersection` | 🔲 | 集合交差。低優先度。 |
| `join` | ✅ | `tuple_join` — すべて Constant のとき `Constant[String]`。全要素が `Constant[String]` かつセパレータが Constant/省略の場合は `LiteralStringFolding` が精密フォールドに道を譲る（2026-07-18）。 |
| `keep_if` | 🚫 | 破壊的変更。 |
| `last` | ✅ | `tuple_last` → 末尾 n 要素。 |
| `length` / `size` | ✅ | `tuple_size` → `Constant[Integer]`。 |
| `max` / `min` | ✅ | `tuple_max` / `tuple_min` → 要素型の Union。 |
| `max_by` / `min_by` | 🔲 | ブロックあり形式。BlockFolding 非対応。中優先度。 |
| `minmax` | ✅ | `tuple_minmax_pair` → `Tuple[Constant[min], Constant[max]]`（全要素 Constant かつ比較可能なとき）。 |
| `none?` | ✅ | `tuple_none?` → `Constant[bool]`。 |
| `pack` | 🔲 | バイナリパッキング → `Constant[String]`。低優先度。 |
| `pop` / `shift` | 🚫 | 破壊的変更。 |
| `product` | 🚫 | 複雑な直積 Tuple。 |
| `push` / `unshift` | 🚫 | 破壊的変更。 |
| `rassoc` | 🔲 | 低優先度。 |
| `reject` | 🔷 | BlockFolding `FILTER_KEEP_ON_FALSEY`。 |
| `repeated_combination` / `repeated_permutation` | 🚫 | Enumerable。 |
| `reverse` | ✅ | `tuple_reverse` → 要素逆順の Tuple。 |
| `reverse!` | 🚫 | 破壊的変更。 |
| `rotate` | 🔲 | `rotate(n)` → 回転後の Tuple。中優先度。 |
| `sample` / `shuffle` | 🚫 | 非決定論的。 |
| `slice` | ✅ | `[]` の別名。`tuple_index`（整数 / Range / start-length 形式）。 |
| `sort` | ✅ | `tuple_sort` → 要素型でソートした Tuple。 |
| `sort!` | 🚫 | 破壊的変更。 |
| `sort_by` | 🔲 | ブロックあり。低優先度。 |
| `sum` | ✅ | `tuple_sum` → 要素型の Union。 |
| `take` | ✅ | `take(n)` → 先頭 n 要素の部分 Tuple。**高優先度。** `tuple_take` 実装。 |
| `take_while` | 🔷 | BlockFolding `FILTER_KEEP_ON_TRUTHY`。 |
| `tally` | 🔲 | `Hash[elem_type, Integer]`。低優先度。 |
| `to_a` | ✅ | `tuple_to_a` → self。 |
| `to_h` | ✅ | `tuple_to_h` → HashShape（`Tuple[Tuple[K,V]…]` 形式）。 |
| `transpose` | 🔲 | 2 次元 Tuple の行列転置。低優先度。 |
| `union` | 🔲 | 集合和（dedup）。低優先度。 |
| `uniq` | ✅ | `tuple_uniq` → Constant 要素の重複除去 Tuple。 |
| `values_at` | ✅ | `values_at(*indices)` → 位置指定 Tuple。**高優先度。** `tuple_values_at` 実装。 |
| `zip` | ✅ | `tuple_zip` → 要素ペア Tuple。 |

### 5-2. 実装チェックリスト（優先度順）

```
高優先度:
[x] values_at(*indices) → TUPLE_HANDLERS → Tuple[T[i1], T[i2], …]
[x] +    (Tuple + Tuple) → TUPLE_HANDLERS → 連結 Tuple
[x] compact             → TUPLE_HANDLERS → nil エントリ除去 Tuple
[x] take(n)             → TUPLE_HANDLERS → 先頭 n 要素 Tuple

中優先度:
[x] drop(n)   → TUPLE_HANDLERS → n 以降の部分 Tuple
[x] rotate(n) → TUPLE_HANDLERS → 回転後 Tuple
[x] flatten   → TUPLE_HANDLERS → 1 段ネスト展開（depth=1 限定で実用十分）
[x] join      → TUPLE_HANDLERS `tuple_join`（すべて Constant のとき Constant[String]）。
    2026-07-18: 全要素 Constant[String] のケースを `LiteralStringFolding` が
    `literal-string` で覆い隠していたのを解消（精密フォールドに委譲）。
[x] slice     → TUPLE_HANDLERS → `[]` の別名（整数 / Range / start-length 形式）

低優先度:
[x] uniq      → TUPLE_HANDLERS → `tuple_uniq`（Constant 要素の重複除去 Tuple）
[x] minmax    → TUPLE_HANDLERS → `tuple_minmax_pair` → Tuple[Constant[min], Constant[max]]
[ ] max_by / min_by → ExpressionTyper ブロックフォールド追加
```

実装ファイル:
- TUPLE_HANDLERS への追加: `lib/rigor/inference/method_dispatcher/shape_dispatch.rb`
- ブロック系追加: `lib/rigor/inference/expression_typer.rb`（`PER_ELEMENT_TUPLE_METHODS`）

---

## 6. Set

現状、Set は `Nominal[Set]` として RBS から型を取得。`SetShape` キャリアは存在しない。

### 6-1. 状況整理

| 観点 | 内容 |
|------|------|
| 現在の精度 | RBS `Set[T]` 経由。`include?` は `bool` 返却（`Constant[bool]` にならない）。 |
| SetShape がない理由 | Set のリテラル構文が Ruby にない（`Set[1, 2, 3]` は `Set.new` 呼び出し）ため形状を静的に確定しにくい。 |
| 精度向上できる範囲 | `Set` の SIZE_RETURNING_NOMINALS への登録で `size`/`length`/`count` が IntegerRange を返す（ShapeDispatch 側）。それ以上は SetShape なしでは難しい。 |

### 6-2. 実装チェックリスト

```
現時点で対応可能（SetShape 不要）:
[ ] size / length / count → SIZE_RETURNING_NOMINALS に Set が登録済か確認
    （登録済みであれば ✅ — shape_dispatch.rb の SIZE_RETURNING_NOMINALS を参照）

将来的な SetShape 導入時に対応:
[ ] include? / member?   → Constant[bool]
[ ] empty?               → Constant[bool]
[ ] subset? / superset?  → Constant[bool]
[ ] + / | / & / -        → 新 Set 型
```

`SetShape` 導入は現サイクルでは対象外。需要が出た時点で ADR 化を検討。

---

## 優先度サマリ

2026-05-22 時点の高優先度タスクは全件実装済み。

| 型 | 状態 | 実装 (2026-05-22) |
|----|------|-------------------|
| String | ✅ | `start_with?` / `end_with?` / `include?` / `delete_prefix` / `delete_suffix` → STRING_BINARY |
| String | ✅ | `to_i` / `to_f` / `ord` → STRING_UNARY |
| Integer | ✅ | `**` / `&` / `\|` / `^` / `<<` / `>>` → NUMERIC_BINARY |
| Float | ✅ | `**` → NUMERIC_BINARY |
| Array / Tuple | ✅ | `values_at` / `+` / `compact` / `take` → TUPLE_HANDLERS |
| bool | ✅ | `===` → BOOL_BINARY |
| Set | — | SetShape 不要で対応できる項目なし (size 確認程度) |
