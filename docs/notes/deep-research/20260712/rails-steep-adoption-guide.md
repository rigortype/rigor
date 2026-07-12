# Ruby on RailsプロジェクトにおけるSteep導入の包括的調査報告：公式仕様とコミュニティ実践知の統合

## 1. 序論：動的型付け言語への静的解析導入の必然性とアーキテクチャの概観

2010年代以降、ソフトウェアエンジニアリングの潮流は静的型付け言語の採用へと大きく傾斜してきた。このパラダイムシフトに対し、Rubyの設計者であるまつもとゆきひろ氏は、抽象解釈を武器として「型宣言なしで静的型チェックを行う未来」を提示した[1]。このビジョンの第一歩としてRuby 3.0から標準バンドルされたのが、型定義言語「RBS」と型解析ツール「TypeProf」である[1]。これらに加え、厳密な静的型検査と強力なLSP（Language Server Protocol）の提供を目的として開発されている型検査器が「Steep（soutaro/steep）」である[2]。

Steepは、プログラムの実行前にソースコードとRBSの不整合を検出する静的解析器であり、型推論よりも明示的な型宣言を要求する設計思想を持つ[4]。Rubyエコシステムには複数の型関連ツールが存在するが、それらは推論の強度や検査の厳格さ、実行速度の面で異なるアーキテクチャを採用している。

| ツール名称 | 主な役割とアプローチ | 型推論の強度 | 型検査の強度 | 解析速度 |
| :---- | :---- | :---- | :---- | :---- |
| **TypeProf** | 実コードを抽象解釈し、RBSファイル（型定義）を自動生成する解析器[6]。 | 強い | 弱い | 遅い[1] |
| **Steep** | 用意されたRBS定義に基づき、実コードとの整合性を厳密に検査する静的チェッカー[6]。 | 弱い | 強い | 速い[1] |
| **Sorbet** | 別ファイルのRBSではなく、Rubyコード内に独自DSL（RBI/sig）で型を記述し、実行時検査も兼ね備える[2]。 | 中程度 | 強い | 極めて速い[7] |

本報告書では、純粋なRubyスクリプトとは異なり、メタプログラミングと動的ディスパッチを多用するフレームワークであるRuby on Rails（以下、Rails）プロジェクトに対してSteepを導入するプロセスを論考する。その際、言語処理系やSteep開発者が規定する「公式資料」の仕様と、現場の開発組織が試行錯誤の末に生み出した「非公式資料（コミュニティ実践知）」のパラダイムを厳密に区別し、セットアップから運用、トラブルシューティングに至るまでの全貌を解き明かす。

## 2. セットアップの手順：静的基盤の構築と動的DSLの解決

RailsプロジェクトへのSteepの導入は、基本的な型検査エンジンの初期化を行う公式手順と、Rails特有の黒魔術（動的メソッド）を型検査器に認識させるためのコミュニティ主導の拡張手順の二段構えで構成される。

### 2.1 公式資料が規定する標準セットアップシーケンス

公式ドキュメントにおけるSteepの導入プロセスは、実装と型定義の厳格な分離を出発点とする。まず、プロジェクトの依存関係を管理するGemfileに対し、開発用グループに限定して gem 'steep', require: false を宣言しインストールを実行する[4]。

続いて、CLIから steep init コマンドを実行し、プロジェクトのルートディレクトリに型検査の振る舞いを決定する構成ファイル Steepfile を生成する[4]。この設定ファイル内では、複数のコンテキスト（ターゲット）を定義することが可能であり、アプリケーションコード、テストコード、ライブラリコードそれぞれに対して異なる解析スコープを割り当てる。具体的には、target :app do ... end のブロック内に、実コードのパスを指定する check ディレクトリ（例：app や lib）、型シグネチャを格納する signature ディレクトリ（例：sig）、および依存する標準ライブラリ（例：pathname や set）を明示的に記述する[4]。さらに、configure_code_diagnostics ブロックを用いて、後述する検査の厳格さ（Diagnostics）を制御する設定を記述する[9]。

