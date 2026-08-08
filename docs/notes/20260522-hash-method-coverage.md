# Hash method coverage — ShapeDispatch & block-fold audit

Generated from `({}.methods - Object.new.methods).sort` on Ruby 4.0 (2026-05-22).
Tracks which methods produce precise `HashShape` results and what is still open.

---

## 凡例

| 記号 | 意味 |
|------|------|
| ✅ | ShapeDispatch (`shape_dispatch.rb`) または ExpressionTyper ブロックフォールドで実装済み |
| 🔷 | 別ティアで処理済み（BlockFolding / ConstantFolding / RBS で十分精度が出る） |
| 🔲 | 未実装だが HashShape 精度向上の価値あり |
| 🚫 | 非対象（破壊的変更・Enumerator 生成・精度向上が negligible） |

---

## メソッド一覧

| メソッド | 状態 | 実装場所 / 備考 |
|----------|------|-----------------|
| `<` | ✅ | HashShape 同士の包含比較 → `Constant[bool]` にたためる。低優先度。 |
| `<=` | ✅ | 同上。 |
| `>` | ✅ | 同上。 |
| `>=` | ✅ | 同上。 |
| `[]` | ✅ | `hash_lookup` — 静的キーで値型を返す。 |
| `[]=` | 🚫 | 破壊的変更。形状が不定になるため対象外。 |
| `all?` | 🔷 | 引数なし・ブロックなし → RBS `bool`。ブロックあり → BlockFolding。 |
| `any?` | ✅ | `hash_any?` — 引数なし・ブロックなし時のみ ShapeDispatch。ブロックあり → BlockFolding。 |
| `assoc` | ✅ | 静的キーなら `Tuple[Constant[k], V]` または `Constant[nil]` に折りたためる。 |
| `chain` | 🚫 | `Enumerator` を返す。HashShape 精度不要。 |
| `chunk` | 🚫 | Enumerable。 |
| `chunk_while` | 🚫 | Enumerable。 |
| `clear` | 🚫 | 破壊的変更。 |
| `collect` | 🚫 | `Hash#map` と同義。`[k,v]` ペアを 2 引数ブロックに渡す形式は現行 BlockParameterBinder が非対応。 |
| `collect_concat` | 🚫 | `flat_map` と同義。同上。 |
| `compact` | ✅ | `hash_compact` — 全値 Constant のときに nil エントリを除去。 |
| `compact!` | 🚫 | 破壊的変更。`!` ブロック済み。 |
| `compare_by_identity` | 🚫 | 破壊的変更（比較方針の変更）。 |
| `compare_by_identity?` | 🔷 | リテラル HashShape では常に `false`。しかし RBS `bool` で十分。 |
| `count` | ✅ | `hash_size` — 引数なし・ブロックなし。ブロックあり → BlockFolding `COUNT_METHOD`。 |
| `cycle` | 🚫 | Enumerable。 |
| `deconstruct_keys` | ✅ | パターンマッチ用サブシェイプ。`slice` と同構造。中優先度。 |
| `default` | ✅ | リテラル HashShape では `Constant[nil]`。低優先度。 |
| `default=` | 🚫 | 破壊的変更。 |
| `default_proc` | ✅ | リテラル HashShape では `Constant[nil]`。低優先度。 |
| `default_proc=` | 🚫 | 破壊的変更。 |
| `delete` | 🚫 | 破壊的変更（形状変化）。 |
| `delete_if` | 🚫 | 破壊的変更。 |
| `detect` | 🔷 | BlockFolding `FALSEY_BLOCK_NIL_METHODS` で falsey ブロック時 `Constant[nil]`。 |
| `dig` | ✅ | `hash_dig` — 静的キー連鎖でネスト値を取り出す。 |
| `drop` | 🚫 | Enumerable。Array of `[k,v]` を返す。 |
| `drop_while` | 🔷 | BlockFolding `FILTER_KEEP_ON_FALSEY` — falsey ブロックで receiver 返却。 |
| `each` | 🚫 | 反復子。返り値は self / Enumerator。 |
| `each_cons` | 🚫 | Enumerable。 |
| `each_entry` | 🚫 | Enumerable。 |
| `each_key` | 🚫 | 反復子。 |
| `each_pair` | 🚫 | `each` の別名。 |
| `each_slice` | 🚫 | Enumerable。 |
| `each_value` | 🚫 | 反復子。 |
| `each_with_index` | 🚫 | Enumerable。 |
| `each_with_object` | 🚫 | Enumerable。 |
| `empty?` | ✅ | `hash_empty?` — 閉じた形状で `Constant[bool]`。 |
| `entries` | ✅ | `to_a` の別名。HASH_SHAPE_HANDLERS に `entries: :hash_to_a` を登録。 |
| `except` | ✅ | **高優先度。** `slice` の補集合。静的キーリストから子 HashShape を生成。`ShapeDispatch#hash_except`。 |
| `fetch` | ✅ | `hash_lookup` — 静的キー。missing key 時は RBS fallback。 |
| `fetch_values` | ✅ | `values_at` と類似。静的キーリストから `Tuple[V_1…]` へ。missing key が RBS では raise なので `values_at` 実装の隣に置ける。中優先度。 |
| `filter` | 🔷 | `select` の別名。BlockFolding 経由。 |
| `filter!` | 🚫 | 破壊的変更。 |
| `filter_map` | 🚫 | Enumerable。2 引数ブロック問題あり。 |
| `find` | 🔷 | BlockFolding `FALSEY_BLOCK_NIL_METHODS`。 |
| `find_all` | 🔷 | `select` の別名。BlockFolding 経由。 |
| `find_index` | 🔷 | BlockFolding `FALSEY_BLOCK_NIL_METHODS`。 |
| `first` | ✅ | `hash_first` — 先頭エントリを `Tuple[K, V]` で返す。 |
| `flat_map` | 🚫 | Enumerable。2 引数ブロック問題あり。 |
| `flatten` | ✅ | `hash_flatten` — `[k1,v1,k2,v2,…]` の Tuple を返す。 |
| `grep` | 🚫 | Enumerable。 |
| `grep_v` | 🚫 | Enumerable。 |
| `group_by` | 🚫 | Enumerable。返り値が `Hash[K, Array[V]]` で複雑。 |
| `has_key?` | ✅ | **高優先度。** `key?`/`member?`/`include?` と同義。静的キーで `Constant[true/false]`。`ShapeDispatch#hash_has_key?`。 |
| `has_value?` | ✅ | 全値 Constant のとき `Constant[true/false]`。低優先度。 |
| `include?` | ✅ | `has_key?` の別名。`ShapeDispatch#hash_has_key?` に同一ハンドラ登録。 |
| `inject` | 🚫 | Enumerable accumulator。 |
| `inspect` | ✅ | `hash_inspect` — CLOSED かつ optional key なし、かつ全値 Constant のときのみ。実 Hash を再構築して本物の `inspect` を呼ぶ（Ruby 4.0 の `{a: 1}` 形式を再導出しない）。`TUPLE_JOIN_BYTE_LIMIT`（4096）でキャップ。ゲート述語は `URIFolding#hash_form_pairs`（`URI.encode_www_form`）と同じ「closed かつ optional key なし」（#121, 2026-08-08）。 |
| `invert` | ✅ | `hash_invert` — 全値が Constant[Symbol/String] のとき反転 HashShape を返す。 |
| `keep_if` | 🚫 | 破壊的変更（`select!` 相当）。 |
| `key` | ✅ | 値 → キー逆引き。全値 Constant で一意なら `Constant[k]`。低優先度。 |
| `key?` | ✅ | `has_key?` と同義。高優先度。`ShapeDispatch#hash_has_key?` に同一ハンドラ登録。 |
| `keys` | ✅ | `hash_keys` — `Tuple[Constant[k]…]` を返す。 |
| `lazy` | 🚫 | Enumerator::Lazy。 |
| `length` | ✅ | `hash_size` に委譲。 |
| `map` | 🚫 | `collect` と同義。2 引数ブロック問題あり。 |
| `max` | 🚫 | Enumerable。ペアの順序付け比較は複雑。 |
| `max_by` | 🚫 | Enumerable。 |
| `member?` | ✅ | `has_key?` と同義。高優先度。`ShapeDispatch#hash_has_key?` に同一ハンドラ登録。 |
| `merge` | ✅ | `hash_merge` — 両側 closed HashShape で右辺優先マージ。 |
| `merge!` | 🚫 | 破壊的変更。`!` ブロック済み。 |
| `min` | 🚫 | Enumerable。 |
| `min_by` | 🚫 | Enumerable。 |
| `minmax` | 🚫 | Enumerable。 |
| `minmax_by` | 🚫 | Enumerable。 |
| `none?` | ✅ | **高優先度。** 引数なし・ブロックなし → `Constant[shape.pairs.empty?]`。`hash_any?` のミラー。`ShapeDispatch#hash_none?`。 |
| `one?` | ✅ | 引数なし・ブロックなし → `Constant[shape.pairs.size == 1]`。中優先度。 |
| `partition` | 🚫 | Enumerable。`[[k,v],…] × 2` を返す。 |
| `rassoc` | 🔲 | 値 → `[k, v]` 逆引き。全値 Constant で一意なら Tuple。低優先度。 |
| `reduce` | 🚫 | Enumerable accumulator。 |
| `rehash` | 🚫 | 破壊的変更（キーのハッシュ再計算）。 |
| `reject` | 🔷 | BlockFolding `FILTER_KEEP_ON_FALSEY` — falsey ブロックで receiver 返却。 |
| `reject!` | 🚫 | 破壊的変更。 |
| `replace` | 🚫 | 破壊的変更。 |
| `reverse_each` | 🚫 | Enumerator。 |
| `select` | 🔷 | BlockFolding `FILTER_KEEP_ON_TRUTHY` — truthy ブロックで receiver 返却。 |
| `select!` | 🚫 | 破壊的変更。 |
| `shift` | 🚫 | 破壊的変更（先頭ペア削除）。 |
| `size` | ✅ | `hash_size` — `Constant[pairs.size]`。 |
| `slice` | ✅ | **高優先度。** `slice(:k1, :k2)` → 対応する子 HashShape を返す。`ShapeDispatch#hash_slice`。 |
| `slice_after` | 🚫 | Enumerable。 |
| `slice_before` | 🚫 | Enumerable。 |
| `slice_when` | 🚫 | Enumerable。 |
| `sort` | 🚫 | 返り値は `Array[[K,V]]`。複雑。 |
| `sort_by` | 🚫 | Enumerable。 |
| `store` | 🚫 | `[]=` の別名。破壊的変更。 |
| `sum` | 🚫 | Enumerable。 |
| `take` | 🚫 | Enumerable。Array of pairs。 |
| `take_while` | 🔷 | BlockFolding `FILTER_KEEP_ON_TRUTHY`。 |
| `tally` | 🚫 | Enumerable。 |
| `to_a` | ✅ | `hash_to_a` — `Tuple[Tuple[K,V],…]` を返す。 |
| `to_h` | ✅ | `hash_to_h` — self を返す。 |
| `to_hash` | ✅ | `to_h` の別名。HASH_SHAPE_HANDLERS に `to_h` と同じエントリを追加するだけ。低優先度。 |
| `to_proc` | 🚫 | `Proc` を返す。静的型付けには不要。 |
| `to_s` | ✅ | `inspect` の厳密な別名（`Hash#to_s` は `Hash#inspect` と同一）。同一ハンドラ `hash_inspect` を登録（#121, 2026-08-08）。 |
| `to_set` | 🚫 | `Set` を返す。 |
| `transform_keys` | ✅ | ExpressionTyper `try_hash_shape_block_fold` — キーを変換した新 HashShape。 |
| `transform_keys!` | ✅ | 同上（bang 形式）。 |
| `transform_values` | ✅ | ExpressionTyper `try_hash_shape_block_fold` — 値を変換した新 HashShape。 |
| `transform_values!` | ✅ | 同上（bang 形式）。 |
| `uniq` | 🚫 | Enumerable。 |
| `update` | 🚫 | `merge!` の別名。破壊的変更。 |
| `value?` | ✅ | `has_value?` の別名。低優先度。 |
| `values` | ✅ | `hash_values` — `Tuple[V_1,…]`。 |
| `values_at` | ✅ | `hash_values_at` — 静的キーリストから `Tuple[V…]`。 |
| `zip` | 🚫 | Enumerable。 |

