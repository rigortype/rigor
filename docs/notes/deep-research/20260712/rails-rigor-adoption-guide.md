# RailsプロジェクトにおけるRigor導入の包括的調査および実践的ガイド：公式仕様とコミュニティ知見の統合的考察

## 1. 序論：Rubyエコシステムにおける型推論の進化とRigorの位置づけ

動的型付け言語であるRubyは、メタプログラミングを駆使した高い記述力と柔軟性により、Ruby on Railsを中心としたWebアプリケーション開発において長年にわたり圧倒的な生産性を提供してきた。しかし、プロジェクトの規模が拡大し、長期間にわたる保守フェーズに移行するにつれて、実行時まで型エラー（特にNoMethodError）が発覚しないという動的言語特有の課題が顕在化する[1]。この問題に対処するため、Stripe社によって開発されたSorbetや、Ruby標準でサポートされるようになったSteep、TypeProfといった静的型チェッカーがコミュニティに浸透してきた[3]。これらの既存ツールは型安全性を飛躍的に高めた一方で、型注釈（Type Annotations）の記述コストや、RBS（Ruby Signature）ファイルの継続的な保守負担（RBSメンテナンス地獄）という新たな課題を開発現場にもたらした[5]。

こうした歴史的背景の中で、全く新しいパラダイムを提示したのが「Rigor」である。Rigorは、型推論（Type Inference）を最優先とし、アプリケーションコードのクリーンさを保ちながら、ゼロ・ランタイム・ディペンデンシー（実行時の依存関係なし）を実現するCLIファーストのRuby向け静的解析器である[7]。本報告書では、複雑なドメインロジックと暗黙的な振る舞いを持つRuby on Railsプロジェクトに対してRigorを導入する際の戦略的アプローチを論じる。ユーザーの要請に基づき、Rigorの公式資料（The Rigor Handbookや公式リポジトリのドキュメント）と、非公式資料（開発者であるtadsan氏の技術書『The Little chibirigor』、RubyKaigi等での登壇資料、開発者コミュニティの知見）を明確に区分しながら、セットアップ手順、導入後の運用、ベストプラクティス、そして高度なトラブルシューティング手法を網羅的に解説する。

## 2. Rigorのセットアップ手順

Rigorのアーキテクチャは、Rails特有のオートロード機構や規約と高度に調和するように設計されている。導入自体はパッケージマネージャを通じた簡潔なプロセスであるが、その裏側ではRailsの動的な性質を静的解析にマッピングするための高度な設定が行われる。

### 2.1 公式資料が規定するインストールと初期化プロセス

公式リポジトリのドキュメントおよびGemの仕様によれば、Rigorを動作させるための必須要件は、Ruby 4.0.0以上（4.1未満）の環境である[7]。インストールは、プロジェクトのGemfileに対して開発用の依存関係として追加することで完了する。

```ruby
gem 'rigortype', require: false
```

ここでrequire: falseを指定することは公式の必須手順とされている。RigorはSorbetのランタイムコンポーネントのようにアプリケーションの実行時にメモリにロードされるライブラリではなく、開発プロセスおよびCI（継続的インテグレーション）環境において外部からコードベースを走査する独立したCLIツールとして機能するためである[2]。

依存関係のインストール後、プロジェクトのルートディレクトリで初期化コマンドを実行する。

```bash
rigor init
```

このコマンドは、プロジェクト内に.rigor.dist.ymlという設定の雛形ファイルを生成する[9]。開発者はこれを.rigor.ymlにリネームし、自プロジェクトの構造に合わせて調整を行う。Rigorの解析エンジンは、このファイルが存在するディレクトリをプロジェクトのルートとして認識し、依存関係グラフの構築を開始する[9]。公式資料において、Railsプロジェクト向けに推奨されている主要な設定項目は以下の通りである。

