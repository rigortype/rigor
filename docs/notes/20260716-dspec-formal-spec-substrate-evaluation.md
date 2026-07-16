# mizchi/dspec — 形式仕様基盤としての評価 + トレーサビリティ規律の移植検討

Date: 2026-07-16.

Status: **research note, no design commitments.**

種別: 外部ツール調査 + Rigor への移植可能性評価 + 形式手法(Lean 4 / Alloy)の
テストオラクル利用評価。
関連: [20260601-gradual-typing-era-mizchi-rigor-ts-review.md](20260601-gradual-typing-era-mizchi-rigor-ts-review.md)
(同一著者の論説レビュー)。

**このノートの実測成果**(調査の副産物だが本体より重要):
`docs/type-specification/special-types.md` の **`void` 節が丸ごと未実装**であることを
発見(§ P1)。2 つの MUST を含む節が現在形で規定する挙動に対し、実装は
`Bases::Void => :translate_untyped`。ADR-1 が名指しで予見していたリスクが実現し、
どのゲートにも映らずに残っていた。

## 対象

- リポジトリ: <https://github.com/mizchi/dspec>
- 調査時 HEAD: `8136008`(2026-07-16 に取得)
- 規模: 16 コミット / 2026-07-13〜2026-07-15 / 単独作者(mizchi, 一部 Kotaro Chikuba 名義)
- 自称: "Typed Pkl prototype for a human-level executable specification language"
- 実装量: `dspec/Schema.pkl` 790 行(型付き authoring 面)、`src/cli.mjs` 14,281 行
  (検査系)、`src/core/clause-ast.mjs` **91 行**(形式意味論の全量)

**注意(方法論)**: `--depth 1` クローンでは全コミットが最新日付・単一著者に潰れて
見える。上記の年齢・著者数は `--unshallow` 後の実測。浅いクローンからリポジトリの
成熟度を読むと、ADR-82 の group-dominant 集計と同じ種類の測定アーティファクトになる。

## 結論(先出し)

二段構えの評価:

> **形式的記述の基盤としては不適合。** Clause AST が無解釈アトム上の命題論理断片で
> しかなく、型・帰納的定義・推論規則という Rigor の仕様に必須の語彙を持たない。
> `T <: U` を書いても `atom("subtype", ["T","U"])` にしかならず、バックエンドが
> 検証できるのはその上のトートロジーだけになる。
>
> **一方、"support の認識論" は移植価値がある。** dspec の本当の発明は形式手法では
> なく、**主張(Rule)と根拠(CheckTarget)の距離を型付きで宣言させ、リンク切れ
> (drift)と未検証(coverage)を機械的に落とす**規律。Rigor はこの規律を診断
> (ADR-65 evidence_tier)とユーザコード(ADR-63/70 protection coverage)には
> 持っているが、**自分自身の規範仕様には持っていない**。
>
> **そして穴は実在した(P1、本ノートで実行)。** `special-types.md` の probe で
> **`void` 節が丸ごと未実装**であることが判明 — 2 つの MUST を含む節が現在形で
> 規定する挙動に対し、実装は `Bases::Void => :translate_untyped` で void を潰して
> いる。ADR-1 が「void が早々に broad alias 扱いされるリスク」として**名指しで
> 予見していた失敗が、そのまま実現して残っていた**。どのゲートにも映らないのは、
> Rigor のゲートが全て FP 指向(鳴るべきでないものが鳴る)で、**未実装の診断=沈黙**
> だから。詳細は下記 P1。

## dspec とは何か

Pkl を authoring 面(型付き文書検証)、Node CLI を検査面とする。モデルの中核:

- `Term`(語彙、ja/en ローカライズ)+ `Rule`(`permission` / `prohibition` /
  `obligation` / `invariant` / `transition` の種別、`when` / `must` / `mustNot` 節)
  + `Decision`(追記専用の設計履歴 = ADR 相当)
- `CheckTarget` / `ImplementationRef` — ルールをテストアンカー・実装シンボルに紐付け、
  `drift` コマンドが解決可能性を常時検査
- **assurance 階層**: `reference` / `executed` / `mutation-tested` / `bounded` /
  `proved`。強い主張にはダイジェスト付き evidence manifest を要求(全順序ではなく
  集合 — mutation testing と bounded model checking は別の問いに答えるため)
- `spec-change compat` — 仕様 before/after を `compatible` / `breaking` /
  `narrowing` / `widening` / `unknown` に分類
- `spec-reading-eval` — 正解ラベル(`entailed` / `contradicted` / `not-supported`)
  付きゴールドセットで「LLM が仕様を正しく読めるか」を採点
- ドメインパック(`db` / `cloud` / `data` / `release` / `runtime`)+ Markdown /
  QuickCheck / TLA+ / Alloy / Lean への決定的射影

## 形式基盤としての評価 — なぜ不適合か

### 1. Clause AST が貧弱すぎる

`src/core/clause-ast.mjs` の全演算子は
`atom | eq | neq | not | and | or | implies | exists | forall` のみ。
`atom` は**文字列引数上の無解釈述語**、`eq`/`neq` は `Object.is` による記号比較。
型・帰納的定義・推論規則・再帰は表現語彙に存在しない。

Rigor の中核仕様 — `value-lattice.md` の束恒等式、`relations-and-certainty.md` の
`<:` と gradual consistency、`control-flow-analysis.md` の edge-aware narrowing — を
書こうとすると、すべて無解釈アトムの羅列に落ちる。**アトムの意味はバックエンドから
見えない**ので、検証できるのは「アトム間の命題論理的含意」だけになる。

### 2. semantic な検証パスが Lean の等式断片しかない

dspec 自身が `ClauseBackendSupport = unmapped | textual | structural | semantic` と
いう率直な適用可能性マトリクスを持ち、そこでの自己申告が:

- **Lean**: `eq` / `neq` / `not` / `implies` のみ semantic。`atom` / `and` / `or` /
  量化子は structural
- **TLA+**: textual(文字列)
- **Alloy**: unmapped
- 自己モデルの `bounded` / `proved` ターゲットは **ゼロ**

README の自己記述が最も正直:

> "This proves the Clause proposition, not the behavior of application code."

つまり生成 Lean が証明するのは `ClauseEnv` 上の Clause 命題であって、対象システムの
振る舞いではない。**Rigor が形式化したいのはまさに後者**。

### 3. 実務コスト

