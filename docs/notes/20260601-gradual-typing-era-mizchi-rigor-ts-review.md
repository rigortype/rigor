# 「漸進的型付け言語の時代に必要なもの」(mizchi) — Rigor / TypeScript 観点考察

Date: 2026-06-01.
Status: research note, no design commitments.
種別: 外部論説の Rigor / TypeScript 観点レビュー。
三部作(外部論説 × 既存言語への型後付け):
- [20260601-type-system-poem-rigor-review.md](20260601-type-system-poem-rigor-review.md)(myuon「型システムポエム」)
- [20260601-revenge-of-the-types-runtime-checker-survey.md](20260601-revenge-of-the-types-runtime-checker-survey.md)(Armin Ronacher「Revenge of the Types」)
- 本ノート(mizchi「漸進的型付け言語の時代に必要なもの」)

## 対象論説

- mizchi「漸進的型付け言語の時代に必要なもの」(2018-07-05)
- 出典 URL: <https://mizchi.hatenablog.com/entry/2018/07/05/180219>

TypeScript / TypedCoffeeScript の実体験から「これからの gradual typing に
何が要るか」を要件として書き出した実務寄り論考。**Rigor(2026, Ruby)は
この2018年要件リストの後発実装**にあたるため、「mizchi の要件を Rigor が
どれだけ満たしたか / TypeScript はどう答えたか」の三者突き合わせで読む。

## 0. 枠組みと結論(先出し)

mizchi の主張を「将来の gradual typing への要件」R1〜R9 + 補(LSP)に割り、
TypeScript(記事の母体)と Rigor(後発の Ruby 版)の回答を並べる。

組織化テーゼ:

> **mizchi の要件リストに対し、Rigor は「2018年に欲しいと言われたものを
> Ruby で律儀に作った」ように読める。** 最大の分岐点は **「型をどこに置き、
> 表現力をどこまで許すか」**。TypeScript は型を**ソース内**に置き表現力を
> **無制限**に伸ばした(結果、mizchi が恐れた"型パズル"が現実化)。Rigor は
> 型を**ソース外**に置き表現力を**予算で頭打ち**にした(パズル回避、ただし
> 精度の天井は低い)。これは mizchi の「コンパイラ向け vs 人間向けの区別」
> という核心問題への、TS と Rigor の**正反対の解**。

## 要件別マッピング

### R1. 握りつぶし可能性(設計に組み込め)
`declare module "a"` で無視、興味のある範囲に限定 — mizchi の中核。

- **TypeScript**: `// @ts-ignore` / `@ts-nocheck` / `@ts-expect-error`(3.9)/
  `any` / `skipLibCheck` / tsconfig `exclude`。行・ファイル・プロジェクト単位。
- **Rigor**: 抑制マーカー(diagnostic-policy)+ **ADR-22 ベースライン
  (`.rigor-baseline.yml`)が握りつぶしを制度化**。既存の動く状態を丸ごと採用し
  **回帰だけを surface**。2018 TS の行単位 ignore より一段強い「0を1の苦しみ」
  緩和で、握りつぶし戦略の最も institutionalized な形。
- → **Rigor が 2018 TS より良く答えている**項目。

### R2. 環境で厳しさを調整できる
- **TypeScript**: tsconfig フラグ(`strict`/`strictNullChecks`/`noImplicitAny`)。
  mizchi の要望にほぼ応えた。
- **Rigor**: `.rigor.yml` の `severity_profile:`、ルール単位 severity、v1 の
  narrowing surface を意図的に絞る設計。同等に調整可能。

### R3. 「コンパイラ向け」と「人間向け」の型を区別せよ(最深の主張)
- **TypeScript**: 型は**ソース内(.ts)**で両者を兼ね、実行時消去。co-located な
  「ドキュメントとしての型」。
- **Rigor**: 型を**ソース外(RBS/生成スタブ)**に出し、アプリ本体に独自 DSL を
  入れない(ADR-0 "AI-Native Purity")。`.rb` を人間/AI が読むクリーンな面、
  RBS を機械契約の面に分離するという明示的回答。2018 の mizchi が「人間の
  ためのドキュメント」を強調したのに対し、2026 の Rigor は **AI 読者を一級の
  消費者**に加える(時代の延長)。
- → **トレードオフ**: mizchi が評価したのは「コードの隣にある型=ドキュメント」。
  Rigor の外部 RBS は co-location を失う。Rigor は **rbs-inline 受理**
  (`#: String` 等を型ソースに)で部分回収し、外部 .rbs と inline の両建て。

### R4. 外部 IO 境界の処理(出口で any、内部は厳密、ラップ層)
- **TypeScript**: 標準実務。記事と同月(2018-07)の TS 3.0 で **`unknown`** が
  入り「境界で受けて検証してから内へ」の原理版(zod 等)へ発展。
- **Rigor**: **robustness 原則が同じ形を型オーサリング側で形式化** — 引数は
  緩く(境界の寛容)/戻り値は厳しく(内部の精度)。さらに **`Dynamic[T]` は
  provenance を持つ**ので「any にキャスト(=由来を捨てる)」より進み、
  **「untyped だが何を知っていたかは覚えている」**。JSON.parse の
  `symbolize_names` 判別 / ActiveRecord `open_receivers` / プラグイン facts が
  Ruby 側の IO 境界を埋める。

