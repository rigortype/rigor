# Matsumoto & Minamide 2008 (多相レコード型 Ruby 型推論) — Rigor 観点考察

Date: 2026-05-18.
Status: research note, no design commitments.
種別: 外部文献の Rigor 観点レビュー。

## 対象論文

- 松本 宗太郎, 南出 靖彦
  「多相レコード型に基づくRubyプログラムの型推論」
  情報処理学会論文誌: プログラミング Vol.49 No.SIG 3 (PRO 36),
  pp.39–54 (Mar. 2008)
- 出典 URL: <https://ipsj.ixsq.nii.ac.jp/records/16465>
- ローカル写し: [IPSJ-TPRO4903005.md](../../IPSJ-TPRO4903005.md) /
  [IPSJ-TPRO4903005.pdf](../../IPSJ-TPRO4903005.pdf)

## 1. 論文要旨（一段落）

ML の型システムに Garrigue のカインド付き多相レコード型 (maskable fields
付き) を載せて、Ruby プログラムの型推論ツールを設計・実装した。オブジェクト
型は `α :: (L, U, R) ▷ α` の三つ組カインドで表現し、`L` は要求メソッド
集合、`U` は定義メソッド集合、`R` はメソッド名→関数型の関係述語。
インスタンス変数は Tofte の **命令的型変数 (`_β`)** で扱い、多相性を抑制
して副作用との健全性を保つ。組込みクラスは独自のシグネチャ言語
(`def m :: C → C'`) で記述し、Ruby のクラス再オープン文化に合わせて
**シグネチャと Ruby 実装が同一クラスに共存** する型システムを設計。
負の位置 (引数) はシグネチャのみから、正の位置 (返り値) はシグネチャ
+ Ruby 定義の両方から型を構築する非対称設計を採用。多相再帰
(Array/String/Integer の相互再帰) と `map` のような正則でない多相
メソッドは **クラス定義の有限回展開 (複製)** で近似する。実装は OCaml +
改造 NodeDump、Ruby 1.8.5 サンプル 39 本中 21 本を型推論可能
(`list.rb`：80 行で 1.26 秒、ただし束縛型変数数 **57,479 個**)。健全性は
「Ruby のごく制限されたサブセットでのみ成立する」設計と明言。

## 2. Rigor の今の設計との対応関係