初期設定が完了した後は、sig/ ディレクトリ配下に .rbs ファイルを作成し、型を宣言していく。公式の手順では、白紙からRBSを記述する負担を軽減するため、rbs prototype rb コマンドを用いて既存のRubyコードの抽象構文木（AST）からプロトタイプとなる型定義を静的生成するか、あるいは rbs prototype runtime を用いて実行時のオブジェクト状態から動的に型定義を抽出するアプローチが推奨されている[10]。最後に、コマンドラインから steep check を実行することで、実コードとRBSのシグネチャ間の静的な整合性検査が開始される[4]。

### 2.2 非公式資料が提示するRails特化型セットアップと依存解決

前述の公式手順をそのままRailsプロジェクトに適用した場合、大量の偽陽性（False Positives）エラーが発生し、解析は実質的に破綻する。原因は、Railsが多用するメタプログラミング（method_missing や define_method によるカラムアクセサやスコープの動的生成）と、膨大なサードパーティGemへの依存である。コミュニティはこの問題を克服するため、高度な依存解決と動的解析ツールの導入を標準化している。

第一に、外部Gemの型定義を解決するための rbs_collection の導入が不可避となる。bundle exec rbs collection init を実行して rbs_collection.yaml を生成し、続いて rbs collection install を実行することで、公式の gem_rbs_collection リポジトリからプロジェクトが依存する各種Gem（actionpack、activerecord など）の型情報が .gem_rbs_collection/ ディレクトリに一括ダウンロードされる[3]。この際、型定義ファイル自体に構文エラーを抱えているGem（コミュニティの報告によれば meta-tags など）が存在する場合、解析器全体がクラッシュする事態を防ぐため、rbs_collection.yaml 内で明示的に ignore: true を指定して当該Gemの型ロードをスキップさせる回避策が広く実践されている[11]。

第二に、ActiveRecordモデルをはじめとするRails特有の動的メソッドの型定義を自動生成する専用ジェネレータの組み込みである。現在、コミュニティでは主に2つの強力なツールが覇権を争っており、プロジェクトの要件に応じて選択される[14]。

| ジェネレータ名称 | アーキテクチャと特徴 | コミュニティにおける評価とユースケース |
| :---- | :---- | :---- |
| **rbs_rails** | Railsアプリケーションのコンテキストをロードした上でRakeタスク（rbs_rails:all）を実行し、ActiveRecordのスキーマやルーティング情報から静的にRBSを出力する[2]。 | 導入事例が極めて多く、安定したデファクトスタンダード。情報量が豊富なため、初期の型導入において最も安全な選択肢とされる[14]。 |
| **orthoses-rails** | orthoses という柔軟なミドルウェア基盤の上に構築されており、アプリケーションのロード時にモジュールやメソッドの動的定義をフックし、より広範なメタプログラミングの痕跡をRBSとして抽出する[14]。 | rbs_rails では対応しきれない複雑なDSLや独自のRailsプラグイン拡張にまで型を付与できるため、近年の中〜大規模プロジェクトで採用が増加している[14]。 |

これらを利用して生成された大量のRBSファイル群と、rbs_collection による外部依存の型情報が揃って初めて、SteepはRailsプロジェクトの全容を正しく抽象解釈し、実用的な静的解析を行う準備が整うのである[7]。

## 3. 導入後に必要なこと：型資産の運用要件とチーム開発への統合

静的型付けの世界において、型定義は一度書いて終わりではなく、アプリケーションの成長に合わせて継続的にメンテナンスされるべき「実行可能なドキュメント」である。導入後の運用フェーズにおいても、公式が想定する理想的なパラダイムと、現場の制約が生み出したコミュニティの自動化パラダイムが存在する。

### 3.1 公式資料が主導する運用パラダイムとインライン型の潮流

