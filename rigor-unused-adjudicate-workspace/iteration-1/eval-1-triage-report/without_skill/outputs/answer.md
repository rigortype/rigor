# 結論: 6件のうち 3件は誤検出（消してはいけない）、3件だけが実際に消せます

6件すべてを実際に追跡して確認しました。判定は真っ二つに割れます。

| # | 対象 | 判定 | 理由 |
|---|---|---|---|
| 1 | `DigestedAssetsPathResolver` | **消すな** | 4番のジョブが本番で使用中 |
| 2 | `HomeHelper` | 消してよい | 中身が空のモジュール |
| 3 | `ProfilesHelper` | 消してよい | 中身が空のモジュール |
| 4 | `SendTalkReminderPushNotificationJob` | **消すな** | 3分ごとに本番で定期実行中 |
| 5 | `SignageHelper` | 消してよい | 中身が空のモジュール |
| 6 | `TalksHelper` | **消すな** | ERB ビュー3箇所から呼ばれている |

「テストからしか使われてない」というのは**この3件については誤り**です。レポート自身の末尾にも「adjudicated corpus での精度は 7%、全行に人間の確認が必要」と書かれているとおり、これは候補リストであって検出結果ではありません。

---

## 消してはいけない3件

### 4. `SendTalkReminderPushNotificationJob` — 本番で3分ごとに動いています

`config/recurring.yml` から solid_queue の定期実行ジョブとして登録されています。

```yaml
production:
  send_talk_reminder_push_notification:
    class: "SendTalkReminderPushNotificationJob"
    schedule: "*/3 * * * *"
development:
  send_talk_reminder_push_notification:
    class: "SendTalkReminderPushNotificationJob"
    schedule: "*/3 * * * *"
```

しかもこのファイルは飾りではなく、`Procfile` で実際にワーカーに読み込まれています。

```
worker: bin/jobs --recurring_schedule_file=config/recurring.yml
```

消すとトーク開始前のリマインダー Push 通知が本番で止まり、さらにワーカーが存在しないクラス名を解決しようとして定期実行スケジュールごと壊れます。

**なぜ Rigor が見落としたか**: エントリポイントが YAML に書かれているためです。加えて `.rigor.dist.yml` の `paths:` は `app` と `lib` だけで、`config/` はそもそも解析対象に入っていません。Rigor には YAML から辿る手段がありません。

### 1. `DigestedAssetsPathResolver` — 上のジョブの巻き添えです

唯一の呼び出し元が、まさにその4番のジョブです。

`app/jobs/send_talk_reminder_push_notification_job.rb:10,17`:
```ruby
assets_resolver = DigestedAssetsPathResolver.new
# ...
Rails.configuration.application_url, assets_resolver.digested_asset_path("icons/2024/512.png")
```

つまりこれは独立した判定ではなく、**4番の誤検出が伝播した二次被害**です。ジョブが「テストからしか到達しない」と誤判定された結果、その呼び先も自動的に道連れになっています。

これは実際に検証できました。ジョブをルートとして扱わせると、1番も一緒にリストから消えます。

```
$ rigor unused --entry-point "app/jobs/*.rb"
  roots:                    94   (90 から増加)
  reachable only from tests: 4   (6 から減少)
```
→ 4番と1番の両方が同時に消え、ヘルパー4件だけが残りました。

### 6. `TalksHelper` — ERB ビューから呼ばれています

`time_with_zone_to_anchor` はビューの3箇所で使われています。

- `app/views/talks/show.html.erb:47` — 一覧へ戻るリンクのアンカー
- `app/views/talks/index.html.erb:13` — タイムスロットへのジャンプリンク
- `app/views/talks/index.html.erb:22` — 見出しの `id=` 属性

消すとトーク一覧・詳細ページが `NoMethodError` で 500 になります。

**なぜ Rigor が見落としたか**: Rigor は Ruby しか解析しません。このプロジェクトには `app/views` 配下に **82個の .erb ファイル**があり、そのすべてが Rigor から見えていません。Rails アプリでは呼び出しの相当量がビューにあるので、ヘルパーは構造的に誤検出しやすい対象です。

---

## 消してよい3件（ただし効果はほぼゼロ）

`HomeHelper` / `ProfilesHelper` / `SignageHelper` は**中身が完全に空**です。

```ruby
module HomeHelper
end
```

`rails g controller` が生成した雛形がそのまま残っているだけで、メソッドが1つもありません。Rails はデフォルトで全ヘルパーをビューに include しますが、空なので実行時の挙動には一切寄与していません。したがって削除しても**何も壊れないし、何も速くならない**純粋な見た目の掃除です。

削除するなら、以下を**セットで**消してください。片方だけ消すと壊れます。

```
app/helpers/home_helper.rb        + spec/helpers/home_helper_spec.rb        + sig/generated/helpers/home_helper.rbs
app/helpers/profiles_helper.rb    + spec/helpers/profiles_helper_spec.rb    + sig/generated/helpers/profiles_helper.rbs
app/helpers/signage_helper.rb     + spec/helpers/signage_helper_spec.rb     + sig/generated/helpers/signage_helper.rbs
```

spec を残すと `RSpec.describe HomeHelper` が `NameError` になります。なおその spec 自身も中身は雛形で、`pending "add some examples to (or delete) #{__FILE__}"` があるだけです。実は spec 側にも「消せ」と書いてあった、というオチです。

ちなみに「テストから到達している」の実体は、この `RSpec.describe HomeHelper` という**定数参照1個だけ**です。テストが機能を検証しているわけではありません。

---

## 補足: この誤検出パターンについて

6件中3件が誤検出（かつ残り3件も実質無害な雛形）だったのは偶然ではなく、Rails では次の3つが構造的に効いています。

1. **ERB が読まれない** — 82ファイルが不可視。ヘルパーは全滅しやすい
2. **YAML のエントリポイントが読まれない** — `config/recurring.yml` の定期ジョブ、`config/schedule.rb` 系、初期化子経由の登録など
3. **誤検出が伝播する** — 誤って死んだ扱いになったコードの呼び先も連鎖的に死ぬ（1番がまさにこれ）

ノイズを減らすなら `--entry-point` が効きます。グロブの書き方に癖があり、`app/jobs/**/*.rb` は**マッチしません**でした。`app/jobs/*.rb` と書いてください。

```sh
rigor unused --entry-point "app/jobs/*.rb"
```

ヘルパーも一括でルート化すれば静かになりますが、それをやると今回の空ヘルパー3件のような本物も一緒に隠れるので、ヘルパーについては手で見たほうがよいと思います。

なお今回聞かれていない "Candidates" 側の3件（`ApplicationMailer`, `ApplicationCable::Channel`, `ApplicationCable::Connection`）も同種のフレームワーク雛形です。`ApplicationMailer` はサブクラスが1つもないので実際に未使用ですが、`ApplicationCable::*` は ActionCable が名前で解決するため消すと危険です。

## おすすめ

いま消すなら空ヘルパー3件だけ。ただし得られるのは3ファイル（実際には spec と rbs も含めて9ファイル）の削除だけで、リスクに見合うかは微妙です。むしろ、レポート6件のうち半分が誤検出だったという事実のほうが、今後この出力を読むときの前提として重要だと思います。