| 設定キー | 公式資料における役割 | Railsプロジェクトにおける意味合い |
| :---- | :---- | :---- |
| rails_zeitwerk | パス解決アルゴリズムの指定 | trueに設定することで、Rails 6以降の標準オートローダーであるZeitwerkの規約（ファイルパスから定数名を推論する規則）にRigorのモジュール解決メカニズムを適合させる。 |
| autoload_paths | 探索対象のルートディレクトリ指定 | app/models, app/controllers, app/services, app/jobsなど、Railsが自動的にロードするパスを配列で明示し、Rigorに解析範囲を指示する。 |
| concern_dirs | 特殊なモジュール名前空間の指定 | app/controllers/concernsなどのディレクトリを指定し、モジュールのネスト構造とファイルパスの乖離を推論器に正しく認識させる。 |

これらの設定を正確に構成することで、Rigorはファイルの配置からクラスやモジュールの階層構造を正確に逆算し、Railsアプリケーション全体の静的な依存関係グラフを構築する[9]。

### 2.2 非公式資料・コミュニティ知見が明かすセットアップの深層

公式手順では単なる設定ファイルの記述として扱われる設定項目だが、開発コミュニティの技術文書やリポジトリ内の設計議論（ADR）を紐解くと、なぜこれらの設定がRailsにおいて不可欠なのかがより明確になる。

Rigorの内部アーキテクチャでは、ソースコードの構文解析にRust実装のパーサークレートであるruby-prismを利用し、bumpaloクレートの高速なアリーナアロケータを用いてAST（抽象構文木）をメモリ上に構築している[3]。この高速な構文解析フェーズの後、RigorはRailsのメタプログラミングによって動的に生成されるメソッド（例えばActiveJobのperform_laterやActionMailerのdeliver_now）を静的に理解するための「プラグイン機構」を稼働させる[10]。

非公式の設計文書（20260602-plugin-boilerplate-reduction-plan.md）によると、RigorはActiveSupportのInflector（単数形・複数形変換やアンダースコア化を行うモジュール）の挙動を静的にエミュレートする仕組みを持っている[10]。Railsプロジェクト特有のルーティングヘルパー（例: user_path）やモデルの関連付け（has_many :usersから推論されるusersメソッド）は、このInflectorの静的解析プラグインによって裏打ちされている[10]。したがって、.rigor.ymlの設定は、単なるパス指定にとどまらず、これら高度なASTウォーカープラグイン群を正確にブートストラップするための基盤として機能していることがコミュニティの調査から明らかになっている。

## 3. 導入後に必要な運用とCI/CDパイプラインへの統合

Rigorのセットアップが完了した直後に直面するのは、既存のコードベースに対する初回の解析結果の処理と、それをチームの開発フローにどう統合していくかという運用上の課題である。ここでは公式仕様と、現場で実践されている非公式なアプローチを対比しながら解説する。

### 3.1 公式資料が定める初回検査とベースラインの確立

Rigorの初期化後、開発者は以下のコマンドを用いてプロジェクト全体の型検査を実施する。

```bash
rigor check
```

このコマンドは、ソースコード全体のASTを解析し、メソッドの呼び出し可能性や型の整合性を検証する[9]。長年運用されてきた大規模なRailsプロジェクトにRigorを初導入した場合、数百から数千の警告が出力されるのが一般的である。公式の「The Rigor Handbook」およびマニュアルでは、既存コードの警告をすべて即座に修正しようとするのではなく、現在のエラー状態を「ベースライン」として記録する漸進的（Gradual）なアプローチを強く推奨している[11]。

ベースラインを設定することで、過去の技術的負債には目をつぶりつつ、新規に追加されるコードや変更される差分に対してのみ厳格なチェックを強制することが可能となる。また、動的すぎるメタプログラミングなどによってどうしてもRigorが型を証明できない局所的な箇所に対しては、以下の抑制ディレクティブを用いて警告をミュートする公式機能が提供されている[12]。

```ruby
# rigor:disable
```

公式マニュアルでは、診断ルール（Diagnostics）ごとにRule-IDが割り振られており、プロジェクトの成熟度に合わせて重大度プロファイル（Severity profiles）を段階的に引き上げていく運用がベストプラクティスとして定義されている[12]。

### 3.2 非公式資料が示す現場の運用戦略とアーキテクチャ検査

公式資料が提供するベースライン機能に加えて、開発コミュニティではRigorが副次的に生成するモジュール依存関係のデータを利用したアーキテクチャ検査が実践されている。非公式なサードパーティツールであるrigor-module-graphは、Rigorが構築したモジュール解決グラフを利用して、Railsプロジェクト内のパッケージ境界を分析する[9]。