---

## 対応要チェックリスト

優先度別に並べています。実装したら ✅ に変更してください。

### 高優先度

- [x] `slice(*keys)` — `slice(:name, :age)` → 対応する子 `HashShape` を返す。`except` の逆。`ShapeDispatch#hash_slice` に実装。全引数が `Constant[Symbol|String]` で対象キーが shape に存在すること。欠損キーは省略（`values_at` と異なり nil を埋めない）。
- [x] `except(*keys)` — `except(:debug)` → 対象キーを除いた `HashShape`。`ShapeDispatch#hash_except`。全引数が `Constant[Symbol|String]`。shape にないキーは無視。
- [x] `has_key?` / `key?` / `member?` / `include?` — 引数が `Constant[Symbol|String]` のとき `Constant[true/false]` に畳む。`ShapeDispatch#hash_has_key?` に実装し、4 エイリアスを同一ハンドラに登録。
- [x] `none?` (引数なし・ブロックなし) — `Constant[shape.pairs.empty?]`。`hash_any?` に倣い `ShapeDispatch#hash_none?` を追加。

### 中優先度

- [x] `fetch_values(*keys)` — 全引数が `Constant[Symbol|String]` で shape に存在するなら `Tuple[V…]`。存在しないキーがあれば decline（RBS が KeyError を示す）。`ShapeDispatch#hash_fetch_values`。
- [x] `assoc(key)` — 引数が `Constant[Symbol|String]` で既知のキーなら `Tuple[Constant[k], V]`、未知のキーなら `Constant[nil]`。`ShapeDispatch#hash_assoc`。
- [x] `one?` (引数なし・ブロックなし) — `Constant[shape.pairs.size == 1]`。`ShapeDispatch#hash_one?`。
- [x] `deconstruct_keys(keys)` — Ruby の `Hash#deconstruct_keys` は `keys` 引数に関わらず receiver 自身を返すため、精密な答えは shape そのもの。`ShapeDispatch#hash_deconstruct_keys`。
- [x] `entries` — `to_a` と同義。HASH_SHAPE_HANDLERS に `entries: :hash_to_a` を登録。

