# ユーザー向けドキュメント レビュー・バッテリー設計 — chibirigor-review の移植検討

**Status:** design note — 後続作業は `docs/ROADMAP.md` § "Documentation — user-facing
docs review battery" にキュー済み。観測は Rigor v0.1.17 後の working tree
（v0.1.18 サイクル、2026-06-10）に対して。

## 背景と依頼

chibirigor（別リポジトリの二巻本）には多観点レビュー・バッテリーのスキル
`/Users/megurine/repo/ruby/chibirigor/.claude/skills/chibirigor-review/SKILL.md`
がある — 10 レンズ（再現性・型理論・編集者・ドメイン著者・日本語校正・Rigor
フィデリティ・Java 読者・Ruby 読者・書評家・辛口書評家）を 4 レイヤー
（真→伝→読→整）に束ね、レイヤー内並列・レイヤー間順次で回し、各所見をノートに
記録して軸を保った修正だけを選択適用する方法論の凍結。

これと同等の品質保証を Rigor の**ユーザー向けドキュメント**
（[`docs/manual/`](../manual/README.md) と [`docs/handbook/`](../handbook/README.md)）
に適用できないか、という検討。ただし制約が一つ明示された:
**書籍ではなくソフトウェアのドキュメントなので、散文を必要以上に充実させる必要は
ない** — chibirigor の「読み物としての厚み」を称揚するレンズはそのままでは持ち込めない。

## 対象の実測（2026-06-10）

| 対象 | 規模 | 性格 |
| --- | --- | --- |
| `docs/manual/` | 14 章 + `plugins/` + `ci-templates/`、約 2,800 行 | **操作リファレンス**。コードブロックの主役は CLI コマンド・`.rigor.yml`・CI テンプレート（`14-rails-quickstart.md` だけで 58 ブロック、`02-cli-reference.md` 36、`10-mcp-server.md` 30）。 |
| `docs/handbook/` | 12 章 + 付録 12 本、約 10,400 行 | **型モデル解説**。20 ファイルが `assert_type` / `dump_type` 入り Ruby スニペットを持ち、「この式の推論結果はこれ」という**機械検証可能な主張**を大量に含む。 |

機械検証の現状: **ゼロ**。`spec/` にドキュメント・スニペットを実行するテストは
なく、`Makefile` にも docs 対象ターゲットはない。v0.1.16 の docs overhaul
（ROADMAP § "Documentation — user-facing docs overhaul"）はコールドリード検証
込みの一回性の手作業パスで、恒常的なゲートは残していない。

設計上の追い風: 両 README が**軸を既に明文宣言している** —

- 読者宣言（handbook: 静的型素養を仮定しない Ruby プログラマ。付録は
  「Coming from X」が一本ずつ読者を宣言）。
- 分担境界（型モデル=handbook / 操作=manual、両 README が相互に明記）。
- 非目標（handbook: 「数時間で通読できる」「エッジケースは spec corpus へ」
  「Ruby 入門はしない」「プラグイン authoring は examples/ へ」）。
- 用語規約（bare "interface" 禁止 — 初出は必ず *structural interface* /
  *RBS interface*）。
- spec binds（handbook が spec corpus と矛盾したら handbook が直る）。

chibirigor の「共通の約束（軸）」に相当するものを新規に発明する必要がなく、
レビューの判定基準として既存宣言をそのまま渡せる。

## 移植判定 — 何が移り、何が落ち、何が反転するか

**そのまま移る（方法論）:** レイヤー駆動（レイヤー内並列・レイヤー間順次）、
独立コンテキストのサブエージェント、「直ったテキストを次層が読む」ゲート、
所見ノートへの永続記録、軸最優先の選択適用、「一文の手直しには回さない」運用。

**落ちる:** ドメイン著者レンズ（mametter — 自著引用の公正さという問題が無い）、
日本語校正（ドキュメントは英語 → 英語テクニカルライティング校正に置換。AI 調
検出はそのまま有効）、散文の厚み・背景の織り込みを*称揚する*書評家レンズ
（ご指示の制約と正面衝突。リファレンスでは表とコードが主役で、背景の薄さは欠陥
ではない）。