公式のエコシステムが前提とする保守作業は、開発者がRubyのロジックを変更するたびに、対となる .rbs ファイルも並行して手動で更新し、常に steep check を通過する状態を維持することである[4]。

しかし、実装と型定義のファイルが物理的に分離していることは、開発時のコンテキストスイッチを増大させ、型定義の乖離（陳腐化）を招きやすい。この課題に対する公式の回答として近年開発が急ピッチで進められているのが rbs-inline である[7]。これは、Rubyのソースコード内に特殊なコメント（マジックコメント）として型情報を埋め込み、トランスパイラを介してRBSファイルを動的生成するアプローチである。具体的には、クラス宣言の直前に # rbs_inline: enabled を記述し、メソッドの上に # @rbs (String) -> String と記述するか、あるいはメソッド定義行の直後に #: (String) -> String とインラインでアノテーションを付与する[20]。公式資料によれば、rbs-inline は将来的にRBS本体に統合される予定のプロトタイプ機能として位置付けられており、エディタから目を離さずに型と実装の整合性を保つための次世代の標準運用フローとして強く推奨されている[20]。

### 3.2 非公式資料が構築する自動化パイプラインと開発文化への適応

実際のRails開発チームにおいて、すべての開発者に高度なRBSの手動保守を要求することは、開発速度の劇的な低下とフラストレーションを招き、型導入そのものの形骸化を引き起こす危険性がある[11]。そのため、現場のプロジェクトでは徹底したトイル（無駄な労力）の削減と、CI（継続的インテグレーション）を軸とした自動化パラダイムが構築されている。

運用上の最初の分水嶺となるのが、自動生成された型定義ファイル群（.gem_rbs_collection/ や sig/rbs_rails/ 配下のファイル）をバージョン管理システム（Git）に含めるか否かという問題である。コミュニティの主流なプラクティスとしては、これらを .gitignore に追加してリポジトリ管理から除外するアプローチが支持されている[11]。この理由は、GemのアップデートやDBスキーマの微細な変更のたびに数千行の型定義の差分が生じ、人間のレビュアーに対するノイズの多いPull Requestが乱造されるのを防ぐためである[11]。

このバージョン管理戦略を支えるため、CI/CDパイプラインには型定義の自動生成と検査のプロセスが強固に組み込まれる。具体的な運用事例として、GitHub Actionsのcronジョブを用いて深夜に rbs collection install や rbs-inline のトランスパイル処理を自動実行し、差分が発生した場合のみBotが自動でPull Requestを作成するワークフローの構築が挙げられる[21]。これにより、開発者は型定義の生成という機械的なタスクから解放され、純粋なビジネスロジックの実装に集中することが可能になる。

さらに先進的な運用として、LLM（大規模言語モデル）を型定義の保守・マイグレーションに組み込む事例も報告されている。既存プロジェクトに残存する古いYARDドキュメントを rbs-inline 形式へ一括変換する際や、TypeProfによる推論結果が広範な untyped（型未定義）にフォールバックしてしまった際、RBS GooseやRoo CodeといったAIエージェントに静的解析の文脈を与え、具体的なクラス型へと詳細化（Refining）させる運用が実運用レベルで成果を上げている[21]。

## 4. ベストプラクティス：型システムの恩恵を最大化し、摩擦を最小化する設計

静的型付けを持たないRubyに後付けで型システムを導入する試みは、常に「型の表現力」と「記述の簡潔さ」のトレードオフとの戦いとなる。本節では、Steepの解析エンジンを正確に駆動させるための公式推奨の構文設計と、Railsプロジェクトにおける開発体験を損なわないためのコミュニティ独自の緩和戦略を対比して解説する。

### 4.1 公式資料が要請する静的解析フレンドリーな設計

Steepは、Rubyの動的な挙動を抽象解釈する際、ソースコード上の静的な記述（AST）を重視する。そのため、コンパイラを正しく誘導するための明示的なアノテーションの付与が公式のベストプラクティスとして定義されている[4]。

