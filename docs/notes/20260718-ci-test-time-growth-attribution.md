# CI テスト時間の伸び — 要因分解（instance gacha vs テスト増加 vs binpacker）

Status: research note, no design commitments. Observations taken against Rigor
**v0.2.9**, GitHub Actions `ubuntu-latest`, binpacker 0.2.0, 2026-07-18.

## きっかけ

CI の "Tests (Ruby 4.0)" 実時間が「段々伸びている」ように見える、という懸念。連続する
2 ラン([#186](https://github.com/rigortype/rigor/actions/runs/29607710808) = 427s /
[#187](https://github.com/rigortype/rigor/actions/runs/29608667875) = 660s、15 分差)を
起点に、①テスト増加 ②GitHub 混雑・個体差 ③binpacker アーキテクチャ ④その他 を切り分けた。

## 手法

`gh run list/view` で成功ラン 239 本(2026-06-22 → 07-17)の "Run tests" ステップ実時間を
収集。加えて binpacker が末尾に出す `Total: N files, MMmSS.s | K examples` 行を代表ランで
取得。この `MMmSS.s` は **全ワーカーの合計 CPU 時間(= 同じ作業にかかった計算コスト)**で、
ワーカー数・スケジューリング品質・混雑ノイズから独立した「純粋な仕事量」指標になる。これが
切り分けの鍵。

## 観測

### 実時間の週次中央値 — 「段差」であって漸増ではない

| ISO週 | 期間 | 中央値 | n |
|---|---|---|---|
| 26 | 06/22–28 | **376s** | 25 |
| 27 | 06/29–07/05 | **392s** | 41 |
| 28 | 07/06–12 | **516s** | 74 |
| 29 | 07/13–19 | **530s** | 99 |

日次中央値では 07-04 まで ~380s 一定 → **07-05 に 490s → 07-06 以降 510–556s 一定**。
分単位に追うと転移は **07-05 08:17(392s)→08:26(533s)の 9 分間**。だがこの日のコミットは
すべて 15:16 以降(bundle update・版上げ・コメント整形のみ、ランタイム非依存)。
**コード変更が無いまま同一コードベースで段差が発生**している。

### 合計 CPU 時間 — 同一テストが個体で 27〜42 分に振れる

| ラン | 実時間 | examples | **合計CPU** | workers | 並列効率* |
|---|---|---|---|---|---|
| 06-23 (基準) | 392s | 7038 | 24m44s | 4 | 94.6% |
| 07-04 (速) | 381s | 7332 | 24m14s | 4 | 95.4% |
| 07-05 08:17 (速) | 392s | **7339** | **24m45s** | 4 | — |
| 07-05 08:26 (遅) | 533s | **7339** | **31m33s** | 4 | 88.7% |
| 07-06 (遅) | 506s | 7340 | 31m50s | 4 | — |
| 07-17 #186 (速) | 427s | 8068 | 27m15s | 4 | 95.7% |
| 07-17 mid | 538s | 8067 | 34m24s | 4 | — |
| 07-17 #187 (遅・最大) | 660s | 8077 | **42m38s** | 4 | 96.9% |

*並列効率 = (合計CPU ÷ 4) ÷ 実時間

07-05 08:17 と 08:26 は **examples=7339 で完全同一・workers=4 同一・profile=ci 同一**なのに
合計 CPU が **24m45s→31m33s(+27%)**。07-17 の同日 3 ラン(examples≈8070)も合計 CPU が
**27m〜42m(+56%)**と振れる。同じテストコードが、その日どのホストを引くかで計算コストが
1.5 倍以上変わる = **noisy neighbor によるホスト共通(コモンモード)変動**。

## 結論（要因分解）

1. **真のテスト増加 — 寄与は小さく、緩やかで健全(約 +10%/月)。** examples 7038→8077
   (+15%)、spec LOC +13%。ただし「きれいなホスト」同士で比べた合計 CPU は 24m44s(06-23)→
   27m15s(07-17 #186) = **+10%** に留まる。これが唯一の実トレンドで、規模相応。

2. **GitHub ホストの性能ばらつき/劣化 — 体感増の主因かつ全ノイズの源。** 同一コードで
   合計 CPU が 27〜42 分に変動。07-05 08:20 UTC 前後で「普通のホスト」の基準が恒久的に
   悪化(24m45s→31m30s)し、週中央値 392→516s の階段になった。その上に大きな per-run
   ノイズが乗る。ユーザーが挙げた 427 vs 660 は **ノイズ同士の比較**(#186 は速い引き、
   #187 は 60 ラン中の最高外れ値、合計 CPU 27m vs 42m)。単発ラン比較でトレンドは測れない。

3. **binpacker はシロ、むしろ優秀。** 全ラン 4 workers / profile: ci(work-stealing 有効、
   `Config#resolve_profile` が `CI`/`GITHUB_ACTIONS` env で自動選択)。並列効率は一貫して
   **94〜97%**(#187 でも 96.9%)。ホストの CPU コストを透過するだけで増幅していない。
   ここを変えても効果はない。

## カテゴリ別ジョブ分割の検討（否定的）

「大カテゴリごとにジョブを分ければ instance gacha に効くか」を検討 → **変動対策として逆効果、
速度目的でも larger runner に劣る**。

- **ガチャは引き直しでなく引く枚数増。** ステージ完了 = N ジョブの max。max-of-N は期待値も
  テールも悪化する(straggler)。noisy neighbor はホスト単位のコモンモードなのでシャード内で
  平均化されず、across-shard では「どれか 1 つが遅い」確率が上がる。
- **binpacker のグローバル均衡を捨てる。** 現状は file 粒度の実測タイミング + LPT +
  work-stealing で 325 ファイルを動的再配分。カテゴリ境界は静的・不均等で、かつて
  parallel_tests で悩んだ偏り([2026-06-22 note](20260622-parallel-suite-runtime-distribution.md))
  を手で再導入することになる。
- **固定オーバーヘッド(checkout/setup-ruby/bundle/boot)が N 倍。**
- **速度が目的なら larger runner が全軸で上。** `workers: auto` は nproc なので larger runner に
  置くだけで自動スケール(設定変更ゼロ)、ガチャは 1 枚のまま、グローバル均衡も維持、
  larger/dedicated は同居ノイズ自体が少なく variance も改善。

分割が正当化されるのは (a) フィードバック遅延目的の薄い smoke tier、(b) DB サービス等
環境が違うテスト群の隔離、(c) 不安定シャードの独立リトライ — いずれも速度/変動が目的ではない。
現 rigor は単一 gem の unit spec なので該当なし。

## 推奨

1. **単発ラン比較をやめ、指標を変える。** binpacker が毎回出す合計 CPU 時間
   (`Total: … NNmSS.s`)か wall の週次中央値を追う。並列効率・混雑ノイズを分離した実トレンド
   (+10%/月)が見える。
2. **wall を縮めたいなら larger runner(コア増)。** 既に 4 vCPU で CPU バウンド、worker 増は
   コア数で頭打ち。larger/dedicated が level と variance の両方に効く唯一のレバー。binpacker
   変更不要。
3. **合計 CPU が examples 増加率を継続的に上回り始めたら**初めてエンジン/spec 重量化を疑う。
   現状は規模相応。

## Runner を金で変える選択肢の評価（larger runner / サードパーティ）

variance(instance gacha)を金で緩和できるか。GitHub 公式 larger runner とサードパーティ
(Blacksmith / WarpBuild)を比較検討した。

### 前提（GitHub billing / runner-choice ページ）

- **公開リポの標準ランナーは無料**(rigor は現状 CI $0)。標準の「混雑の少ない上位版」という
  商品は無く、払って変えられるのは実質 larger runner のみ。
- **larger runner は公開リポでも常に課金**(原文 "Larger runners are always charged for,
  even when used by public repositories")、無料枠も効かず、**GitHub Team / Enterprise Cloud
  プランが必要**。料金は vCPU にほぼ比例(8-core Linux ≈ $0.032/min 前後)。
- runner-choice ページは larger runner の**性能一貫性を明言していない** → 確実に買えるのは
  コア数(=wall 短縮)で、variance 低減はおまけ・非保証。

### サードパーティ（2026-07-18 時点の料金ページ）

| | 単価(Linux x64) | 主張 | OSS 無料枠 |
|---|---|---|---|
| WarpBuild | 4vCPU $0.008 / 8vCPU $0.016 / 16vCPU $0.032 /min | 「50%安・2x速」 | 明記なし |
| Blacksmith | 2-core $0.004/min(vCPU 可変) | 「67%削減・2x速」 | あり・**選別制**(現状 Celery/Ladybird/Zen/Limbo の4件のみ、要申請) |

サードパーティが速く安いのは概ね本当で、**高クロックの専有ベアメタル**を使うため per-core が
速く(消費分数も減る)、同居ノイズが少ないので **variance 軸に GitHub larger より直接効く**。
技術的には本件の「合計CPUのブレ」に最も刺さる。

### 結論 — 見送りが妥当

金銭は障壁でない(8vCPU 2x で概算 **月 $15–30**、GitHub larger の半額弱)。判断軸は金額でなく
**「cosmetic な便益 vs 恒久的な供給網依存」**:

- 第三者の GitHub App に Actions アクセスを与え、**インストールして使われる型チェッカーの CI を
  外部インフラで回す**ことは [ADR-31](../adr/31-contribution-and-supply-chain-policy.md)
  (供給網ポリシー)の領域。ephemeral VM で raw self-hosted の fork-PR 永続リスクは薄いが、
  信頼依存は恒久的。得られるのは見た目(variance)の改善のみ。
- 公開リポの self-hosted は fork-PR 任意コード実行の既知アンチパターンで **不可**。
- 実トレンドは +10%/月・中央値 530s・最悪 11分の**実害なし**問題。恒久依存を足す取引に見合わない。

**再検討トリガー**: (a) wall が実スループット障害(恒常 >15分程度)まで育つ、または
(b) **Blacksmith OSS 無料枠に rigor が通る**なら ROI 反転(無料で 2x・専有、残コストは App 信頼のみ)
— 申請は低コストなので打診の価値はある。

## 落としどころ（2026-07-18 決定）

- **有料 runner(larger / サードパーティ)は見送り。** 無料の実対処で足りる。
- 実対処 = **単発ラン比較をやめ、合計CPU時間 / wall 週次中央値で追う**(+10%/月 の実トレンドが
  見える)。加えて **`*.md` のみの PR ではテストを走らせない**のが妥当な落としどころ。

### `*.md`-only PR スキップの実装上の注意（重要）

**naive な `paths-ignore` は不可。** [ci.yml:6-13](../../.github/workflows/ci.yml) は `push` にのみ
`paths-ignore: "**/*.md"` を掛け、**`pull_request` は意図的に無フィルタ**にしている。コメント
(ci.yml:9-11)の通り、**paths-filter された required check は pending のまま固着してマージを
ブロックする**ため。`pull_request` に `paths-ignore` を足すと md 限定 PR がマージ不能になる。

正しい実装は **「required check は必ず報告しつつ、重いステップだけ条件スキップ」**パターン:
`test` ジョブは全 PR で起動させ(checkout まで実行 → 数十秒で success 報告)、変更ファイルを判定して
md-only なら `make test-binpacker` / `make test-ractor-pool` をスキップする(`dorny/paths-filter`
等の guard step + `if:`)。これで required 契約を壊さずスイート実行だけ省ける。

なお前提として AGENTS.md は **md 限定変更を master 直コミット**(PR 不要)と定めており、push 側は
既に paths-ignore 済み。よって md-only PR はエッジケース(規約外で PR を開いた場合)なので便益は
限定的だが、コストは小さい。ci.yml 変更は非 md → **branch + PR 必須**(その PR 自体はテストが走る)。

## 時間帯依存の検証（否定）

「JST 昼に作業すれば欧州・米国の開発者と runner を奪い合わず速いのでは?」を、収集済みの
239 ラン(段差後 07-06 以降 173 ラン)で検証した。**前提は正しいが効果は検出できない。**

- **前提は正確**: JST 昼(例 10–18時 = UTC 01–09)はグローバル CI のオフピーク(米国は夜、欧州は
  早朝以前)。JST 深夜(0–3時 = UTC 15–18)は欧州午後+米国午前のピークに重なる。
- **だが実データに差が無い**(段差後、UTC 時刻でビン分け):

  | | JST 昼 (UTC 00–09) | グローバルピーク (UTC 13–22) |
  |---|---|---|
  | 実行時間 中央値 | 517s | 523s(差 6 秒) |
  | キュー待ち 中央値 | 3s | 3s |

  全 24 時間帯が実行 494–556s・キュー待ち 2–3s の帯に収まり日内トレンドは無い。差 6 秒は
  per-run のばらつき(σ≈65s)に埋もれる。キュー待ち(run createdAt → Tests job startedAt)は
  全時間帯で中央値 ~3 秒 = **ピーク時でも容量枯渇していない**(混雑で割当が遅れる現象自体が無い)。

**なぜ効かないか**: instance gacha は「混雑」ではなく「配置くじ」。速さを決めるのは *どの物理
ホスト/CPU 世代に VM が載るか* であって、その瞬間の世界全体の CI 稼働量ではない → 時刻と無相関。
支配的な変動は 07-05 の段差のような**プール/世代の入れ替わり(日〜週スケール)**で、これは時刻では
動かせない。

**結論**: 作業時間をずらす価値はない。数秒〜数%の未検出効果を狙うより、md-only PR スキップ +
中央値/合計CPU 追跡の方が確実。

## 関連

- [2026-06-22 Parallel spec suite: runtime-based distribution](20260622-parallel-suite-runtime-distribution.md)
  — `--group-by filesize` が「大きいが速い」ファイルで崩れる問題(binpacker 採用の前史)。
- [2026-06-23 binpacker parallel-suite trial](20260623-binpacker-parallel-suite-trial.md)
  — binpacker 導入トライアルと CI 変動の初期観測。
