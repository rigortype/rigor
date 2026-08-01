# 標準ライブラリ決定論的モジュール関数カバレッジ

2026-05-22 生成。`Math.methods - Module.methods` 等から各モジュールの公開関数を洗い出し、  
`Constant[T]` または精度精緻化（`non-empty-string` 等の Refinement）が得られる関数を分類する。

---

## 凡例

| 記号 | 意味 |
|------|------|
| ✅ | 実装済み |
| 🔲 | 未実装だが `Constant[T]` または Refinement に折りたためる価値あり |
| 🔷 | 別ティア処理済み（RBS 等で十分） |
| 🚫 | 非対象（副作用・非決定的・型精度向上が negligible） |

---

## 実装アーキテクチャ上の前提

現行 `ConstantFolding` の `invoke_unary` / `invoke_binary` は **インスタンスメソッド受信者** を対象とする。  
`Math.sqrt(4.0)` のようなモジュール関数呼び出しは受信者が `Math` モジュールオブジェクト（シングルトン）であり、  
現状は未処理（`CATALOG_BY_CLASS` に `Math` が存在しない）。

**推奨実装方針（実装時に決定）:**

```
Option A: ConstantFolding に try_fold_module_function を追加し、
          受信者型が Math / Shellwords / CGI / URI の singleton であることを
          receiver_type.class_name で認識 → 専用 invoke ハンドラで実際に評価

Option B: 新規 ModuleFunctionFolding ティアを MethodDispatcher に挿入
          （ConstantFolding と同列の独立ファイル）

Option A が低コスト。関数数が増えたら Option B に昇格を検討。
```

受信者型認識の課題: Rigor が `Math` 定数を `Type::Nominal["Math"]` として解決するか  
`Type::Constant[Math module object]` として解決するかは既存の singleton 型処理（`Random.rand` など  
`CATALOG_BY_CLASS` に含まれる Random に対するインスタンス/クラスメソッド分岐）を参照して確認が必要。

---

## 1. Math

`Math.methods - Module.methods` → 28 関数（Ruby 4.0.5）。  
全て `Constant[Float]` または `Tuple[Constant[Float], Constant[Integer]]` へ折りたためる。

### 1-1. メソッド一覧

| メソッド | シグネチャ | 返却型 | 状態 | 備考 |
|----------|-----------|--------|------|------|
| `acos(x)` | Float → Float | `[0, π]` Float | ✅ | ドメイン外 (`\|x\| > 1`) で DomainError |
| `acosh(x)` | Float → Float | Float ≥ 0 | ✅ | ドメイン外 (`x < 1`) で DomainError |
| `asin(x)` | Float → Float | `[-π/2, π/2]` Float | ✅ | |
| `asinh(x)` | Float → Float | Float | ✅ | |
| `atan(x)` | Float → Float | `(-π/2, π/2)` Float | ✅ | |
| `atan2(y, x)` | Float, Float → Float | `(-π, π]` Float | ✅ | 2 引数。`y`/`x` ゼロの符号注意。 |
| `atanh(x)` | Float → Float | Float | ✅ | ドメイン外 (`\|x\| ≥ 1`) で DomainError |
| `cbrt(x)` | Float → Float | Float | ✅ | 負の実数にも対応（`(-8)***(1/3.0)` とは異なる） |
| `cos(x)` | Float → Float | `[-1, 1]` Float | ✅ | |
| `cosh(x)` | Float → Float | Float ≥ 1 | ✅ | |
| `erf(x)` | Float → Float | `(-1, 1)` Float | ✅ | 誤差関数 |
| `erfc(x)` | Float → Float | `(0, 2)` Float | ✅ | 相補誤差関数 |
| `exp(x)` | Float → Float | Float > 0 | ✅ | Refinement: `positive-float` 付与可能 |
| `expm1(x)` | Float → Float | Float > -1 | ✅ | `exp(x) - 1`（小さな x で精度良好） |
| `frexp(x)` | Float → [Float, Integer] | `Tuple[Float, Integer]` | ✅ | 仮数・指数分解。返値が Tuple。 |
| `gamma(x)` | Float → Float | Float | ✅ | ドメイン外 (`x ≤ 0` の整数) で DomainError |
| `hypot(x, y)` | Float, Float → Float | Float ≥ 0 | ✅ | Refinement: `non-negative-float` |
| `ldexp(f, e)` | Float, Integer → Float | Float | ✅ | 仮数・指数から Float 再構成 |
| `lgamma(x)` | Float → [Float, Integer] | `Tuple[Float, Constant[1\|-1]]` | ✅ | 対数ガンマ + 符号。Tuple 返却。 |
| `log(x)` | Float → Float | Float | ✅ | ドメイン外 (`x ≤ 0`) で DomainError |
| `log(x, base)` | Float, Float → Float | Float | ✅ | 2 引数形式別ハンドラ要 |
| `log10(x)` | Float → Float | Float | ✅ | |
| `log1p(x)` | Float → Float | Float | ✅ | `log(1+x)`（小さな x で精度良好） |
| `log2(x)` | Float → Float | Float | ✅ | |
| `sin(x)` | Float → Float | `[-1, 1]` Float | ✅ | |
| `sinh(x)` | Float → Float | Float | ✅ | |
| `sqrt(x)` | Float → Float | Float ≥ 0 | ✅ | ドメイン外 (`x < 0`) で DomainError。Refinement: `non-negative-float` |
| `tan(x)` | Float → Float | Float | ✅ | |
| `tanh(x)` | Float → Float | `(-1, 1)` Float | ✅ | |

