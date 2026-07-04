# Rails アプリのカバレッジ強化オンボーディング — sig-gen carrier トラップと engine-bound な天井

Status: real-project triage + 仮説メモ。2026-07-04、Rigor v0.2.6 (`[Unreleased]`) 時点で
`~/repo/ruby/rigor-survey/{redmine,mastodon}` に対して実施。非normative（設計コミットメント
なし）。redmine は Rails 8.1.3 (git a12198ea0)、mastodon は Rails 8.1.3 (v4.6.0-rc.1+186)。

Grounding: [`rigor-project-init`](../../skills/rigor-project-init/SKILL.md) スキルの手順に沿った
オンボーディング中に観測。[`rigor-protection-uplift`](../../skills/rigor-protection-uplift/SKILL.md)
が警告する carrier-additivity トラップの実測ケース。狙う穴は
[ADR-58](../adr/58-ivar-field-typing.md)（ivar field typing）+ [ADR-67](../adr/67-parameter-type-inference.md)
（parameter inference）、tractability ラベルは [ADR-75](../adr/75-dynamic-provenance.md) /
[ADR-63](../adr/63-type-protection-coverage.md)。

> **⚠️ 訂正（2026-07-04 再調査、バグ A 修正後）** — 本ノート初版の見出し的主張
> 「sig-gen の生成 `sig/` はカバレッジを下げる／目的に純負」は **誤り**だった。それは終始
> **RBS 環境クラッシュ（バグ A）のアーティファクト**で、sig/ をロードするたびに env が壊れ
> 全 type-of が Dynamic に落ちていたためカバレッジが低く見えていた（手動 git 修正1件では他の
> bare-class アダプタ等で env が再クラッシュし続け 0.1576 のままだった）。バグ A をエンジンで
> 修正すると、**生成 `sig/` はカバレッジを大きく上げる**（redmine +10.3pp / mastodon +5.4pp）。
> carrier-additivity トラップは実在するが、その顕在化は「カバレッジ減」ではなく
> **「非掲載メンバ脱落による sig-quality FP の増加」**（下記「再調査」節）。以下 §2・バグ B・H1 は
> この訂正で置き換わる。§4 の最終状態・§1（プラグイン中立）・H4（engine-bound）は有効。

## 目的と初期状態

ユーザ要求は「redmine / mastodon の型カバレッジを強化したい」。両プロジェクトとも `.rigor.yml`・
baseline・`sig/` の一切なし（未オンボード）。`rigor plugins` は **0 プラグイン loaded** — 素の
エンジンでの計測だった。

## 実施手順（project-init）

`.rigor.dist.yml` を両者に作成（`target_ruby: "3.3"`, `paths: [app, lib]`, `severity_profile:
lenient`, acknowledge モード）。プラグイン集合は検出結果から:

- **redmine**（素の Rails）: actionpack / activerecord / actionmailer / rails-routes / rails-i18n /
  activesupport-core-ext（6）
- **mastodon**（+Devise/Pundit/Sidekiq/rails-i18n）: 上記 + devise / pundit / sidekiq（9）

`rigor plugins` で全ロード確認（load-error 0）。以降 `cwd=target` + `BUNDLE_GEMFILE=<rigor>/Gemfile`
で Flake 経由実行。

## 観測データ

### 1. プラグインはカバレッジ中立

redmine `app/models` の protection カバレッジ（`coverage --protection`）:

| 構成 | ratio | protected/total | tractability |
| --- | --- | --- | --- |
| プラグイン 0 | 0.1868 | 1924 / 10300 | engine_gap 6980, add_rbs 33 |
| プラグイン 6（上記） | **0.1868** | 1924 / 10300 | engine_gap 6980, add_rbs 33 |

**バイト単位で同一。** Rails プラグインは *診断* と一部の戻り値/relation 型付けには効くが、
protection の分母である **dispatch site の受信者型付けは動かさない**。

### 2. sig-gen 生成 `sig/` はカバレッジを下げる（本命の現象）

`rigor sig-gen --params=observed --write app lib` で 169 ファイル生成後、redmine 全体（app+lib、
28267 dispatch sites）で A/B（キャッシュ排除、git_adapter の superclass 修正済み＝下記バグ対処後）:

