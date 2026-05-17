# Matsumoto & Minamide 2010 (Ruby CFA) — Rigor 観点考察

Date: 2026-05-18.
Status: research note, no design commitments.
種別: 外部文献の Rigor 観点レビュー。

## 対象論文

- 松本 宗太郎, 南出 靖彦
  「Rubyプログラムの制御フロー解析とその健全性の証明」
  情報処理学会論文誌 プログラミング Vol.3 No.2, pp.9–25 (Mar. 2010)
- 出典 URL: <https://ipsj.ixsq.nii.ac.jp/records/37907>
- ローカル写し: [IPSJ-TPRO0302003.md](../../IPSJ-TPRO0302003.md) /
  [IPSJ-TPRO0302003.pdf](../../IPSJ-TPRO0302003.pdf)

## 1. 論文要旨（一段落）

Ruby のサブセット **SemiRuby**（class 定義は事前所与・`def` はクラス名・
メソッド名・定義識別子の三つ組へ簡約・block はラムダ式・`return`/`break`
は `throw`/`catch` ペアに翻訳）に対して操作的意味論を与え、その上で
**半フロー感度 (semi-flow-sensitive) な制御フロー解析** を設計する。各
プログラム点に「クラス×メソッド名 → メソッド定義」の写像である
**メソッド状況 (method configuration)** を関連付け、`def` 式の評価で
これを更新、`if` 合流で集合的和をとる。値そのものはフロー非感度、
しかし *どの定義が見えているか* はフロー感度、という非対称設計が新規性。
最後に Palsberg–Schwartzbach 型の安全性解析（未定義メソッド呼び出し
なし／`yield` の対象はラムダ式）を定義し、**保存 + Progress** で
健全性を証明する。実装は OCaml + BDDBDDB（Datalog 処理系）。

## 2. Rigor の今の設計との対応関係

| 論文側の概念 | Rigor 側の対応物 | 一致度・所見 |
| --- | --- | --- |
| **半フロー感度** という指針 | [`docs/type-specification/control-flow-analysis.md`](../type-specification/control-flow-analysis.md) のエッジ感度ナローイング、trinary certainty、fact stability | 一致。値のフルフロー感度を避けるという論文の現実主義は、Rigor の certainty/effect モデルとも整合。 |
| **メソッド状況 D = {(C,f) → d}** | Rigor の dispatcher 階層（plugin → dependency-source → bundled）+ Plugin::FactStore（[ADR-9](../adr/9-cross-plugin-api.md)） | Rigor は静的に "どの定義が見えるか" を per-walker でしか決めていない。論文の D はプログラム点ごとに動的に切り替わる点で Rigor より強力。 |
| **例1：トップレベル class A 再オープン** | [ADR-17 `pre_eval:`](../adr/17-monkey-patch-pre-evaluation.md) | 論文では半フロー感度 CFA が "x:Fixnum / y:String" を**そのまま**区別する。Rigor は同等の精度を「先に一度走らせて project-wide な ProjectPatchedMethods を作る」二段階アプローチで近似する設計。論文側の方が解析機構としては美しく、ADR-17 は工学的妥協であることが浮き彫りになる。 |
| **例2：def の中で def を上書き** | Rigor では事実上ハンドルしていない | 論文の解析はこれも精度よく解析する。Rigor は ADR-5 robustness principle（Postel 流の非対称規律）で「実務でそう頻繁には起きない」と切る側。代償として精度差は埋まらない。 |
| **例3：if 分岐内の def** | Rigor の Union narrowing | 双方とも保守的な和になる点で一致。論文も Rigor も "本質的に静的解析不可能" と同じ判断。 |
| **SemiRuby の throw/catch による return/break モデル化** | Rigor の non-local-exit 扱い（diagnostic family の制御部分） | 設計判断としては同型。 |
| **インスタンス変数 F[[l,@x]]** | Rigor のインスタンス変数推論（IVar の per-class shape） | 論文はロケーションごとに分割管理する点で Rigor より細かい。Rigor はクラス単位＋初期化文脈で抑える。 |
| **安全性解析（未定義メソッド・yield 健全性）** | Rigor の `call.method-not-found` 系（[diagnostic-policy](../type-specification/diagnostic-policy.md)） | 検査対象はほぼ同じ。Rigor は加えて `def.return-type-mismatch` 系まで踏み込むが、論文側はそこまで型を持たない（値の集合のみ）。 |
| **健全性の形式証明（保存 + Progress）** | **Rigor には存在しない** | 仕様コーパスは RFC 2119 規範だが、機械検証も操作的意味論もない。論文側がスコープを SemiRuby に絞ったからこそ証明できた事実は重要。Rigor が同等の証明を狙うなら、まず「証明可能な核 (Rigor Core)」の切り出しが先になる。 |
| **実装：OCaml + BDDBDDB (Datalog)** | Rigor：手書き Ruby 推論エンジン + ファイルベース キャッシュ（[ADR-4](../adr/4-type-inference-engine.md), [ADR-6](../adr/6-cache-persistence-backend.md)） | 論文の Datalog 化はメンテ性で美しいが、(a) RBS との結合、(b) plugin の任意 Ruby ロジック、(c) Ractor 並列化（[ADR-15](../adr/15-ractor-concurrency.md)）といった Rigor の制約とは噛み合わない。設計トレードオフの差。 |