第一に、@dynamic アノテーションの徹底である。Rubyでは attr_reader や delegate などを利用してメソッドを生成することが日常的に行われるが、ソースコード上に def 構文が存在しないため、Steepはこれを「RBSには存在するが実装が見当たらない（MethodDefinitionMissing）」としてエラー判定する[4]。これを回避するため、クラス定義内に # @dynamic name, contacts のようにアノテーションを記述し、当該メソッドが動的に実装されていることを明示して静的検査をスキップさせることが仕様上要求される[4]。

第二に、フローセンシティブ・タイピング（Flow-sensitive typing）の制約を補うための @type var アノテーションの利用である[4]。Steepは、is_a? や nil? といった単純な条件分岐に対しては、ブロック内部での型を安全に絞り込むことができる。しかし、untyped な外部入力や、複雑なUnion型（例：Phone | Email）に対して case 文で分岐を行うようなケースにおいて、コンパイラが変数の型を特定しきれない場合がある。このような場面では、条件分岐の直前または直後に # @type var other: Phone のようにローカル変数の型を明示的にキャストするアノテーションを挿入し、コンパイラに型のヒントを与えることが必須のプラクティスとなる[4]。

### 4.2 非公式資料が提唱する「頑張らない型導入」と段階的適応

上記のような公式の厳格なプラクティスをRailsアプリケーション全体に適用することは、極めて高い導入障壁となる。そこでコミュニティ、特に大規模なプロダクション環境を運用する企業群からは、「型検査のパスを最終目的とせず、エディタでのコーディング支援（LSP）を最大化する」という実利主義的なベストプラクティスが提唱されている。このパラダイムはコミュニティ内で「頑張らない型導入」と呼称されている[11]。

このアプローチの核心は、Steepfile の設定において型不整合によるエラーメッセージ（Diagnostics）を意図的にすべてサイレント化することにある。 具体的には、以下のように Steepfile を構成する。設定の意図としては、D::Ruby::ALL に対して nil を割り当てるか、あるいは将来的なAPIである configure_code_diagnostics(D::Ruby.silent) を用いて、Steepからのすべての警告を無視するように指示を出すことである[9]。 この割り切った設定により、開発者は型エラーの修正という多大な苦役から解放される一方で、LSPを通じて、自動生成されたActiveRecordのメソッドやリレーションの強力な入力補完、ホバー時のドキュメント表示といった恩恵だけを純粋に享受することができる[11]。また、CLIやエディタ上だけでなく、katakata_irb などのREPL環境においても、この静的な型情報を活用した実行時のメソッド補完が劇的に向上し、開発効率を飛躍的に高めることが実証されている[11]。

さらに、型検査のエラーを一部有効化してバグの事前検知を狙う場合でも、アプリケーションの全域を一斉に検査対象とするビッグバンアプローチは避けられる。Steepfile の check ディレクトリ指定を利用し、最初は副作用の少ない小規模なモジュール群から着手し、次にコアドメインである app/models へ、最後にロジックが複雑に絡み合う app/services へと、段階的（Incremental）に型検査の対象領域を広げていく漸進的導入が、破綻を防ぐための鉄則として共有されている[7]。

## 5. 期待通りに型がつかないときのトラブルシューティング

型宣言を持たないレガシーコードや、メタプログラミングの極致であるRailsのコードベースに対して静的解析を適用する過程では、型の不整合（Type Mismatch）やメソッドの未定義（NoMethod）といったエラーに無数に遭遇する。本節では、Steepが提供する公式のエスケープハッチと、Rails特有の黒魔術に対するコミュニティのワークアラウンドを詳解する。

### 5.1 公式資料が提供する解析抑制メカニズム

開発を進める中で、コンパイラの推論能力を超える高度な抽象化や、一時的に型の解決を後回しにしたい場面が必ず発生する。Steepはこれらの状況に対応するため、柔軟なエラー抑制機能を提供している。