### 低優先度

- [x] `to_hash` — HASH_SHAPE_HANDLERS に `to_hash: :hash_to_h` を登録。
- [x] `default` (引数なし / キー引数) — リテラル HashShape はデフォルト値なし → `Constant[nil]`。`ShapeDispatch#hash_default`。
- [x] `default_proc` — 同上 → `Constant[nil]`。`hash_default` を共用。
- [x] `has_value?` / `value?` — 全値が `Constant` のとき `Constant[true/false]`。`ShapeDispatch#hash_has_value?`。
- [x] `key(value)` — 全値が Constant のとき、最初に一致したキーの `Constant[k]`、存在しないとき `Constant[nil]`。`ShapeDispatch#hash_key`。
- [x] `<`, `<=`, `>`, `>=` — 両辺が閉じた HashShape（全値 Constant）のとき包含比較を `Constant[bool]` に畳む。`ShapeDispatch#hash_compare`。

---

## 実装に関するメモ

### `slice` / `except` / `has_key?` の置き場所

`ShapeDispatch::HASH_SHAPE_HANDLERS` に追加し、`dispatch_hash_shape` 経由で呼ぶ。引数は `args` 配列として渡ってくるので、全要素が `Type::Constant` かつ値が `Symbol | String` かどうかを確認してから処理する。

### `none?` / `one?`

`hash_any?`/`hash_empty?` と同じパターン。HASH_SHAPE_HANDLERS へのエントリ追加と実装メソッド追加のみ。

### `fetch_values` と `assoc`

`values_at` (hash_values_at) と実装が非常に近い。`values_at` は欠損キーを `Constant[nil]` で埋めるが、`fetch_values` は欠損キーで decline（RBS の raise セマンティクスを尊重する）。

### `entries` / `to_hash`

1 行の HANDLERS エントリ追加のみ。リグレッションリスクが最小。

### 包含比較 `<` / `<=` / `>` / `>=`

`hash_merge` のように両引数が `Type::HashShape` のときのみ畳む。左辺の全ペアが右辺に含まれるかどうかを静的に判定できる。実装コストは小さいが使用頻度も低いため低優先度。