| 構成 | ratio | protected | tractability |
| --- | --- | --- | --- |
| sig あり | 0.1576 | 4454 | engine_gap 19572, add_rbs 0 |
| **sig なし** | **0.1953** | **5520** | engine_gap 18437, add_rbs 116 |

生成 `sig/` は保護率を **0.195 → 0.158（保護サイト 1066 減）** させた。一方 `app/models` の
`check` 診断数は **57（sig なし）= 57（fix 済み sig あり）** で不変。**診断を1件も減らさずに
保護だけを削る。**

### 3. mastodon も同一パターン

`app/models`（sig なし、プラグイン込み）: ratio 0.1773（1043 / 5884）、engine_gap 3786, add_rbs 20。
triage（app+lib 1312 ファイル, ~27s）: total 2358（error 4 / warning 26 / info 2328）、hint は
`gem-without-rbs`（323 gem が RBS なし＝想定内）と `genuine-bugs` ×6 のみ。project-monkey-patch /
unresolved-toplevel / activesupport-core-ext の hint は**無し**（AS overlay + プラグインが
undefined-method クラスタを解消済み）。

### 4. 最終オンボード状態（sig 破棄、クリーン baseline）

| | redmine | mastodon |
| --- | --- | --- |
| baseline | 225 バケット / 796 診断 | 1138 バケット / 2358 診断 |
| `check`（baseline 上） | No diagnostics | No diagnostics |

baseline の大半はプラグイン認識トレース `:info`（rails-routes.helper, actionpack.filter-call,
activerecord.model-call 等）。実型診断は小さい（redmine: undefined-method 12, possible-nil 10,
argument-type-mismatch 1 / mastodon: possible-nil 14, always-truthy 2）。

## 遭遇したバグ

### バグ A — sig-gen の superclass 欠落 → RBS 環境クラッシュ（危険）

`rigor baseline generate` が `sig/lib/redmine/scm/adapters/git_adapter.rbs` で
`RBS::DuplicatedDeclarationError: ::Redmine::Scm::Adapters::GitAdapter` を出して失敗。

原因: ソースは `class GitAdapter < AbstractAdapter` だが、sig-gen は superclass を省いて
`class GitAdapter` を生成。Rigor の RBS 環境ビルドは **sig 宣言と解析ソースから収集した宣言
（superclass 付き）をマージ**しようとし、superclass の有無不一致が RBS 上で二重宣言として衝突する。
sig 単体（+core）ロードでは再現せず、フル環境ビルド時のみ発火。`< AbstractAdapter` を追記すると解消。

**危険な点: 失敗が「改善」に化ける。** 環境ビルドが落ちると Rigor は *RBS 環境なし*で解析続行し、
全 type-of クエリが `Dynamic[top]` に劣化 → undefined-method を証明できず**偽の診断減少**が起きる。
実際、壊れた sig で `app/models` の `check` は 26 件（undefined-method 23 件が偽消失）、fix 後は 57 件。
この 57→26 を「sig が FP を半減させた」と誤読しかけた（後述の対処で判明）。

### バグ B — 生成 `sig/` の carrier-additivity（診断利得ゼロで保護減）

上記データ 2。sig を fix しても保護は下がる（診断は不変）。sidecar `sig/` にクラスを宣言すると
そのクラスは推論モードから RBS 宣言モードに切り替わり、**推論が付けていた非宣言メンバが落ちる** →
`x.foo.bar` の `foo`（sig 非掲載）が Dynamic を返す → `bar` の受信者が Dynamic 化。undefined-method
は FP-discipline で発火しない（Dynamic 受信者は不問）ため診断は増えないが、protection は失われる。
`untyped` は主に**引数**位置（`(untyped, untyped) -> 具体型`）で無害、損失はクラス再宣言による
メンバ脱落側。`rigor-protection-uplift` スキルが明記する「sidecar sig は purely additive ではない」
の実測。

## 対処の経緯（誤読 → 反証 → 確定）

1. sig 生成後、`app/models` 保護 0.187→0.156 かつ診断 57→26 を観測 → 当初「carrier トラップで
   保護減、代わりに FP 半減」と両立解釈。