**反転する:** L3 読み味レイヤー。辛口書評家の粗探し属性だけを残して向きを変え、
**痩せ方向ではなく太り方向の検出専任**にする — 水増し・manual/handbook 間の重複
（分担境界宣言が判定基準）・散文で書かれているが表 1 枚で済む箇所・非目標違反
（通読時間の膨張）。説明不足側は L2 の読者レンズが既に担うので二重にしない。

**新設（最大の差分）:** L0 機械層。書籍と違いこのドキュメントの主張の多くは
決定的に検証できる — handbook のスニペットは `rigor check` に通して `assert_type`
主張を実採点でき、manual のフラグ・設定キー・ルール ID は CLI 実体・config
schema・ルールレジストリと突合できる。chibirigor の「採点ハーネス」（読者の再現
実装を採点する）に対応するが、対象がドキュメント自身になる。LLM レンズに行かせる
前に機械で落とすべき故障モード（実装と乖離した旗・出力例）はここで恒久的に塞ぐ。
一度書けば毎リリース無料で回る資産であり、レビュー・バッテリーは「L0 が緑」を
前提に走る。

## 提案構成 — 5 レイヤー

実行順は **機械 → 真 → 伝 → 簡 → 整**。chibirigor 同様、フルサイクルは節目だけ、
日常は困っている層だけを回す。

| レイヤー | 問い | 中身 | 形態 |
| --- | --- | --- | --- |
| **L0 機械** | 検証可能な主張は実挙動と一致するか | (1) handbook スニペット抽出 → `rigor check` 実行 → `assert_type` 採点、(2) manual の CLI フラグ / `.rigor.yml` キー / ルール ID を実装と突合、(3) 相対リンク・ADR 参照の実在性 | **LLM レンズではなく `spec/docs/`（または `make docs-check`）として常設** |
| **L1 真** | 意味的な主張は実装・spec と一致するか | 機械で取れない意味の主張（「キャッシュは X で無効化」「この診断は Y で発火」「balanced では `:info`」）。handbook は spec corpus と（spec binds で判定基準明確）、manual は実装・実挙動と突合。レビュアーは `lib/rigor/` 読み放題 + CLI 実行可。型理論レンズは appendix-type-theory ほか付録群に限定 | LLM レンズ（chibirigor レンズ 6 の主役昇格） |
| **L2 伝** | 宣言された読者に通じるか | (a) **Ruby-only 読者**（chibirigor レンズ 8 ほぼ verbatim — 「過剰な平易化はしない」but 節込み）、(b) **手順再現**（manual 01/14 を本文だけで完走できるか、実行型）、(c) **付録読者**（「Coming from X」を X 経験者として読む — 全 9 本は重いので改稿分のみサンプリング） | LLM レンズ |
| **L3 簡** | 太っていないか（痩せ検出はしない） | 水増し・重複・表で済む散文・非目標違反。辛口書評家の反転版 | LLM レンズ |
| **L4 整** | 英語・用語・体裁 | 英文テクニカルライティング校正（AI 調検出込み）、用語規約準拠（"structural interface" 規約は半機械化可）、manual↔handbook 境界規律、リンク文言 | LLM レンズ（必ず最後） |

## 運用上の決定事項

- 所見ノートの出力先は chibirigor の `_<lens>-review.md` 方式（対象ディレクトリ
  直下）を採らない — `docs/manual/` / `docs/handbook/` は出荷ドキュメントなので
  汚さず、`docs/notes/` 配下に逃がす。
- スキルとして `.claude/skills/rigor-docs-review/SKILL.md` に凍結し、authoring 後
  `waza check` を一度（CLAUDE.md の規約どおり）。
- 初回フルサイクルでは L1 で実装乖離が一定数出る見込み — handbook / manual は
  v0.1.16 の overhaul 時点が最終検証で、その後 ADR-51（CI 出力 6 形式 + CI
  自動検出）等が `11-ci.md` ほかに入っており、追従の検証はされていない。

## 後続作業（ROADMAP にキュー済み）

効果順: **(1)** L0 機械ハーネス（恒久資産で最優先）→ **(2)** `rigor-docs-review`
SKILL.md の凍結（L1–L4 レンズ文面化）→ **(3)** 初回フルサイクル実走。
詳細は `docs/ROADMAP.md` § "Documentation — user-facing docs review battery"。
