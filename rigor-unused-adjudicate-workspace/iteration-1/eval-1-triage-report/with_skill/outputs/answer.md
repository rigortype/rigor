6件を1件ずつ確認しました。**消していいものは0件です。** 4件は本番で動いている生きたコードで、残り3件は「空のモジュール」なので消しても壊れませんが、それは掃除であって死んだコードの削除ではありません。

`rigor unused` が答えているのは「到達可能なコードがこの定数名を書いているか」だけで、「消していいか」ではありません。今回はそのギャップがきれいに出ています。

## 生きている（消すと壊れる）

**4. SendTalkReminderPushNotificationJob** — 本番で3分おきに動いています。

```yaml
# config/recurring.yml
production:
  send_talk_reminder_push_notification:
    class: "SendTalkReminderPushNotificationJob"
    schedule: "*/3 * * * *"
```

このスケジュールは実際にワーカーに読ませています（`Procfile:2` と `deploy/task_definition.jsonnet:17` の両方が `bin/jobs --recurring_schedule_file=config/recurring.yml`）。Solid Queue が**文字列から**クラスを引くので、Ruby のコードには `perform_later` が1箇所もありません。消すとトーク開始前のリマインダー通知が例外も出さずに止まります。

**1. DigestedAssetsPathResolver** — 上のジョブが使っています（`app/jobs/send_talk_reminder_push_notification_job.rb:10` の `DigestedAssetsPathResolver.new`）。ジョブが誤って死んだ扱いになった巻き添えで、こちらも一緒に落ちてきただけです。ジョブが生きている以上、これも生きています。

**6. TalksHelper** — ERB から呼ばれています。

- `app/views/talks/show.html.erb:47`
- `app/views/talks/index.html.erb:13`, `:22`

いずれも `time_with_zone_to_anchor(...)`。`rigor unused` は ERB を読まないので、spec だけが定数名を書いている状態に見えていました。

## 空っぽ（消しても壊れないが、死んでいたわけではない）

**2. HomeHelper / 3. ProfilesHelper / 5. SignageHelper** — 中身は `module Xxx\nend` だけです。

まず前提の確認として、`include_all_helpers` はこのリポジトリのどこにも設定されていません（既定値 `true`）。`ApplicationController < ActionController::Base` なので、`app/helpers/*` は**全部**すべてのビューに include されています。つまりフレームワーク的にはこの3つも読み込まれていて、「到達不能」ではありません。レポートの分類が間違っています。

ただし定義しているメソッドが0個なので、include されていても何も起きません。消したいなら消せますが、消す対象は3ファイルではなく6ファイルです。対になる spec も `rails generate` が置いたままの中身なしなので（3つとも `pending "add some examples to (or delete) #{__FILE__}"` の1行だけ）、一緒に消してください。

- `app/helpers/{home,profiles,signage}_helper.rb`
- `spec/helpers/{home,profiles,signage}_helper_spec.rb`
- ついでに `sig/generated/helpers/{home,profiles,signage}_helper.rbs`

これは「使われていない機能の削除」ではなく「ジェネレータの残骸の掃除」です。判断はお任せします。

## なぜ4件も外したのか

今回のレポートは実質2つのパターンで説明がつきます。どちらも Rails では定番です。

- **設定がクラス名を持っている** — `config/recurring.yml` が文字列でジョブ名を書く。Ruby 側に呼び出しが存在しないのは正常です。
- **`include_all_helpers` は既定で true** — 明示的に切っていない限り `app/helpers/*Helper` は全部生きています。config を1回見れば4行まとめて片付きます。

そのうえで、生きているジョブが参照していた `DigestedAssetsPathResolver` が連鎖で落ちてきていました。1件を生きていると判定したら、そこから参照されている行は独立した候補として扱わずに見直す必要があります。

## 補足と、このレポートの限界

- レポート冒頭の **Candidates（3件）** — `ApplicationCable::Channel` / `ApplicationCable::Connection` / `ApplicationMailer` — は今回の質問の対象外ですが、こちらも鵜呑みにしないでください。特に `ApplicationCable::Connection` は ActionCable が規約に従って名前で参照するクラスで、Ruby のコードからは誰も書きません。`app/mailers/` に `ApplicationMailer` のサブクラスが1つもないのは事実なので、「メーラー機能自体を使っていない」という話にはなり得ますが、それは別途の判断です。
- **このレポートは過少報告します。** root を広く取りすぎる情報源があると、死んでいる行が黙って消えます。今回のように「6件のうち0件」でも、それは死んだコードが0件という意味ではありません。下限値です。
- **メソッド単位の話は一切していません。** 定数名がどこかで1回書かれていれば、中の全メソッドが死んでいてもそのクラスは「到達可能」です。巨大化したモデルの整理には、このコマンドは効きません。

なお `roots: 90 (44 from plugins)` と出ているので、Rails のプラグイン自体はちゃんと効いています（コントローラが軒並み死んだ扱いになる病理的なケースではありません）。

（履歴での裏取りは今回できていません。このクローンは74コミットしか持っておらず、全部 dependabot なので、`git log` の「最終更新」がファイルの実際の変更時期を示していません。上の判定は履歴ではなく参照箇所そのものに基づいています。）
