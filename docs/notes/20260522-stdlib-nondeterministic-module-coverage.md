# 標準ライブラリ非決定論的・除外対象モジュール カバレッジ

2026-05-22 生成。決定論的グループ文書 (`20260522-stdlib-deterministic-module-coverage.md`) の対になる文書。  
`Constant[T]` への折りたたみが **原則不可・あるいは実益が薄い** モジュールを収録する。

---

## 凡例

| 記号 | 意味 |
|------|------|
| 🚫 | 対象外（副作用・非決定的・型精度向上が negligible）|
| 🔲 | 限定的に精度向上の余地あり（返値 Refinement など）|
| 🔷 | RBS で十分な精度が出ている |

---

## 除外基準

以下のいずれかに該当するモジュールをこのグループとする。

1. **副作用**: ファイルシステム・ネットワーク・OS プロセスを変更する
2. **非決定論**: 同一引数でも実行ごとに異なる出力を返す（乱数・タイムスタンプ等）
3. **返値が untyped**: `Marshal.load` のようにリテラル入力でも返値型が静的に不明
4. **折りたたみ実益が薄い**: 計算は決定論的でも、実際の定数値を型推論に使う場面がない（Base64 / Digest）

---

## 1. SecureRandom

`SecureRandom.methods - Module.methods` → 12 メソッド（Ruby 4.0.5）:  
`:alphanumeric, :base64, :bytes, :gen_random, :hex, :rand, :random_bytes, :random_number, :urlsafe_base64, :uuid, :uuid_v4, :uuid_v7`

**除外理由:** OS の乱数源から読み取るため、同一呼び出しでも必ず異なる値を返す。  
`hex(n)` の返値型は `String`（`non-empty-string` Refinement 追加は可能）、  
`uuid` / `uuid_v4` / `uuid_v7` の返値型は RBS で `String` 済み。

| メソッド | 返値型 | 状態 | 備考 |
|----------|--------|------|------|
| `hex(n)` | String (hex) | 🚫 | 非決定的。RBS で `String`。|
| `base64(n)` | String | 🚫 | 非決定的。 |
| `urlsafe_base64(n)` | String | 🚫 | 非決定的。 |
| `random_bytes(n)` / `bytes(n)` | String (binary) | 🚫 | 非決定的。 |
| `gen_random(n)` | String | 🚫 | 非決定的（内部実装用）。 |
| `rand` / `random_number` | Float\|Integer | 🚫 | 非決定的。 |
| `uuid` / `uuid_v4` | String | 🚫 | 非決定的。 |
| `uuid_v7` | String | 🚫 | 非決定的（タイムスタンプ成分含む）。 |
| `alphanumeric(n)` | String | 🚫 | 非決定的。 |

---

## 2. Random

`Random.methods - Class.methods` → 7 メソッド:  
`:bytes, :new_seed, :rand, :random_number, :seed, :srand, :urandom`

**除外理由:** クラスメソッドはグローバル乱数状態に依存。  
`Random.new(seed)` インスタンスは seed 固定で決定論的だが、  
インスタンスメソッドの精度向上は ConstantFolding 対象外（インスタンス状態を持つ）。

| メソッド | 状態 | 備考 |
|----------|------|------|
| `rand` / `random_number` | 🚫 | グローバル乱数。 |
| `bytes(n)` | 🚫 | 非決定的。 |
| `srand(seed)` | 🚫 | 副作用（グローバル状態変更）。 |
| `seed` / `new_seed` | 🚫 | 非決定的。 |
| `urandom(n)` | 🚫 | OS 乱数源。 |

---

## 3. FileUtils

`FileUtils.methods - Module.methods` → 57 メソッド（代表のみ抜粋）。

**除外理由:** ファイルシステムへの副作用専用モジュール。  
戻り値は操作対象パスや `nil` であり、型精度向上の意味がない。

| カテゴリ | メソッド例 | 状態 |
|---------|-----------|------|
| ファイルコピー / 移動 | `cp`, `cp_r`, `mv`, `install` | 🚫 |
| ファイル削除 | `rm`, `rm_f`, `rm_r`, `rm_rf` | 🚫 |
| ディレクトリ操作 | `mkdir`, `mkdir_p`, `rmdir` | 🚫 |
| リンク | `ln`, `ln_s`, `ln_sf`, `ln_sr` | 🚫 |
| パーミッション | `chmod`, `chmod_R`, `chown`, `chown_R` | 🚫 |
| 比較 | `cmp` / `compare_file`, `identical?` | 🚫 |
| ユーティリティ | `pwd` / `getwd`, `cd` / `chdir`, `touch` | 🚫 |
| メタ情報 | `commands`, `options`, `options_of`, `have_option?` | 🚫 |

---

## 4. Marshal

`Marshal.methods - Module.methods` → `:dump, :load, :restore`

**除外理由（ユーザー決定）:** `dump` は決定論的（同一オブジェクトで同一バイト列）だが、  
生成されるバイト列をリテラル型として使う場面がない。  
`load` / `restore` はバイナリから任意の Ruby オブジェクトを復元するため返値型が `untyped`（静的に推論不可）。  
決定論性はあっても型推論上の実益が Marshal には存在しない。

| メソッド | 状態 | 備考 |
|----------|------|------|
| `dump(obj)` | 🚫 | 決定論的だが返値 (binary String) を定数として使う場面なし。 |
| `load(str)` / `restore(str)` | 🚫 | 返値型が `untyped`。 |