## 3. 論文が Rigor に示唆する具体ポイント

1. **「メソッド定義の見え方だけはフロー感度」というスライス** は、
   Rigor が次に精度を稼ぐ余地の一つを明確化している。現状 Rigor は
   `:leaf` 規律 + [ADR-17](../adr/17-monkey-patch-pre-evaluation.md) の
   事前評価でほぼ静的に決めてしまうが、**部分的にプログラム点単位の
   "method configuration" を持つ** という中間案は理論的に正当化可能だと
   本論文は示している。実装コストとキャッシュ整合性（ADR-6）次第。

2. **ADR-17 の MVP（明示的ファイル列挙）で十分か** の議論補強材料に
   なる。論文の例1のような top-level 上書きはまさに ADR-17 のユース
   ケースで、論文は「半フロー感度 CFA で解ける」と示している。
   つまり ADR-17 の "explicit list" 路線は精度の下限を確実に押し上げる、
   安価で正しい第一歩であると追認される。

3. **健全性証明の不在** は Rigor の戦略的な空白として残っている。論文と
   同じく **コア + 外周** の二層構造（SemiRuby ↔ Ruby 全体）を取れば、
   Rigor も "Rigor Kernel" だけは保存・Progress を狙えるはず。これは
   現時点で [ROADMAP](../ROADMAP.md) にも入っていないが、長期で価値の
   高いトラックである。

4. **本論文の第一著者 = Soutaro Matsumoto = Steep の作者** という事実は、
   Rigor が Steep 互換性（[ADR-8](../adr/8-steep-inspired-improvements.md)）
   と RBS 上位互換に置いている重みを再確認させる。Steep の現代的な実装の
   系譜的前史をこの論文に見ることができる：method configuration が
   Steep の中では subtyping + global env のサニタイズで隠蔽されている、
   という比較は単独でメモ価値がある。

5. **block を lambda、return/break を throw/catch に翻訳する SemiRuby の
   スタイル** は、[ADR-16](../adr/16-macro-expansion.md) のマクロ展開
   基盤 Tier A（block-as-method）の意味論基礎としてそのまま流用できる。
   SemiRuby の意味論を Tier A の「正しさ」の定義に採用する選択肢は
   検討に値する。

## 4. まとめ

論文は Rigor の **「メソッド定義の動的性 vs 静的解析」** という最大級の
根本問題を、SemiRuby という最小核に絞ることで形式的に解いて見せた成果
である。Rigor は工学的にはより広い Ruby 表面をカバーしているが、
(a) `pre_eval` のような事前評価による近似に頼っており、(b) 健全性の
機械的証明を持たない。論文の半フロー感度 CFA とその健全性証明は、Rigor
の **将来の "Rigor Kernel" 切り出し** と **method configuration を部分
採用するナローイング強化** の両方向に、信頼できる出発点を提供している。

## 関連 ADR / 仕様

- [ADR-5: Robustness Principle](../adr/5-robustness-principle.md)
- [ADR-8: Steep-Inspired Improvements](../adr/8-steep-inspired-improvements.md)
- [ADR-15: Ractor Concurrency](../adr/15-ractor-concurrency.md)
- [ADR-16: Macro / DSL Expansion Substrate](../adr/16-macro-expansion.md)
- [ADR-17: Monkey-Patch Pre-Evaluation](../adr/17-monkey-patch-pre-evaluation.md)
- [Control Flow Analysis 仕様](../type-specification/control-flow-analysis.md)

## 姉妹ノート

- [Matsumoto & Minamide 2008 (Polymorphic Record 型) Rigor 観点考察](20260518-matsumoto-2008-poly-records-rigor-review.md)
  — 同著者の 2008 年論文（本論文の参考文献11）の Rigor 観点レビュー。
