# Ren et al. 2013「The Ruby Type Checker (rtc)」— Rigor 観点考察

**Status:** research note, no design commitments. 外部文献の Rigor 観点レビュー。
**Date:** 2026-07-12。
**Rigor version:** master @ `138bf2c4`（v0.2.9 リリース直後）に対する観察。

## 対象論文

- Brianna M. Ren, John Toman, T. Stephen Strickland, Jeffrey S. Foster
  **"The Ruby Type Checker"**
  Proc. 28th ACM Symposium on Applied Computing (SAC '13), pp. 1565–1572,
  Coimbra, Portugal, March 2013. ACM 978-1-4503-1656-9/13/03.
  （University of Maryland, College Park。配布 URL のファイル名は `oops13.pdf` だが
  奥付の刊行は SAC'13。）
- 一次資料 URL: <https://www.cs.tufts.edu/~jfoster/papers/oops13.pdf>

**Why:** rtc は Rigor と**同じゴール（Ruby に型安全性を、動いているコードを壊さずに）**を
掲げながら、機構が正反対の設計点にある — Rigor が「静的・推論優先・注釈不要」なのに対し、
rtc は「実行時・注釈をルートとする検査・pay-for-what-you-use」。この対極を突き合わせて
(a) Rigor の設計判断がどの軸で意図的に分岐しているかの確認、(b) rtc が「実行時なので自然に解ける」
としている難所（eval / method_missing / reflection）が Rigor では何の代償で近似されているかの棚卸し、
(c) 両者が独立に同じ実バグ形（`false`/`nil` の戻りアーム）へ収束している事実の記録、を行う。
本論文は Foster 研の DRuby → Rubydust → **rtc** → （後の）RDL という米国側 Ruby 型付け系譜の中核であり、
[Matsumoto & Minamide 2010（Steep 前史）](20260518-matsumoto-2010-cfa-rigor-review.md)の日本側系譜と対になる
継続ベンチマークとして価値がある。

**読み順.** §1 が rtc のサーフェス棚卸し、§2 が型言語の対応、§3 が設計判断の分岐（最重要）、
§4 が Rigor に効く具体示唆、§5 が系譜とベンチマークとしての位置づけ。

---

## 1. rtc 側のサーフェス棚卸し

1. **実行時型検査 — ただしメソッド入口／出口で。** rtc は Ruby ライブラリとして実装され、
   型検査は実行時に走る。だが「純粋な動的型付けより早く（メソッド entry/exit で）、
   純粋な静的型付けより遅く」という**中間点**に自らを置く。静的検査が苦手な高度に動的な機能
   （eval・reflective method invocation）を実行時ゆえ自然に扱える、というのが売り。

2. **"pay for what you use" — 注釈をルートとする検査。** 注釈のないプログラムは通常どおり走る。
   オブジェクトは **raw（未型付け）** と **annotated（型付き）** に分割され、
   **型検査は annotated 値がレシーバになったときだけ**発火する。注釈はプログラマが明示するか、
   型検査対象の呼び出しへ引数として渡された値に暗黙に付与される。

3. **注釈 DSL（クラス・メソッド・オブジェクトに付与）。**
   - `rtc_annotated` — クラスを注釈対象に。
   - `typesig "personnel_id : () -> Fixnum"` — メソッド型を**文字列**で宣言。
   - `rtc_annotate` — 値に型を載せた annotated 版を作る（安全な upcast のみ）。
   - `rtc_cast` — union 型などで downcast したいとき用の別メソッド（cast は概念的に upcast と異なるので分離）。
   - `rtc_instantiate` — 型パラメータを明示的に具体化。
   - `rtc_autowrap` — クラスの全インスタンスを自動 annotate（非パラメータ化クラスのみ）。

4. **型システムの表現力。** nominal 型／**union**（`Manager or %false`）／**intersection**（同一メソッドへ
   複数 `typesig` を書くと交差＝オーバーロード相当）／**block（高階メソッド）型**
   （`() { (String) -> %any } -> String`）／**パラメトリック多相**（`Array<t>`, `map<u>: () {(t) -> u} -> Array<u>`）／
   **type cast**／**Tuple 型**（`Tuple<t1,…,tn>`、i 番目が ti）／型エイリアス（`%true`, `%bool`, `%any`, `%false`）。

5. **プロキシによる実装。** annotated オブジェクトは `method_missing` を持つ **Proxy** で包まれ、
   呼び出しを横取りして entry/exit で型検査し、下層オブジェクトへ delegate、引数と戻り値も annotate する。
   Proxy 実装の細部: `self` 上のプロキシ追跡（Proxy スタック）、native メソッドが Proxy を嫌う問題への
   `:unwrap => [0]`（呼び出し前にプロキシを剥がす引数位置指定）、`false`/`nil` は包まない
   （boolean 比較を横取りできないため）、`define_method` より `eval` 生成メソッドの方が呼び出しが速い、等。

6. **non-strict モード（既定）。** raw 配列を annotate する際、`Array` のような容器では要素型まで検査すると
   反復コストが高い。既定の non-strict では**型コンストラクタ（容器の種類）だけ**を照合し、
   型パラメータ（要素型）は検査しない。`$RTC_STRICT = true` で厳格モード（要素も反復検査）に切り替え。
   非厳格でも「格納値を**使った**時点」で誤りは捕まる。

7. **評価.** 被験プログラム = Sudoku / Ascii85 / ministat / finitefield / hebruby / set / RDS
   （SinglyLinkedList 等）＋ 組込 Array/Hash/Set。最初の 5 本は Rubydust ベンチ由来。
   相対オーバーヘッドは大きい（Sudoku 0.04s → 非厳格 5.34s → 厳格 7.58s、method 横取りコストが主因）が
   絶対時間ではテストは速い。本番は `RTC_DISABLED` で無効化可。使用頻度は被験プログラムで union / 多相が最多、
   標準ライブラリで intersection / block 型が最多、tuple と `rtc_cast` はごく稀。**実バグを 1 件検出**
   （Sudoku の `search` が解なし時に `false` を返すが `string_solution` は妥当解を仮定 → 注釈不整合で発火）。

---

## 2. 型言語の対応（rtc ↔ Rigor）

| rtc の型構成子 | Rigor 側の対応物 | 所見 |
| --- | --- | --- |
| nominal 型 | Nominal キャリア（RBS スーパーセット） | 直対応。 |
| union（`A or B`） | Union（[value-lattice.md](../type-specification/value-lattice.md)） | 直対応。rtc は「正規 union、disjoint union ではない」と明記 — Rigor の union と同義。 |
| intersection（複数 `typesig`） | メソッドオーバーロード（RBS overload） | rtc は同名メソッドへ複数 `typesig` を書き、交差＝全注釈を満たす、と定義。Rigor のオーバーロード解決（`OverloadSelector`）と同型。 |
| block（高階）型 | block 型（[structural-interfaces](../type-specification/structural-interfaces-and-object-shapes.md), [ADR-16](../adr/16-macro-expansion.md) Tier A） | 直対応。rtc の `() { (String) -> %any } -> String` は Rigor の block 型注釈にそのまま写る。 |
| パラメトリック多相（`Array<t>`, `map<u>`） | ジェネリクス＋軽量 HKT（[ADR-20](../adr/20-lightweight-hkt.md)） | 対応。rtc は `map` の `u` を「ブロック初回呼び出し結果から推論、未呼出なら `%none`＝bot」とする — Rigor の block 戻り推論と同じ着想。 |
| Tuple 型（`Tuple<t1,…,tn>`） | Tuple キャリア＋Data/Struct member shape（[ADR-48](../adr/48-data-struct-value-folding.md)） | 対応。rtc は「配列を均質コレクションと固定長タプルの両用途で使う」ことを Tuple で区別 — Rigor の Tuple/HashShape 分離と同じ動機。rtc は DRuby と違い「Tuple 用メソッドが使われている間は Tuple、非 Tuple メソッドが来たら Array に昇格」と明言。 |
| type alias（`%true`/`%bool`/`%any`/`%false`） | special types（[special-types.md](../type-specification/special-types.md)） | `%any` = untyped = **Rigor の `Dynamic[top]`**。`%false`/`%true`/`%bool` は Rigor の `false`/`true`/`bool` リテラル・boolish に対応。`%none` = bot。ほぼ一対一。 |
| `rtc_cast`（実行時 downcast） | assertion 注釈（[rbs-extended.md](../type-specification/rbs-extended.md) の `rigor:v1:assertion`） | 概念対応。rtc は実行時に値をテストしてから型を貼り替える。Rigor は静的に narrowing で同じ効果を得るか、明示 assertion を書く。 |
| union/intersection の**曖昧性禁止** | オーバーロード解決の一意性（value-pinning／consistency） | rtc は型変数束縛が曖昧になる union/intersection を**注釈時に禁止**し、曖昧なメソッド呼び出しで error。Rigor は**検査時に**整合性で解く。同じ難所への対処時点が違う（§3-4）。 |

型言語の表現力はほぼ等価で、rtc の文字列 DSL は Rigor が上位互換とする RBS/RDL 系譜の直系前身
（rtc → RDL の注釈文字列は本論文の `typesig` がルーツ）。

---

## 3. 異なる設計判断（最重要）

1. **静的 vs 実行時 — 設計空間の対極。**
   rtc は実行時にメソッド境界で検査する。含意: (a) **観測された実行パスしか守らない**
   （走らなかった分岐・メタプロされたメソッドは無検査）、(b) プロキシ横取りの**実行時オーバーヘッド**、
   (c) 反面 eval/reflection/`method_missing` を**自然に**扱える。
   Rigor は静的・注釈不要・実行時コストゼロで**全パス**を守るが、動的機能を静的近似する代償を払う。
   **ゴール（低 FP の Ruby 型安全）は同一、機構は正反対** — [Elixir レビュー](20260604-elixir-v1.20-type-system-rigor-review.md)で見た
   「同ゴール・逆機構」構図の、実行時側の実例。

2. **動的機能の扱いが交換されている（Rigor の最大の難所を rtc は実行時で回避）。**
   rtc は関連研究比較で「実行時に動くので realizable な実行パスだけを観測し、
   eval・reflective method invocation・`method_missing` を伴う動的機能の存在下でも容易に動く」と明言する。
   これはまさに Rigor が静的に苦闘してきた領域そのもの — `pre_eval`（[ADR-17](../adr/17-monkey-patch-pre-evaluation.md)）、
   マクロ展開基盤（[ADR-16](../adr/16-macro-expansion.md)）、implicit-self 呼び出し解決（[ADR-24](../adr/24-self-method-call-resolution.md)/[ADR-57](../adr/57-self-call-return-adoption.md)）、
   そして `Dynamic[T]` provenance の全アーク（[ADR-75](../adr/75-dynamic-provenance.md)/[ADR-82](../adr/82-dynamic-origin-algebra.md)）。
   rtc はこれらを「実行時に払う」ことで**構造的に消している**。Rigor は「静的近似＋プラグイン脱出口」で払う。
   **これは根本トレードで追従不可 — 記録のみ。** ただし裏を返せば、rtc が守れない
   「走らなかったパス／未起動のメタプロメソッド」こそ Rigor が静的に守れる領域であり、優位も対称に存在する。

3. **推論 vs 検査（Rubydust との対比が Rigor に効く）。**
   本論文は自らを Rubydust（An et al., POPL 2011 — 制約ベース型**推論**）と対置し、rtc は型**検査**だと言う。
   Rigor は推論優先（DRuby/Rubydust 側の系譜）**かつ**静的**かつ**低 FP、という第三の点にいる。
   rtc が検査を選んだ理由 — (a) Ruby フロントエンドの保守を避ける、(b) 動的機能を扱う、
   (c) エラーを**発生と同時に**報告（Rubydust は制約を末尾で解くため報告が分かりにくい）— のうち
   (c) は Rigor も「検査時に発生源つきで即報告」で満たすが、(a)(b) は Rigor が**あえて逆を選んだ**
   （フルフロントエンドと静的近似のコストを引き受けて全パス保護とゼロ実行時コストを得る）。

4. **union/intersection 曖昧性の対処時点。**
   rtc は型変数束縛が曖昧になる union/intersection を**注釈時に構文で禁止**し、
   曖昧なメソッドが呼ばれたら実行時 error にする（`m1<t,u>: (t or u) -> ...` は t/u が同位置に現れ曖昧、等）。
   Rigor は同じ曖昧性を**検査時のオーバーロード解決**（value-pinning・gradual consistency）で解く。
   Rigor の方が「禁止せず解く」ぶん表現力に寛容だが、解けない曖昧を静かに `Dynamic` へ落とす危険もある。
   rtc の「曖昧は明示エラー」は、Rigor のオーバーロード解決が沈黙で Dynamic 化する箇所の provenance を
   **`framework_dsl_boundary` ではなく `analyzer-budget-cutoff` 系で明示する**設計判断の参考になる。

5. **容器検査コストの non-strict/strict 二値モード。**
   rtc は「容器の要素型まで見ると反復が高い」を non-strict（コンストラクタのみ）/strict（要素も）の
   **グローバルモードフラグ**で解決する。Rigor は同じコスト問題を**per-carrier の予算**
   （[ADR-41 inference budgets](../adr/41-inference-budget-design.md)、[inference-budgets.md](../type-specification/inference-budgets.md)）と
   shape-carrier の要素型 join（[ADR-56](../adr/56-block-captured-local-mutation.md) slice C、ADR-48 member layout）で解く。
   rtc の二値フラグは粗いが「容器か中身か」という軸の存在自体は共通の本質。Rigor の予算制は
   「容器の種類は常に無料・中身は fuel が尽きたら Dynamic」という連続版と読める。

---

## 4. Rigor に効く具体示唆

1. **`false`/`nil` 戻りアームが両システムで最高価値の実バグ形（独立収束）。** ✅ Rigor は既に着手済み。
   rtc の唯一の実バグ検出も、注釈反復で見つけた「最も多い誤り」も、いずれも
   **「メソッドが時々 `false` を返す」エッジケースの取りこぼし**と**「intersection のアームを 1 本忘れる」**だった。
   これは Rigor の union-arm predicate polarity（[ADR-57 WD3](../adr/57-self-call-return-adoption.md)、
   [union-arm-predicate-polarity ノート](20260710-union-arm-predicate-polarity.md)）と possible-nil 系
   （[ADR-58](../adr/58-ivar-field-typing.md)）が狙う領域そのもの。**独立した二つの Ruby 型システムが
   「money bug は `false`/`nil` の戻りアーム」に収束した**事実は、Rigor がここへ投じてきた工数の妥当性を外部から裏書きする。
   追加アクション不要だが、Rigor の diagnostic 例集・ハンドブックに「rtc も同じ結論」を引く価値はある。

2. **rtc は「型注釈を test-protection に変換する装置」— ADR-70 の test-protected 軸のデータ点。**
   rtc の本質は「注釈が実行時アサーションになり、テストスイートに exercise される」こと。
   これは融合保護（[ADR-70](../adr/70-fused-protection-coverage.md)）の **test-protected 軸を、
   ただのテストではなく型契約で実現した形**にほかならない。含意:
   - rtc の「保護」はテストカバレッジで上限が決まる（走らないパスは無保護）— ADR-70 が
     「test-protection はスイートの仕事、依存グラフで選んではいけない」とした理由と同じ構造。
   - Rigor の type-protection（静的・全パス・推論精度で上限）と rtc 型の runtime-protection は**相補**。
     ADR-70 の attribution（「型を足せ」vs「テストを足せ」）に、rtc は
     「注釈を runtime 契約化すればテストが型を exercise する」という**第三の中間手**を示唆する。
   記録価値: ADR-70 のフレーミングが「静的型 ∪ 走るテスト」だったところに、rtc は
   「静的型 ∪ **型契約化された** 走るテスト」という中間層が存在することを歴史的に実証している。

3. **`%any`=Dynamic の位置づけと provenance。**
   rtc の `%any` は「ブロックが何を返してもよい」を表す明示的 untyped で、非厳格モードや native 境界で頻出する。
   Rigor の `Dynamic[T]` と役割は同じだが、Rigor は provenance（[ADR-75](../adr/75-dynamic-provenance.md)/[ADR-82](../adr/82-dynamic-origin-algebra.md)）で
   「なぜ Dynamic か」を追う。rtc は追わない（実行時なので不要）。逆に言えば **Rigor の provenance アークは
   「静的だからこそ必要になったメタデータ」** であり、rtc との対比はその存在理由を鮮明にする
   — 実行時チェッカは Dynamic の由来を知る必要がない（値が来た時点で実物を見る）。

4. **`rtc_cast` / assertion の稀少性は「注釈は書きたくない」の裏書き。**
   rtc の評価で tuple 型と `rtc_cast` は「ごく稀」だった。cast（＝人が型を手で貼り替える操作）が
   実プログラムで滅多に要らないという観測は、Rigor の「手書き RBS より `sig-gen`・推論精度」志向
   （`feedback_no_ai_generated_rbs`）と同じ方向の外部証拠。人は narrowing を書きたがらない → 推論・narrowing で自動的に効かせよ。

---

## 5. 系譜とベンチマークとしての位置づけ

- **Foster 研の Ruby 型付け系譜の中核。** DRuby（Furr, An, Foster, Hicks — "Static Type Inference for Ruby",
  OOPS'09。静的・制約ベース推論）→ Rubydust（POPL 2011。動的・実行時制約収集、末尾で解く）→
  **rtc（本論文、SAC'13。実行時検査、注釈をルート）** → （後の）RDL。
  Rigor は DRuby の「推論で型を立ち上げる」ゴールを継ぎつつ、Rubydust/rtc が実行時に逃した
  「静的・全パス・ゼロ実行時コスト」を取りに行った設計と読める。rtc の `typesig` 文字列 DSL は
  RDL を経て現在の RBS/Sorbet 期の型注釈文化の一源流であり、Rigor が RBS 上位互換を選んだ判断の下流にある。

- **日本側系譜（Steep 前史）との対。** 既存の [Matsumoto & Minamide 2010（Ruby CFA）ノート](20260518-matsumoto-2010-cfa-rigor-review.md)が
  Steep の前史（method configuration の semi-flow-sensitive CFA）を扱ったのに対し、本ノートは
  米国 Foster 研の系譜を扱う。**両系譜とも最終的に「RBS＋実用チェッカ」へ収束**し、Rigor はその合流点の下流にいる。
  method configuration（誰が見えるか＝フローセンシティブ）と rtc（実行時に実物を見る）は、
  「動的ディスパッチの可視性をどう確定するか」という同一問題への静的／実行時の二解答であり、
  Rigor の dispatcher 階層＋ `pre_eval` はその**静的近似**という位置づけが両ノートを合わせると明瞭になる。

- **継続ベンチマークとしての再訪契機.** rtc 単体は 2013 年で古く追随項目はないが、
  Foster 研系（RDL とその後継、runtime-contract × 型推論のハイブリッド）が新作を出したら、
  ADR-70 融合保護の「型契約を runtime 化して test-protection にする」中間手の実装例として再ベンチする価値がある。

---

## 6. まとめ

rtc は Rigor と**同じゴール（動くコードを壊さない Ruby 型安全）を正反対の機構で追った**
実行時型チェッカである。最大の含意は二つ。

1. **動的機能（eval/method_missing/reflection）を rtc は実行時で構造的に消し、Rigor は静的近似＋プラグインで払う**
   — これは根本トレードで、Rigor の `Dynamic` provenance アーク・`pre_eval`・マクロ基盤・self-call 解決の
   すべてが「静的を選んだ代償」であることを外から照らす（追従せず記録）。対称に、rtc が守れない
   未実行パス・未起動メタプロメソッドは Rigor の静的優位領域。

2. **二つの独立した Ruby 型システムが「`false`/`nil` の戻りアーム取りこぼし」を最高価値の実バグ形として収束させた**
   — Rigor の union-arm polarity（ADR-57）・possible-nil（ADR-58）への投資は業界前線と一致している。
   加えて rtc は「型注釈を test-protection に変換する装置」として、融合保護（ADR-70）の
   test-protected 軸に**型契約化という中間手**が存在することを歴史的に実証しており、これは記録価値が高い。

型言語（union/intersection/block/多相/tuple/alias）はほぼ等価で、rtc の `typesig` 文字列は
Rigor が上位互換とする RBS/RDL 注釈文化の直系前身。本ノートは設計コミットを持たないが、
ADR-70 の attribution 説明とハンドブックの diagnostic 例集に「rtc も同じ結論／同じ実バグ形」を
引く小改善余地を残す。

## 関連 ADR / 仕様

- [ADR-16: Macro / DSL Expansion Substrate](../adr/16-macro-expansion.md)
- [ADR-17: Monkey-Patch Pre-Evaluation](../adr/17-monkey-patch-pre-evaluation.md)
- [ADR-41: Inference Budget Design](../adr/41-inference-budget-design.md)
- [ADR-48: Data / Struct Value Folding](../adr/48-data-struct-value-folding.md)
- [ADR-57: Self-Call Return Adoption（union-arm polarity）](../adr/57-self-call-return-adoption.md)
- [ADR-58: Instance-Variable Field Typing](../adr/58-ivar-field-typing.md)
- [ADR-70: Fused Static∪Dynamic Protection Coverage](../adr/70-fused-protection-coverage.md)
- [ADR-75: Dynamic[T] Provenance](../adr/75-dynamic-provenance.md)
- [Special Types 仕様](../type-specification/special-types.md)
- [Value Lattice 仕様](../type-specification/value-lattice.md)
- [Control Flow Analysis 仕様](../type-specification/control-flow-analysis.md)

## 姉妹ノート

- [Matsumoto & Minamide 2010 (Ruby CFA) — Rigor 観点考察](20260518-matsumoto-2010-cfa-rigor-review.md)
  — 日本側の Steep 前史。本ノート（米国 Foster 研系譜）と対をなす。
- [Elixir v1.20 の漸進的集合論型システム — Rigor 観点考察](20260604-elixir-v1.20-type-system-rigor-review.md)
  — 「同ゴール・逆機構（健全 vs 非健全）」構図の別実例。