**Math 定数:**
- `Math::E` → `Constant[2.718281828459045]` — 定数解決（メソッド畳み込みではない）。本スライス対象外。
- `Math::PI` → `Constant[3.141592653589793]` — 同上。定数キャリアの課題として別途。

### 1-2. 実装チェックリスト

```
前提:
[x] Math シングルトン受信者の認識方法を確認（Type::Singleton, class_name == "Math"）
[x] MathFolding モジュール（Tier D。option B — 独立 *_folding.rb ファイル）

高優先度（頻用・返値が単純 Float）:
[x] sqrt    → Constant[Float]
[x] exp     → Constant[Float]
[x] log     → Constant[Float]（1/2 引数の可変長）
[x] log2    → Constant[Float]
[x] log10   → Constant[Float]
[x] sin / cos / tan → Constant[Float]

中優先度（2 引数または特殊返値）:
[x] atan2   → Constant[Float]
[x] hypot   → Constant[Float]
[x] ldexp   → Constant[Float]
[x] frexp   → Tuple[Constant[Float], Constant[Integer]]
[x] lgamma  → Tuple[Constant[Float], Constant[Integer]]

低優先度（ニッチな数値解析用途）:
[x] erf / erfc / expm1 / log1p / cbrt
[x] acos / asin / atan / acosh / asinh / atanh
[x] cosh / sinh / tanh / gamma

Refinement 追加（値の範囲が分かる場合）— 今回は対象外:
[ ] exp → positive-float
[ ] sqrt / hypot → non-negative-float
```

実装ファイル: `lib/rigor/inference/method_dispatcher/math_folding.rb`（`ShellwordsFolding` パターンの Tier D モジュール。`dispatch_stdlib_module_tiers` に配線）。Refinement 付与（`positive-float` / `non-negative-float`）は需要が出たときの follow-up。

---

## 2. Shellwords

`Shellwords.methods - Module.methods` → 7 メソッド（実体 3 関数 + エイリアス）。

| メソッド | エイリアス | シグネチャ | 返却型 | 状態 | 備考 |
|----------|-----------|-----------|--------|------|------|
| `escape(str)` | `shellescape` | String → String | `Constant[String]` | ✅ | `ShellwordsFolding` 実装済み。`""` 入力でも `"''"` を返すため常に非空。 |
| `split(line)` | `shellsplit`, `shellwords` | String → Array[String] | `Tuple[Constant[String]…]` | ✅ | `ShellwordsFolding` 実装済み。不正クォートは nil を返し RBS に委譲。 |
| `join(array)` | `shelljoin` | Array[String] → String | `Constant[String]` | ✅ | `ShellwordsFolding` 実装済み。`Tuple[Constant[String]…]` 引数時のみ。 |

### 2-1. 実装チェックリスト

```
高優先度:
[x] escape / shellescape → Constant[String] (Constant[String] 引数時)
[x] split / shellsplit / shellwords → Tuple[Constant[String]…] (Constant[String] 引数時)
[x] join / shelljoin → Constant[String] (Tuple[Constant[String]…] 引数時)
```

