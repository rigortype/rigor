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

**2026-08-05 reconciliation** (this slice): every row below was re-probed empirically with
`rigor type-of` against `lib/rigor/inference/method_dispatcher/regexp_folding.rb` on `master` —
neither the table nor the source alone was trusted. Two rows were stale in the "doc under-reports"
direction (`escape` / `quote` marked 🔲 while already folded) and one in the "doc mis-categorizes"
direction (`last_match` marked 🚫 — out of scope — while a real, narrowing-based fold exists). Both
directions are now fixed. `union` and `linear_time?` were confirmed live gaps (wide `Regexp` / `bool`
on an all-constant call site) and closed in this slice.

| メソッド | シグネチャ | 返却型 | 状態 | 備考 |
|----------|-----------|--------|------|------|
| `escape(str)` | String → String | `Constant[String]` | ✅ | `RegexpFolding#fold_escape`（`REGEXP_ESCAPE_METHODS`）。ドキュメントが 🔲 のまま古くなっていた — 実装は既に存在（2026-08-05 訂正）。 |
| `quote(str)` | String → String | `Constant[String]` | ✅ | `escape` の別名。同一ハンドラを共有。ドキュメントが 🔲 のまま古くなっていた（2026-08-05 訂正）。 |
| `compile(pattern)` | String → Regexp | `Constant[Regexp]` | ✅ | `Regexp.new` 別名（`rb_reg_s_new` 同一 C エントリポイント）。`RegexpFolding::REGEXP_NEW_METHODS` に `:compile` を追加し `fold_new` を共有（#121 P3）。 |
| `union(*patterns)` / `union(array)` | String\|Regexp… → Regexp | `Constant[Regexp]` | ✅ | `RegexpFolding#fold_union`。可変引数・単一配列引数・既存 Regexp 要素・0 引数（`/(?!)/`）のいずれも実 `Regexp.union` へ委譲して Ruby の挙動をそのまま再現（2026-08-05, #121 P3）。 |
| `last_match` | → MatchData? | `MatchData` / `String` / `String?` | ✅ | グローバル `$~` 依存だが、証明済みマッチ辺 (`Narrowing#regex_match_predicate_scopes` が narrow した scope) では `RegexpFolding#fold_last_match` が非 nil `MatchData` / キャプチャ群の `String` へ絞り込む。証明されない辺では RBS の `MatchData?` に委譲。単純な定数畳み込みではなく narrowing ベースなので純粋な「引数が定数なら畳み込む」パターンとは異なるが、実装は存在する — ドキュメントが 🚫（対象外）のまま古くなっていた（2026-08-05 訂正）。 |
| `linear_time?(pattern)` | String\|Regexp → bool | `Constant[bool]` | ✅ | `RegexpFolding#fold_linear_time`。第 2 引数（`timeout:` キーワードが positional slot に落ちるケース）がある場合は明示的に RBS へ委譲（2026-08-05, #121 P3）。 |
| `timeout` / `timeout=` | — | — | 🚫 | グローバル設定の読み書き。副作用 / 実行時状態で畳み込み対象外。 |
| `try_convert(obj)` | Object → Regexp? | — | 🚫 | ダックタイプ変換（`to_regexp` 等）。任意オブジェクトを受理するため静的に判定不能。 |

### 3-1. 実装チェックリスト

```
高優先度:
[x] escape / quote → Constant[String] (Constant[String] 引数時) — 既存実装、ドキュメントのみ訂正（2026-08-05）

低優先度:
[x] compile      → Constant[Regexp] (Constant[String] 引数時) — #121 P3
[x] union        → Constant[Regexp] (全要素が Constant[String|Regexp] 時、0 引数含む) — #121 P3 (2026-08-05)
[x] linear_time? → Constant[bool] (Constant[String|Regexp] 単一引数時) — #121 P3 (2026-08-05)
[x] last_match   → 証明済みマッチ辺での narrowing、既存実装。ドキュメントのみ訂正（2026-08-05）
```

---

## 4. CGI（エスケープ / アンエスケープ系）

`CGI.methods - Module.methods` → エスケープ関係 16 メソッド（実体 4 機能 + CamelCase / snake_case / エイリアス）。

**2026-08-05 reconciliation**: every row below was stale — all eight were marked 🔲 despite
`lib/rigor/inference/method_dispatcher/cgi_folding.rb` (`CGIFolding`, a Tier D module distinct from
the `constant_folding.rb` location this section originally proposed) already folding every one of
them, confirmed empirically with `rigor type-of` (`CGI.escape("hello world")` →
`Constant["hello+world"]`, `CGI.escapeElement("<BR><A HREF=\"url\"></A>", "A", "IMG")` →
`Constant["<BR>&lt;A HREF=&quot;url&quot;&gt;&lt;/A&gt;"]`, etc. — all eight forms checked). This
whole section is done; no further CGI work is queued.