これは、Shopifyが開発したPackwerkなどの境界チェックツールに類似したアプローチであり、rigor checkが生成するJSONL形式のエッジデータを出力することで、Rails特有の「あらゆる場所からあらゆるモデルが呼び出される」という密結合なアーキテクチャを可視化・リファクタリングするための指標として活用されている[9]。

さらに、関西Ruby会議09や関ケ原Ruby会議01などで共有された現場の知見によれば、Rigorの導入はRBSファイルのメンテナンスコスト削減という大きな恩恵をもたらす。従来のSteepやSorbetの運用では、rbs-inlineやrbs_railsといったツールを用いてRBSファイルを自動生成し、依存ライブラリの更新に合わせて継続的にファイルを再生成するCIパイプライン（DependabotやRenovateとの格闘）が必須であった[5]。Rigorはこの「RBS依存」から脱却し、コードそのものの振る舞いから型を直接推論するアプローチを取るため、導入後の運用保守にかかる手数を劇的に削減できるという報告がなされている[5]。

## 4. ベストプラクティス：推論を最大限に活かすコード設計

RigorをRailsプロジェクトで成功させるための核心は、ツールに型注釈を強制するのではなく、Rigorの推論器（Inference Engine）が自然に型を理解できるような、Rubyらしい素直なコードを書くことにある。

### 4.1 公式ハンドブックが推奨する構造的型付けとナローイング

公式ドキュメント「The Rigor Handbook」は、静的型付けの背景知識を持たないRubyプログラマに向けて書かれた体系的なガイドである[11]。ここで最も強調されているベストプラクティスが、制御フローに基づく「ナローイング（型の絞り込み）」と、Ruby特有のデータ構造に対する「Shape（構造）」の活用である。

#### ナローイング（Narrowing）による型の確定

Rigorは変数の状態を分岐ごとに追跡する。例えば、ActiveRecordのクエリ結果がUser | nilとなる場合、明示的な型キャストを書くのではなく、Ruby標準の構文を用いて推論器に型を確定させるアプローチをとる。

```ruby
user = User.find_by(id: params[:id])
# ここでの user の型は `User | nil` (Union型)

if user.nil?
  return render status: :not_found
end

# 制御フローがここを通過した場合、Rigorは user の型を確実な `User` として扱う
user.update!(last_login_at: Time.current)
```

ifやcase、または真偽値を返す述語メソッド（Predicate methods）を利用して変数の取り得る型を削っていくこのアプローチは、コードの可読性を損なうことなく安全性を担保する公式推奨のパターンである[11]。

#### 構造的型付け（Tuples and Hash Shapes）の活用

Railsアプリケーションでは、外部APIとの通信やフロントエンドとのJSONのやり取りにおいて、モデルインスタンスではなくハッシュや配列が頻繁に利用される。Rigorは、リテラル表現（[a, b, c]や{key: value}）のレイアウトを静的に証明できる場合、それらを単なるArrayやHashではなく、厳密な「タプル」や「ハッシュシェイプ」として推論する[11]。

さらに、公式仕様としてTypeScriptのUtility Typesに類似したShape投影関数（Shape-projection functions）が提供されており、動的なハッシュの型定義を強力にサポートしている[11]。

| 投影関数 | 適用効果 | Railsにおけるユースケース例 |
| :---- | :---- | :---- |
| pick_of | 指定したキーのみを抽出したShapeを生成 | JSONレスポンスから必要な属性のみを取り出すシリアライザの戻り値定義。 |
| omit_of | 指定したキーを除外したShapeを生成 | パスワードハッシュや内部IDを除外したAPIレスポンスの構造定義。 |
| partial_of | すべてのキーをオプショナルにしたShapeを生成 | updateメソッドに渡される、一部の属性のみが含まれたパラメータハッシュ。 |
| required_of | すべてのキーを必須にしたShapeを生成 | バリデーション通過後の、欠落が許されない厳格なデータ構造。 |
| readonly_of | 変更不可能なShapeを生成 | 定数化された設定値や、凍結された（frozen）ハッシュオブジェクトの表現。 |

