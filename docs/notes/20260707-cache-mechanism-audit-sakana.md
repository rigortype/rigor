## 次セッション向け引き継ぎメモ: キャッシュ堅牢化・コンパクト化

### 現在の状態

- 変更されているファイルは **`lib/rigor/cache/store.rb` のみ**。
- 変更量はおおよそ **+107 / -17**。
- `ruby -c lib/rigor/cache/store.rb` は **Syntax OK**。
- **spec / docs / CHANGELOG は未変更**。
- **Nix Flake 経由の検証は未実施**。
- 途中の TODO と実コードが一部乖離していたため、次セッションでは **`git diff` を真実として再確認すること**。

---

## ここまでで分かったこと

### 1. ディスク使用量削減の主因は「圧縮率」ではなく「孤児世代」

実リポジトリの `.rigor/cache` では、`rbs.environment` が複数世代残っていた。

- `rbs.environment`: 約 **1.77MB × 7 entry**
- 実際に live なのは概ね 1 世代で、残りは orphan と見られる。
- ただし cache 全体は約 **16MB** 程度なので、既定の **256MB byte cap** では eviction が発火しない。

結論:

> zlib の圧縮レベルを上げるより、content-keyed producer の古い世代を回収する方が本筋。

zlib level 9 の再圧縮効果は小さい。

- 全体で約 8% 程度。
- env blob では約 3% 程度。

そのため、圧縮レベル変更や zstd 導入は現時点では採用しない方針でよい。

---

## 既に `store.rb` に入っている変更

### 1. Payload ABI marker の追加

追加済み:

```ruby
require_relative "../version"

PAYLOAD_ABI_VERSION = Rigor::VERSION
```

`schema_marker_value` は以下の形に変更済み。

```ruby
"#{PAYLOAD_ABI_VERSION}.#{Descriptor::SCHEMA_VERSION}.#{FORMAT_VERSION}"
```

意図:

- Store の Marshal payload を Rigor version 境界で invalidation する。
- byte layout や descriptor schema が変わっていなくても、Rigor 側の class layout / semantics が変わる可能性があるため。
- `IncrementalSnapshot` は既に fingerprint に `Rigor::VERSION` を含めているので、それとの parity でもある。

注意:

- Rigor をアップグレードするたびに cache root が全消去される。
- 初回 run は cold になる。
- これは意図した rebuild だが、ユーザー体感コストはある。

---

### 2. `fetch_or_compute` の write failure を握り潰す変更

追加済み helper:

```ruby
def write_entry_for_compute(path, descriptor, value, serialize: nil)
  return false if @read_only

  write_entry(path, descriptor, value, serialize: serialize)
  true
rescue SystemCallError, IOError
  false
end
```

効果:

- cache root の権限問題
- disk full
- root が途中で削除された
- read-only mount

など filesystem 側の問題で解析 run が落ちず、単に「cache write に失敗した miss」として進む。

意図的に残している挙動:

- serializer が `String` を返さない等の producer contract 違反は `TypeError` として見える。
- これは開発者に知らせるべきエラーなので握り潰さない。

---

### 3. rename 後の directory fsync

`atomically_replace` の rename 後に以下が呼ばれるようになっている。

```ruby
fsync_directory(File.dirname(path))
```

`fsync_directory` は best-effort で、失敗は握り潰す。

意図:

- temp file 自体の fsync に加えて、rename の directory entry 側の耐久性を少し上げる。
- platform 差があるため、失敗しても run は壊さない。

---

### 4. stale temp file cleanup

追加済み:

```ruby
STALE_TEMP_FILE_AGE_SECONDS = 60 * 60
```

`cleanup_stale_temp_files` が `*.tmp.*` のうち 1 時間以上古いものを削除する。

注意:

- 現ディスク上では temp leak は観測されていない。
- 防御的改善。

---

### 5. whole-project producer の generation cap

追加済み:

```ruby
GENERATION_CAP_BY_PRODUCER = {
  "analysis.run-diagnostics" => 16,
  "rbs.class_ancestor_table" => 2,
  "rbs.class_type_param_names" => 2,
  "rbs.constant_type_table" => 2,
  "rbs.environment" => 2,
  "rbs.known_class_names" => 2
}.freeze
```

`evict_excess_generations` が producer ごとに古い世代を削除する。

意図:

- byte cap に届かない orphan 世代を回収する。
- 特に RBS 系 producer は live 世代が少ないため効果がある。

不確実性:

- `analysis.run-diagnostics` の cap `16` は要注意。
- 多数の異なる invocation path-set を使う運用では、まだ使える世代を消す可能性がある。
- hardcoded allow-list なので、新規 whole-project producer は自動では cap されない。

---

## まだ未完了の重要項目

### 1. read-only store の stale marker guard

現状、`ensure_schema_version!` は未変更。

現在のコードは read-only で即 return する。

```ruby
return if @read_only
```

問題:

- Rigor upgrade 後、writable run がまだ走っていない。
- `schema_version.txt` は古い marker のまま。
- LSP / editor mode は read-only store。
- read-only store は marker を確認せず、古い Marshal blob を読んでしまう。

これは payload ABI marker の価値を半分未完成にしている。

次に必要な修正:

- read-only mode でも **marker が current の場合だけ disk read を許可**する。
- marker missing / stale / unreadable なら disk は miss 扱い。
- read-only なので root clear や marker write はしない。

設計案:

```ruby
disk_available = ensure_schema_version!
path = disk_available ? entry_path(...) : nil
```

`ensure_schema_version!` は boolean を返す形にする。