2. baseline generate が RBS 二重宣言でクラッシュ → 環境が壊れている疑い。
3. sig 単体ロードは OK、フル環境のみ NG → ソース収集宣言との superclass 衝突と特定、`< AbstractAdapter`
   で修正。git_adapter だけが発火（RBS は最初の衝突で abort、解決順で git が先頭だった）。
4. **fix 後に再計測すると `check` は 57=57**（sig の診断利得は幻）。つまり「57→26」は壊れた環境の
   副産物だった。保護低下だけが本物（キャッシュ排除・全体 A/B で 0.195→0.158 と再現）。
5. 目的（カバレッジ）に対し sig は純負（保護減・診断利得ゼロ）と結論 → 生成 `sig/` を破棄し、
   sig なしでクリーンな baseline を再生成・配線。

## 仮説

- **H1（REFUTED — 下記「再調査」節）: 「sig-gen の sidecar `sig/` は protection カバレッジに
  純負」は誤り。** 真相は env クラッシュ（バグ A）のアーティファクト。env 修正後は sig が
  カバレッジを +5〜10pp 上げる。carrier トラップは「メンバ脱落 → undefined-method FP 増」として
  顕在化する（coverage 増 vs FP 増のトレードオフ）。

- **H2: superclass 欠落は sig-gen の一般的欠陥。** 全 169 ファイルで `class X < Y` が `class X` に
  なる。多くは env 内で衝突相手を持たず顕在化しないだけで、subclass が解析対象に含まれると
  RBS 環境全体を落とす潜在地雷。修正候補は (a) sig-gen が superclass を出力、(b) env ビルドが
  「superclass 無しの冗長 reopen」を DuplicatedDeclarationError にせずマージ許容。**(b) は特に重要** —
  1 ファイルの sig 不備で*全体*が Dynamic に落ちる挙動は影響が不均衡。

- **H3: 環境ビルド失敗のサイレントさ自体が UX バグ。** 「診断が減った」が「RBS 環境が壊れた」を
  意味しうる。env build 失敗をより強く可視化（専用診断 / 非ゼロ exit / triage hint）すべき。
  今回は stderr の 1 行警告のみで、`baseline generate` は壊れた env のまま 748 診断を書き出した
  （信頼できない baseline）。

- **H4: カバレッジ天井は engine-bound。** 未保護の **~94% が engine_gap**（redmine 18437/28267）、
  手書き RBS で閉じられる `add_rbs` は **<0.5%**（redmine 116, mastodon 20）。正体は untyped 引数
  → Dynamic ivar/receiver 連鎖で、これは ADR-58 / ADR-67 が狙う領域そのもの。config/plugin/sig
  では動かず、実際のレバーはエンジン実装。redmine/mastodon はその優先度づけの実証コーパスになる。

## Follow-up

- sig-gen の superclass 出力 / env マージ許容（バグ A、H2）— **両方 FIXED（2026-07-04）**。
  真因は superclass 不一致そのものではなく、生成 sig が inherited nested type
  （`GitAdapter::Revision`）を参照 → `stub_missing_referenced_types` の stub 掃引が
  既宣言の `class GitAdapter` を囲み名前空間として `module` 再宣言 → class/module kind
  衝突で `DuplicatedDeclarationError`（superclass を足すと nested type が継承経由で解決 →
  stub 不要 → 衝突回避、で「効いた」）。修正 (a) `Generator#record_superclass` +
  `Writer#superclass_suffix`：plain-constant 親を `class X < Y` として出力（`Struct.new`
  等の computed 親は従来どおり無出力）。修正 (b) `RbsLoader.append_stub_declarations`：
  env に既宣言の名前を stub しない（`collect_missing_namespaces` の `declared.include?`
  ガードを掃引側にも適用）。**(b) 単独で env 崩落を防ぐ** = H2(b) の「1 ファイルで全体 Dynamic」
  という不均衡を解消。回帰テスト：generator_spec / writer_spec / rbs_loader_spec。
- env ビルド失敗の可視化強化（H3）— 未着手（`warn_about_env_build_failure_once` の 1 行
  警告のみ。専用診断 / 非ゼロ exit / triage hint は demand-gated）。
- ADR-58 WD1b/WD2・ADR-67 の実装がカバレッジ最大レバー（H4）。in-place additive carrier での
  protection A/B（H1 の裏取り）。

## 再調査（2026-07-04、バグ A エンジン修正後）