これらの機能を活用することで、Rubyコード内に複雑なクラスを定義することなく、ハッシュオブジェクトのまま型安全なデータの受け渡しが可能となる[11]。

### 4.2 非公式資料に見る「動くコードを脅かさない」漸進的哲学

公式資料が「いかに推論させるか」に焦点を当てる一方で、開発者であるtadsan（にゃんだーすわん）氏による技術書『The Little chibirigor』や各種登壇資料は、「どこまで推論を諦めるか」というより深い設計哲学を明かしている[13]。

Rubyには、TypeProfのようにプログラム全体を「型レベルで実行」し、メソッドの呼び出し元から引数の型までを逆算してRBSを生成するアプローチも存在する[15]。しかし、Rigor（および学習用モデルであるchibirigor）は、あえてこの手法を採用していない。全体実行は、Railsのような巨大で複雑なコードベースにおいては状態の爆発（State explosion）を引き起こしやすく、推論時間が指数関数的に増大するか、大量の誤検知を生む原因となるためである[15]。

Rigorのアーキテクチャの核心は「ボトムアップの合成」である。書いてある式から型を上向きに積み上げることを基本とし、呼び出し元からの引数の逆算は原則行わない。引数の型が不明な場合、Rigorはそれを潔くuntyped（内部表現ではDynamic[top]）として扱う[11]。これは静的解析の「敗北」ではない。tadsan氏の掲げる「動くコードを脅かさない（never frighten working code）」という設計選択であり、不明瞭なものは不明として逃がし、確実に矛盾している（例えばIntegerに対してupcaseメソッドを呼んでいるなど）箇所のみを警告することで、チェッカーの沈黙とスケーラビリティを確保しているのである[14]。

このアプローチは、コミュニティで「ダックタイピングに着想を得たヒューリスティック推論」として広く支持されている。RubyKaigi 2026でのShia氏による発表「Good Enough Types」や、dak2氏の「No Types Needed, Just Callable Method Check」で提唱された「完全な型証明は不要であり、メソッドが呼び出し可能かどうかの確認（Callable Method Check）のみで実用上は十分である」という新しい価値観を、Rigorは体現している[3]。したがって、Railsプロジェクトにおける最大のベストプラクティスは、「型を完全につけることに固執せず、Rigorのダックタイピング・ヒューリスティックに身を委ね、自然なRubyコードを維持すること」である。

## 5. 期待通りに型がつかないときのトラブルシューティング

推論ファーストの哲学を持つRigorであっても、RubyおよびRailsの極度に動的な性質により、推論器が型の特定に失敗しuntypedやNoMethodError相当の警告を吐き出すケースは避けられない。こうした状況において、どのように問題を切り分け、推論器をアシストするべきか、公式の手法と非公式のアーキテクチャ知見の両面から解説する。

### 5.1 公式資料が提供するデバッグツールと回避策

Rigorがなぜ特定の変数をそのように解釈したのか（あるいは解釈に失敗したのか）を調査するため、公式に2つの強力な内部状態検査メソッドが提供されている[12]。

* **dump_type(expr)**: このメソッド呼び出しをコード上に配置してrigor checkを実行すると、チェッカーはその行における指定された式（expr）の推論結果を標準出力またはログに直接ダンプする11。これにより、開発者はRigorが変数をどのように見ているかをリアルタイムに把握できる。
* **assert_type(expr, ExpectedType)**: 指定した式が、開発者の意図する型（ExpectedType）と一致しているかを静的にアサートする11。一致しない場合、Rigorは解析フェーズでエラーを報告するため、複雑なメソッドチェーンのどの段階で型情報が欠落したかを特定するためのブレークポイントとして機能する。

これらのツールを用いて調査した結果、動的すぎるメソッド定義（define_methodによる実行時のメソッド追加など）が原因でRigorの限界を超えていると判明した場合、公式ハンドブックは「RBS」およびその拡張版である「RBS::Extended」を用いた推論の「後押し（nudge）」を最終手段として推奨している[11]。コード本体に冗長な型注釈を汚染させることなく、別ファイルのRBSでシグネチャを定義し、それを外部の真実（Roots）としてRigorの推論器に注入することで、推論不能な壁を越えることができる。

