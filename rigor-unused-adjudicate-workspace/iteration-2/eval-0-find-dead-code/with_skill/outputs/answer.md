# conference-app の棚卸し結果

`rigor unused` を回して、出てきた行を1件ずつ手で判定しました。結論から言うと **消せるものは思ったより少なくて、9ファイル・36行程度** です。

`rigor unused` のレポートはそのまま削除リストにはなりません（このレポートの実測精度は約7%＝ほとんどが偽陽性）。なので全19行を手で潰した結果を、確信度の順に3段階で出します。

---

## 1. 確実に死んでいる（3クラス / 18行）

Alba のシリアライザ3つが、どこからも参照されていません。

| クラス | ファイル |
| --- | --- |
| `SignageResource` | `app/resources/signage_resource.rb:1` |
| `SignageDeviceAssignResource` | `app/resources/signage_device_assign_resource.rb:1` |
| `SignageScheduleAssignResource` | `app/resources/signage_schedule_assign_resource.rb:1` |

**根拠。** `app/resources/` の8個のうち、実際に生きているのは `SignagesController#index` から入る連鎖だけです。

```
SignageDeviceResource（コントローラから）
  → SignagePanelResource
    → SignageScheduleResource
      → SignagePageResource ＋ SignagePanelAssignResource
```

上の3つはこの連鎖の外にあります。リポジトリ全体（`.git`・`vendor` を除く全ファイル、ERB・YAML 含む）を検索して、**出現箇所は自分自身の定義と自動生成された `sig/generated/resources/*.rbs` の2箇所だけ**でした。snake_case のオートロードパス表記（`signage_resource` 等）でも検索しましたが、同じ2ファイルしか出ません。専用の spec もありません。

`SignageResource` と `SignageScheduleAssignResource` は `SignageScheduleResource` を参照していますが、参照される側は生きているので巻き添えはありません。

削除するなら `app/resources/*.rb` と対応する `sig/generated/resources/*.rbs` をセットで。

## 2. 「機能ごと使っていない」雛形（3クラス / 12行）

死んだコードというより、`rails new` が作ったまま一度も使われていない機能です。クラス単体ではなく**機能を畳むかどうかの判断**になります。

**ActionCable** — `ApplicationCable::Channel`, `ApplicationCable::Connection`
`app/channels/` にチャネルが1つもなく、`turbo_stream_from` もブロードキャストも JS 側の `createConsumer` も、`/cable` のマウントもありません。`BroadcastAnnouncementJob` は名前に反して Cable を使わず `UnreadAnnouncement` を insert しているだけです。畳むなら `config/cable.yml` と `config/application.rb:14` の `require "action_cable/engine"` も一緒に。Redis 設定もぶら下がっているので、この一群は少し慎重に。

**ApplicationMailer** — `app/mailers/application_mailer.rb`
サブクラスが1つもなく、`mail(`・`deliver_later`・`deliver_now` がリポジトリ内に一切ありません。畳むなら `app/views/layouts/mailer.html.erb` / `.text.erb`（これも雛形）と `config/application.rb:10` の `require "action_mailer/railtie"` も。

## 3. 空のジェネレータ残骸（3モジュール / 6行）

`HomeHelper`, `ProfilesHelper`, `SignageHelper` — **中身が `module X \n end` だけ**です。

Rails の `include_all_helpers` は無効化されていないので、これらは「読み込まれている」という意味では生きています。ただしメソッドを1つも定義していないので、消しても何も起きません。*死んだコード* ではなく *残骸* として扱ってください。レビュアーに求める注意の量が違います。

---

## 消せなかったもの（＝レポートに出たが生きていた10件）

ここが一番大事なところで、レポートを鵜呑みにしていたら壊していた行です。

| クラス | 生きている理由 |
| --- | --- |
| `SpeakersTalk` | `has_many :speakers_talks` の中間モデル。定数として誰も書かない |
| `ProfileBadgesProfile` | 同上（`app/models/profile.rb:3`） |
| `SendTalkReminderPushNotificationJob` | `config/recurring.yml` に**文字列で**クラス名指定（3分ごと実行） |
| `DigestedAssetsPathResolver` | 上のジョブが使っている。ジョブが誤判定されると芋づるで落ちる典型 |
| `TalkDecorator` ほか3つ | `active_decorator` gem がモデル名から規約で解決する |
| `TalksHelper` | `app/views/talks/*.erb` の3箇所から `time_with_zone_to_anchor` を呼んでいる（ビューは解析対象外） |

---

## 調査上の注意（数字の信頼度）

**デフォルト実行では本命3件が見えませんでした。** 素直に `rigor unused` を回すと候補は3行（ActionCable×2 と ApplicationMailer）だけで、**上の「確実に死んでいる」3つは1つも出てきません**。この repo は `sig/` を `signature_paths:` に配線していて、それを外して再実行すると候補が3→9に増えます（roots が 90→53）。今回の収穫はすべて署名なし実行側から出たものです。両方の和集合を判定しました。Rigor 側の挙動として報告に値すると思うので、必要なら issue を立てます。

**Git 履歴が使えません。** shallow clone（74コミット）で、しかもほぼ Dependabot のバージョン上げです。通常なら「このファイルは最後にいつ触られたか」を判断材料にしますが、今回それは使えないので、上の判定はすべて参照関係の実地調査だけに基づいています。「最近追加されて配線されていないだけの未完成コード」を取り違える可能性は、原理的には残ります。

**取りこぼしはあります（量は不明）。** このレポートが答えるのは「どのクラスも定数として参照されていないか」だけです。具体的には：

- **メソッド単位の死んだコードは一切対象外。** 定数が1回でも名指しされていれば、全メソッドが死んでいてもそのクラスは「到達可能」です。体感的に棚卸しの本丸はこちらだと思いますが、この道具では出せません。
- 解析対象は `paths:` の `app` と `lib` のみ（102ファイル / 2,195行）。`config/`・`db/`・ビューのクラスは対象外です。
- `TIMEOUT = 30` のような値定数は最初から除外されています。

**まとめると**、104クラス中で自信を持って「死んでいる」と言えるのは3クラス。機能ごと畳む判断を含めても9ファイル・36行で、全体の1.6%程度です。棚卸しとしては「思ったより綺麗」という結論になります。

なお conference-app には一切変更を加えていません（Rigor は開発チェックアウトから読み取り専用で実行）。