第一に、Steep 1.7.0より正式導入された steep:ignore コメント機能である[8]。これは従来のプロジェクト全体に適用される設定とは異なり、コードの特定行や特定ブロックに対してピンポイントで型検査を無効化する機能である。 行末に # steep:ignore を記述すればその行の全エラーが無視され、# steep:ignore NoMethod のようにエラー種別を指定することで特定の警告のみを抑制できる[8]。また、広範な処理を対象とする場合は # steep:ignore:start と # steep:ignore:end でブロックごと囲むことで、リファクタリング困難なレガシーコードを安全に解析対象外に隔離することが可能である[8]。

第二に、既存プロジェクトへの導入時に威力を発揮する --save-expectations オプションを用いたエラーのベースライン化である[19]。既存の膨大な型エラーを直ちに修正することが不可能な場合、steep check --save-expectations を実行することで、現在発生しているすべてのエラー情報をYAML形式で保存できる。次回の検査時から with_expectations = true を設定して実行することで、保存されたエラーは「既知の違反」として許容され、以降に新規追加されたコードの型エラーのみをCIで検知する運用が実現する[19]。

第三に、RBSの型システム自体に組み込まれている untyped（型未指定）の積極的な利用である[8]。RBS 3.5以降、引数やブロックに対して型検査を行わないことを明示する構文が強化されており、静的解析が困難な複雑なハッシュの受け渡しや、動的メソッドの引数に対しては、無理に厳格な型を定義しようとせず、意図的に untyped にフォールバックさせることが公式のエコシステムにおいても正しい対処法として扱われている[8]。

### 5.2 非公式資料が解明するRails特有の障壁と実践的ワークアラウンド

Railsアプリケーションにおける型エラーの大半は、開発者のコーディングミスではなく、ActiveSupportが拡張したコアクラスの挙動と、Steepの抽象解釈エンジンとの間のインピーダンス・ミスマッチに起因する。コミュニティはこれらの頻出エラーを分析し、以下のようなワークアラウンドを蓄積している。

#### ActiveSupportの動的表現に起因するエラー

Rubyの標準メソッドではない、Rails特有のメタプログラミング表現はSteepに認識されにくい。例えば class_attribute を用いて定義されたクラス属性のアクセサを呼び出すと、RBS上にはそのシグネチャが存在しないため即座に NoMethod エラーとなる[26]。 また、型絞り込み（Type Narrowing）における限界も深刻である。Steepは nil? や is_a? による条件分岐を通じて変数の型を絞り込むことができる（例：Integer? を Integer に確定させる）[5]。しかし、Rails開発で多用される blank? や present? メソッドを条件分岐に使用した場合、Steepはこれらをコンパイラレベルでの型ガード関数として認識しないため、ブロック内部でも型の絞り込みが行われず、結果として NoMethod エラーが発生し続ける[26]。 この問題に対する最も効果的なワークアラウンドは、型検査器の挙動に合わせてRuby側の実装をリファクタリングすることである。すなわち、if user.present? を if user（直接のnilチェック）に置き換えたり、user.present? ? user.name : nil をRuby標準のぼっち演算子 user&.name に書き換えることで、Steepのフローセンシティブな型推論を正しく機能させることができる[26]。

#### サードパーティGemの型定義不足とモンキーパッチ

kaminari（ページネーション）、discard（論理削除）、draper（デコレータ）など、ActiveRecordのモデルクラスに対して動的にメソッドを追加する拡張Gemを使用した場合、gem_rbs_collection をインストールしただけではプロジェクト固有のモデル（例えば User クラス）にそのメソッドの型は提供されず、User.page(1) などの呼び出しがすべて NoMethod となる[26]。 この課題に対するコミュニティの対処法は以下の通りである。