| 機能 | CamelCase | snake_case | エイリアス | 返却型 | 状態 |
|------|-----------|-----------|-----------|--------|------|
| URL エスケープ | `CGI.escape` | — | — | `Constant[String]` | ✅ |
| URL アンエスケープ | `CGI.unescape` | — | — | `Constant[String]` | ✅ |
| HTML エスケープ | `CGI.escapeHTML` | `CGI.escape_html` | `CGI.h` | `Constant[String]` | ✅ |
| HTML アンエスケープ | `CGI.unescapeHTML` | `CGI.unescape_html` | — | `Constant[String]` | ✅ |
| 要素エスケープ | `CGI.escapeElement` | `CGI.escape_element` | — | `Constant[String]` | ✅ |
| 要素アンエスケープ | `CGI.unescapeElement` | `CGI.unescape_element` | — | `Constant[String]` | ✅ |
| URI コンポーネントエスケープ | `CGI.escapeURIComponent` | `CGI.escape_uri_component` | — | `Constant[String]` | ✅ |
| URI コンポーネントアンエスケープ | `CGI.unescapeURIComponent` | `CGI.unescape_uri_component` | — | `Constant[String]` | ✅ |

### 4-1. 実装チェックリスト

```
[x] escapeHTML / escape_html / h                  → Constant[String] — ドキュメントのみ訂正（2026-08-05）
[x] unescapeHTML / unescape_html                  → Constant[String] — ドキュメントのみ訂正（2026-08-05）
[x] escape (URL) / unescape (URL)                 → Constant[String] — ドキュメントのみ訂正（2026-08-05）
[x] escapeURIComponent / escape_uri_component     → Constant[String] — ドキュメントのみ訂正（2026-08-05）
[x] unescapeURIComponent / unescape_uri_component → Constant[String] — ドキュメントのみ訂正（2026-08-05）
[x] escapeElement / escape_element                → Constant[String] — ドキュメントのみ訂正（2026-08-05）
[x] unescapeElement / unescape_element            → Constant[String] — ドキュメントのみ訂正（2026-08-05）
```

実装ファイル: `lib/rigor/inference/method_dispatcher/cgi_folding.rb`（`CGIFolding` モジュール、
Tier D）。エイリアスは `fold_cgi_call` / `fold_cgi_element` の 2 ハンドラに集約。
テスト: `spec/integration/fixtures/module_function_folding/demo.rb` +
`type_construction_spec.rb`「fixtures/module_function_folding.rb」ブロック。

---

## 5. URI（エンコード / デコード系）

`URI.methods - Module.methods` → 16 メソッド。精度向上対象は encode/decode 系のみ。

**2026-08-05 reconciliation**: the four component encode/decode rows were stale — marked 🔲 despite
`lib/rigor/inference/method_dispatcher/uri_folding.rb` (`URIFolding`, Tier D) already folding all
four, confirmed empirically with `rigor type-of`. The remaining rows (`encode_www_form` /
`decode_www_form` / `parse` / `join` / `extract`) were re-checked and were genuine, still-open gaps.