実装ファイル: `lib/rigor/inference/method_dispatcher/shellwords_folding.rb` (`ShellwordsFolding` モジュール)。  
`dispatch_precise_tiers` の `FileFolding` 直後に接続。  
`Singleton["Shellwords"]` 受信者を `dispatch_target?` で検出し、`Shellwords.escape` / `.split` / `.join` を inference 時に直接呼び出す。

---

## 3. Regexp（クラスメソッド）

`Regexp.methods - Class.methods` → `:compile, :escape, :last_match, :linear_time?, :quote, :timeout, :timeout=, :try_convert, :union`

| メソッド | シグネチャ | 返却型 | 状態 | 備考 |
|----------|-----------|--------|------|------|
| `escape(str)` | String → String | `Constant[String]` | 🔲 | 正規表現メタ文字エスケープ。**高優先度。** |
| `quote(str)` | String → String | `Constant[String]` | 🔲 | `escape` の別名。同上。 |
| `compile(pattern)` | String → Regexp | `Constant[Regexp]` | ✅ | `Regexp.new` 別名（`rb_reg_s_new` 同一 C エントリポイント）。`RegexpFolding::REGEXP_NEW_METHODS` に `:compile` を追加し `fold_new` を共有（#121 P3）。 |
| `union(*patterns)` | String… → Regexp | `Regexp` | 🔲 | 可変引数・Regexp 型返却。低優先度。 |
| `last_match` | → MatchData? | MatchData\|nil | 🚫 | グローバル `$~` に依存。実行時状態。 |
| `linear_time?(pattern)` | String → bool | `Constant[bool]` | 🔲 | パターンが線形時間かを静的解析。低優先度。 |
| `timeout` / `timeout=` | — | — | 🚫 | グローバル設定。 |
| `try_convert(obj)` | Object → Regexp? | — | 🚫 | ダックタイプ変換。 |

### 3-1. 実装チェックリスト

```
高優先度:
[ ] escape / quote → Constant[String] (Constant[String] 引数時)

低優先度:
[x] compile → Constant[Regexp] (Constant[String] 引数時) — #121 P3
[ ] union   → Regexp (全引数 Constant[String] 時)
```

---

## 4. CGI（エスケープ / アンエスケープ系）

`CGI.methods - Module.methods` → エスケープ関係 16 メソッド（実体 4 機能 + CamelCase / snake_case / エイリアス）。

| 機能 | CamelCase | snake_case | エイリアス | 返却型 | 状態 |
|------|-----------|-----------|-----------|--------|------|
| URL エスケープ | `CGI.escape` | — | — | `Constant[String]` | 🔲 |
| URL アンエスケープ | `CGI.unescape` | — | — | `Constant[String]` | 🔲 |
| HTML エスケープ | `CGI.escapeHTML` | `CGI.escape_html` | `CGI.h` | `Constant[String]` | 🔲 |
| HTML アンエスケープ | `CGI.unescapeHTML` | `CGI.unescape_html` | — | `Constant[String]` | 🔲 |
| 要素エスケープ | `CGI.escapeElement` | `CGI.escape_element` | — | `Constant[String]` | 🔲 |
| 要素アンエスケープ | `CGI.unescapeElement` | `CGI.unescape_element` | — | `Constant[String]` | 🔲 |
| URI コンポーネントエスケープ | `CGI.escapeURIComponent` | `CGI.escape_uri_component` | — | `Constant[String]` | 🔲 |
| URI コンポーネントアンエスケープ | `CGI.unescapeURIComponent` | `CGI.unescape_uri_component` | — | `Constant[String]` | 🔲 |

**優先度:** `escapeHTML` / `unescapeHTML` / `h` が最頻用途。`escape` / `unescape` (URL) が次点。

### 4-1. 実装チェックリスト

```
高優先度:
[ ] escapeHTML / escape_html / h  → Constant[String]
[ ] unescapeHTML / unescape_html  → Constant[String]

中優先度:
[ ] escape (URL)   → Constant[String]
[ ] unescape (URL) → Constant[String]
[ ] escapeURIComponent / escape_uri_component   → Constant[String]
[ ] unescapeURIComponent / unescape_uri_component → Constant[String]

低優先度:
[ ] escapeElement / escape_element   → Constant[String]
[ ] unescapeElement / unescape_element → Constant[String]
```

実装ファイル: `constant_folding.rb` に `try_fold_cgi` メソッド。  
エイリアスは同じハンドラから分岐（1 メソッドに集約）。

---