### R5. any = Top∧Bottom の逃げ道、守るかは自己責任
- **TypeScript**: `any` がまさにそれ(unsound な脱出口)。
- **Rigor**: `Dynamic[T]` が gradual fallback。T の精度と由来を運ぶラッパで
  境界で可逆(value-lattice の Dynamic 代数)。**ユーザがソースに書く `any` DSL は
  存在しない**(inline DSL なし)— 逃げ道はエンジン内部 + RBS `untyped`。
  「自己責任の any」の表面積を provenance で減らす。

### R6. 推論が動的型付けと同じ見た目に
- **TypeScript**: mizchi が「見た目上は動的型付けと同じものを書ける」と評価。
- **Rigor**: **推論ファーストを TS より極端に振る**。TS は関数境界/公開 API に
  注釈を欲しがるが、Rigor は CFA + 呼び出し点合成でユーザメソッドの
  シグネチャまで推論し**ソース内注釈ゼロを目標**にする。ただし **Ruby の
  メタプログラミングは JS より推論が難しい**ので、TS なら推論で埋まる所が
  Rigor では `Dynamic[T]`/プラグインに落ちる余地が大きい。野心は上、地形は険しい。

### R7. 型パズルの罠(表現力が裏目に出る)
mizchi が名指しした Flow Redux connect、Generics 過剰、型表現の非一意性。

- **TypeScript**: 記事直後から conditional types(2.8)/mapped/template literal
  types が拡張され**型レベルがほぼチューリング完全化 → 型パズルが現実化**。
  `.d.ts` はパズルの代名詞に。
- **Rigor**: **意図的な学習**。false-positive 規律 + 「複雑な型は `.rbs` へ、
  ソースに書かせない」+ **inference-budgets(無制限な型レベル計算を禁じる
  予算)** が型パズルの直接の抑止。ADR-20 HKT が「**lightweight**」なのも
  パズル回避が理由。**2018 の教訓を取り込み表現力をわざと頭打ち**にした。
- → **代償**: combineReducers 級の精度は表現できない。複雑性は**プラグイン
  (Ruby で書くエンジン側)に移す** — 難所をユーザの型パズルでなくプラグイン
  作者の仕事に。**「パズルをユーザソースからエンジンへ追い出した」**のが
  TS との分水嶺。

### R8. ライブラリ型定義管理の地獄(DefinitelyTyped)
- **TypeScript**: `@types/*` 生態系。成熟したが依然痛点、近年は自前 types
  同梱が増加。
- **Rigor**: RBS 生態系(gem_rbs_collection)+ プラグイン catalogue +
  **`rigor sig-gen`(手書きでなく生成)** + ADR-25 プラグイン提供 RBS。手は
  **「巨大な手書き型定義リポジトリでなく推論+生成に寄せる」**。sig-gen の穴
  こそ価値あるシグナル、という方針。Rails 等の枠組みメタプロは全ユーザが
  再導出せず保守されたプラグインが担う。

### R9. 後発言語への提言(構文予約のみ/握りつぶしを設計に/コミュニティ実装)
- **Rigor は2026年の具体的実現**。Ruby 構文に**何も足さず**、RBS(外部)+
  既存 rbs-inline/Steep 注釈を使う。「構文予約のみ」を通り越して**予約ゼロ**で
  over-satisfy。握りつぶしはベースラインで設計済み。**mizchi の2018年
  ウィッシュリストを Ruby でほぼ逐条実装した姿**。

### 補. LSP / 静的解析メタデータの重要性
mizchi が2018に強調。Rigor は ADR-19 `rigor lsp` + **ADR-33 `rigor mcp`
(AI 消費者向け)** を備え、見越された LSP メタデータ層に **2026年的拡張
(MCP)** を足す。

## 総括

- **R1/R2/R4/R6/R7/R9/LSP** は Rigor が律儀に、時に 2018 TS より良く満たす。
  Rigor は「mizchi が必要と言ったもの」の Ruby 版実装として読める。
- **最大の分岐は R3 + R7 の解き方**:
  - TypeScript = 型を**ソース内**・表現力**無制限** → co-location は得たが
    **型パズルが現実化**。
  - Rigor = 型を**ソース外**・表現力**予算で頭打ち** → パズル回避し `.rb` を
    クリーンに保つが**精度の天井が低く** co-location を失う(rbs-inline で部分回収)。
  - mizchi の「コンパイラ向け/人間向けを区別せよ」への**正反対の回答**で、
    優劣でなく賭けの違い。
- **mizchi が Rigor に突っ込みそうな点**: ①外部 RBS は「コードの隣の
  ドキュメント」性を弱める。②Ruby のメタプロは JS より推論が難しく
  「動的と同じ見た目」の推論に TS より穴が出やすい(Dynamic/プラグイン依存増)。
- **Rigor が2018年から前進した点**: ①`Dynamic[T]` provenance(由来を捨てる
  any からの脱却)。②ベースラインによる握りつぶしの制度化。③型パズルを
  ユーザソースからプラグインエンジンへ追い出す構造。④AI/MCP を型メタデータの
  一級消費者に。

ひとことで — **mizchi が2018年に「これからの漸進的型付けに要る」と並べた
条件を Rigor は2026年の Ruby で大半満たしている。ただし彼が最後まで悩んだ
「型をどこに置き表現力をどこまで許すか」だけは TypeScript と真逆(ソース外・
予算で頭打ち)を選んでおり、それが Rigor の個性であり同時に精度上限の
出どころになっている**。