---

## 5. GC

`GC.methods - Module.methods` → 20 メソッド。

**除外理由:** GC 操作はランタイム状態（ヒープ使用量・オブジェクト生存数等）を返す。  
同一コードでも実行環境・タイミングで値が変わる。

| カテゴリ | メソッド例 | 状態 |
|---------|-----------|------|
| 統計取得 | `count`, `stat`, `stat_heap`, `total_time` | 🚫 |
| GC 実行 / 制御 | `start`, `compact`, `disable`, `enable` | 🚫 |
| 設定 | `config`, `measure_total_time`, `stress` | 🚫 |
| 検証 | `verify_compaction_references`, `verify_internal_consistency` | 🚫 |

---

## 6. Base64（悩ましいグループ）

Ruby 4.0 では bundled gem に降格（`require "base64"` が必要）。  
`Base64.methods - Module.methods` → `:decode64, :encode64, :strict_decode64, :strict_encode64, :urlsafe_decode64, :urlsafe_encode64`

**除外理由（決定論グループに入れない理由）:**

| 観点 | 内容 |
|------|------|
| 決定論性 | ✓ 同一入力で常に同一出力 |
| 定数折りたたみの実益 | ✗ `encode64("hello")` → `"aGVsbG8=\n"` を定数値として型推論に使う場面がない |
| 返値型精度 | △ 返値は常に `String`（RBS 済み）。`non-empty-string` Refinement は追加可能だが効果が小さい |
| bundled gem 問題 | `require "base64"` が必要（Ruby 4.0 以降）。受信者型の認識が gems 状況に依存 |

**将来の昇格条件:** `non-empty-string` / `base64-string` 専用 Refinement を導入する場合、  
決定論グループに移動して `strict_encode64` / `urlsafe_encode64` へ Refinement 付与を検討。

| メソッド | 状態 | 備考 |
|----------|------|------|
| `encode64(str)` | 🚫 | 決定論的。折りたたみ実益なし。改行 (`\n`) 含む点が特殊。 |
| `strict_encode64(str)` | 🚫 | 改行なし版。同上。 |
| `urlsafe_encode64(str)` | 🚫 | URL-safe 版。同上。 |
| `decode64(str)` | 🚫 | デコード。返値 binary String。 |
| `strict_decode64(str)` | 🚫 | strict 版。不正入力で `ArgumentError`。 |
| `urlsafe_decode64(str)` | 🚫 | URL-safe 版。同上。 |

---

## 7. Digest（悩ましいグループ）

`Digest.methods - Module.methods` → `:hexencode`（Digest モジュールレベルは 1 関数のみ）。  
実用上は `Digest::MD5.hexdigest(str)` / `Digest::SHA256.hexdigest(str)` 等のクラスメソッドが対象。

**除外理由（決定論グループに入れない理由）:**

| 観点 | 内容 |
|------|------|
| 決定論性 | ✓ 暗号学的ハッシュ関数は決定論的 |
| 定数折りたたみの実益 | ✗ テスト用リテラル入力に実際のハッシュ値が出ても型推論上使えない |
| 返値型精度 | △ `hexdigest` → 固定長 hex 文字列（MD5: 32 文字, SHA256: 64 文字）。専用 Refinement `hex-string` / `md5-hex-string` を定義すれば添付可能 |
| 返値長 | Digest アルゴリズムごとに長さが異なる。汎用 Refinement では長さ情報が失われる |

**将来の昇格条件:** `hex-string` / `md5-hex-string` / `sha256-hex-string` 等の長さ付き Refinement を  
`imported-built-in-types.md` に追加する場合、決定論グループへ移動して Refinement 付与を検討。

| メソッド / クラス | 状態 | 備考 |
|-----------------|------|------|
| `Digest.hexencode(str)` | 🚫 | 入力文字列を hex 表現に変換。定数折りたたみ実益なし。 |
| `Digest::MD5.hexdigest(str)` | 🚫 | 32 文字 hex 文字列。決定論的だが値を使わない。 |
| `Digest::SHA1.hexdigest(str)` | 🚫 | 40 文字 hex 文字列。同上。 |
| `Digest::SHA256.hexdigest(str)` | 🚫 | 64 文字 hex 文字列。同上。 |
| `Digest::SHA512.hexdigest(str)` | 🚫 | 128 文字 hex 文字列。同上。 |
| `Digest::*#digest(str)` (binary) | 🚫 | バイナリ文字列。 |
| `Digest::*#update` / `<<` | 🚫 | 破壊的状態蓄積。 |

---

## サマリ: 非対象グループの型精度向上シナリオ

現状は全て 🚫 だが、以下のシナリオで一部が昇格しうる。

| シナリオ | 対象 | 必要な前提 |
|---------|------|-----------|
| `non-empty-string` Refinement 拡充 | `SecureRandom.uuid`, `SecureRandom.hex(n > 0)`, `Base64.encode64`, `Digest::*.hexdigest` | Refinement 型として `non-empty-string` が充実し、返値に自動付与するルールが整備される |
| `hex-string` 専用 Refinement | `SecureRandom.hex`, `Digest::*.hexdigest` | `imported-built-in-types.md` への新規 Refinement 追加 + length 情報付与 |
| UUID 文字列型 | `SecureRandom.uuid` / `uuid_v4` / `uuid_v7` | `uuid-string` Refinement（36 文字、特定フォーマット） |