| 論文側の概念 | Rigor 側の対応物 | 一致度・所見 |
| --- | --- | --- |
| **シグネチャ言語 `def m :: C → C'`** | [RBS（およびその Rigor 上位互換）](../type-specification/rbs-compatible-types.md) | 本論文は RBS 標準化 (2020年頃) の 12 年前。事実上の **RBS 前史**。同じく "Ruby プログラム本体に型は書かない／シグネチャを別途与える" という分離戦略は同じだが、RBS は `.rbs` ファイル分離、本論文は同一クラスへの共存という構文上の違い。 |
| **多相レコード型 + Garrigue カインド** | RBS の **公称型 + interface 部分構造** ハイブリッド | Rigor は **公称型優位**。多相レコード型の構造的アプローチは取らない。論文が苦しんだ「型表記が肥大化する／57k 型変数」問題は、RBS が公称名を前面に出すことで概ね回避できている。これは Steep 時代に同著者がたどり着いた工学的結論と整合。 |
| **命令的型変数 (IVar の多相制限)** | Rigor の per-class IVar shape + initialization tracking (仕様は [internal-spec](../internal-spec/inference-engine.md)) | 問題領域は完全に同じ：副作用持つ ivar を多相に汚染させない。論文は Tofte 流の型変数分類、Rigor は per-class shape の固定化＋カインド分離なしの実装で対処。**論文の解は理論的に綺麗、Rigor の解は実用的に十分**、というトレードオフの違い。 |
| **正の位置／負の位置の非対称扱い** | [ADR-5 ロバストネス原則](../adr/5-robustness-principle.md) | これは興味深い**正味同方向**の非対称性。論文「呼び出し側に課す要求 (負位置) は少なめ、提供側として認める実装 (正位置) は寛大に」。Rigor「引数 (負位置) は寛容、返り値 (正位置) は厳格」。**呼ぶ側に楽をさせる側**は両者一致、**返り値側の厳格／寛容の向き**が逆だが、これは「型推論ツールとして引っかかりを減らしたい (論文)」vs「型カタログとして信頼を作りたい (Rigor)」という目的差から自然に出てくる差。Rigor がロバストネス原則を選んだ正当化材料として、本論文の対義設計と比較するメモは [ADR-5](../adr/5-robustness-principle.md) に追記する価値がある。 |
| **多相再帰の "クラス展開" 対応** | RBS の宣言済み公称型 + 個別ジェネリクス | 論文では Array/String/Integer の相互再帰が単相に潰れ、誤検出を生むため `Array#0`/`Array#1` のように **手で展開**。Rigor 側はそもそも RBS が `class Array[Elem]` を最初から多相で宣言できるので構造的な単相崩壊が起きない。Rigor が「**手書き RBS (および将来 sig-gen) を信頼する**」 ([ADR-14](../adr/14-rbs-sig-generation.md), [AGENTS.md § RBS Authorship](../../AGENTS.md)) と決めている理由の傍証。 |
| **`map` の正則でない型 (多相再帰 + 多相メソッド)** | RBS の `def map: [U] () { (Elem) -> U } -> Array[U]` | 論文は表現不能で「結果配列の要素型 = 入力配列の要素型」と保守的に近似 → 実用例 `[1,2,3].map{|x|x.to_s}.map{|x|(x+"0").to_i}` で誤検出。RBS (Rigor) は自然に書ける。**ML 型推論の限界が公称ジェネリクスでの宣言主義に押し出された理由**を本論文が明示している。 |
| **異種混合コレクション** | Rigor の Union 型 ([value-lattice.md](../type-specification/value-lattice.md)) | 論文は要素型を「共通フィールドのみ持つ構造型」で扱う (フィールドアクセス可、識別不可)。Rigor は Union (識別可、絞り込み必要)。Union の方が **narrowing/refinement と相性が良い**、Garrigue 流の方が **アクセスの自由度が高い**、というのが本質的な差。Rigor が control-flow narrowing を重視する設計なので Union 寄りで正解。 |
| **`as(Integer)` キャスト案** (§7) | RBS::Extended の `%a{rigor:v1:assert_type ...}` / `%a{rigor:v1:return_override ...}` ([rbs-extended.md](../type-specification/rbs-extended.md)) | **同方向の発想が 12 年の隔たりを超えて再合流**している。論文の「`as` メソッドはランタイムでは何もしない・型推論側にだけ意味を持つ」設計は、Rigor の predicate / assertion annotation と完全に同じ哲学。 |
| **健全性に対するスタンス** | Rigor の "RFC 2119 仕様＋実装は実用優先" | **完全一致**。論文「実用的な Ruby プログラムへの対応を理論的正当性より優先」。Rigor 「robustness principle を採用、機械化された健全性証明は持たない」 ([ADR-5](../adr/5-robustness-principle.md), [implementation-expectations.md](../internal-spec/implementation-expectations.md))。同著者の 2010 年 CFA 論文 ([姉妹ノート](20260518-matsumoto-2010-cfa-rigor-review.md)) でだけ証明を与えていたのは、対象を SemiRuby に絞れたからこそ。 |
| **varargs を扱えない** | RBS の `*args: T` / `**kwargs: T` ネイティブサポート | 論文では `print` を手で `print1`/`print2`/`print3` に分割していた。RBS 言語の表現力が **何を解決したのか** が具体的に見える例。 |
| **エラー出力が内部表現の生 dump (§7課題)** | Rigor の diagnostic policy / family hierarchy ([diagnostic-policy.md](../type-specification/diagnostic-policy.md), [ADR-8](../adr/8-steep-inspired-improvements.md)) | 同著者がこの問題を**早期から認識**していたことが分かる。Steep 〜 Rigor の長年の投資が診断 UX に集中している直接の系譜。 |
| **クラス継承の "親メソッドのコピー" 実装** | Rigor / RBS の lookup チェーン | 論文の実装単純化のための妥協。Rigor は Ruby の真の継承探索を保ったまま解析を回せる (identity 維持)。 |

## 3. 論文が Rigor に示唆する具体ポイント

