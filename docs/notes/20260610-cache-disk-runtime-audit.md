# キャッシュ機構監査 — ディスク使用量と warm-run ロードコスト

*2026-06-10. Status: measurement note feeding an ADR — informational, not normative. The
spec binds. Observations taken against Rigor v0.1.17 (working tree @ `69aed050`),
macOS / APFS / Apple Silicon。実プロジェクトキャッシュは `rigor-survey/` コーパス
(約 30 プロジェクト + sweep ディレクトリ) と Mastodon を分析。GitLab のキャッシュは
手元に checkout がなく対象外。Redmine の `.rigor` は 248KB しかなく RBS ブロブを
欠いていた(`--no-cache` 運用か env build 失敗の形跡 — 本監査の結論に影響なし)。*

## Question

ADR-6 のファイルシステムキャッシュ(`.rigor/cache`)は、ディスク使用量と
実行時(warm-run)パフォーマンスの観点で改善余地があるか。実際に生成された
キャッシュファイルを測って答える。

## 現状の構成(前提)

- ルートはプロジェクトローカル `.rigor/cache`(`Analysis::Runner::DEFAULT_CACHE_ROOT`)。
- エントリは producer 別シャーディング + `RIGOR\x00\x01` ヘッダ + varint 長 +
  Marshal 値 + SHA-256 トレーラ(`Cache::Store`)。
- RBS 由来 producer は 7 つ(`rbs.environment` / `rbs.instance_definitions` /
  `rbs.singleton_definitions` / `rbs.known_class_names` / `rbs.constant_type_table` /
  `rbs.class_ancestor_table` / `rbs.class_type_param_names`)。いずれも
  単一ブロブ(ADR-7 slice 6-D: per-class ディスクエントリは遅かったため)。
- `max_bytes` のデフォルトは nil = `Store#evict!` は **no-op**。

## 実測 1 — ディスク使用量: ほぼ全プロジェクトが一律 ~32MB、内容は重複

survey コーパスの `.rigor` はプロジェクト規模によらずほぼ一律 **~32MB**
(oj / ox / rbnacl のような小型 gem でも)。Mastodon は 37MB。内訳は
3 つの RBS ブロブが支配的:

| producer | Mastodon 実測 | gzip 後 (比率) |
| --- | --: | --: |
| `rbs.instance_definitions` | 14.5MB | 2.1MB (14.4%) |
| `rbs.environment` | 10.6MB | 1.7MB (16.1%) |
| `rbs.singleton_definitions` | 9.0MB | 1.2MB (13.3%) |
| (残り 7 producer + plugin.* 合計) | ~3MB | — |

さらに、独自 `signature_paths:` を持たないプロジェクト(oj / slim / parser …)は
**キャッシュキーも内容も byte 同一**(`rbs.environment` の entry が同一キー
`a9a23d…`、内容 md5 一致)。つまりこのマシン上の 30+ プロジェクト×32MB ≈
**1GB 超が同一データの重複**である。

## 実測 2 — warm-run ロードコスト: Marshal.load が支配、検証は誤差

`Store#read_entry` の 3 ブロブぶんの内訳(Mastodon キャッシュ、Flake 内実測):

| producer | read | SHA-256 検証 | Marshal.load | 計 (`read_entry`) | allocs |
| --- | --: | --: | --: | --: | --: |
| `rbs.environment` | 1ms | 3ms | 154ms | 163ms | 0.56M |
| `rbs.instance_definitions` | 2ms | 5ms | 366ms | 406ms | 1.06M |
| `rbs.singleton_definitions` | 1ms | 3ms | 180ms | 190ms | 0.58M |
| **計** | **4ms** | **11ms** | **700ms** | **759ms** | **2.2M** |

- ディスク read と SHA-256 エンベロープ検証は合計 ~15ms で誤差。**対処不要**。
- zlib inflate は 3 ブロブ計 ~49ms — Marshal.load の 7% に過ぎず、
  **値ペイロードの圧縮は実行時ほぼ中立でディスク −85% が取れる**。

## 実測 3 — definitions ブロブ 2 つは env キャッシュ前提下でネット負け

ADR-7 slice 6-D の単一ブロブ化は「per-class *ディスク*エントリ vs 単一ブロブ」の
比較であり、「ブロブ vs キャッシュ済み env からの再構築」は測っていなかった。
測ると:

| 経路 | 時間 | allocs |
| --- | --: | --: |
| `rbs.instance_definitions` ブロブ Marshal.load(全クラス) | 366ms | 1.06M |
| キャッシュ済み env から `build_instance` **全 492 クラス** | **137ms** | **0.5M** |
| `rbs.singleton_definitions` ブロブ Marshal.load | 180ms | 0.58M |
| env から `build_singleton` 全 491 クラス | 178ms | 0.6M |
| (参考)主要 12 クラスだけオンデマンド構築 | 0.0ms | — |