### 5.2 非公式資料が解き明かす推論失敗の根本原因とRails特有の対応

公式資料が「どう対処するか」を教えてくれるのに対し、非公式資料や内部設計の議論は「なぜ型がつかなかったのか」というメカニズムの深い理解を提供する。RailsプロジェクトでRigorの推論が破綻する典型的なパターンは以下の通りである。

#### 動的ディスパッチによるMethodRegistry探索の失敗

Rigorの内部では、MethodRegistryと呼ばれるO(1)でルックアップ可能なハッシュマップ（`HashMap<(ReceiverType, MethodName), MethodInfo>`）が稼働している[3]。例えば、レシーバがString型でメソッド名がupcaseであることが静的に判明していれば、このレジストリから即座に「戻り値はString型である」という情報を引き出すことができる[3]。 しかし、send(dynamic_method_name)やpublic_sendのように、呼び出されるメソッド名が実行時の変数や文字列補間に依存している場合、ASTを静的に走査するRigorはMethodNameを確定できず、レジストリを引くことができない。この結果、戻り値は必然的にuntypedとなる。解決策としては、静的に解析可能な形式にコードをリファクタリングするか、前述のRBSによる明示的なシグネチャ提供が必要となる。

#### Union型の発散と限界

複雑な条件分岐や巨大なコレクションの処理を経た結果、変数の型がString | Integer | Array | nilのような巨大なUnion型に膨れ上がってしまうことがある[1]。Rigorの推論器は、ある変数が複数の型を取り得る場合、安全性を期すために「すべての型で共通して呼び出し可能なメソッド」以外を拒絶する傾向がある。この場合、推論器の欠陥ではなく、単一の変数に多すぎる責務を負わせているコード設計の兆候であると捉えるべきである。メソッドを小さく分割し、早期リターン（Early return）によるナローイングを徹底することで、推論器は再び軌道に乗る。

#### RailsのInflectorとプラグインの不整合

Railsプロジェクトにおいて、URLヘルパー（例: admin_user_path）やモデルの関連付けによる動的メソッドが突然NoMethodErrorとして報告された場合、Rigor内部のプラグイン機構とRailsプロジェクトの設定が乖離している可能性が高い。 前述の通り、RigorのASTウォーカープラグインはActiveSupportのInflectorを静的に模倣している[10]。もし、プロジェクト独自のconfig/initializers/inflections.rbで特殊な単数・複数形の不規則変化規則（Irregular rules）を定義している場合、Rigorの静的パーサーがその初期化ファイルを正しく読み込めていなければ、文字列の変換に失敗し、メソッド名を見失ってしまう。このような場合は、設定ファイル（.rigor.yml）で初期化コードの解析パスが正しく通っているか、あるいはRigorのバージョンアップによって該当プラグインの対応状況が変化していないか（ADRの追跡など）を確認する必要がある[10]。

## 6. 結論と提言

本報告書の分析を通じて、RigorがRailsプロジェクトにおける型安全性の確保において、極めて革新的かつ実用的な選択肢であることが示された。SorbetやTypeProfといった既存のアプローチが、それぞれ型注釈の記述コストや全体実行によるスケーラビリティの課題を抱える中、Rigorは「推論ファースト」と「ダックタイピングに基づくヒューリスティック」という割り切った設計を採用している。

RailsプロジェクトへのRigor導入を成功に導くための要諦は以下の3点に集約される。

1. **漸進的（Gradual）な導入の徹底:** .rigor.ymlでZeitwerkやオートロードのパスを正確に設定した上で、既存コードの警告は一度ベースラインとして吸収する。初日から完璧な型付けを目指すのではなく、日々のプルリクエストで新規に追加されるコードの安全性を確保する防波堤として活用する。
2. **Rubyのセマンティクスを信じた設計:** 型注釈によってコンパイラを満足させるプログラミングスタイルから脱却し、早期リターンやガード節による「型の絞り込み（Narrowing）」や、リテラルベースの「Shape」を活用する。Rigorの推論器が自然と文脈を理解できる素直なRubyコードを書くこと自体が、最高のリファクタリングとなる。
3. **推論の限界を受け入れたトラブルシューティング:** untypedの発生は静的解析の敗北ではなく、Rigorの「動くコードを脅かさない」という哲学の表れである。dump_typeやassert_typeを用いて解析の途切れを特定し、どうしても静的証明が困難なメタプログラミング領域に対してのみ、RBSを用いた外科手術的な「後押し」を行う。