1. **「型変数が万単位に爆発する」現象の証拠** として、本論文の `list.rb`
   結果 (束縛型変数 57,479 個) は引用価値が高い。Rigor が **構造的多相
   レコードを採用しなかった選択** の正当化材料として、
   [ADR-1](../adr/1-types.md) もしくは [ADR-3](../adr/3-type-representation.md)
   に脚注を入れられる。

2. **ADR-5 ロバストネス原則の対照例** として、本論文の「負位置は
   シグネチャのみ・正位置は実装も含める」設計は、**同じ "非対称性を
   入れる" という方針の別解** である。Rigor が選んだ方向と論文の方向の
   対比を、[ADR-5](../adr/5-robustness-principle.md) または
   [`docs/type-specification/robustness-principle.md`](../type-specification/robustness-principle.md)
   の "Why this asymmetry, not the other" 節として整理する余地がある。

3. **`as(klass)` キャストと Rigor の `%a{rigor:v1:assert_type}` の系譜的
   近さ** は、Rigor の RBS-extended アノテーション設計の正当化材料。
   同じ著者が 12 年隔てて同じ結論に達している事実は、設計選択の頑健性を
   示す。

4. **多相再帰の手動展開アプローチ** は Rigor の sig-gen
   ([ADR-14](../adr/14-rbs-sig-generation.md)) のスコープ判断に示唆を
   与える：完全自動な多相再帰解析を狙うのではなく、**公称ジェネリクス
   の宣言コストを開発者に払ってもらう代わりに、推論側はその宣言を絶対視
   する**という Rigor の戦略は、本論文が機械的な解として持ち込んだ
   「クラス複製展開」を **人間 (ライブラリ作者) に肩代わりさせている**
   構造として理解できる。

5. **健全性証明の戦略的不在** が、同著者の 2008 → 2010 → Steep → 現在
   という流れの中で**一貫した工学的判断**であることを本論文が裏付ける。
   Rigor が同じ判断を継承しているのは正統な路線にあり、独自に弁護する
   必要はない。

6. **Steep への系譜の起点** として、本論文 → CFA 論文 → Steep → RBS と
   いう流れの第一段がここにある。RBS の表現力 (公称ジェネリクス・
   varargs・block 引数・多相メソッド) は、すべて **本論文が ML+カインド
   では表現できなくて困った場所** に対応している。RBS の設計理由を
   読み解くための「失敗ケース集」として価値が高い。

## 4. まとめ

論文は、Ruby を ML 流の構造的多相レコード型で型付けする試みが、
**多相再帰・多相メソッド・varargs・健全性・型表記サイズ** という五つの壁
に同時にぶつかることを実証的に示した。Rigor は同じ著者の系譜の延長線上
にあるが、これらの壁を **RBS という別の選択肢** (公称型優位 + 宣言主義
+ plugin による拡張 + 部分構造の interface) で迂回している。本論文は、
Rigor が **なぜ Garrigue 風の構造的型推論を採らないか・なぜ RBS 互換を
最優先するか・なぜ完全健全性を狙わないか** という設計判断の **歴史的な
妥当性検証** として読める一級の資料である。特に [ADR-1](../adr/1-types.md),
[ADR-5](../adr/5-robustness-principle.md),
[ADR-14](../adr/14-rbs-sig-generation.md), そして RBS-extended
アノテーション仕様の **背景文献として明示引用するのに最適**。

## 関連 ADR / 仕様

- [ADR-0: Concept](../adr/0-concept.md)
- [ADR-1: Type Model and RBS Superset Strategy](../adr/1-types.md)
- [ADR-3: Internal Type Representation](../adr/3-type-representation.md)
- [ADR-5: Robustness Principle](../adr/5-robustness-principle.md)
- [ADR-8: Steep-Inspired Improvements](../adr/8-steep-inspired-improvements.md)
- [ADR-14: RBS Signature Generation](../adr/14-rbs-sig-generation.md)
- [RBS::Extended アノテーション仕様](../type-specification/rbs-extended.md)
- [Robustness Principle 仕様](../type-specification/robustness-principle.md)

## 姉妹ノート

- [Matsumoto & Minamide 2010 (Ruby CFA) Rigor 観点考察](20260518-matsumoto-2010-cfa-rigor-review.md)
  — 同著者の 2010 年論文 (本論文の続編に当たる CFA 論文) の Rigor
  観点レビュー。
