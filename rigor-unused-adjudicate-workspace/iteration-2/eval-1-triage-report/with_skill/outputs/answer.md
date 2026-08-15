6件すべて手で裏取りしました。結論から言うと **「テストからしか使われていない」ものは 1件もありません。消していいのは 0件、掃除として消せるのが 3件** です。

## 先に前提の確認（レポートをどう読むべきか）

- **roots は効いています** — `roots: 90 (44 from plugins, 2 matched no declaration)`。Rails プラグインが routes からコントローラを root にしているので、レポート全体は「読む価値がある」状態です（`0 from plugins` なら設定を直すのが先でした）。
- **`paths: [app, lib]` なので `app/views/**/*.erb` は解析対象外です。** ヘルパーの行はこの穴に落ちます。ヘルパー4件はまずここを疑うべき行でした。
- **git 履歴は使えません。** このクローンは shallow (`git rev-parse --is-shallow-repository` → true、74コミット) で、6ファイルすべての「最終更新」が同一の依存bumpコミット (`build(deps): bump jwt …`) として出ます。これは grafts の産物であって、ファイルの古さの証拠にはなりません。なので「最終更新日」は今回の判断材料から外しています。
- **`signature_paths` を空にして再実行**したところ、test-only が 6→10、candidates が 3→9 に増えました（`ProfileDecorator` などの decorator 4件、`SpeakersTalk` / `ProfileBadgesProfile` の中間モデル、`Signage*Resource` 3件が追加）。今回の6件の判定には影響しませんが、`sig/` が参照としてカウントされることで見えなくなっている行がある、という事実だけ頭に置いておいてください（これらも FP 定番の形なので、慌てて消さないこと）。

## 6件の判定

| # | クラス | 判定 | 根拠 |
| --- | --- | --- | --- |
| 1 | `DigestedAssetsPathResolver` | **本番で生きている。消すな** | `app/jobs/send_talk_reminder_push_notification_job.rb:10` で `DigestedAssetsPathResolver.new` として呼ばれている。#4 が誤判定された巻き添えで一緒に落ちてきた行 |
| 2 | `HomeHelper` | 生きている（ただし**空**） | `include_all_helpers` はデフォルト true で、このアプリはどこでも無効化していない → 全ビューに include される。中身は `module HomeHelper; end` の空 |
| 3 | `ProfilesHelper` | 生きている（ただし**空**） | 同上 |
| 4 | `SendTalkReminderPushNotificationJob` | **本番で生きている。消すと壊れる** | `config/recurring.yml` に `class: "SendTalkReminderPushNotificationJob"` として production/development 両方に登録、`Procfile` の `worker: bin/jobs --recurring_schedule_file=config/recurring.yml` で実際にそのファイルが読まれている。3分おきに走る定期ジョブ |
| 5 | `SignageHelper` | 生きている（ただし**空**） | 同上（`include_all_helpers`）。なお `SignageController` は存在せず（あるのは `SignagesController` / `SignageDevicesController`）、命名規約のペアすら外れている |
| 6 | `TalksHelper` | **生きている。消すな** | `time_with_zone_to_anchor` が `app/views/talks/show.html.erb:47`、`app/views/talks/index.html.erb:13,22` の計3箇所で使われている。ERB は解析対象外なので Ruby からの呼び出し元が見えなかっただけ |

## じゃあ何をすればいいか

**消してはいけない（3件）**: `SendTalkReminderPushNotificationJob`、`DigestedAssetsPathResolver`、`TalksHelper`。特に #4 は消しても `rigor check` もテストも通ってしまい、気づくのは「トーク開始のプッシュ通知が来ない」とユーザーに言われたときです。

**掃除として消せる（3件）**: `HomeHelper` / `ProfilesHelper` / `SignageHelper`。ただしこれは「デッドコードを見つけた」ではなく **「`rails generate` の残骸を見つけた」** です。中身が空で、include されても何も足していません。消すなら3点セットで:

- `app/helpers/{home,profiles,signage}_helper.rb`
- `spec/helpers/{home,profiles,signage}_helper_spec.rb` — 中身は `pending "add some examples to (or delete) #{__FILE__}"` だけの雛形で、コメントにも「delete」と書いてあります
- `sig/generated/helpers/{home,profiles,signage}_helper.rbs` — 生成物なので再生成でも可

レビュアーに出すときは「デッドコード削除」ではなく「ジェネレータ残骸の削除」と書いたほうが通りやすいはずです。

## このレポートについて補足

- `rigor unused` の測定済み精度は **7%**（適正化済みコーパスで57行中4行が本当に dead）です。今回 6/6 が false positive だったのは、その水準からすると外れ値ではありません。レポートは欠陥リストではなくレビューキューです。
- 逆方向の見落としもあります。このコマンドは過少報告もするので、「レポートに出ていない = 生きている」ではありません。
- 気づいた点として、`config/recurring.yml` の `"SendTalkReminderPushNotificationJob"` という文字列は、今回のレポートでは `cannot decide` への降格材料として拾われていませんでした（`cannot decide: 0`）。`paths:` に `config` が入っていないことと関係している可能性があります。YAML に文字列でクラス名を書くタイプの仕組み（定期ジョブ、キュー定義、設定ファイル）は、当面は自分で grep して確認してください。