1. 前述の orthoses 等のミドルウェア型ジェネレータを採用し、実行時にモジュールがincludeされた状態をフックしてRBSを自動生成させる17。
2. 個別のモデルに対して手書きで型定義のスタブを作成するか、AIエージェントを用いて不足しているRBSのモンキーパッチを自動生成して適用する24。
3. ジェネレータ側のアップデート（rbs_rails の拡張など）を待ち、現状は steep:ignore コメントを用いて一律で警告を隠蔽する26。

#### 偽陽性とメソッドシグネチャの不整合

Steepは非常に厳格なチェッカーであるため、メタプログラミングによるメソッド移譲（delegate や method_missing）などにおいて、実際の引数の数やキーワード引数の扱いがRBSの定義とわずかでも異なると、多種多様なエラーを報告する。以下の表は、頻出する診断エラー（Diagnostics）とその発生メカニズムである[30]。

| エラーコード（Diagnostic ID） | 発生メカニズムとコミュニティの対処法 |
| :---- | :---- |
| **Ruby::MethodDefinitionMissing** | RBSに定義されたメソッドが実コード（Ruby）に存在しない（attr_reader などで動的生成されている）。@dynamic アノテーションを付与して回避する[4]。 |
| **Ruby::MethodArityMismatch** | キーワード引数として渡すべきところを順序引数として渡している、あるいは引数の数がRBSと一致しない場合に発生する。移譲メソッドなどではRBS側で引数を `(*untyped) -> untyped` と定義し直して緩和する[24]。 |
| **Ruby::DifferentMethodParameterKind** | 省略可能な引数であるにもかかわらず、RBS側の引数定義に ? プレフィックスを付け忘れている場合に発生する。RBSのシグネチャを修正する[30]。 |
| **Ruby::BreakTypeMismatch** | ブロック内部から break で戻り値を返す際、RBSで定義されたブロックの戻り値型と一致しない場合に発生する[30]。 |
| **Ruby::InvalidIgnoreComment** | steep:ignore コメントの構文が間違っている（前後に別の文字列が含まれているなど）場合に発生する。単独行での記述を徹底する[26]。 |

このように、期待通りに型がつかない場合のトラブルシューティングは、Steep側（RBS）の制約を緩めるアプローチと、Ruby側の実装を静的解析フレンドリーにリファクタリングするアプローチの双方向からの歩み寄りが不可欠となる。

## 6. 結論

Ruby on Railsプロジェクトに対するSteepの導入は、動的言語の極致とも言えるフレームワークの柔軟性と、静的解析が要求する厳密な秩序との間の壮大な擦り合わせ作業である。

公式資料は、Steepfile の緻密な構成、@dynamic や @type var といったアノテーション、そして steep:ignore や rbs-inline のような最新の機能を駆使することで、論理的かつ厳格に型の整合性を担保する強固なフレームワークを提供している。 一方で、実際のプロダクション環境を運用するコミュニティは、この厳密さがもたらす初期の認知負荷と膨大な運用コストを冷静に評価し、rbs_rails や orthoses-rails を用いた型情報の徹底的な自動生成と、「型エラーをサイレント化してLSPによる開発体験の向上のみを抽出する」という極めて実利的なパラダイム（頑張らない型導入）を確立した。

Railsへの型導入を成功させるための最適解は、最初から完全な静的型安全性を追い求めることではない。プロジェクトの性質やチームの習熟度を評価し、まずは自動生成された型定義とLSP補完による恩恵を享受しつつ、コアドメインから漸進的に型検査の厳格度（Severity）を高めていくアプローチである。AIによる型推論の支援や rbs-inline 構文の成熟が加速する現在、公式が提供する洗練された解析エンジンと、コミュニティが練り上げた泥臭いワークアラウンドを適切にブレンドすることこそが、現代のRuby on Rails開発における最も現実的かつ強力な型導入戦略となる。

## 引用文献

