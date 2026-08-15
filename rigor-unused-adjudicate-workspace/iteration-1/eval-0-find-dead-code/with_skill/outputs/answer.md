# conference-app の棚卸し結果

先に結論を。**`rigor unused` は 9 行返しましたが、うち「本当に死んでいるコード」は 0 件です。**
手を入れる価値があるのは、性質の違う 2 件だけでした。

- **A. 中身が空の helper 3 本**(＋雛形のままの spec 3 本)= 実質ノーリスクで消せる 6 ファイル
- **B. 使われていない「機能」2 つ**(Action Cable / Action Mailer の雛形)= 消すかどうかはオーナー判断

削減見込みは合計 9 ファイル・約 40 行。`app` + `lib` が 2,195 行なので、
**このコードベースに目立った死蔵コードはありません**、というのが正直な答えです。

---

## 前提: レポート自体は信用できる状態だった

```
Reachability
  declared (project-owned): 104
  roots:                    90 (44 from plugins, 2 matched no declaration)
  reachable:                100
  candidates:               3
  reachable only from tests: 6
  cannot decide:            0
  namespace-only (excluded): 1
```

まず `roots` を見ています。`44 from plugins` = Rails プラグイン群
(`rigor-actionpack` / `rigor-activerecord` / `rigor-actionmailer` / `rigor-rails-routes` …) が
ちゃんとコントローラやジョブを根として供給できています。ここが `0 from plugins` だと
「コントローラが全部死んで見える」病理パターンで、その場合は行を精査するより先に
プラグイン設定を直す話になりますが、今回はそうではありません。レポートは読む価値があります。

なお `reachable only from tests: 6` は `reachable: 100` の**内数**です(足さないでください)。

---

## A. 消して問題ないもの — 空の helper 3 本

| 対象 | 場所 |
| --- | --- |
| `HomeHelper` | `app/helpers/home_helper.rb` |
| `ProfilesHelper` | `app/helpers/profiles_helper.rb` |
| `SignageHelper` | `app/helpers/signage_helper.rb` |

3 本とも `module Xxx` / `end` だけで**中身が 1 行もありません**。
`config` にも `ApplicationController` にも `include_all_helpers = false` / `clear_helpers` の
記述がないので、Rails の既定どおり全 helper が全ビューに include されています
= 到達可能性の意味では「生きて」いますが、生きているのは空っぽの箱です。

対応する `spec/helpers/{home,profiles,signage}_helper_spec.rb` も
`pending "add some examples to (or delete) #{__FILE__}"` の生成直後のままなので、
helper 本体と一緒に落とすのがきれいです。合計 6 ファイル。

> 補足: `TalksHelper` も同じバケツに出ましたが、こちらは**生きています**(下記)。
> `SessionsHelper` / `ApplicationHelper` はそもそもレポートに出ていません。

---

## B. 「コードが死んでいる」ではなく「機能を使っていない」もの

レポートの candidates 3 行は全部このかたちでした。`rails new` が置いた雛形で、
フレームワークからは参照されるので厳密には「死んだコード」ではありません。
ただ、そのディレクトリに**他に何も無い**ので、正直な所見は
「その機能自体が使われていない」です。判断はお任せします。

### B-1. Action Cable(WebSocket)を一切使っていない

- `ApplicationCable::Channel` — `app/channels/application_cable/channel.rb:2`
- `ApplicationCable::Connection` — `app/channels/application_cable/connection.rb:2`

根拠:
`app/channels` 配下にこの 2 ファイル以外の channel が無い / `turbo_stream_from`・
`broadcast_*`・`broadcasts_to` の呼び出しがコードにもビューにも 1 件も無い /
`config/importmap.rb` に `@rails/actioncable` の pin が無く、JS 側に consumer も無い。
turbo-rails は入っていますが、使っているのは Drive / Frames の範囲で、
Streams(= Cable 経由)は使っていません。

消すなら `app/channels/`、`config/cable.yml`、`config/application.rb:14` の
`require "action_cable/engine"` がセットです。
ただし将来 `turbo_stream_from` を 1 行書いた瞬間に `ApplicationCable::Connection` は
必要に戻ります(既定の接続クラスなので)。削減は 6 行程度なので、
「消す」より「使っていないと認識しておく」ほうが得かもしれません。

### B-2. Action Mailer でメールを 1 通も送っていない

- `ApplicationMailer` — `app/mailers/application_mailer.rb:1`

根拠: `app/mailers` に子クラスが無い / `app` `lib` 全体で `deliver_later`・`deliver_now`・
`mail(` の呼び出しが 0 件(ヒットするのは `config/environments/*.rb` の設定行だけ)。
`app/views/layouts/mailer.html.erb` と `mailer.text.erb` も生成時のままです。

こちらも「メール機能を今後使う予定があるか」で決める話で、
使う予定があるなら残して構いません。

---

## 却下した行(＝触ってはいけないもの)

- **`SendTalkReminderPushNotificationJob`** — 生きています。`config/recurring.yml` に
  `class: "SendTalkReminderPushNotificationJob"` として 3 分おきのスケジュールが
  production / development 両方に定義されています。Solid Queue のスケジューラが
  文字列で名前を呼ぶので、Ruby 側に `perform_later` が 1 件も無いのは正常です。
- **`DigestedAssetsPathResolver`** — 生きています。上のジョブが
  `app/jobs/send_talk_reminder_push_notification_job.rb:10` で `.new` しています。
  ジョブが誤判定された結果、その依存先まで芋づるでレポートに落ちてきた
  **カスケード**です。ジョブが生きている以上、こちらも生きています。
- **`TalksHelper`** — 生きています。`time_with_zone_to_anchor` が
  `app/views/talks/index.html.erb`(2 か所)と `app/views/talks/show.html.erb:47` で
  実際に呼ばれています。ERB 内の helper 呼び出しは解析が追えていないだけです。
- **helper 4 本のクラスタ全体** — `include_all_helpers` の既定 true により全ビューで生きています。
  A 節で消すことを勧めているのは「到達不能だから」ではなく「中身が空だから」です。

---

## この結果の限界(読む前に知っておいてほしいこと)

1. **これは下限であって棚卸し表ではありません。** 根を過大に申告するプラグインがあると、
   行は黙って消えます。「他に死蔵コードは無い」ではなく「この手法で見える範囲では無い」です。
2. **メソッド単位の話は一切していません。** 定数が 1 回でも名指しされていれば、
   その中の全メソッドが死んでいてもクラスは「到達可能」と数えられます。
   もし本当の悩みが「肥大化したモデル」なら、このツールは答えになりません。
3. **今回は `app` と `lib` だけが解析対象です**(`.rigor.dist.yml` の `paths`)。
   `app/views` の ERB 83 ファイルと `spec/` は解析パスに入っておらず、
   `TalksHelper` の件が示すとおり ERB 経由の参照は追えていません。
   ビューテンプレート自体の死蔵は、この結果からは何も言えません。
4. `cannot decide` は 0 件でした(実行時に名前を組み立てられうる、と判定された行はゼロ)。

---

*conference-app には一切変更を加えていません(解析実行により `.rigor/` キャッシュが
更新されるのみで、これは元から untracked のディレクトリです)。*