Pkl + Node 24 + pnpm を Ruby/Nix リポジトリに持ち込むコスト。生後 3 日・単独作者・
互換性保証なしのプロトタイプ(README が pre-release を明言、削除コマンドは alias を
残さず unknown として弾く方針)。ドメインパックは完全に DevOps 指向(cloud / data /
release / runtime)で型理論とは無縁。

### 4. 代替の方が強い

型意味論を本当に形式化するなら **Lean 4 を直接**(束恒等式・narrowing の健全性)、
有界検査なら **Alloy を直接**使う方が、dspec の Clause AST を経由するより表現力・
証明力とも桁違いに上。dspec はその場合「Lean ファイルへのポインタ登録簿」以上には
ならない。

## 移植価値のある規律 — 対応表

| dspec | Rigor の既存対応物 | ギャップ |
| --- | --- | --- |
| Rule の安定 id + `drift`(リンク切れ検査) | 仕様コーパスの RFC 2119 文言 | 規範節 → spec の機械可読リンクが**ない** |
| `coverage`(approved rule は自動チェック必須) | `spec/docs/`(user docs のみ)、RuleCatalog 完全性 spec | 規範節単位のカバレッジは**ない** |
| assurance 階層(reference / executed / … / proved) | ADR-65 evidence_tier(診断)、ADR-63/70 protection coverage(ユーザコード) | **自分の規範仕様に対しては未適用** |
| `spec-change compat`(breaking/narrowing/widening) | ADR-50 互換性契約(人手運用)、ADR-50 WD7 / ADR-77 WD2 `rigor upgrade`(accepted・deferred) | 機械分類は既存 deferred 作業に合流 |
| `spec-reading-eval`(LLM の仕様読解採点) | ADR-73/74 skills + llms.txt、[ACP 13 モデル検証](20260620-opencode-acp-cross-model-validation.md)(*振る舞い*の評価) | *読解*のゴールドセット評価が**ない** |
| `Decision`(追記専用履歴) | ADR コーパス + ADR-49 ルーブリック | Rigor の方が成熟 |

## Rigor 側のギャップ実測(2026-07-16)

規範コーパスの規模(規範キーワード `MUST`/`MUST NOT`/`SHOULD`/`SHOULD NOT`/`MAY` の
**出現数** — 散文中の用法も含むので、独立した規範節数の上限値):

| コーパス | 出現数 | ファイル数 |
| --- | --- | --- |
| `docs/type-specification/` | 289 | 17 |
| `docs/internal-spec/` | 547 | 17 |

これに対する機械的リンクの実態:

- `spec/docs/` は 3 spec(`handbook_snippets_spec.rb` / `link_integrity_spec.rb` /
  `manual_drift_spec.rb`)で、**すべて user-facing docs(manual + handbook)専用**
- `spec/` 全体から `type-specification` を参照するのは **1 箇所のみ**、しかも
  integration fixture の `demo.rb` 内の偶発的言及
- CLAUDE.md は「spec binds」と宣言しているが、**規範コーパスが engine から乖離しても
  落ちるゲートは存在しない**

**先例は既にある**: `manual_drift_spec.rb` は CLI サブコマンド / config キー /
rule ID / `documentation_url` アンカーの 4 軸で、まさに dspec の drift と同じ形
(「実装側の集合と文書側の集合が一致すること」)を実装済み。規範コーパスへの拡張は
新アーキテクチャではなく**既存パターンの延長**。

## 実践案

全 836 出現に id を振る「完全レジストリ」は**推奨しない** — 散文 MUST の多くは
原子的にテスト可能な命題ではなく(オーサリング規約や説明的用法を含む)、id を振って
coverage ゲートを立てると、実質を伴わない `reference` リンクを量産して **false
assurance** になる。dspec が `reference` と `executed` を型で区別しているのは、まさに
この失敗を知っているから。