Rigorがもたらす最大の価値は、型の厳密さを追求するあまり失われがちであった「Rubyを書く楽しさ」と「生産性」を取り戻しながら、必要十分（Good Enough）な安全網を敷くことにある。その設計哲学と内部メカニズムを深く理解して運用することで、Railsプロジェクトの保守性と開発スピードは長期的に高められるであろう。

## 引用文献

1. The Ruby Type Checker - Department of Computer Science, [https://www.cs.tufts.edu/~jfoster/papers/oops13.pdf](https://www.cs.tufts.edu/~jfoster/papers/oops13.pdf)
2. Unleashing the Power of Type Checking in Ruby with Sorbet - Harled Inc., [https://harled.ca/blog/unleashing_the_power_of_type_checking_in_ruby_with_sorbet](https://harled.ca/blog/unleashing_the_power_of_type_checking_in_ruby_with_sorbet)
3. ちょっとすごいRubyの型チェッカーを作ってます｜にゃんだーすわん - pixivFANBOX, [https://tadsan.fanbox.cc/posts/11959067](https://tadsan.fanbox.cc/posts/11959067)
4. Sorbet · A static type checker for Ruby, [https://sorbet.org/](https://sorbet.org/)
5. 関ケ原Ruby会議01のGoldスポンサーをしました - リーナー開発者ブログ, [https://developer.leaner.co.jp/entry/regional-rubykaigi-sekigahara01](https://developer.leaner.co.jp/entry/regional-rubykaigi-sekigahara01)
6. 拙者、『型は欲しいが型は書きたくない』者たちとの和睦を結び、るびぃにおける型の領地安堵を実現せんと欲す者也 #sekigahara01/sekigahara01 - Speaker Deck, [https://speakerdeck.com/sanfrecce_osaka/sekigahara01](https://speakerdeck.com/sanfrecce_osaka/sekigahara01)
7. rigortype | RubyGems.org | your community gem host, [https://rubygems.org/gems/rigortype](https://rubygems.org/gems/rigortype)
8. GitHub - rubocop/rubocop: A Ruby static code analyzer and formatter, based on the community Ruby style guide., [https://github.com/rubocop/rubocop](https://github.com/rubocop/rubocop)
9. rigor-module-graph 0.1.3 on Rubygems - Libraries.io - security, [https://libraries.io/rubygems/rigor-module-graph](https://libraries.io/rubygems/rigor-module-graph)
10. rigor/docs/design/20260602-plugin-boilerplate-reduction-plan.md at master - GitHub, [https://github.com/rigortype/rigor/blob/master/docs/design/20260602-plugin-boilerplate-reduction-plan.md](https://github.com/rigortype/rigor/blob/master/docs/design/20260602-plugin-boilerplate-reduction-plan.md)
11. rigor/docs/handbook/README.md at master · rigortype/rigor · GitHub, [https://github.com/rigortype/rigor/blob/master/docs/handbook/README.md](https://github.com/rigortype/rigor/blob/master/docs/handbook/README.md)
12. rigor/docs/manual/README.md at master · rigortype/rigor · GitHub, [https://github.com/rigortype/rigor/blob/master/docs/manual/README.md](https://github.com/rigortype/rigor/blob/master/docs/manual/README.md)
13. The Little chibirigor - Zenn, [https://zenn.dev/tadsan/books/the-little-chibirigor](https://zenn.dev/tadsan/books/the-little-chibirigor)
14. この本について｜The Little chibirigor - Zenn, [https://zenn.dev/tadsan/books/the-little-chibirigor/viewer/about](https://zenn.dev/tadsan/books/the-little-chibirigor/viewer/about)
15. Part 0 はじめに：推論を土台にした型チェッカー｜The Little chibirigor - Zenn, [https://zenn.dev/tadsan/books/the-little-chibirigor/viewer/part0-introduction](https://zenn.dev/tadsan/books/the-little-chibirigor/viewer/part0-introduction)