バグ A（superclass 出力 + stub 掃引ガード）を修正した working tree で全て再計測。affected specs
155/0 green。redmine で修正済みエンジンにより sig を再生成 → superclass 出力確認
（`class GitAdapter < AbstractAdapter`、127 with-superclass / 51 bare）、`baseline generate`
クラッシュ解消（281 バケット / 956 診断を正常書き出し）。

### 訂正 R1 — 生成 `sig/` はカバレッジを大きく上げる（§2 を置換）

redmine 全体（app+lib、28267 sites、キャッシュ排除 A/B、**sig-gen が env を壊さなくなった状態**）:

| 構成 | ratio | protected | tractability |
| --- | --- | --- | --- |
| **sig あり（修正済みエンジン）** | **0.2986** | **8440** | engine_gap 16168, add_rbs 49 |
| sig なし | 0.1953 | 5520 | engine_gap 18437, add_rbs 116 |

**+10.3pp（保護サイト +2920）。** 初版 §2 の 0.1576（sig あり）は、手動 git 修正1件では他ファイルで
env が再クラッシュしていた *壊れた env* の数字だった。mastodon `app/models` でも同傾向:
sig あり 0.2311（1360/5884）vs なし 0.1773（1043/5884）→ **+5.4pp**。

### 訂正 R2 — carrier トラップの真の顕在化 = sig-quality FP 増（バグ B を再定義）

env が健全化すると、sig がクラス再宣言時に落とす非掲載メンバが **今度は証明可能な
`call.undefined-method` として噴出**する。redmine triage A/B（baseline 非依存）:

| rule | sig あり | sig なし |
| --- | --- | --- |
| call.undefined-method | 155 | 33 |
| call.wrong-arity | 22 | 0 |
| def.return-type-mismatch | 10 | 0 |
| （error 合計） | 201 | 57 |

adjudication（全て sig-quality FP）:
- **undefined-method +122**: メッセージが `undefined method 'scope_select' … the project defines
  'Redmine::Activity::Fetcher#scope_select'` と自白 — sig がクラス宣言時に**実在メンバを落とした**。
- **wrong-arity +22**: `Struct.new` サブクラス（`Webhook::Executor`, `Redmine::Notifiable`,
  `MultipleValuesDetail` 等）の生成 initialize を sig が欠く → `given 3, expected 0`。
- **return-type-mismatch +10**: 過度に狭い推論戻り（`declared nil, inferred X` / `declared bool`）。

つまり **coverage +10pp と FP +150 のトレードオフ**。protection-uplift の二重ゲート
（coverage 増 AND 新規診断ゼロ）を FP 側で破る。acknowledge モードでは baseline が吸収するが、
「実在メソッドを undefined と言う」FP で baseline を汚す。

### 訂正 R3 — 再調査で見えた最大のエンジンレバー: **プロジェクト自身の `sig/` を additive に**

FP の根は「sig にクラスを宣言するとそれが *完全*とみなされ、推論が付けていたメンバが落ちる」
（RBS 宣言モードの all-or-nothing）。もし **プロジェクト自身の `sig/` を推論とマージ（additive）**
できれば、coverage +10pp を **FP ゼロ**で得られる。候補: (a) sig-gen が宣言クラスの全メソッドを
（un-inferrable は `untyped` 戻りで）出力し脱落を無くす、(b) エンジンがプロジェクト sig を
authoritative-complete でなく inference-additive に扱う。(b) はバグ A のクラッシュ修正より
射程が大きく、Rails アプリ全般の「sig-gen で coverage を上げたいが FP を出したくない」を解く。
H1 の in-place additive carrier 案（rbs-inline `#:` / return-override）は (a) の手動版に相当。

## GOTCHAs（再実行者向け）

- 診断メッセージは i18n 由来の非 ASCII を含む → JSON パースは `File.read(f, encoding:"UTF-8").scrub`。
- `coverage` に `--no-cache` は無い → `rm -rf .rigor/cache` でバスト。`coverage --protection` の
  数値は複数回・キャッシュ排除で安定（交絡なし）。
- 生成物（`.rigor.dist.yml` / `.rigor-baseline.yml` / `.rigor/cache/`）は survey チェックアウト内で
  untracked。sweep の tag 切替でも残存する。