**2026-08-05 follow-up**: `encode_www_form` / `decode_www_form` are now implemented (#121). `parse`
and `join` were re-classified 🔲 → 🚫: they are not pending work but out of this category by the
repo's own rule, since a URI object has no `Constant[…]` representation, and the one genuinely
valuable move (narrowing `parse`'s ten-arm return union to the scheme class a constant string
selects) can surface a diagnostic that does not fire today — bucket-3 / P0, not an FP-safe fold.
`extract` was then implemented too, so **the URI section is now fully classified**: every row is ✅,
🔷, or 🚫, and none is pending.

| メソッド | シグネチャ | 返却型 | 状態 | 備考 |
|----------|-----------|--------|------|------|
| `encode_www_form_component(str)` | String → String | `Constant[String]` | ✅ | RFC 3986 パーセントエンコード。ドキュメントのみ訂正（2026-08-05）。 |
| `decode_www_form_component(str)` | String → String | `Constant[String]` | ✅ | ドキュメントのみ訂正（2026-08-05）。 |
| `encode_uri_component(str)` | String → String | `Constant[String]` | ✅ | Ruby 3.2+。ドキュメントのみ訂正（2026-08-05）。 |
| `decode_uri_component(str)` | String → String | `Constant[String]` | ✅ | ドキュメントのみ訂正（2026-08-05）。 |
| `encode_www_form(arr)` | Array/Hash → String | `Constant[String]` | ✅ | Tuple（`[k, v]` の Tuple 列）または閉じた HashShape の全要素が Constant のとき折りたたむ。64 ペア上限（#121, 2026-08-05）。 |
| `decode_www_form(str)` | String → Array | `Tuple[Tuple[Str,Str]…]` | ✅ | Constant[String] 引数を精密 Tuple に持ち上げる（#121, 2026-08-05）。 |
| `parse(str)` | String → URI | URI オブジェクト | 🚫 | **カテゴリ外**（🔲 ではない）。`URI::Generic` 系は `ConstantFolding::FOLDABLE_CONSTANT_CLASSES` に無いため `Constant[URI]` は作れない。10 アームの返却 union を scheme クラスへ絞る案は精度上の利得はあるが、gradually-valid な dispatch を精密化して新規診断を surface し得る = bucket-3/P0 であり、FP-safe fold カテゴリ（#121）の範囲外。 |
| `join(base, *paths)` | String… → URI | URI オブジェクト | 🚫 | `parse` と同じ理由（URI オブジェクトに Constant が無い）。 |
| `extract(str)` | String → Array[String] | `Tuple[Constant[String]…]` | ✅ | 1 引数形式のみ折りたたむ。第 2 引数（schema フィルタ）は辞退。Ruby の obsolete 警告は fold 内で抑止（#121, 2026-08-05）。 |
| `split(str)` | String → Array[String?] | — | 🔷 | RBS `Array[String?]` で十分。 |
| `for(scheme, …)` | — | URI | 🚫 | オブジェクト生成。 |
| `regexp` / `scheme_list` etc. | — | — | 🚫 | 設定 / メタ情報。 |

### 5-1. 実装チェックリスト

```
高優先度:
[x] encode_www_form_component → Constant[String] — ドキュメントのみ訂正（2026-08-05）
[x] decode_www_form_component → Constant[String] — ドキュメントのみ訂正（2026-08-05）
[x] encode_uri_component      → Constant[String] — ドキュメントのみ訂正（2026-08-05）
[x] decode_uri_component      → Constant[String] — ドキュメントのみ訂正（2026-08-05）

中優先度（未実装、次スライス候補）:
[ ] encode_www_form → Constant[String] (Tuple / HashShape 引数時)
[ ] decode_www_form → Tuple[Tuple[Constant[String], Constant[String]]…]
```

実装ファイル: `lib/rigor/inference/method_dispatcher/uri_folding.rb`（`URIFolding` モジュール、Tier
D）。テスト: `spec/integration/fixtures/module_function_folding/demo.rb` +
`type_construction_spec.rb`「fixtures/module_function_folding.rb」ブロック。

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
| ✅ 済 | `Regexp.escape` / `quote` | `Constant[String]`（ドキュメントのみ 2026-08-05 訂正、実装は既存） |
| ✅ 済 | `Shellwords.escape` / `shellescape` / `split` / `shellsplit` / `join` / `shelljoin` | `Constant[String]` / `Tuple[Constant[String]…]` |
| ✅ 済 | `CGI.escapeHTML` / `h` / 全 8 系統（`CGIFolding`） | `Constant[String]`（ドキュメントのみ 2026-08-05 訂正、実装は既存） |
| ✅ 済 | `URI.encode_www_form_component` / `decode_www_form_component` / `encode_uri_component` / `decode_uri_component` | `Constant[String]`（ドキュメントのみ 2026-08-05 訂正、実装は既存） |
| ✅ 済 | `Math.sqrt` / `exp` / `log` / `sin` / `cos` ほか | `Constant[Float]` |
| ✅ 済 | `Math.atan2` / `hypot` / `frexp` / `lgamma` | `Constant[Float]` / `Tuple` |
| ✅ 済 | `CGI.escape` / `unescape` (URL) | `Constant[String]`（ドキュメントのみ 2026-08-05 訂正、実装は既存） |
| ✅ 済 | Math 全 28 関数（`MathFolding`） | `Constant[Float]` / `Tuple` |
| ✅ 済 | `URI.encode_www_form` / `decode_www_form` / `extract` | `Constant[String]` / 精密 Tuple（#121 P3, 2026-08-05）。URI 節はこれで全行分類済み |
| ✅ 済 | `Regexp.union` / `linear_time?` | `Constant[Regexp]` / `Constant[bool]`（#121 P3, 2026-08-05） |
| ✅ 済 | `Regexp.last_match` | 証明済みマッチ辺での narrowing（ドキュメントのみ 2026-08-05 訂正、実装は既存） |
