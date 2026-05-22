# Date / Time / DateTime method coverage audit

Generated 2026-05-23 as the Phase 1 artifact of a `rigor-type-coverage-uplift`
session (Phase 4 / Slice 4 of the post-`c9a535a` coverage-uplift line).

Unlike the String / Integer / Hash / Math audits, the Date / Time conclusion is
**not** a list of dispatch-tier additions. The reader surface is already
catalog-ready; the single blocker is a missing type carrier. This document
records that finding. The carrier was authorised and implemented (see § 4);
the 🟦 rows below are now ✅.

---

## 凡例

| 記号 | 意味 |
|------|------|
| ✅ | `Constant[Date]` / `Constant[Time]` キャリア経由で fold 済み |
| 🚫 | 非対象（破壊的・非決定的・マシン依存） |

---

## 1. 現状

`Date` / `DateTime` / `Time` は `CATALOG_BY_CLASS`（`constant_folding.rb`）に
登録済みで、`DATE_CATALOG` / `TIME_CATALOG` が C ソースから抽出済み。リーダ
メソッド群（`year` / `month` / `day` / `hour` / `wday` / `leap?` / `strftime`
/ `iso8601` / `next_day` / `>>` …）は `:leaf` 分類で **fold 適格**。

それにもかかわらず精密化が起きないのは、`Type::Constant` の `SCALAR_CLASSES`
（`lib/rigor/type/constant.rb`）に `Date` / `Time` が含まれず、`ConstantFolding`
の `foldable_constant_value?` も両クラスを受け付けないため。`Date.new(2026,1,1)`
は `Nominal[Date]` 止まりで、その上の `.year` も RBS ティアの `Integer` に
広がる。

`spec/integration/fixtures/date_catalog/demo.rb` と `time_catalog.rb` は、この
状況を「a future `Constant<Date>` carrier would be eligible to fold them」と
明記し、現状の `Nominal` 答えが unsound carrier を生まないことを回帰で固定して
いる。本監査はその「future carrier」を正式な判断事項として起票するもの。

---

## 2. メソッド分類（Date / DateTime）

`Date.new(...)` の引数が全て `Constant[Integer]` のとき、以下が `Constant` に
fold 可能になる（カタログ分類は確認済み・`date_catalog/demo.rb` が裏付け）:

| 群 | メソッド | fold 先 | 状態 |
|----|---------|---------|------|
| Integer リーダ | `year` `month`/`mon` `day`/`mday` `wday` `yday` `cwyear` `cweek` `cwday` `jd` | `Constant[Integer]` | ✅ |
| bool 述語 | `leap?` `julian?` `gregorian?` `sunday?`…`saturday?` | `Constant[bool]` | ✅ |
| String リーダ | `to_s` `iso8601` `strftime(fmt)` `httpdate` `rfc3339` | `Constant[String]` | ✅ |
| Date ナビ | `next_day` `prev_day` `next_month` `prev_year` `succ` `>>` `<<` `next` | `Constant[Date]` | ✅ |
| DateTime 追加 | `hour` `min` `sec` `offset` `zone` | `Constant[Integer\|String]` | ✅ |
| 比較 | `<=>` `==` `<` `>` (Date×Date) | `Constant[bool\|Integer]` | ✅ |
| 破壊的 | （Date は不変。該当なし） | — | — |

---

## 3. メソッド分類（Time）

`Time.utc(...)` / `Time.gm(...)` / `Time.at(epoch)` の引数が全て定数のとき:

| 群 | メソッド | fold 先 | 状態 |
|----|---------|---------|------|
| Integer リーダ | `year` `month` `day` `hour` `min` `sec` `wday` `yday` `usec` `nsec` `utc_offset` | `Constant[Integer]` | ✅ |
| bool 述語 | `utc?`/`gmt?` `sunday?`…`saturday?` `dst?` | `Constant[bool]` | ✅ |
| String リーダ | `strftime(fmt)` `to_s` `ctime`/`asctime` `inspect` | `Constant[String]` | ✅ |
| Time ナビ | `getutc`/`getgm` `+` `-`(Numeric) `round` `floor` `ceil` | `Constant[Time]` | ✅ |
| 破壊的 | `localtime` `gmtime` `utc` | — | 🚫 ブロックリスト済み |
| マシン依存 | `getlocal` | — | 🚫 `TIME_CATALOG` ブロックリストに追加 |
| 非決定的 | `Time.now` / `Time.at` / `Time.local` / `Time.new` | — | 🚫 carrier 化対象外（ローカルゾーン依存） |

**Time の不変性の注意**: `Time#localtime` / `gmtime` / `utc` は `time_modify`
で receiver を in-place 変更する。`Time` は純粋不変ではない。`Constant[Time]`
キャリアにする場合、`String` / `Set` と同じく `value.dup.freeze` で凍結する必要
がある（凍結 `Time` への `localtime` は `FrozenError` → fold は rescue で
decline、健全）。`TIME_CATALOG` は既に 3 つの擬似ミューテータをブロックリスト済み。

---

## 4. 実装（carrier 新設、承認のうえ実施）

Date / Time の精密化は **ディスパッチ層の追加では達成できず**、`Type::Constant`
に新しいスカラキャリアを足す型システム変更が前提だった。`Set` キャリアの前例に
沿って以下を実装した:

1. **`lib/rigor/type/constant.rb`**
   - 先頭で `require "date"`（`Date` / `DateTime` は stdlib。`Time` は core）。
   - `SCALAR_CLASSES` に `Date`（`DateTime` は `Date` のサブクラスなので包含）と
     `Time` を追加。
   - `initialize` の凍結分岐を `freezable_carrier?` に切り出し、`Date` / `Time`
     を `value.dup.freeze` 対象に追加（凍結 `Time` への `localtime` は
     `FrozenError` → fold は rescue で decline、健全）。
   - `describe` を特例化 — `Date#inspect` は astronomical Julian day 表記で
     不可読なので `iso8601`（`"2026-01-01"`）を使う。`Time#inspect` は
     `"2026-01-01 00:00:00 UTC"` と簡潔なので既定のまま。

2. **`constant_folding.rb`**
   - `foldable_constant_value?` の許可クラス集合（`FOLDABLE_CONSTANT_CLASSES`）に
     `Date` / `Time` を追加。リーダ群はカタログ（`catalog_allows?`）経由で
     自動的に fold するため UNARY/BINARY Set への追加は不要。

3. **コンストラクタ fold**（`Constant[Date]` / `Constant[Time]` を産む入口）
   - `Date.new(y,m,d)` / `DateTime.new(...)` — `MethodDispatcher#meta_new` に
     `date_new_lift`（`range_new_lift` / `regexp_new_lift` と同じ場所・同じ形）。
   - `Time.utc(...)` / `Time.gm(...)` — Tier D `TimeFolding` モジュール
     （`dispatch_stdlib_module_tiers` に配線）。UTC 固定なのでマシン非依存。
   - `Time.now` / `Time.at` / `Time.local` / `Time.new` / `Date.today` /
     `Date.parse` は **対象外** — 非決定的、またはローカルゾーン依存。

4. **FP 規律 — マシン依存の排除**
   - `Time.utc` / `gm` のみを fold（UTC 固定）。`Time.at` / `Time.local` /
     `Time.new`（明示オフセットなし）は解析マシンのゾーンに依存するため非対象。
   - `Time#getlocal` を `TIME_CATALOG` のブロックリストに追加 — ミューテータでは
     ないが結果が解析マシンのゾーンに依存するため、`Constant[Time]`（常に UTC）
     から fold するとホスト依存の値が型に焼き込まれる。`getutc` / `getgm` は
     UTC 結果なので fold 可能なまま。
   - `rigor check lib` クリーン、4345 examples 0 failures で回帰固定。
