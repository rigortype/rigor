# Date / Time / DateTime method coverage audit

Generated 2026-05-23 as the Phase 1 artifact of a `rigor-type-coverage-uplift`
session (Phase 4 / Slice 4 of the post-`c9a535a` coverage-uplift line).

Unlike the String / Integer / Hash / Math audits, the Date / Time conclusion is
**not** a list of dispatch-tier additions. The reader surface is already
catalog-ready; the single blocker is a missing type carrier. This document
records that finding so the carrier decision is made deliberately rather than
folded silently into a dispatch slice.

---

## 凡例

| 記号 | 意味 |
|------|------|
| ✅ | 既存ティアで精密化済み |
| 🟦 | カタログ的には fold 可能だが `Constant` キャリア不在のため `Nominal` 止まり |
| 🚫 | 非対象（破壊的・非決定的） |

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
| Integer リーダ | `year` `month`/`mon` `day`/`mday` `wday` `yday` `cwyear` `cweek` `cwday` `jd` | `Constant[Integer]` | 🟦 |
| bool 述語 | `leap?` `julian?` `gregorian?` `sunday?`…`saturday?` | `Constant[bool]` | 🟦 |
| String リーダ | `to_s` `iso8601` `strftime(fmt)` `httpdate` `rfc3339` | `Constant[String]` | 🟦 |
| Date ナビ | `next_day` `prev_day` `next_month` `prev_year` `succ` `>>` `<<` `next` | `Constant[Date]` | 🟦 |
| DateTime 追加 | `hour` `min` `sec` `offset` `zone` | `Constant[Integer\|String]` | 🟦 |
| 比較 | `<=>` `==` `<` `>` (Date×Date) | `Constant[bool\|Integer]` | 🟦 |
| 破壊的 | （Date は不変。該当なし） | — | — |

---

## 3. メソッド分類（Time）

`Time.utc(...)` / `Time.gm(...)` / `Time.at(epoch)` の引数が全て定数のとき:

| 群 | メソッド | fold 先 | 状態 |
|----|---------|---------|------|
| Integer リーダ | `year` `month` `day` `hour` `min` `sec` `wday` `yday` `usec` `nsec` `utc_offset` | `Constant[Integer]` | 🟦 |
| bool 述語 | `utc?`/`gmt?` `sunday?`…`saturday?` `dst?` | `Constant[bool]` | 🟦 |
| String リーダ | `strftime(fmt)` `to_s` `ctime`/`asctime` `inspect` | `Constant[String]` | 🟦 |
| Time ナビ | `getlocal` `getutc`/`getgm` `+` `-`(Numeric) `round` `floor` `ceil` | `Constant[Time]` | 🟦 |
| 破壊的 | `localtime` `gmtime` `utc` | — | 🚫 ブロックリスト済み |
| 非決定的 | `Time.now` | — | 🚫 carrier 化対象外 |

**Time の不変性の注意**: `Time#localtime` / `gmtime` / `utc` は `time_modify`
で receiver を in-place 変更する。`Time` は純粋不変ではない。`Constant[Time]`
キャリアにする場合、`String` / `Set` と同じく `value.dup.freeze` で凍結する必要
がある（凍結 `Time` への `localtime` は `FrozenError` → fold は rescue で
decline、健全）。`TIME_CATALOG` は既に 3 つの擬似ミューテータをブロックリスト済み。

---

## 4. 結論 — 判断事項: `Constant` キャリアの新設

Date / Time の精密化は **ディスパッチ層の追加では達成できない**。`Type::Constant`
に新しいスカラキャリアを足す型システム変更が前提となる。直近に `Set` を
キャリア化した前例があり（`[Unreleased]` の "Set constant carrier"）、手順は確立
している。所要変更:

1. **`lib/rigor/type/constant.rb`**
   - 先頭で `require "date"`（`Date` / `DateTime` は stdlib。`Time` は core）。
   - `SCALAR_CLASSES` に `Date`（`DateTime` は `Date` のサブクラスなので包含）、
     `Time` を追加。
   - `initialize` の凍結分岐に `Date` / `Time` を追加（`value.dup.freeze`）。
   - `describe` を特例化 — `Date#inspect` / `Time#inspect` は冗長
     (`#<Date: 2026-01-01 ((...j,...))>`) なので `to_s`（`"2026-01-01"`）を使う。
   - `erase_to_rbs` は既定の `value.class.name`（`"Date"` / `"Time"`）で可。

2. **`constant_folding.rb`**
   - `foldable_constant_value?` に `Date` / `Time` を追加。
   - リーダ群はカタログ（`catalog_allows?`）経由で自動的に fold するため
     UNARY/BINARY Set への追加は不要。

3. **コンストラクタ fold**（`Constant[Date]` / `Constant[Time]` を産む入口）
   - `Date.new(y,m,d)` — `MethodDispatcher#meta_new` に `date_new_lift`
     （`range_new_lift` / `array_new_lift` と同じ場所・同じ形）。
   - `Time.utc(...)` / `Time.gm(...)` / `Time.at(epoch)` — Tier D
     `TimeFolding` モジュール、または `meta_new` 拡張。`Time.now` は非決定的
     なので **対象外**（`Nominal[Time]` を維持）。
   - `Date.parse` / `Date.today` も非対象（前者は文字列依存だが今回スコープ外、
     後者は非決定的）。

4. **FP 規律の確認** — `Constant[Time]` を `localtime` 等のミューテータと組み
   合わせたとき、凍結 Time が `FrozenError` を投げて fold が decline すること、
   `rigor check lib` がクリーンであることを回帰で固定。

### 推奨

型キャリアの新設は本コーパスのディスパッチ拡充とは粒度が異なる意図的な判断で
あり、`date_catalog/demo.rb` が現状を「deliberate deferral」として固定している。
**carrier 新設を独立スライスとして明示承認のうえ着手する**ことを推奨する。承認
されれば §4 の 4 ステップは `Set` キャリアの前例に沿ってほぼ機械的に実装できる。