- writable + marker OK / repaired: `true`
- read-only + marker current: `true`
- read-only + marker missing/stale/unreadable: `false`
- filesystem failure: `false`

---

### 2. marker / disk failure の in-memory-only degrade

現状、`ensure_schema_version!` は `mkdir_p`, `File.read`, `File.write`, `Dir.children` などで raise しうる。

改善したい挙動:

- cache root が壊れている
- 権限がない
- root が消えた
- marker が読めない / 書けない

こうした場合でも解析 run を壊さない。

候補:

```ruby
@disk_disabled = true
```

を導入し、marker 確認・修復に失敗したら、その Store instance では disk を諦めて in-memory memo のみ使う。

期待挙動:

- producer block は通常通り実行。
- disk read / write はしない。
- stats は miss として記録。

---

### 3. `atomically_replace` 失敗時の temp cleanup

現状、`atomically_replace` には失敗時の ensure cleanup がない。

現在は 1 時間後の `cleanup_stale_temp_files` に頼る形。

次に入れるとよい形:

```ruby
tmp = nil
begin
  tmp = "#{path}.tmp.#{Process.pid}.#{SecureRandom.hex(4)}"
  ...
ensure
  unlink_entry(tmp) if tmp && File.exist?(tmp)
end
```

---

### 4. specs 未追加

最低限ほしい focused specs:

- `schema_marker_value` が `Rigor::VERSION` を含む。
- stale marker 時に writable store は root を clear する。
- read-only store は current marker のときだけ disk hit を許す。
- read-only store は stale / missing marker の entry を読まない。
- `fetch_or_compute` は filesystem write failure で落ちない。
- serializer contract error は握り潰さない。
- failed temp file cleanup。
- stale `*.tmp.*` cleanup。
- generation cap が old entries を消す。
- generation cap が allow-list 以外の producer を消さない。
- `max_bytes: nil` のとき temp cleanup / generation cap を動かすかどうかの仕様確認。

---

### 5. docs / CHANGELOG 未更新

更新対象:

#### `docs/internal-spec/cache.md`

現在 `"4.2"` と書かれている箇所を更新する。

新形式:

```text
<Rigor::VERSION>.<Descriptor::SCHEMA_VERSION>.<Store::FORMAT_VERSION>
```

read-only marker semantics / generation cap / stale temp cleanup も記載する。

#### `docs/adr/54-cache-slimming.md`

WD3 の eviction 説明に補足する。

要旨:

- byte cap だけでは小規模 repo の orphan 世代が残る。
- whole-project producer には generation cap を追加した。

#### `CHANGELOG.md` `[Unreleased]`

候補:

```markdown
- **[cache]** Persistent cache entries are now rebuilt after a Rigor upgrade and old cache generations are reclaimed more aggressively.
  - The cache root marker now includes the Rigor version, so Marshal payloads written by an older release are not reused after an upgrade.
  - Whole-project cache producers now keep only a small number of recent generations, which prevents stale RBS and run-result cache entries from accumulating below the global byte cap.
```

---

## 次セッションの推奨順序

1. **`ensure_schema_version!` を boolean 化**
   - read-only stale guard
   - disk failure degrade
   - この2つを同時に閉じる。
   - ABI marker の価値を完成させる最重要部分。

2. **`fetch_or_compute` / `fetch_or_validate` に `disk_available` gate を入れる**
   - disk unavailable 時は read も write もしない。
   - producer block は実行する。
   - memo には載せる。

3. **`atomically_replace` に ensure cleanup を入れる**

4. **focused specs を追加**

5. **docs / CHANGELOG 更新**

6. **検証**

最低限:

```sh
nix --extra-experimental-features 'nix-command flakes' develop --command bundle exec rspec spec/rigor/cache/store_spec.rb
nix --extra-experimental-features 'nix-command flakes' develop --command ruby -c lib/rigor/cache/store.rb
nix --extra-experimental-features 'nix-command flakes' develop --command git diff --check
```

可能なら:

```sh
nix --extra-experimental-features 'nix-command flakes' develop --command make verify
```

---

## 設計判断とトレードオフ

### 採用: payload ABI marker

理由:

- Marshal payload は byte format が同じでも、Rigor 側の class layout / semantics 変更で stale になりうる。
- `IncrementalSnapshot` との parity がある。

トレードオフ:

- Rigor upgrade ごとに cache root 全消去。
- 初回 cold run が発生。

---

### 採用: generation cap

理由:

- content-keyed producer は新 key を書く一方で旧 key を消さない。
- byte cap だけでは小さい orphan が残る。
- 実リポジトリで `rbs.environment` の orphan 世代を確認済み。

トレードオフ:

- hardcoded allow-list。
- `analysis.run-diagnostics` cap=16 の妥当性は要確認。
- 将来的には producer metadata で `generation_cap:` を宣言する設計の方がよい可能性がある。

---

### 採用: filesystem failure の degrade

理由:

- cache は best-effort。
- 解析 run を壊してはいけない。

注意:

- producer contract error まで握り潰すとバグを隠すため、serializer の型違反は見えるままでよい。

---

### 非採用: zlib level tuning / zstd

理由:

- 実測で効果が小さい。
- zstd は新規依存にもなる。
- 現在の主要問題は圧縮率ではなく orphan accumulation。

---

## 最後に

次セッションでは、まず **read-only marker guard** と **disk failure degrade** を閉じるのが最優先。

現在入っている ABI marker は方向性として正しいが、read-only store が古い marker を確認せずに読むため、LSP / editor path ではまだ stale payload reuse の穴が残っている。そこを閉じてから specs / docs / verification に進むのが安全。