1. Ruby3.1 静的解析の導入で開発体験を向上させる (RBS, TypeProf)｜Offers Tech Blog - Zenn, [https://zenn.dev/overflow_offers/articles/20220509-ruby3-type-interpretation](https://zenn.dev/overflow_offers/articles/20220509-ruby3-type-interpretation)
2. [Steep]Railsの本番環境にruby3.0の型定義を入れていく - Qiita, [https://qiita.com/tatematsu-k/items/a0e8bf3a244a6e6b95f5](https://qiita.com/tatematsu-k/items/a0e8bf3a244a6e6b95f5)
3. RBS CollectionをRailsアプリで試してみよう - Zenn, [https://zenn.dev/leaner_dev/articles/20210915-rubykaigi-2021-rbs-collection](https://zenn.dev/leaner_dev/articles/20210915-rubykaigi-2021-rbs-collection)
4. soutaro/steep: Static type checker for Ruby - GitHub, [https://github.com/soutaro/steep](https://github.com/soutaro/steep)
5. いかにして動的型付けのRubyに静的な型検査を持ち込むか？ SteepとRBSが目指すもの - Findy Engineer Lab, [https://findy-code.io/engineer-lab/soutaro](https://findy-code.io/engineer-lab/soutaro)
6. [Ruby3.0]型推論、型検査（Typeprof、Steep）を試してみる - Qiita, [https://qiita.com/_akira19/items/34dbcb1246fbf1a6cf62](https://qiita.com/_akira19/items/34dbcb1246fbf1a6cf62)
7. Rails アプリケーションへの型導入検討 - エムスリーテックブログ, [https://www.m3tech.blog/entry/typed-rails-application](https://www.m3tech.blog/entry/typed-rails-application)
8. Release Note 1.7 · soutaro/steep Wiki - GitHub, [https://github.com/soutaro/steep/wiki/Release-Note-1.7](https://github.com/soutaro/steep/wiki/Release-Note-1.7)
9. RBSとSteepメモ（Ruby、Railsにおける型付け） - Linyclar, [https://linyclar.github.io/rails_memos/typing/](https://linyclar.github.io/rails_memos/typing/)
10. Rubyの型付けの変遷とRBS入門：今から型安全なRubyコードを書くために - Qiita, [https://qiita.com/tatematsu-k/items/0d2874d3fb8de12fd4c9](https://qiita.com/tatematsu-k/items/0d2874d3fb8de12fd4c9)
11. Railsプロジェクトへの「頑張らない型導入」のすすめ - メドピア開発者ブログ, [https://tech.medpeer.co.jp/entry/2023-small-rbs-introduce](https://tech.medpeer.co.jp/entry/2023-small-rbs-introduce)
12. `rbs validate` error with `rbs collection` · Issue #432 · soutaro/steep - GitHub, [https://github.com/soutaro/steep/issues/432](https://github.com/soutaro/steep/issues/432)
13. 小規模Railsプロジェクトに型を導入してみる #rbs - Qiita, [https://qiita.com/ken1flan/items/bcd777ab96fe20dea2ba](https://qiita.com/ken1flan/items/bcd777ab96fe20dea2ba)
14. DSL により動的に定義されるメソッドの型シグネチャの導入｜Rails アプリケーション型付けハンドブック(rbs/steep) - Zenn, [https://zenn.dev/sanfrecce_osaka/books/steep-rails-typing-handbook/viewer/introduce-type-signature-for-defined-method-by-dsl](https://zenn.dev/sanfrecce_osaka/books/steep-rails-typing-handbook/viewer/introduce-type-signature-for-defined-method-by-dsl)
15. Rails RBSを試す - Zenn, [https://zenn.dev/kuronekopunk/scraps/b640bc3ef8dec8](https://zenn.dev/kuronekopunk/scraps/b640bc3ef8dec8)
16. Railsチュートリアルのsample_appに型を導入 - Zenn, [https://zenn.dev/fu_ga/articles/fff97cf13e9b21](https://zenn.dev/fu_ga/articles/fff97cf13e9b21)
17. 【Rails・RBS】VSCodeで型の参照とコード補完ができるようにする, [https://chietech.com/2024/01/03/rails-rbs](https://chietech.com/2024/01/03/rails-rbs)
18. Railsの型ファイル自動生成における課題と解決 / Yuki Kurihara - MIXI DEVELOPERS, [https://mixi-developers.mixi.co.jp/rails%E3%81%AE%E5%9E%8B%E3%83%95%E3%82%A1%E3%82%A4%E3%83%AB%E8%87%AA%E5%8B%95%E7%94%9F%E6%88%90%E3%81%AB%E3%81%8A%E3%81%91%E3%82%8B%E8%AA%B2%E9%A1%8C%E3%81%A8%E8%A7%A3%E6%B1%BA-yuki-kurihara-7b6a522fbf24](https://mixi-developers.mixi.co.jp/rails%E3%81%AE%E5%9E%8B%E3%83%95%E3%82%A1%E3%82%A4%E3%83%AB%E8%87%AA%E5%8B%95%E7%94%9F%E6%88%90%E3%81%AB%E3%81%8A%E3%81%91%E3%82%8B%E8%AA%B2%E9%A1%8C%E3%81%A8%E8%A7%A3%E6%B1%BA-yuki-kurihara-7b6a522fbf24)
19. A Thorough Look into RBS for Rails - Graham Marlow, [https://mgmarlow.com/words/2025-09-21-brief-look-into-rbs-rails/](https://mgmarlow.com/words/2025-09-21-brief-look-into-rbs-rails/)
20. soutaro/rbs-inline: Inline RBS type declaration - GitHub, [https://github.com/soutaro/rbs-inline](https://github.com/soutaro/rbs-inline)
21. AIを使ってYARDからrbs-inlineへ移行しました - kickflow Tech Blog, [https://tech.kickflow.co.jp/entry/rbs-inline-with-ai](https://tech.kickflow.co.jp/entry/rbs-inline-with-ai)
22. RBS に出会って変わった Ruby への向き合い方 - Timee Product Team Blog, [https://tech.timee.co.jp/entry/2024/12/24/000000](https://tech.timee.co.jp/entry/2024/12/24/000000)
23. Ruby の型システムの現実的な運用を、先入観にとらわれずに考えてみた - Wantedly, [https://www.wantedly.com/companies/wantedly/post_articles/545209](https://www.wantedly.com/companies/wantedly/post_articles/545209)
24. RubyKaigi 2024 で RBS と LLM の話をしました - Zenn, [https://zenn.dev/leaner_dev/articles/20240521-rubykaigi-2024-lets-use-llms-from-ruby](https://zenn.dev/leaner_dev/articles/20240521-rubykaigi-2024-lets-use-llms-from-ruby)
25. steep/lib/steep/diagnostic/ruby.rb at master - GitHub, [https://github.com/soutaro/steep/blob/master/lib/steep/diagnostic/ruby.rb](https://github.com/soutaro/steep/blob/master/lib/steep/diagnostic/ruby.rb)
26. Steep-1.7.0.dev.1 の ignore コメントを試す | Webシステム開発, [https://www.timedia.co.jp/tech/20240502-tech/](https://www.timedia.co.jp/tech/20240502-tech/)
27. Steep::CLI - gem.sh, [https://gem.sh/gems/steep/v1.0.1/classes/Steep::CLI](https://gem.sh/gems/steep/v1.0.1/classes/Steep::CLI)
28. Output format selection and improved automation formats · Issue, [https://github.com/soutaro/steep/issues/977](https://github.com/soutaro/steep/issues/977)
29. RubyKaigi2024で印象に残ったセッション - Zenn, [https://zenn.dev/nyancat/articles/20240525-ruby-kaigi-2024](https://zenn.dev/nyancat/articles/20240525-ruby-kaigi-2024)
30. Steep エラーリファレンスを作りました（2024/09/30 時点） - Timee Product Team Blog, [https://tech.timee.co.jp/entry/2024/10/02/153330](https://tech.timee.co.jp/entry/2024/10/02/153330)