代わりに、Rigor 自身の方法論(ADR-62 の adjudicate-don't-assume、ADR-49 の
measurement-gated defaults)に従い、**機械を作る前に穴の実在を測った**。その結果
(P1)が、作るべき機械の形を汎用レジストリより遥かに狭く決めた(P1')。

### P1(実行済み — 穴の実在を確認): `special-types.md` の probe

`docs/type-specification/special-types.md`(小規模、core semantics、高 stakes、
ADR-75/82/83 が繰り返し触る領域)を対象に、規範節ごとに「これを engine が守らなく
なったとき赤くなる spec が存在するか」を probe した(2026-07-16、全 14 節の完全裁定
ではなくカバレッジ probe)。

**結果 — `void` 節が丸ごと未実装。しかもどこにも記録されていない。**

`special-types.md` § `void`(L66-92)は現在形で以下を規定する:

> `void` is **not** an ordinary value type in Rigor. It is a result marker …
> **Rigor keeps `void` distinct internally so it can diagnose value use**
> - In value context, a `void` result **MUST** produce a primary "use of void value"
>   diagnostic and is materialized as `top` for downstream recovery.
> - When imported RBS places `void` in a generic slot, Rigor **MUST** preserve the slot.
> - `void | bot` normalizes to `void` in result summaries.

実装([`lib/rigor/inference/rbs_type_translator.rb:51`](../../lib/rigor/inference/rbs_type_translator.rb)):

```ruby
RBS::Types::Bases::Void => :translate_untyped,
```

**`void` は RBS 境界で `untyped`(= `Dynamic[top]`)に潰されている。** 実測:

| 仕様の要求 | 実装 |
| --- | --- |
| `void` を内部で区別 | `Type::Void` carrier 不在(`lib/rigor/type/` になし) |
| "use of void value" 診断(MUST) | rule id ゼロ。`lib/` `spec/` とも文字列ヒット 0 |
| generic slot 保存(MUST) | 変換時に消滅 |
| `void \| bot` → `void` 正規化 | 正規化対象の `void` が存在しない |
| 値文脈で `top` に materialize | `Dynamic[top]` になる(= 検査されない) |

**記録状況**: ROADMAP / CURRENT_WORK / CHANGELOG に void 意味論の保留記録は**なし**
(ヒットは全て RBS シグネチャ中の `-> void`)。`special-types.md` 自身にも
"not yet" / "planned" 等の保留マーカーは**なし**。internal-spec に `Void` carrier の
規定も**なし**。

**しかも ADR-1 がこの失敗を名指しで予見していた**:

- [ADR-1:30](../adr/1-types.md) — "Special RBS types such as `untyped`, `top`, `bot`,
  and `void` **must be handled with type-theoretic clarity rather than as ad hoc
  aliases**."
- [ADR-1:74](../adr/1-types.md)(リスク節)— "**`void` and `untyped` are likely to be
  treated as broad aliases too early.**"

予見されたリスクが、そのままの形で実現し、誰にも気づかれずに残っていた。

### P1 が示したもの — なぜ既存ゲートが取り逃がすか

この乖離が生き延びた理由は構造的で、示唆が大きい:

**Rigor のゲートはすべて false-positive 指向**。corpus byte-identical、regression
sweep、`make check` 自己診断 — いずれも「**鳴るべきでないものが鳴る**」を捕まえる。
未実装の診断は**沈黙**なので、どのゲートにも映らない。

これは **ADR-62(mutation testing = false-negative 測定)が解こうとした盲点と同じ
クラス、ただし一段上のレイヤ**。ADR-62 はコードを壊して「歯」を測るが、
*機能そのものが存在しない*場合は壊すコードがないので mutation testing でも捕まらない。
**「仕様が約束した診断が実装されたことが一度もない」は、Rigor の現行ゲート網の
完全な死角**。

n=1 章の probe でこれが出た。他章の全裁定は未実施だが、**穴の実在は確定**した
(`Dynamic[top]` は 46 spec ファイル、`NilClass` は 15 と、他節のカバレッジは
妥当に見える — 全節が穴なのではなく、*沈黙する MUST* が刺さる)。

### P1 の帰結 (a): void 乖離そのものの解消

これは移植検討とは独立した、いま存在する具体的エンジニアリング項目。CLAUDE.md の
「spec binds」に従えば実装が非適合なので、二択:

1. **仕様を実装に合わせる** — `void` を `untyped` の別名として認め、§ void を
   縮約する。ADR-1:30 の「ad hoc alias にするな」に正面から反するので、ADR で
   その撤回を明示的に記録する必要がある
2. **実装を仕様に合わせる** — `Type::Void` carrier + 値文脈診断 + slot 保存。
   新しい診断ルール = ADR-50 WD1 の必須規律追加 = **BC** なので bleeding-edge
   overlay 経由(既定 off)。FP 面は狭い(`puts` の戻り値使用は明確に疑わしい)が、
   `-> void` を返す RBS は膨大にあるので corpus 実測が要る

**どちらでもよいが、現状(仕様が現在形で嘘をつく)は選択肢ではない。** 判断には
corpus 実測(`-> void` メソッドの戻り値が値文脈で使われる実頻度)が要るので、
ADR 起票が妥当。

### P1 の帰結 (b): 「約束された診断」ゲート — 実測が示した狭い機械

P1 は汎用レジストリ(836 節に id)を**不要**にした。刺さったのは特定の一クラス —
**「仕様が診断を約束しているのに、その rule id が存在しない」**。これは:

- **機械的に検査可能** — 規範節が診断を約束する箇所で rule id を名指しさせ、
  `CheckRules::ALL_RULES` に存在することを検査する
- **既存パターンの延長** — `manual_drift_spec.rb` の軸 3 が既に
  「`ALL_RULES` の全 ID が catalogue に載っていること」を実装済み。**逆向き**
  (仕様が約束した ID が実装に存在すること)を足すだけ
- **false assurance を生まない** — `reference` リンクの量産ではなく、
  「約束 vs 実在」という二値。dspec の `assurances` 階層でいえば最下段だが、
  **void はその最下段で落ちていた**
- **Rigor の死角を正確に射抜く** — FP 指向ゲート網 + ADR-62 mutation testing が
  どちらも構造的に見られない「一度も実装されなかった診断」を、唯一捕まえる形

規模も小さい: 診断を約束する規範節は 836 出現のごく一部。

### (b) 実行 — 全章棚卸しの結果(2026-07-16)

`docs/type-specification/` 全 17 章から「診断を約束する規範節」を抽出(53 節)し、
実装語彙と突き合わせた。**診断語彙の全体は 39 id** — `CheckRules::ALL_RULES` の
26 に加え、非 check family(`dynamic.*` / `pre-eval.*` / `rbs.coverage.*` /
`rbs_extended.*`)の 13。`ALL_RULES` は全体ではない(`known_suppression_token?` が
family 単位で非 check id を受理する設計)ので、棚卸しは全語彙に対して行う必要がある。

**`diagnostic-policy.md` § Identifier taxonomy が宣言する 12 family の実装状況**:

| 宣言 family | lib 実装 | 仕様の status 記述 |
| --- | --- | --- |
| `call.*` / `def.*` / `flow.*` / `dynamic.*` / `rbs_extended.*` / `rbs.coverage.*` | あり | — |
| `plugin.<id>.*` | 動的(プラグイン) | — |
| **`static.*`** | **0** | **保留マーカーなし**(現在形) |
| **`compat.*`** | **0** | **保留マーカーなし**(現在形) |
| **`hint.*`** | **0** | **保留マーカーなし**(現在形) |
| **`generated.<provider>.*`** | **0** | **保留マーカーなし**(現在形) |
| `sig.*` | 7(JSON 出力のみ) | ✅ **正直に明記** — "The slice-1 MVP surfaces these identifiers through the command's JSON output rather than the diagnostic stream" |

**12 family 中 4 つが実装ゼロ、かつ保留マーカーなし。** `static.*` は特に射程が広い —
`diagnostic-policy.md:5`「The cutoff identifiers used by inference budgets live in the
`static.*` family」、`:10`「Calling a method on `top` without proof is a diagnostic」、
`:21`「Rigor **MUST** report the cutoff」、`special-types.md:11`「Diagnostics for
unguarded calls on `top` belong to the `static.*` family」— いずれも現在形。

### 裁定 — 「未記録の drift」と「既知の保留」を分ける

全てが同罪ではない。ADR-62 の adjudicate-don't-assume に従って分類:

**✅ 正直な記述(模範 — 仕様は正しい書き方を既に知っている)**

- `inference-budgets.md:75` — "The budget table above is **normative-for-v1 intent. As
  of this writing the configurable `budgets:` surface is not yet wired** — no `budgets:`
  key is parsed and the table's rows are not enforced." 実際 `configuration.rb` に
  `budgets` キーは存在しない。**54 行目の MUST を 75 行目が明示的に留保している。**
  [ADR-41](../adr/41-inference-budget-design.md)(Proposed)も同じ事実を記録
- `diagnostic-policy.md:43` — `sig.*` の JSON-only を明記

**❌ 未記録(実害)**

- **`void` 診断** — 実装 0、仕様に保留マーカーなし、ADR / ROADMAP / CHANGELOG にも
  記録なし(§ P1)
- **`static.*` の `top` 半分** — budget 半分は上記の通り正直に留保されているが、
  「`top` への無保証呼び出しは診断」の半分はどこにも留保がない
- **`compat.*` / `hint.*` / `generated.*`** — ADR-1 / ADR-2 の**創設期の宣言が現在形の
  まま残った**もの(`hint.role-generalization.*` は [ADR-1:366](../adr/1-types.md) が
  設定スイッチ `style.suggest_role_generalization` 付きで定義しているが、この設定キーも
  `configuration.rb` に存在しない)。保留記録なし

つまり `docs/type-specification/diagnostic-policy.md` § Identifier taxonomy は、
**一部が「設計時のウィッシュリスト」を規範的分類表として提示している**状態。

### なぜ既存ゲートが構造的に見られないか(gate の形が確定)

`manual_drift_spec.rb` の 4 軸を読み直すと、**全て impl → doc 方向**である:

- 軸 2: "every top-level key in `Configuration::DEFAULTS` **must be mentioned in** the
  configuration reference"
- 軸 3: "every ID in `CheckRules::ALL_RULES` **must appear in** the diagnostic catalogue"

**逆方向(doc → impl)は一切検査されていない。** だから「仕様が宣言したが実装が
存在しない」は 5 件すべて素通りする。P1 の FP 指向ゲート論(沈黙は映らない)の、
ドキュメント側での正確な対応物。

**したがってゲートの形は確定した**(かつ当初案より小さい):

> `diagnostic-policy.md` が宣言する各 family は、**実装 id を 1 つ以上持つか、
> 明示的な保留マーカーを持つか**のいずれかでなければならない。

- 836 節への id 付与は**不要** — 検査対象は分類表の 12 行
- **「実装しろ」ではなく「宣言するか、保留を明記しろ」** — `sig.*` と `budgets:` が
  既に正しい書き方を実演しているので、規範は確立済み・強制だけが無い
- `manual_drift_spec.rb` に軸を 1 本足すだけ(既存パターンの逆向き)
- false assurance を生まない — `reference` リンクの量産ではなく「宣言 vs 実在」の二値

### P2(独立・新規性あり): 自分のドキュメントに対する spec-reading eval

dspec の `spec-reading-eval` は Rigor の弱点を正確に突いている。Rigor は AI 消費者
向けに skills(ADR-73)+ `rigor docs` / llms.txt(ADR-74)を出荷しているが、
**エージェントがそれを正しく読めているかの評価は存在しない**。
[ACP 13 モデル検証](20260620-opencode-acp-cross-model-validation.md)は*振る舞い*
(`rigor-next-steps` を完走できるか)を測ったが、*読解*(仕様から何が entailed か)は
未測定。

`waza` は既に Flake にあり skill 評価に使える。ゴールドセット
(entailed / contradicted / not-supported)を handbook / type-spec の一章に対して
作るのは、machinery 不要で即着手できる。P1 とは独立。

### P3(ポインタのみ・新規作業不要)

`spec-change compat` の機械分類は、Rigor では **ADR-50 WD7 / ADR-77 WD2 の
`rigor upgrade`(accepted・具体的 BC ターゲット待ちで deferred)** に合流する。
凍結面(rule ID / CLI 語彙 / JSON キー)の before/after 分類という形なら、その ADR が
実装される時の設計入力になる。診断出力自体は ADR-50 WD1 で非契約なので対象外。

## Lean 4 / Alloy を直接テストオラクルにする案の評価

dspec を却下する理由が「形式化するなら直接 Lean/Alloy を使え」だったので、その案自体を
評価した(同日、本ノート内で完結)。**結論: いま CI オラクルとして作るのは見送り。
ただし Alloy は設計時の道具として今日から使える。**

**コーパス前例はゼロ** — `docs/adr/` `docs/notes/` 全体で Lean / Alloy / Coq / TLA+ に
言及するのは本ノートが最初。真に未評価。

### 却下理由 1: 形式化できる層は、バグがある層ではない

形式化が現実的なのは**型代数**(束恒等式、`Dynamic[T]` 代数、`<:`、正規化)のみ。
narrowing / dispatch / evaluator の形式化は Ruby 意味論(ブロック、メタプロ、RBS
overload 解決、`coerce`)の形式化を要求し、非現実的。

では実バグはどちらに出ているか — コーパスの健全性バグの層別:

| バグ | 層 |
| --- | --- |
| ADR-56: block exit scope 破棄 → `1.upto(6){ result *= i }` が `Constant[1]`(実行時 720) | evaluator の scope 配線 |
| ADR-78: `public_send(method_name)` の定数畳み込み → 12 FP | dispatcher の fold ゲート |
| ADR-57: tail-only body evaluator が explicit / block-internal return を落とす | evaluator |
| ADR-91 / #110: Kernel fold の所有権 | dispatcher のゲート |
| ADR-64: coerce 障壁 | Ruby の dispatch 意味論 |
| `\|\|` / `&&` の value-position edge-narrowing バグ | narrowing 配線 |

**一つも型代数のバグではない。** 逆にコーパス唯一の純粋な代数の問い(ADR-83
Dynamic-facet 代数)は「実装したが user-visible value ゼロ」で決着し、その判断は
**経済的な問い**(精度が上がるか)であって形式的な問い(無矛盾か)ではなかった —
Lean が答えられない問い。Rigor の意思決定を律速しているのは健全性ではなく
**FP と精度の経済**。

### 却下理由 2(決定的): conformance link のない模型は、本ノートの `void` そのもの

形式模型がオラクルになるには実装との対応リンクが要る。選択肢は (1) 模型から実装を抽出
(既存 Ruby エンジンには不可能)、(2) 模型を実行可能にして differential test(誰も
書かない言語で第二実装を保守)、(3) 何もない(= 証明付きドキュメント)。現実には (3)。

**(3) の帰結は本ノートの P1 が実演済み**: Lean が void 意味論を完璧に証明しても、
その証明は `Bases::Void => :translate_untyped` の隣で眠るだけ。これは dspec 却下の理由
("This proves the Clause proposition, not the behavior of application code")に**一段上で
落ちる**構図で、しかも悪化する — 証明があると「検証済み」の心理的保証がつくのに、
コードは何も守っていない。

### 下の段が二つ空いている(ADR-86 のラダー型)

- **段 0(完全に空): 型代数の property-based testing。** `rantly` / `propcheck` 類は
  Gemfile にゼロ。`spec/rigor/type/combinator_spec.rb` は 132 例あるが全て例示ベースで、
  例えば `Dynamic[Dynamic[T]] → Dynamic[T]`(冪等則)を**一点で**確認しているだけ。
  ∀ に上げるのは翻訳ギャップゼロ(オラクル = 実装そのもの)・既存 rspec 内・保守二重化
  なし。空振りしない見込みもある — **ADR-1:29 が
  「Erasure must never produce a narrower type than Rigor proved」と ∀ 命題を明示**し、
  この erasure / rendering ファミリでは実バグが出荷済み(sig-gen の record-key RBS
  クラッシュ、`&block` が env を壊す `(**untyped, ?{ (?) -> void })` を吐いた #51)。
- **段 1(既存・実績あり): rigor-rs differential。** [ADR-91:80](../adr/91-kernel-intrinsic-fold-ownership-gate.md)
  — **rigor-rs の differential harness が item 1(Kernel fold polarity)を実際に発見**。
  ADR-91 の対処は「外部検出器を in-repo invariant gate に変換」(ADR-62 kinship として
  明記)で、`rely-on-rigor-rs-differential` 自体は「外部・port スケジュール結合で CI
  ゲートではない」as complement, demand-gated で保留。**動いていて実バグを釣った
  オラクルが既にある**。翻訳ギャップもない(両者が同じ仕様を実装)。Lean 模型はこれより
  弱いオラクルを高コストで作ることになる。

### それでも手を伸ばす場所

- **Alloy = 設計時の思考道具(今日から可)。** 新しい代数操作を提案する ADR の中で
  「この正規化は合流的か」に数分で反例を返す。使い捨てるので conformance link 不要・
  保守ゼロ。CI ゲートではない。
- **Lean 4 = rigor-rs パリティが一級の課題になったら。** 二実装が一仕様を実装する構図
  では機械化仕様が**共通の審判**として資産になる(WebAssembly の機械化仕様の位置)。
  `value-lattice.md` + `relations-and-certainty.md` + `normalization.md` は小さく形式化
  可能。ただし今は differential harness の方が安くて既に動いている。

### 推奨順序

段 0(型代数 PBT)→ ADR-91 が保留した rigor-rs differential の in-repo ゲート化 →
それでも埋まらない ∀ が残ったら Lean。記録するなら **ADR-86 と同じ形**(standing
rejection + 非形式手法優先ラダー + 再評価トリガ)。

### 段 0 実行 — PBT spike の結果(2026-07-16)

gem 依存なしの手書きジェネレータで実施(ADR-62 WD1 が `mbj/mutant` を却下して自前
ハーネスを作った先例に倣う。当たりが出てから gem / commit を判断する spike 段階)。
`seed=20260716` / 2,000 ケース。法則の出典はすべて normative。

**ジェネレータの健全性を先に検証**(green を信じる前に): 13 carrier を生成
(Dynamic 15.3% / Difference 12.0% / Bot 8.8% / Top 8.4% / IntegerRange 8.4% /
Tuple 8.0% / Singleton 7.8% / Constant 7.8% / HashShape 7.7% / Nominal 7.6% /
Union 3.5% / Intersection 3.0% / Refined 1.9%)、生成時 rescue の握り潰し **0 件**、
ネストした実型を生成(`[{ k0: singleton(Object), … }, untyped]` 等)。**空振りでない**。

| 法則 | 出典 | 結果 |
| --- | --- | --- |
| L1 `erase_to_rbs` は valid RBS | internal-type-api:140 | **PASS** |
| L2 `normalize` 冪等 | internal-type-api:141 | **実行されず**(下記) |
| L3 `eql?` ⟹ hash 一致 | internal-type-api:28 | PASS |
| L4 `union(T,bot)==T` / 冪等 / 可換 | value-lattice | **PASS** |
| L5 `dynamic(top)` は canonical untyped | internal-type-api:118 | PASS |

**結果 1: 存在する型代数は堅い。** これは Lean/Alloy 却下理由 1 の**独立した裏付け**
になった — 形式化できる層を 2,000 ケース叩いて反例ゼロ。形式手法が答える問いは、
Rigor では既に答えが出ている。

**結果 2(本命): PBT の収穫は法則違反ではなく、契約の考古学だった。**
L2 は `respond_to?(:normalize)` ガードで**黙ってスキップ**された。理由を追うと —

### 三つ目の同型事例: `internal-type-api.md` の型オブジェクト契約

`docs/internal-spec/internal-type-api.md` は CLAUDE.md が **normative** に分類し、
自らを "the public contract that every Rigor type object **MUST satisfy**" と現在形で
規定する。実装状況(23 carrier 中):

| 契約メソッド | 実装 carrier 数 | 備考 |
| --- | --- | --- |
| `describe` | 19 | ✅ |
| `erase_to_rbs` | 19 | ✅ |
| `accepts` | 2 | `acceptance_router` 経由 |
| **`normalize`** | **0** | MUST 付き(冪等・`self` 返却・`normalization.md` へ routing)。**lib 全体に `def normalize` を持つ Type が存在しない** |
| **`traverse`** | **0** | lib 全体に近い名前すら不在 |
| **`consistent_with`** | **0** | lib 全体に `consistent` を含むメソッドが**ゼロ** |
| **`equal_value`** | **0** | 同上 |
| **`has_method`** | **0** | `arg_class_has_method?` 等のエンジン内ヘルパのみ |
| **`subtype_of`** | **0** | 能力は `subtype_verdict` / `rbs_subtype?` 等でエンジン内に存在するが、契約が規定する**carrier のメソッド面としては不在** |

核心の carrier `Rigor::Type::Nominal` が公開するのは `initialize` / `describe` /
`erase_to_rbs` / `inspect` の 4 つだけ。

**裁定(名前問題ではない)**: 同文書 line 22 は「メソッド名は ADR-3 OQ2 未解決なので
束縛しない」と明示的に除外しており、line 21 は具象クラス集合も束縛しない。しかし
`consistent` / `traverse` / `equal_value` は **lib 全体で近い名前すら存在しない**ので、
綴りの問題ではなく**能力の不在**。名前の carve-out は綴りを免責するのであって、
メソッド面ごとエンジン内ヘルパへ移設することは免責しない。

## void 三択の A/B 実測(2026-07-16、ADR-92 WD2 の carry-over)

ADR-92 WD2 が measurement-gated とした三択のうち、**選択肢 (b)(`void → top`、RBS に縮約)**
を A/B した。`Bases::Void => :translate_top` に変えて corpus 診断を diff。

| corpus | baseline | `void → top` | 判定 |
| --- | --- | --- | --- |
| mail `lib` | 26 | 26 | IDENTICAL |
| kramdown `lib` | 68 | 68 | IDENTICAL |
| haml `lib` | 60 | 60 | IDENTICAL |
| liquid `lib` | 5 | 5 | IDENTICAL |
| mastodon `app/models` | 0 | 0 | IDENTICAL(248 files / 1350 RBS classes) |

**空振り検証**(green を信じる前に): translator を計装して `Bases::Void` の翻訳回数を計測 —
mail **2回** / kramdown **29回**。kramdown の 29 サイトが実際に `Dynamic[top]` → `top` に
変わった上で、診断は不変。**測定は非空振り。**

**結論: (b) は診断上タダ。** ただし理由が重要 — **`top` と `Dynamic[top]` を区別する機構
(`static.*` = 「無保証の `top` 呼び出しは診断」)自体が未実装**なので、両者ともメソッド
呼び出しに対して沈黙する。つまり (b) の価値は「今効く」ことではなく、**RBS からの無許諾
乖離を除去し、`static.*` が入った時に正しく効く土台にする**こと。表現の正しさの前払い。

**(a) と (b) の関係 — 単純な上下ではない。** 仕様は void を `top` と*区別*する理由を明記
している:

> Rigor's contribution on top of the RBS rule is to record that the value reached the
> position by recovery from `void` and to surface that as a primary diagnostic, so the
> analyzer can explain *why* a `top` appeared

つまり (b) を素朴に実装すると **void の由来が失われ**、この「なぜ `top` になったか説明する」
能力が消える。ただしこれは **ADR-75 の型を回避する設計パターンがそのまま使える** —
provenance は「値についてのメタデータであって、値そのものの一部ではない」。`dynamic_origins`
と同じ identity-keyed side-table(`void_origins`)を置けば、**`void → top` + 由来 side-table
= (a) の意図を (b) の土台の上で実現できる**。carrier を増やして lattice を分岐させる必要は
ない(ADR-75 WD1 が `Dynamic` carrier に `provenance:` フィールドを足すのを却下したのと同じ
理由 — value-equality が壊れる)。

**推奨**: (b) を先に landing(タダ・fidelity 回復・(a) の土台)→ (a) は `static.*` +
`void_origins` side-table と併せて設計。ただし (a) は新規必須規律 = ADR-50 WD1 の BC なので
`bleeding_edge:` 経由。**(c)(実装追認)は測定により不要** — (b) がタダである以上、
RBS と ADR-1:30 の両方を捨てる理由がない。

## void セマンティクスの検証 — ユーザー報告から(2026-07-16)

報告された想定挙動:

```ruby
def foo #: void
  p 1
end
def bar = foo
a = bar   # 「a: 1 になっている。void ≒ top まで広げてほしい」
```

**実測(rbs-inline プラグイン + `# rbs_inline: enabled`)**:

| 書き方 | `dump_type` |
| --- | --- |
| トップレベル `def foo #: void` → `a = bar` | **`1`**(報告どおり) |
| クラス内 `def cv #: void` | `Dynamic[top]`(landing 前) |
| クラス内 `def cbar; cv; end`(**注釈なし**) | `Dynamic[top]` ← **void 性は伝播していた** |

**原因は void ではなくトップレベル。** synthesizer の出力を直接確認すると:

```rbs
class C
  def cv: () -> void
end
```

トップレベル `def` は **一行も生成されない**(upstream rbs-inline は `class`/`module` 宣言しか
出さない)。行末 `#: void` 構文自体は正しく `() -> void` に変換されている。void 固有ではなく
`#: () -> String` でも同じく無視される。

**方法論の落とし穴 2 件**(どちらも危うく誤報):
1. magic comment `# rbs_inline: enabled` が必須(ADR-32 WD2)。無いとプラグインは**何も寄与
   しない**。最初のテストがこれで「注釈が効かない」と結論しかけた
2. `#: void` は def 行末尾で正しい。upstream rbs-inline 自身が `def self.write(...) #: void` と
   書いている

**accepted signature は境界で信頼されている**(`relations-and-certainty.md:48` のとおり) —
対照実験で `#: () -> String` を `p 1` の本体に付けると型は `String` になり
`return-type mismatch: declared String, inferred 1` が出る。宣言が推論に勝つ。

### 報告が (b) の論拠を強くした

報告者の要望は「`void` ≒ `top` まで広げて**後方互換性を保証しない**」。これは fidelity 論より
強い (b) の論拠になる — **`Dynamic[top]` は目的を裏切る**:

- `Dynamic[top]` = gradual の逃がし口。何とでも consistent。`a = bar; a.length` は黙って通る →
  **呼び出し側が静かに依存できてしまう**(= `void` が防ぎたかった唯一のこと)
- `top` = 使用前に証明を要求 → 宣言した契約に忠実

**(b) を landing した**(`Bases::Void => :translate_top`)。

### 残りは二部品に分解される

報告者の第二の要望「代入・引数を警告」= 仕様 § void の未実装 MUST = ADR-92 選択肢 (a)。
報告者自身が挙げた「型とは別のルールレベル」案は**直接使用なら carrier 不要**で成立するが、
**報告例は transitive ケース**(`a = bar`、`bar` は無注釈)なので呼び出し点の RBS を読むだけ
では void が見えない。必要なのは:

1. **`static.*` の実装** — 今日 Reserved と marker を付けた 4 family の一つ。**これが (b) が
   タダだった理由そのもの**: `static.*` が無いので `top` も `Dynamic[top]` も等しく沈黙する。
   これが入って初めて `top` が噛む。**欠けていた連結子**
2. **`void_origins` side-table** — ADR-75 パターン(provenance は値についてのメタデータであって
   値の一部ではない)+ ADR-82 WD6 の chain-origin 伝播。carrier 不要・lattice 非分岐で
   transitive ケースが解ける

三部品((b) / `static.*` / `void_origins`)とも、本ノートの調査が触った場所。**報告された
二つの理想は、仕様が元々書いていた意図とほぼ一致し、`static.*` という欠けた連結子まで含めて
説明がつく。**

## 第四の事例 — rbs-inline ingestion: spec と ADR-32 の正面衝突(2026-07-16 裁定)

「rbs-inline をデフォルトロードにしては?」というユーザー提案を受けて、`overview.md:68` の
MUST と ADR-32 のプラグイン方式が整合しているかを裁定した。**結果: 整合していない。しかも
第 1〜3 事例(沈黙による未実装)より鋭い — accepted・実装済みの ADR が binding spec と
正面衝突している。**

`overview.md` § "Compatibility hierarchy"(**2026-04-28**、`4e49c10b`):

> Rigor … **MUST NOT require `# rbs_inline: enabled` to begin parsing them**. Only the
> rbs-inline configuration directives such as `# rbs_inline: enabled` and
> `# rbs_inline: disabled` are interpreted; the rbs-inline annotation comments themselves
> (for example `#: String`, `# @rbs`, parameter annotations) are **always parsed and used
> whenever present**.

ADR-32(**2026-05-25**、accepted・v0.1.10 実装):

> WD2 — The plugin synthesises RBS **only** for files whose first non-blank lines include
> `# rbs_inline: enabled`. … Rejected: **Always-on once the plugin is loaded**

タイムラインが決定的: **spec が 1 ヶ月先**。ADR-32 は spec の存在を認識しないまま
(References は ADR-0/2/5/6/15/25/27/29 — **overview.md を一度も引かない**)、spec が
MUST NOT と書いた形をそのまま WD2 で採用し、spec が要求する形を「Rejected alternative」に
置いた。2026-05-29 の docs-alignment pass もこの節を素通りしている。

**CLAUDE.md の規則で裁定は自動**: "When an ADR and the spec disagree on analyzer behaviour,
the spec binds." → **出荷挙動が非準拠**。二軸で:

1. **起動モデル** — spec は annotation を「official type sources … always parsed whenever
   present」とする。素の Rigor(プラグイン未設定)は一切 parse しない
2. **magic comment** — spec は「MUST NOT require」。プラグイン既定は `require_magic_comment:
   true`

**準拠形は既に存在する**: WD10 の `require_magic_comment: false` がまさに spec の意味論。
upstream `parser.rb:73` を検証 — `# rbs_inline: disabled` は `opt_in` 判定より**前に**無条件で
守られる(`return if with_disable_magic_comment`)ので、`false` 側でも per-file opt-out は
生きる。**準拠は工学の問題ではなく、配線とデフォルトの問題。**

### ユーザー提案への回答が反転した

当初私は「ADR-27/31 の auto-load deferral に反する」としてデフォルト化に反対した。裁定の
結果、**binding spec はユーザー提案より強いことを要求している**(提案 = デフォルトロード +
オプトアウト可能;spec = magic comment 不要で常時 parse、`disabled` のみ解釈)。反対は
起動モデルの問いについて一次資料により覆った。ADR-0(zero-dep)/ ADR-27/31(コード実行)/
standalone install(gem 不在)の懸念は**機構**を制約するのであって、**義務**を消さない。

機構の選択肢と残余(ADR-93 に整理):
- core 再実装 — ADR-32 WD1 の却下理由(grammar drift)は健在。義務は挙動であって実装方式
  ではないので、却下を維持できる
- **presence-gated デフォルト配線**(ADR-72 パターン)— rbs-inline ライブラリが解決可能
  (Rigor 環境 or ADR-90 の bundle-fallback)なら bundled プラグインを自動有効 +
  `require_magic_comment: false`。解決不能なら hint
- 残余(standalone で gem 不在)— 「always parsed」は core 依存なしには完全充足不能。
  ADR-0 との真の緊張はここ**だけ**に絞られる

## ADR-93 WD4 の初回測定(2026-07-16、herb + mail)

自然実験 = **herb**(marcoroth の HTML+ERB toolchain): 本物の rbs-inline annotation が
~25 ファイル、magic comment は 2 ファイルのみ、**そして手書き `sig/` が同じコードを覆う**。

**発見 1(ブロッカー、同日修正)**: プラグイン有効化で **env 全崩壊**(1,490 classes → 0、
`require` すら未解決化、偽 `call.unresolved-toplevel` 74 件)。機構 —
`RBS::Environment#add_source` は `sources` へ**先に** append してから decl を挿入するので、
`sig/` と衝突する virtual 定数が挿入途中で raise → per-entry rescue は skip するが**毒された
source が残り**、`sources` から作り直す `resolve_type_names` が全 rescue の外で再噴出。
sig/ と inline の重複は移行中プロジェクトの*期待される状態*であり、**今日の opt-in ユーザー
全員が踏む実バグ**(ADR-93 とは独立)。修正 = skip の transactional 化 + rbs `>= 3.0, < 5.0`
帯への resolve 時 backstop + 明示 `.rbs` 勝ち + cache-hit 安全な
`virtual_rbs_collision_quarantined` + 一回限りの命名 warning。

**方法論の教訓(2件、自分の誤り)**: ① 最初「RBS は重複検出を resolve まで遅延する」と
読んだが誤り — 真の機構は「eager 挿入 + dirty partial add の再噴出」。backtrace を
resolve_type_names:533 で止めずに add_source の内部まで読むべきだった。② 私の最初の修正
(retry ループ)は、rescue **ハンドラ内**で `unload` が再 raise して自分の rescue に
捕まらず、herb で沈黙失敗した。最小再現の green を herb で再検証したことが命拾い。

**発見 2(修正後の A/B/C、herb lib)**:

| モード | 診断 | 差分 |
| --- | --- | --- |
| A: プラグイン無し | 11 | — |
| B: opt-in + magic 尊重(現行 ADR-32) | 11 | ±0(magic 2 ファイルは両方 sig/ と衝突 → 隔離、sig 勝ち) |
| C: `--treat-all-as-inline-rbs`(ADR-93 目標形) | 12 | **−3 genuine wins** + 4 FP |

+4 は `call.possible-nil-receiver` × `Regexp.last_match(1)`(`=~` 成功後、group は
`/\n([ \t]+)\z/` で必ず参加 → 実行時 nil 不可能)。**annotation が引き起こしたのではなく、
sig/ の `-> untyped` が隠していた既存の engine 不精度が露出した**もの。match-成功エッジでの
`last_match(n)` 非nil 化という将来の narrowing fact に routing。

**発見 3(WD1/WD2 を作り替える反証)**: 注釈ゼロの mail で `--treat-all-as-inline-rbs` が
26 → 42。原因 — upstream rbs-inline の opt-out モードは**無注釈 def 全部に `-> untyped`
スケルトンを合成**し、accepted signature は本体推論に勝つので、**inference-first と正面
衝突**する(推論の方が `untyped` より精密)。spec が bind するのは「annotation が在れば
honour する」ことであって「無注釈コードの untyped 影を製造する」ことではない。よって
ADR-93 の適合形は **annotation 存在ゲート**(ファイル内容の安価なスキャン。magic comment は
不要のまま = MUST NOT は守られる)であり、全ファイル無条件ではない。

## ADR-93 WD1 の実装 — 測定が設計を二度作り替えた(2026-07-16)

WD4 の測定を受けて WD1(magic-comment 不要モード)を実装。**測定が私の設計案を二度反証した。**

**第一の反証(前節 Finding 3)**: 「`require_magic_comment: false` にする」= upstream の
opt-out モード = **無注釈 def 全部に untyped スケルトンを合成**。mail 26→42。
→ 案を「ファイルに注釈があるときだけ寄与する」ゲートに変更。

**中間検証で分かった、その案も不十分な点**: 混在ファイルの実測 —

```
class Mixed
  def annotated: (String) -> Integer        # 注釈あり: 本物
  def unannotated: (untyped x) -> untyped   # 注釈なし: スケルトン
```

ファイル単位ゲートでも、**注釈が1つあるファイルの他メソッドは untyped で汚染される**。
member 単位のフィルタは upstream AST への結合(ADR-32 WD1/WD3 が grammar-drift 理由で
却下した路線)なので v1 では採らず、「注釈付きファイルは upstream 準拠(`rbs-inline --output`
が生成するのと同じもの)」として受容。**残余として記録**。

**第二の反証 — `#:nodoc:`**: ゲート実装後も mail は 26 に戻らず **31**。原因は
`class AddressList #:nodoc:` — RDoc ディレクティブが `#: <type>` と字句衝突し、**upstream が
型 alias `nodoc` の TypeAssertion として parse する**(`nodoc` を消費し末尾コロンを捨てる)。
mail の **61 ファイル**がこれだけでゲートを通過していた。Ruby で最も普遍的なコメントの一つ。

- upstream のバグであり報告に値するが、**出力は無害**(`# :nodoc:` コメントとして戻るだけで
  偽の型は出ない)→ フィルタはゲート層のみで足りる
- 検出は upstream 自身の `AnnotationParser` に委譲(正規表現で `#:` を探す実装は、
  `http://example.com#:` を含む素の doc コメントを誤検出するし、文法は upstream のもの
  = ADR-32 WD3)

**最終測定**:

| corpus | base | ゲート後 | |
| --- | --- | --- | --- |
| mail(注釈ゼロ) | 26 | **26** | 42 → 31 → 26 と段階的に修復 |
| kramdown / haml / liquid | 68 / 60 / 5 | 同じ | no-op ✓ |
| herb(実注釈あり) | 11 | 12 | **−3 genuine wins** / +4 |

**教訓**: 「upstream に委譲すれば grammar は upstream のもの」(ADR-32 WD3)は正しいが、
**upstream の*目的*は Rigor の目的と違う** — `rbs-inline --output` は sig/ を*生成*する道具
なので無注釈 def にスケルトンを吐くのが正しい。Rigor は*推論*が一次なので同じ出力が害になる。
委譲の境界は「文法」であって「何を寄与とみなすか」ではない。

**残り(ADR-93 WD1a)**: herb の +4(`Regexp.last_match(1)` の可 nil 判定)は ADR-57 プロトコル
上 artifact なので、**既定フリップの前に根本修正が必要**。side-quest ではなく前提条件。

## 総合 — 発見された共通パターン

本ノートの調査は、同一のバグクラスを **4 つ独立に**発見した(#4 は沈黙でなく矛盾という、より鋭い亜種):

| # | 場所 | 内容 | 記録 |
| --- | --- | --- | --- |
| 1 | `special-types.md` § void | 2 MUST を含む節が丸ごと未実装(`Bases::Void => :translate_untyped`) | **なし** |
| 2 | `diagnostic-policy.md` § taxonomy | 宣言 12 family 中 4 つ(`static.*` / `compat.*` / `hint.*` / `generated.*`)が実装ゼロ | **なし** |
| 3 | `internal-type-api.md` § method surface | 契約メソッド `normalize` / `traverse` / `consistent_with` / `equal_value` / `has_method` / `subtype_of` が carrier に不在 | **なし** |
| 4 | `overview.md:68` vs ADR-32 | binding spec「always parsed / MUST NOT require magic comment」に対し、accepted ADR が opt-in プラグイン + magic-comment ゲートを実装(spec が 1 ヶ月先、ADR は spec を引かない) | **なし**(相互参照ゼロ) |

**共通の診断**: Rigor の規範コーパスには**創設期の地層**(ADR-1 / ADR-2 / ADR-3 期)が
あり、それは*設計目標*として書かれたものが*束縛的契約*として現在形で提示されたまま、
出荷物と一度も突き合わされていない。

**そして正しい書き方は既にコーパス内に 2 例ある** — どちらも後年の追記:

- `inference-budgets.md:75` — "**As of this writing the configurable `budgets:` surface
  is not yet wired**"
- `diagnostic-policy.md:43` — `sig.*` の JSON-only 明記

**規範は確立済み。強制だけが無い。** これが「宣言するか、保留を明記しろ」ゲート
(§ (b))の射程を決める — 対象は void の 1 節ではなく、創設期地層の全体。

## 却下

- **dspec 自体の採用** — 形式基盤としての不適合(上記 1〜4)+ Pkl/Node 導入コスト +
  生後 3 日・単独作者・互換性保証なし
- **Lean 4 / Alloy を CI テストオラクルに(現時点)** — 形式化できる層にバグがなく、
  conformance link なしの模型は `void` の失敗を再演する。段 0 / 段 1 が空いている
- **全規範節への id 付与 + coverage ゲート** — false assurance を量産する。P1 の実測が
  穴を示してから
- **dspec 経由の Lean/Alloy 射影** — 直接書く方が桁違いに強い

## 再評価トリガ

- **(形式手法)** rigor-rs パリティが一級の program になった場合 — 二実装の共通審判
  として機械化仕様が資産になる。ただしまず ADR-91 が保留した differential の
  in-repo ゲート化が先
- **(形式手法)** 段 0 の PBT では張れない ∀ 命題が実害を出した場合
- dspec の Clause AST が型・帰納的定義・推論規則を獲得した場合(現状 91 行、命題論理
  断片 — 大幅な設計変更が必要)
- rigor-rs との仕様パリティ検証が「表駆動の規範節レジストリ」を要求した場合
  (ADR-91 の spelling-parity spec が既にその形の萌芽。クロス実装パリティは
  レジストリの最も強い正当化理由になりうる)
- dspec が複数作者・互換性保証を獲得し、Ruby 側 authoring 面を持った場合