## 5. URI（エンコード / デコード系）

`URI.methods - Module.methods` → 16 メソッド。精度向上対象は encode/decode 系のみ。

| メソッド | シグネチャ | 返却型 | 状態 | 備考 |
|----------|-----------|--------|------|------|
| `encode_www_form_component(str)` | String → String | `Constant[String]` | 🔲 | **高優先度。** RFC 3986 パーセントエンコード。 |
| `decode_www_form_component(str)` | String → String | `Constant[String]` | 🔲 | 高優先度。 |
| `encode_uri_component(str)` | String → String | `Constant[String]` | 🔲 | 高優先度（Ruby 3.2+）。 |
| `decode_uri_component(str)` | String → String | `Constant[String]` | 🔲 | 高優先度。 |
| `encode_www_form(arr)` | Array/Hash → String | `Constant[String]` | 🔲 | Tuple / HashShape 引数時に折りたためる。中優先度。 |
| `decode_www_form(str)` | String → Array | `Tuple[Tuple[Str,Str]…]` | 🔲 | 中優先度。 |
| `parse(str)` | String → URI | URI オブジェクト | 🔲 | RBS で十分。`Constant[URI]` は複雑。低優先度。 |
| `join(base, *paths)` | String… → URI | URI オブジェクト | 🔲 | 低優先度。 |
| `extract(str)` | String → Array[String] | Tuple? | 🔲 | 低優先度。 |
| `split(str)` | String → Array[String?] | — | 🔷 | RBS `Array[String?]` で十分。 |
| `for(scheme, …)` | — | URI | 🚫 | オブジェクト生成。 |
| `regexp` / `scheme_list` etc. | — | — | 🚫 | 設定 / メタ情報。 |

### 5-1. 実装チェックリスト

```
高優先度:
[ ] encode_www_form_component → Constant[String]
[ ] decode_www_form_component → Constant[String]
[ ] encode_uri_component      → Constant[String]
[ ] decode_uri_component      → Constant[String]

中優先度:
[ ] encode_www_form → Constant[String] (Tuple / HashShape 引数時)
[ ] decode_www_form → Tuple[Tuple[Constant[String], Constant[String]]…]
```

実装ファイル: `constant_folding.rb` に `try_fold_uri` メソッド。

---

## 6. Base64 / Digest の扱いについて

これら 2 モジュールは **計算自体は決定論的** だが、精度向上の実益が薄いため  
非決定論的グループ文書 (`20260522-stdlib-nondeterministic-module-coverage.md`) に収録した。

| モジュール | 理由 |
|-----------|------|
| **Base64** | `encode64("hello")` → `"aGVsbG8=\n"` は確かに定数。しかし実用コードで Base64 を定数リテラルに折りたたむ場面はほぼない。返値型は常に `String` であり RBS が十分。Refinement `non-empty-string` は追加可能だが効果が小さい。 |
| **Digest** | `MD5.hexdigest("foo")` → 32 文字 hex 文字列。定数折りたたみで実際のハッシュ値が得られても静的解析上の用途がない。返値型 `String` は RBS 済み。hex 文字列専用 Refinement (`hex-string`) を追加する場合は決定論グループへ昇格を検討。 |

---

## 優先度サマリ

| 優先度 | モジュール・メソッド | 期待する精度向上 |
|--------|---------------------|-----------------|
| 🔴 高 | `Regexp.escape` / `quote` | `Constant[String]` |
| ✅ 済 | `Shellwords.escape` / `shellescape` / `split` / `shellsplit` / `join` / `shelljoin` | `Constant[String]` / `Tuple[Constant[String]…]` |
| 🔴 高 | `CGI.escapeHTML` / `h` | `Constant[String]` |
| 🔴 高 | `URI.encode_www_form_component` / `decode_www_form_component` | `Constant[String]` |
| ✅ 済 | `Math.sqrt` / `exp` / `log` / `sin` / `cos` ほか | `Constant[Float]` |
| ✅ 済 | `Math.atan2` / `hypot` / `frexp` / `lgamma` | `Constant[Float]` / `Tuple` |
| 🟡 中 | `CGI.escape` / `unescape` (URL) | `Constant[String]` |
| ✅ 済 | Math 全 28 関数（`MathFolding`） | `Constant[Float]` / `Tuple` |
| 🟢 低 | `URI.encode_www_form` / `decode_www_form` | `Constant[String]` / Tuple |