instance 側は**再構築の圧勝**(2.7 倍速・allocs 半分)、singleton 側は同等。
しかも実ランが消費する definition は既知クラスの一部なので、遅延構築なら
実コストはさらに小さい(loader には per-process memo
`@instance_definition_cache` / `@singleton_definition_cache` が既にある)。
つまりこの 2 ブロブは **ディスク 23.4MB/プロジェクトを払って warm-run を
最大 ~550ms 遅くしている**。cold-run 側も「全クラス eager 構築 + 23MB 書き込み」
が消えるぶん速くなる。

## 実測 4 — 周辺コスト(いずれも現状は軽微)

- **`RbsDescriptor.build`**(producer ごとに呼ばれ計 7 回/run): 18 ファイルの
  vendored sig + プロジェクト sig の SHA-256 sweep。実測 1.3ms × 7。現状は
  誤差だが、大きな `signature_paths:`(`gem_rbs_collection` 等)では線形に
  効くので loader への per-run memo は安い保険。
- **ADR-45 `fresh?` 検証**(`analysis.run-diagnostics`): Mastodon は
  2,312 ファイル / 15.5MB を全件 re-digest。digest sweep 実測は
  248 ファイル/0.5MB で cold 24ms / warm 5ms — 全体でも warm ~50–150ms 規模。
  mtime fast-path は節約が小さいわりに健全性を落とす(ADR-45 の教訓に逆行)
  ので**非推奨**。

## 実測 5 — eviction とエントリ蓄積

現状 survey 各ディレクトリは 1 entry/producer だが、これは
`Descriptor::SCHEMA_VERSION` bump がルートを全消去してきたため。
schema が安定すると、**rbs gem のバージョン bump や `signature_paths:` 変更は
古いキーの ~33MB ブロブを孤児として残す**(content-keyed なので新キーで書き、
旧キーは誰も消さない)。`max_bytes` デフォルト nil で `evict!` は動かない。

## 所見(改善ポイント、優先順)

1. **definitions ブロブ 2 つの廃止**(実測 3)— `cached_instance_definition` /
   `cached_singleton_definition` をキャッシュ済み env からのオンデマンド構築 +
   既存 per-process memo に切り替える。ディスク −23.4MB/プロジェクト(−70%)、
   warm-run 最大 −550ms / −1.6M allocs、cold-run も短縮。診断 byte-identical +
   `make bench-perf` でゲート。
2. **値ペイロードの zlib 圧縮**(実測 2)— フォーマットバージョン bump
   (`Store::HEADER` の format byte)で deflate 書き込み。残る env ブロブ
   10.6MB → 1.7MB。inflate コストは Marshal.load の 1 割未満。
   1 と合わせて **33.7MB → ~1.7MB(−95%)**。
3. **eviction の既定動作**(実測 5)— 妥当なデフォルト上限(例 256–512MB)
   か起動時 age-based sweep。schema 安定後の孤児ブロブ蓄積を防ぐ。
4. (小)`RbsDescriptor.build` の per-run memo(実測 4)。

### 対処不要と判断した点

- SHA-256 エンベロープ検証・ディスク read(計 ~15ms、誤差)。
- クロスプロジェクト共有ルート(XDG `~/.cache/rigor` に `rbs.*` だけ置く案):
  content-keyed なので安全に共有でき、ADR-6 が defer したのは cross-*machine*
  のみ — だが 1+2 後は重複が ~1.7MB×N に縮み、複雑さに見合わない。
- ADR-45 `fresh?` の mtime fast-path(実測 4、健全性とのトレードに見合わない)。

## Follow-up

所見 1–3 は [ADR-54](../adr/54-cache-slimming.md) に設計判断としてまとめ、
**同日 WD1–WD4 として実装着地**(commits `5f53db09` / `0c671e04` /
`d2465fe1` / `5ced88f1`)。着地時の実測:

- 圧縮後の `rbs.environment` エントリ = **1.76MB**(raw 11.0MB の 16%)。
  アクティブセット全体で **~2.2MB/プロジェクト**(実測 5 の予想どおり)。
- WD3 の孤児ストーリーはこのリポジトリ自身で生体確認: `.rigor/cache` に
  **~180MB / 47 エントリ**が堆積(アクティブは ~2MB / 14 エントリ)。
  4MB 上限の試行ランが stale 分だけを刈り、次ランは warm のまま。
- スライスゲート: cache / environment / configuration スペック、
  self-check 診断の `--no-cache` / cold / warm 一致、Mastodon コーパスの
  no-cache / cold / warm 一致(`--format json` の diagnostics 配列 2,061 件が
  3 ラン完全一致; `stats.wall_seconds` 等のメタデータは比較から除外)。
- Mastodon の `.rigor` ディレクトリ実測: **37MB → 2.6MB**。warm ラン
  (ADR-45 ヒット経路)は新フォーマット下で real ~15s / user ~2.6s
  (並行スペック実行下の参考値; cold は real ~171s)。
- 検証手法の教訓: 旧バージョン比較を `git worktree` + `bundle exec ruby
  <worktree>/exe/rigor` で行うと**両ツリーの Rigor が混載ロード**される
  (`already initialized constant Rigor::VERSION`)。健全なゲートは同一コードでの
  `--no-cache` vs cold vs warm 比較(分析ロジックはキャッシュ非依存)。
