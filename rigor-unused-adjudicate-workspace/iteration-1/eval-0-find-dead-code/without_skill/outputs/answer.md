# conference-app の棚卸し結果

`rigor unused`(到達可能性レポート)を走らせて、出てきた候補を1件ずつ手で裏取りしました。結論から言うと **「消せる」と断言できるのは 6 ファイル(約 24 行)**、それに加えて **「機能ごと使ってないので捨てるか決めてほしい」ものが 2 件** です。数字としては小さいですが、逆に言うと **このアプリにはほぼ死にコードが無い** ことが確認できた、というのが今回いちばん価値のある結果です。

## 何をどう測ったか

`rigor unused` は「プロジェクト内で宣言されたクラス/モジュールのうち、到達可能なコードから名前を呼ばれていないもの」を出します。診断(`rigor check`)ではなく **レビュー待ち行列** で、公称の精度は 7% 程度(=93% は誤検知)。なので出力そのものは答えではなく、そこから人が絞り込みます。今回はその絞り込みまでやりました。

2 通り走らせています。

| 実行 | roots | candidates | test からのみ到達 |
| --- | --- | --- | --- |
| 既定(`.rigor.dist.yml` のまま) | 90 | 3 | 6 |
| `signature_paths: []`(sig/ を外す) | 53 | 9 | 10 |

差が出るのは既知の挙動で、**生成済み RBS がそのクラス自身への参照として数えられてしまう**ため(rigor 側の issue #363)。`sig/generated` と `sig/rbs_rails` を持っているこのアプリでは、**sig を外した 19 行のほうが正直な上限**です。以下はその 19 行を全部裁いた結果です。母数は「プロジェクト所有の宣言 104 個」。

## 消していいもの(6 個)

### 1. 使われていない Alba リソース 3 つ

| ファイル | 状況 |
| --- | --- |
| `app/resources/signage_resource.rb` | リポジトリ全体で宣言以外の出現ゼロ |
| `app/resources/signage_device_assign_resource.rb` | 中身が空(`include Alba::Resource` だけ) |
| `app/resources/signage_schedule_assign_resource.rb` | 参照ゼロ。しかも `SignageScheduleResource` は `signage_schedule_assigns` に **`SignagePanelAssignResource`** を使っている |

サイネージの JSON は `SignagesController#index` の `SignageDeviceResource.new(...).serialize` 1 箇所からしか作られず、そこから辿れるのは Device → Panel → Schedule → Page / PanelAssign の系列だけ。上の 3 つはどこにも繋がっていません。Alba は名前からリソースを推論する使い方もできますが、このアプリに `Alba.serialize` 相当の呼び出しは無く、明示的な `.new` しか使っていないので推論経由で生きている線もありません。

3 つ目については、`SignageScheduleAssignResource`(未使用)と `SignagePanelAssignResource`(schedule の assigns に使用中)の食い違いが気になります。**単に消すか、実は繋ぐつもりだったのかは、サイネージを書いた人に一度確認してください。** 消すだけなら安全です。

### 2. 空の helper モジュール 3 つ

`app/helpers/home_helper.rb` / `profiles_helper.rb` / `signage_helper.rb` — いずれも `module X\nend` の 2 行、`rails g controller` の生成物です。対応する spec (`spec/helpers/*_helper_spec.rb`) も `pending "add some examples to (or delete) #{__FILE__}"` のまま。**helper と spec をセットで削除**でいいです(合わせて 6 ファイル)。Rails は helper を規約で自動 include するので、レポート上は「test からのみ到達」に見えていますが、中身が空である以上どちらでも同じです。

## 機能ごと決めてほしいもの(2 件)

### ActionCable 一式

`app/channels/application_cable/{channel,connection}.rb` の 2 ファイルだけがあり、**実際のチャネルは 1 つも無い**。`turbo_stream_from` も `broadcast_*` も使っていません(お知らせ配信の `BroadcastAnnouncementJob` は DB に `UnreadAnnouncement` を入れるだけで WebSocket を使っていない)。つまり「このクラスが未使用」ではなく **「ActionCable 機能をまるごと使っていない」**。捨てるなら `config/application.rb` の `require "action_cable/engine"`、`config/cable.yml`、`app/channels/` をまとめて。将来使う予定があるなら現状維持で構いません。

### ApplicationMailer

`app/mailers/` には `application_mailer.rb` しか無く、サブクラスもメール送信も存在しません。こちらも同じ判断(`require "action_mailer/railtie"` ごと落とすか、置いておくか)。ただしメール送信は「そのうち足す」筆頭なので、私なら残します。

## 消してはいけないもの(裏取り済みの誤検知 9 件)

レポートに出るが **生きている** もの。理由をメモしておくと次回の棚卸しが速くなります。

| 名前 | 生きている理由 |
| --- | --- |
| `SpeakersTalk`, `ProfileBadgesProfile` | `has_many :speakers_talks` / `:profile_badges_profiles` の中間テーブル。Rails がシンボルからクラス名を導出するので、コード上に定数として現れない |
| `ProfileDecorator`, `SpeakerDecorator`, `TalkDecorator`, `UserDecorator` | **`active_decorator` gem** がビュー描画時に命名規約で `extend` する。`@talk.sanitized_abstract` などがビューで実際に使われている |
| `SendTalkReminderPushNotificationJob` | `config/recurring.yml` に `class: "SendTalkReminderPushNotificationJob"` として登録された solid_queue の定期実行ジョブ |
| `DigestedAssetsPathResolver` | 上のジョブから使われている(ジョブが生きているので芋づるで生きている) |
| `TalksHelper` | `time_with_zone_to_anchor` を `app/views/talks/{index,show}.html.erb` が使用。ERB は解析対象外なので見えていない |

19 行中、本当に死んでいたのは 6 件。**精度でいうと 32%** で、公称の 7% よりだいぶ良い数字でした(このアプリが小さく、Rails プラグインが効いているため)。

## 次にやると効くこと

1. **`config/recurring.yml` と `active_decorator` を root として教える。** この 2 つが 6 件の誤検知を作っています。当面は実行時フラグで潰せます:
   ```sh
   rigor unused --entry-point='app/jobs/*.rb' --entry-point='app/decorators/*.rb'
   ```
   これで roots が 90 → 94 に増え、「test からのみ到達」が 6 → 4 に減るのを確認済みです。**グロブは `app/jobs/*.rb` と書いてください** — `app/jobs/**/*.rb` は直下のファイルにマッチせず無反応でした。
2. **棚卸しのたびに `sig/` を外した実行も併せて見る。** 既定の実行だと生成 RBS が候補を 9 → 3 に見かけ上減らしてしまい、実際に消せた Alba リソース 3 つは **既定の実行では 1 件も出てきませんでした**。上流の issue #363 が直るまではこの二度撃ちが正解です。
3. **`paths:` を広げるのは効きません。** `config/` を足しても宣言と参照が同じだけ増えるので候補数はほぼ動きません。効くのは root を増やすことだけです。

## まとめの一言

「消せるコードがどれくらいあるか」への答えは **アプリコードで 9 ファイル・36 行(うち即断で消せるのが 6 ファイル・24 行)、加えて未使用の Rails 機能 2 つ**。棚卸しの成果としては地味ですが、104 個の宣言のうち死んでいるのが 6 個という結果自体が、このコードベースがよく手入れされている証拠です。削除より、上の 1. のように root を設定に固定して **次回以降のレポートを読む価値のあるものにしておく** ほうが投資対効果は高いと思います。
