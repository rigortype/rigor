# gem_rbs_collection audit, re-run on master — what moved since 0.4.7

Status: field report, no design commitments. Re-runs the
[2026-11-06 audit](20261106-gem-rbs-collection-audit.md) on Rigor master four days later and
classifies every remaining `rigor check` error. It also hand-checks a sample of `sig-gen`
`tighter_return` proposals against the gems' source. The question: what has master fixed, and which
Rigor-side gaps still cost a collection sig author most?

## Method and what differed from the baseline

| | baseline (2026-11-06) | this run (2026-11-10) |
| --- | --- | --- |
| Rigor | 0.4.7 gem, mise install | master `374dcf6ae916730124874afb91d5dffae29e00ad` (`VERSION` still reads 0.4.7) |
| Engine Ruby | mise 4.0.6 | Flake 4.0.5, `bundle exec` against the checkout's `vendor/bundle` |
| Collection checkout | `main` before 12:49 that day, presumably `a2080c5` | `8b20c86`, which adds the faraday `?match_data:` fix, plus the local marcel edits |
| `rigor check` cache | default (cold first run) | `--no-cache` on every `check` |
| Oracle gems | `ruby -e Gem::Specification.find_by_name` under mise 4.0.6 | the same 4.0.6 binary with its default gem paths (see below) |
| Output | `tmp/rigor_audit.jsonl` | `tmp/rigor_audit_374dcf6ae.jsonl`, plus each check and sig-gen stdout saved separately |

The harness is unchanged (`bin/rigor_audit_all`, resumed with its argument). The whole batch ran in
one `nix develop` shell with three shims first on `PATH`:

- `rigor` runs `BUNDLE_GEMFILE=<rigor>/Gemfile BUNDLE_PATH=<rigor>/vendor/bundle bundle exec ruby
  <rigor>/exe/rigor "$@" </dev/null`. It restores the Flake's `PATH` and `GEM_PATH` and inserts
  `--no-cache` after `check`. It tees stdout into one file per gem, keyed by the cwd.
  `--version` cannot tell master from 0.4.7 because the version constant was not bumped. Proof
  that the shim runs master instead: `$LOADED_FEATURES` resolves `rigor/cli.rb` under the
  checkout's `lib/`, and the master-only fixes below, #2884 above all, are present.
- `ruby` calls `/Users/megurine/.local/share/mise/installs/ruby/4.0.6/bin/ruby` directly, with
  `GEM_PATH`, `GEM_HOME` and `RUBYLIB` unset. No `mise` command ran.

Two traps showed up while setting this up:

1. **The Flake's `ruby` is a wrapper that `--set`s `GEM_PATH`**, so exporting `GEM_PATH` does not
   reach the lookup.
2. **The unwrapped Flake Ruby cannot see native-extension gems built for mise 4.0.6.** It drops
   them silently as "extensions not built". The first pass therefore reported `gem not installed`
   for bcrypt, bigdecimal 3.1 and 4.0, cgi, llhttp, msgpack, nkf, oga, racc and stackprof. Those
   ten rows were deleted and re-run through the resume path with the 4.0.6 binary. A resolver
   diff over all 196 dirs confirmed that baseline-equivalent lookup now matches for every gem.

The batch took about 20 minutes and nothing hung. The baseline's `faker/2.23` and `nokogiri/1.11`
sig-gen rows were `parse error`; both parse now. The cause was not recovered, and the like-for-like
sig-gen totals below exclude those two gems.

Two collection-side changes since the baseline move numbers without any engine change:

- `8b20c86` made `Faraday::Adapter::Test` `match_data` optional, which removes faraday/2.5's
  `call.argument-type-mismatch`.
- `bin/test` left `_test/.gem_rbs_collection/` install directories in faraday 2.5 and 2.7,
  retryable 3.0 and marcel 1.0. The faraday ones now raise
  `rbs.coverage.definition-build-failed` (`DuplicatedMethodDefinitionError`) warnings, because
  `signature_paths: [".."]` loads `_test/` too.

## `rigor check` results

| | baseline | master | delta |
| --- | ---: | ---: | ---: |
| clean dirs | 130/196 | 130/196 | 0 |
| errors | 42 in 19 gems | 28 in 17 gems | −14 |
| warnings | 198 | 200 | +2 |
| info | 6 | 6 | 0 |

The count of clean dirs is unchanged, but the set moved: email_address/0.2 became clean and
faraday/2.7 picked up a warning. Every per-gem change:

| gem | baseline | master | cause |
| --- | --- | --- | --- |
| email_address/0.2 | 14 errors | clean | #2884 fixed (`def self.new: -> Address` honoured); positive control `EmailAddress.new(…).nope` reports on `EmailAddress::Address` |
| faraday/2.5 | 1 error | 1 warning | collection `8b20c86` fixed the RBS; the warning is the stray `.gem_rbs_collection/` dir |
| faraday/2.7 | clean | 1 warning | stray `.gem_rbs_collection/` dir |
| concurrent-ruby/1.1 | 4 errors | 5 errors | master now types `then`'s block parameter from `Future[T]`, so a wrong overload pick (below) surfaces once more at `promises.rb:18`; 0.4.7 re-run on the same tree confirms 13/68/82/84 were the baseline four |

Error rules on master: `call.undefined-method` 21, `call.argument-type-mismatch` 4,
`call.possible-nil-receiver` 2, `flow.always-raises` 1. The warning mix is unchanged:
`call.unresolved-toplevel` 147 and `rbs.coverage.definition-build-failed` 46. 37 of those 46 are
`NoMixinFoundError` / `NoSuperclassFoundError` for a dependency gem's RBS that the harness does not
put on `signature_paths`.

### Every master error, classified

The baseline's three buckets only cover 19 of the 28. The other nine are a fourth kind: a
dependency's RBS is missing from the harness, so they are neither a Rigor false positive nor an
RBS bug. The baseline note also left its single-error gems unclassified; they are the same nine.

**Rigor false positive: 11 errors.** Each repro below was run under
`check --no-cache` on master, with a control that fires.

| site | mechanism | minimal repro | issue |
| --- | --- | --- | --- |
| concurrent-ruby `promises.rb:13`, `:18`, `:68` | Overload selection accepts a signature-only class as a `maybe` match for an unrelated signature-only class, so the first overload wins. `any_fulfilled_future(*Event) -> Future[nil, bot]` is taken for `Future` arguments; `Event#&`/`zip(Event) -> Event` is taken for a `Future`, which then reaches `Kernel#then` and reads `bool`. | `class Ev; def zip: (Ev) -> Ev \| (Fut) -> Fut; end; class Fut; def value: () -> Integer; end` then `Ev.new.zip(Fut.new).value` reports `value` undefined on `Ev`. The same shape with `String \| Integer` selects correctly. | #2844 covers it in its cause section (`Nominal` as well as `Singleton`), though its title says singleton only |
| concurrent-ruby `promises.rb:82`, `:84` | A method type parameter's upper bound is ignored in overload selection. `make_future: … \| [X < AbstractEventFuture] (X) -> X \| …` binds `X = RuntimeError` or `X = String`. The bound is ignored even for a core bound class. | `def make: [X < Numeric] (X) -> X \| [T] (T) -> Array[T]` then `make("s")` types `String` | unfiled |
| faker `test.rb:49` | RBS `A & B` reads as its first informative member (#529). `Faker::Base.unique: () -> (UniqueGenerator & class)`: `class` translates to untyped, so the receiver is `UniqueGenerator` and `first_name` reads as undefined. | `def self.unique: () -> (Gen & class)` on `Base`, `Name < Base` with `def self.first_name`; `Name.unique.first_name` reports | #3032 |
| stripe `stripe.rb:9` | Same mechanism with an interface: `Customer#address: () -> (StripeObject & _Address)?` drops `_Address`, so `city` reads as undefined | `def address!: () -> (Obj & _Addr)` then `.city` reports on `Obj` | unfiled, same issue as faker |
| csv `test.rb:19`, `:27` | The collection's `csv/3.3/csv.rbs` is quarantined whole as a duplicate of the bundled stdlib CSV. The rbs 4.2 stdlib CSV RBS declares no `CSV.open`, so `CSV.open("f")` types `IO?` (`type-of` shows `IO?`; probably private `Kernel#open`), giving `possible-nil-receiver`. | `require "csv"; b = CSV.open("example.csv"); b.read` with `libraries: [csv]` | unfiled. Same family as the baseline's abbrev collision; cgi, bigdecimal and yard are also quarantined |
| sentry-ruby `test.rb:14` | `flow.always-raises` at error severity on `1 / 0` inside `begin … rescue ZeroDivisionError` | the three-line `begin/rescue` | related to #2116, which says a raise inside `begin…rescue` must flow to the handler; the diagnostic itself is unfiled |
| rack `body_proxy.rb:8` | Steep's `# @type var app: Rack::_Application` plus `app = _ = nil` is not honoured, so `app` is `nil` | — | by design: `docs/handbook/appendix-steep.md` gives core no in-source annotations |

**Real RBS bug, Rigor correct: 4 errors.** All four are retryable/3.0 `test.rb:41,59,91,92`. The
cause is `gems/retryable/3.0/retryable.rbs:74`, where `type options` declares all ten keys
required. The fix is ruby/gem_rbs_collection#1126, which is not in this checkout.

**Intentional: 4 errors.** protobuf/3.10.3 `enum.rb:9,10` and `messages.rb:18,19`: `___error___`
markers.

**Missing dependency RBS (harness): 9 errors.** ActiveSupport core extensions are absent because
the gemspec dependency is not on `signature_paths`:

- `1.hour` in actionmailer/8.1 `railsguides.rb:69` and activerecord/8.1 `:187`
- `5.minutes` in activestorage/8.1 `:33` and delayed_job/4.1 `:14`
- `1.minute` in activejob/8.1 `:48`
- `1.week` in json-jwt/1.16 `:23`
- `blank?` in carrierwave/3.0 `:30`
- `present?` in cancancan/3.5 `:16`
- `as_json` in active_model_serializers/0.10 `:47`

## `sig-gen --diff` results

191 dirs produced sig-gen JSON; the baseline had 189. The 5 dirs still reporting `gem not installed`
are the same 5 as the baseline.

| classification | baseline (189) | master, same 189 | delta | master, all 191 |
| --- | ---: | ---: | ---: | ---: |
| `new_method` | 27,316 | 27,253 | −63 | 27,570 |
| `tighter_return` | 2,736 | 2,722 | −14 | 2,862 |
| `skipped` | 97,211 | 97,318 | +107 | 98,613 |

The net movement is small, and it goes from `new_method`/`tighter_return` into `skipped`. A
candidate-level diff against 0.4.7 on three gems attributes it:

- activesupport/8.1 lost 9 `tighter_return` that read an ivar written elsewhere. Examples are
  `BroadcastLogger#debug?` → `bool` and `MockLogger#flush` → `Integer`; both are now
  `untyped-return` skips. This matches the cross-file ivar-join and census commits since 0.4.7
  (`61ed87d87`, `c8a50708f`). It is a precision loss, not a wrong answer.
- activesupport/7.0 gained 6 `-> Array[untyped]` proposals on `define_callbacks` wrappers such as
  `ExecutionWrapper.to_run`.
- activerecord/8.1 moved `Preloader::Association#records_by_owner` to
  `overridden-by-unsigned-subclass`, which is correct.
- faraday/2.5 and 2.7 each gained one proposal. It is wrong; see the sample below.

Top gems by `tighter_return`:

| gem | count |
| --- | ---: |
| activerecord/8.1 | 371 |
| activesupport/8.1 | 294 |
| activerecord/7.2 | 265 |
| activerecord/8.0 | 263 |
| activesupport/7.0 | 256 |
| actionpack/8.1 | 154 |
| actionpack/7.2 | 152 |
| nokogiri/1.11 | 140 (new; parse error in the baseline) |
| yard/0.9 | 128 |
| mail/2.8 | 107 |

2,841 of the 2,862 proposals tighten a declared `untyped`. 112 propose `bot` and 45 propose `top`.

`skipped` by reason, with the top gems for each:

| reason | count | top gems |
| --- | ---: | --- |
| `sig.skipped.untyped-return` | 94,882 | stripe/20.0 39,578; parser/3.2 6,533; google-cloud-ai_platform-v1 3,230; activerecord/8.1 2,877 |
| `sig.skipped.unresolvable-superclass` | 3,231 | concurrent-ruby/1.1 437; rubyXL 180; oga 178; graphql 166 |
| `sig.skipped.overridden-by-unsigned-subclass` | 465 | activerecord 7.2/8.0 61 each, 8.1 52; graphql 29 |
| `sig.skipped.unrenderable-rbs` | 20 | yard 5 |
| `sig.skipped.top-level-def` | 15 | yard 10 |

## A sample of `tighter_return` proposals, checked against gem source

28 proposals were read against the installed gem's `lib/`. They span the highest-risk slice (all
21 that tighten a non-`untyped` declaration), a random draw from other gems, and spot checks of the
`bot` proposals.

**Wrong. These would mislead a sig author.**

| gem | proposal | why it is wrong | repro / issue |
| --- | --- | --- | --- |
| mail/2.8 | `Mail::Utilities#uri_parser -> URI::RFC2396_Parser` | drops the `else URI` arm | #2950, still open |
| faraday/2.5, 2.7 | `Stub#matches? -> [bool, {}]`, declared `[bool, { ?match_data: MatchData? }]` | `meta = {}` is filled by the callee `path_match?(path, meta)`; the empty-record literal ignores a write through an argument | `meta = {}; [fill(meta), meta]` with `fill` writing `meta[:k]`; unfiled |
| railties/8.1 | `Rails::Railtie::Configuration#watchable_files -> []` | `@@watchable_files ||= []` is a mutable registry that apps `concat` into; an empty tuple is never the right signature | `def files = (@@files ||= [])` proposes `[]`; unfiled (sibling of the closed #2293) |
| tzinfo/2.0 | `DataSource#get_country_info -> bot`, declared `CountryInfo` | template method: calls the protected hook `load_country_info`, which the base raises in and `RubyDataSource`/`ZoneinfoDataSource` override | `Src#get_info` calling a protected hook overridden by `Src::Impl` in another file proposes `bot`; unfiled |
| tzinfo/2.0 | `Timezone.all_data_zone_identifiers -> bot`, declared `Array[String]` | same: dispatches to the abstract base's `data_timezone_identifiers` | unfiled, same issue |
| rest-client/2.1 | `AbstractResponse#inspect -> bot`, declared `String` | abstract `raise NotImplementedError`; `Response` and `RawResponse` override it. The `overridden-by-unsigned-subclass` guard does not fire because the subclasses are signed | unfiled |
| rails-html-sanitizer/1.6 | `Sanitizer#sanitize -> bot`, declared `String` | same: abstract base whose signed subclasses implement it | unfiled, same issue |
| lint_roller/1.1 | `Plugin#about -> bot`, `#rules -> bot` | abstract base that plugin gems outside the analysed `lib` implement | unfiled, same issue |
| activerecord/8.1 | `SchemaStatements#indexes`, `#rename_table`, `#change_column`, … `-> bot` (21 in 8.1) | module-level abstract methods that every adapter overrides; the subclass guard does not see module includers | unfiled, same issue |
| stackprof/0.2 | `StackProf.run -> bot`, `.results -> bot`, declared `Hash[Symbol, untyped]` | taken from `stackprof/truffleruby.rb`, which loads only under `RUBY_ENGINE == "truffleruby"`; on MRI the C extension defines them | unfiled |
| sidekiq/7.0 | `Job::ClassMethods#perform_in -> String`, declared `top` | `Client#push` returns `nil` when middleware halts the job. Rigor is faithful to the collection's RBS, which is the real bug: `gems/sidekiq/7.0/client.rbs:27` `push -> String` (also `transaction_aware_client.rbs:3`, `job.rbs:12`) should be `String?` | collection RBS bug |

**Correct.**

- sidekiq `Capsule#mode -> :random | :strict | :weighted`
- activesupport `DateTime#utc -> Time`
- activesupport `CallbackChain#prepend -> Array`
- activesupport `EventReporter#subscribe -> Array`
- launchdarkly `BigSegmentStoreManager#poll_store_and_update_status -> BigSegmentStoreStatus`
- launchdarkly `DynamoDB.new_feature_store -> CachingStoreWrapper`
- actionpack `ParameterMissing#corrections -> Array[String]`
- actionpack `Request::Session.disabled -> Session`
- activemodel `Type::Date#type_cast_for_schema -> String`
- sinatra `Base#halt -> bot`, from `throw`
- mini_magick `MogrifyRestricted#format -> bot`, a deliberate `NoMethodError`
- redis `Future#class -> singleton(Redis::Future)`
- async `Clock.now -> Float`
- activerecord `Association#reload -> Association | nil`
- parser `Diagnostic#render -> [String×5] | [String×3]`, accurate but over-precise (an author writes `Array[String]`)

**Noise, not wrong.** Several proposals tighten to `top`, for example yard `CLI::Help#run` and
activemodel `LazyAttributeHash#marshal_load`. They are formally tighter than `untyped` but nobody
would write them; the sample turned up 45.

Read across the `bot` stream: 52 of the 112 `bot` proposals have a
`NotImplementedError`/"must implement" body. Some of those are final behaviour and correct, such as
`InlineAdapter#enqueue_at`. But every overridden abstract method that was checked was wrong, so
`bot` needs a review gate before it is applied. The same advice was in the baseline note; it now
has a mechanism behind it.

## Rigor-side gaps, ranked by cost to a collection sig author

1. **`bot` proposed for abstract and template methods that are overridden.** The current guard
   misses three cases: signed subclasses (rest-client, rails-html-sanitizer), module includers
   (activerecord `SchemaStatements`), and indirect dispatch to an overridden hook (tzinfo).
   Implementations outside `lib` (lint_roller) are a fourth. The result is a wrong signature that
   would break Liskov compatibility with every override. Unfiled.
2. **Dependency RBS is not resolved for a collection dir.** This produced 9 of the 28 errors and
   37 `NoMixin`/`NoSuperclass` build failures that turn whole class trees `Dynamic`, which hides
   both true positives and sig-gen evidence. A way to expand `manifest.yaml` or gemspec
   dependencies into `signature_paths` for a collection-style layout is unfiled. #2946 (closed)
   covered only stdlib lock entries.
3. **Overload selection takes a `maybe` for unrelated signature-only classes** (#2844). In the
   collection every class is signature-only, so this affects all overloaded APIs, not only the 3
   errors seen here. #2844's title should widen from `singleton(A)` to nominal acceptance.
4. **Literal carriers in proposals ignore later writes.** A hash literal filled by a callee
   (faraday) and a class-variable memo `||= []` (railties) are both proposed as their empty
   literal. Unfiled. Relatives: #2293 (closed), #2425, #2179.
5. **RBS intersections read as their first member** (#529's design). `A & _Iface` and `A & class`
   report undefined methods of the dropped member (faker, stripe). Unfiled.
6. **Method type-parameter upper bounds are ignored in overload selection**
   (`[X < AbstractEventFuture]`). Unfiled.
7. **#2950** (mail `uri_parser`, union arm dropped) is still open.
8. **Collection RBS for a default or bundled gem is quarantined whole against the bundled stdlib
   copy.** Affected: csv, cgi, bigdecimal, yard (quarantined) and abbrev, base64 (duplicate
   method). The fallback is worse than either copy; `CSV.open` reads `IO?`. Unfiled; the baseline
   note named the abbrev case.
9. **sig-gen reads platform-guarded files** (`require "x/truffleruby" if RUBY_ENGINE == …`) as
   ordinary definitions. Unfiled.
10. **`flow.always-raises` fires inside a `begin` whose `rescue` handles that exact class.**
    Related to #2116.

Filed on 2026-11-10, after this note was written:

| gap | issue |
| --- | --- |
| 1. `bot` for overridden abstract and template methods | #3029 |
| 2. dependency RBS for a collection dir | #3030 |
| 3. overload `maybe` for signature-only classes | #2844 (title widened) |
| 4. empty literal carriers that later code fills | #3031 |
| 5. intersections read as their first member | #3032 |
| 6. type-parameter upper bounds in overload selection | #3033 |
| 7. mail `uri_parser` | #2950 |
| 8. default-gem collection RBS quarantined against stdlib | #3034 |
| 9. platform-guarded files read by sig-gen | #3035 |
| 10. `flow.always-raises` inside a handled `rescue` | #3036 |

The collection-side sidekiq `Client#push -> String` bug (`gems/sidekiq/7.0/client.rbs:27`) is an
upstream candidate, not a Rigor issue.

Steep's in-source annotations (`@type var`, `_ = x`) are not on this list. They cause one error
here, and leaving them out of core is a documented decision.

## Limitations and the instrument

- The baseline JSONL stores only counts. Candidate-level attribution therefore exists only for the
  three gems re-run under 0.4.7 (`activesupport` 8.1 and 7.0, `activerecord/8.1`).
- The shims and the per-gem raw outputs lived in a session scratchpad and were not kept. The
  shim recipe above is enough to rebuild them. The JSONL is in the gem_rbs_collection checkout at
  `tmp/rigor_audit_374dcf6ae.jsonl`.
- The stray `_test/.gem_rbs_collection/` dirs should be removed, or excluded from
  `signature_paths`, before the next run.

## Lockfile-route re-run (after #3043)

The same audit, re-run the evening of 2026-11-10 on master `adaf5c7cc` (the #3043 merge, which closed
#3030). The collection checkout is unchanged: `8b20c86` plus the local marcel edits. Since
`374dcf6ae`, master has also merged #3037 (#3029, abstract `bot`), #3039 (#3036,
`flow.always-raises` in a handled `rescue`) and #3042 (#3035, platform-guarded files).

### Method

- **Per-dir setup.** Each of the 196 `_test/` dirs got `bin/test`'s setup without steep, run by the
  mise Ruby 4.0.6 binary by absolute path with a scrubbed environment. The steps are: a `Gemfile`
  with the gem at `~> <version>.0` plus `_test/metadata.yaml` `additional_gems`, then
  `bundle lock --local`, then an `rbs_collection.yaml` with a `local` source at the checkout's
  `gems/`, then `rbs collection install`. The setup renames `Gemfile` and `Gemfile.lock` to `.back`,
  as `bin/test` does. When a step failed, the dir's files were removed, so it has no lockfile and
  falls back to `signature_paths: [".."]`. The six dirs with leftovers from earlier `bin/test` runs
  (actionmailer/8.1, cancancan/3.5, faraday 2.5 and 2.7, marcel/1.0, retryable/3.0) had them moved
  aside first. faraday 2.5 and 2.7 then failed setup, so their stray `.gem_rbs_collection/` dirs
  are gone, not regenerated. Setup took 21 s for all 196 dirs, run six at a time.
- **Run.** Unchanged harness (`bin/rigor_audit_all`, which now writes the route-dependent
  `.rigor.yml` and records `route`). One `nix develop` shell ran it with the shims from
  "Method" above: `bundle exec` on the checkout, and `--no-cache` and `</dev/null` on every
  `check`. It took 1,180 s (19.7 min). Output: `tmp/rigor_audit_adaf5c7cc_lock.jsonl` in the
  collection checkout. The earlier JSONL files are kept.
- **Routes.** 131 dirs used the lockfile and 65 fell back with `setup_failed`. Every failure came
  from `bundle lock --local`; `rbs collection install` never failed. Grouped:

| reason | dirs | examples |
| --- | ---: | --- |
| a dependency is not installed locally, or only a newer version is (Rails 6.0/7.0/7.1/8.0 lines, `mime-types-data`, `retriable`, `sorbet-runtime`, `rack ~> 2.0`, …) | 58 | carrierwave/3.0 (`ssrf_filter`), json-jwt/1.16, active_model_serializers/0.10, activerecord/8.0 (`activesupport 8.0.5.2`), faraday 2.5/2.7, sentry-ruby/5.2, protobuf/3.10.3 |
| the gem itself is not installed at `~> <version>.0` | 5 | delayed_job/4.1, llhttp-ffi/0.5, mysql2/0.5, rack/2.2, ruby-odbc/0.999992 (also `gem not installed` for sig-gen, as before) |
| an `additional_gems` entry is not installed | 2 | sinatra/4.0 (`sinatra-contrib`), activeadmin/3.3 (`devise` → `warden`) |

Each fallback dir now also reports the new `rbs.coverage.collection-not-installed` info (65).

One sig-gen run crashed: rubyXL/3.4 (lockfile route) hit a Ruby VM `[BUG] Segmentation fault` in the
Flake Ruby 4.0.5, at `lib/rigor/inference/alias_mutation_floor.rb:258`. Two re-runs in the same
setup passed (`skipped` 381, `new_method` 54). It is treated as transient. The JSONL row still reads
`parse error`, and the sig-gen totals below leave rubyXL out of both sides.

### `rigor check`, lockfile-route dirs (131) against the same dirs at `374dcf6ae`

| | 374dcf6ae (`signature_paths: [".."]`) | adaf5c7cc (lockfile) | delta |
| --- | ---: | ---: | ---: |
| clean dirs | 87 | 117 | +30 |
| errors | 18 in 10 gems | 16 in 6 gems | −2 |
| warnings | 155 | 116 | −39 |
| info | 5 | 0 | −5 |

| rule | before | after |
| --- | ---: | ---: |
| `call.unresolved-toplevel` (warning) | 116 | 113 |
| `rbs.coverage.definition-build-failed` (warning) | 32 | 0 |
| `rbs.coverage.quarantined-signature` (warning) | 5 | 0 |
| `rbs.coverage.synthesized-namespace` (info) | 5 | 0 |
| `call.undefined-method` | 12 | 10 |
| `call.argument-type-mismatch` | 4 | 4 |
| `call.possible-nil-receiver` | 2 | 2 |
| `flow.always-truthy-condition` (warning) | 2 | 2 |
| `def.override-return-widened` (warning) | 0 | 1 |

Fallback dirs (65): errors went from 10 to 9; sentry-ruby's `flow.always-raises` is gone (#3036,
fixed by #3039). Warnings went from 45 to 44. Leaving out the new info, clean dirs went from 43 to
45. Across all 196 dirs, ignoring the new info, clean dirs went from 130 to 162 and errors from 28
to 25.

**Did the harness gaps close?** Yes, wherever the lockfile route ran.

- Missing-dependency errors: the 5 in lockfile dirs are gone (actionmailer, activejob, activerecord
  and activestorage 8.1, and cancancan 3.5). The other 4 (active_model_serializers, carrierwave,
  delayed_job, json-jwt) remain only because those dirs failed setup offline.
- Build failures: every `rbs.coverage.definition-build-failed` in a lockfile dir is gone (32 → 0).
  The 13 left across the batch all sit in fallback dirs, and all are `NoMixinFoundError` or
  `NoSuperclassFoundError` for a dependency. That makes 25 of the 37 `NoMixin`/`NoSuperclass`
  failures cleared; the other 12 are in dirs that failed setup. sinatra/4.0 is the 13th and new; see
  below.
- The 5 `quarantined-signature` warnings (csv, cgi, bigdecimal 3.1 and 4.0, yard) and the abbrev
  and base64 duplicate-method warnings are gone too. That is the lockfile route's stdlib-name skip.
  It does not fix #3034: csv still errors the same way, below.

#### Every remaining error, classified

Lockfile route, 16 errors:

| site | count | class | issue |
| --- | ---: | --- | --- |
| concurrent-ruby/1.1 `promises.rb:13`, `:18`, `:68` | 3 | Rigor false positive: overload `maybe` for signature-only classes | #2844 |
| concurrent-ruby/1.1 `promises.rb:82`, `:84` | 2 | Rigor false positive: type-parameter upper bound ignored | #3033 |
| faker/2.23 `test.rb:49` | 1 | Rigor false positive: `A & class` read as `A` | #3032 |
| stripe/13.0 `stripe.rb:9` | 1 | Rigor false positive: `A & _Iface` read as `A` | #3032 |
| csv/3.3 `test.rb:19`, `:27` | 2 | Rigor false positive: `CSV.open` reads `IO?` | #3034 |
| retryable/3.0 `test.rb:41,59,91,92` | 4 | real RBS bug (`type options`, every key required) | ruby/gem_rbs_collection#1126 |
| marcel/1.0 `test.rb:33`, `:34`, `:35` | 3 | **new**: correct; an RBS gap in the uncommitted local edit | — |

Fallback route, 9 errors:

| site | count | class | issue |
| --- | ---: | --- | --- |
| protobuf/3.10.3 `enum.rb:9,10`, `messages.rb:18,19` | 4 | intentional `___error___` markers | — |
| rack/2.2 `body_proxy.rb:8` | 1 | Steep `@type var` annotation, by design | — |
| active_model_serializers, carrierwave, delayed_job, json-jwt | 4 | missing dependency RBS; these dirs failed setup offline | — (#3030 route works once set up) |

**Errors new on the lockfile route.** There are three, all on marcel/1.0, and none is a false
positive. `Marcel::Magic.by_extension`, `.by_path` and `.all_by_magic` are reported as undefined on
`singleton(Marcel::Magic)`. The uncommitted local edit to `gems/marcel/1.0/_test/test.rb` calls
them, but the working tree's `marcel.rbs` declares only `Magic.by_magic`. The gem does define all
three (`marcel-1.0.4/lib/marcel/magic.rb:73,80,93`), so the RBS is incomplete, and Steep would
report the same calls. At `374dcf6ae` the stray `.gem_rbs_collection/` copy made `Marcel::Magic`
fail to build (`DuplicatedMethodDefinitionError`), so the class read as `Dynamic` and hid these
calls.

**A new warning, a Rigor false positive.** actioncable/8.1 `test.rb:32` reports
`def.override-return-widened`: "widened from nil to top (overrides ApplicationCable::Channel#subscribed)".
`ChatChannel#subscribed: () -> void` (`_test/test.rbs`) overrides a hook that
`ApplicationCable::Channel` does not define. The parent signature is the RBS-only
`ActionCable::Channel::Base#subscribed: () -> nil` (`actioncable-generated.rbs:189`), which the
lockfile route now loads. Per diagnostic-policy.md and ADR-35, the rule covers only a project-defined
ancestor, and RBS-only ancestors are deferred to #130. A project class in between lets the RBS-only
signature through and attributes it to the project class. Minimal repro (`signature_paths: [sig]`):

```rbs
class Base;   def hook: () -> nil;  end   # RBS only, no Ruby source
class Mid < Base; end                       # also in app.rb, no hook
class Leaf < Mid;    def hook: () -> void; end   # fires: "overrides Mid#hook"
class Direct < Base; def hook: () -> void; end   # silent (control)
```

This is unfiled; it relates to #130. A second question goes with it, for the fully project case
(`PLeaf < PMid`, which also fires): whether `-> void` overriding `-> nil` should count as widening.
`void` is the RBS idiom for a hook whose result nobody reads.

**sinatra/4.0 is not an engine change.** It went from clean to a `NoMixinFoundError` on
`Rack::Utils`, on the fallback route both times. Running `374dcf6ae` on today's tree produces the
same warning, so the cause is in the tree, not the engine. Why the 11-10 run was clean was not
recovered.

### `sig-gen --diff`

| classification | 374dcf6ae, lockfile dirs (130) | adaf5c7cc, same | delta | 374dcf6ae, fallback dirs (60) | adaf5c7cc, same | delta |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `new_method` | 22,065 | 21,326 | −739 | 5,452 | 5,452 | 0 |
| `tighter_return` | 2,221 | 2,563 | +342 | 641 | 598 | −43 |
| `skipped` | 78,400 | 77,775 | −625 | 19,831 | 19,865 | +34 |

(130 = 131 lockfile dirs less rubyXL. 60 = 65 fallback dirs less the 5 `gem not installed`.)

On the lockfile route the movement is dependency RBS taking effect. Classes whose superclass now
resolves get evaluated: `sig.skipped.unresolvable-superclass` fell from 3,231 to 2,113 across the
batch. Methods that a dependency's RBS already declares stop counting as `new_method`. The largest
moves:

| gem | `new_method` | `tighter_return` |
| --- | ---: | ---: |
| activerecord/8.1 | −261 | +46 |
| activerecord/7.2 | −170 | +55 |
| actionpack 7.2 / 8.1 | −32 / −57 | +50 / +48 |
| railties/8.1 | −48 | +48 |
| yard/0.9 | −78 | +27 |

rubocop and rubocop-ast trade `skipped` for `new_method`. The 11-10 wrong proposals stand where
#3029 did not reach them: mail `uri_parser` (#2950), railties `watchable_files -> []` and faraday
`matches? -> [bool, {}]` (#3031).

**`bot` dropped after #3037 (#3029): from 112 to 37** across all dirs. The new skip reasons
account for it: `sig.skipped.overridden-bot` 297, `abstract-method` 72 and `template-method` 55.
#3042 adds `platform-guarded` with 11 (parser 8, stackprof 3).
`sig.skipped.overridden-by-unsigned-subclass` fell from 465 to 245. Every wrong `bot` in the 11-10
sample is now skipped: tzinfo, rest-client, rails-html-sanitizer, lint_roller, the activerecord
`SchemaStatements` methods and stackprof. A source check of 13 of the remaining 37 found deliberate
raises or exits, all correct: `assigns`, `assert_template`, `_routes`,
`CollectionProxy#prepend`, `Header#decoded`, `Type::Value#as_json`, `MissingRoute#path`,
`Attribute::Null#with_value_from_database`, `ReadOnlyNullEncryptor#encrypt`, and others.
Proposals that tighten a non-`untyped` declaration went from 21 to 13. `top` proposals went from 45
to 54.

### Updated gap ranking

1. **#3030 is fixed (#3043) for any dir whose setup completes.** The remaining cost is
   operational: offline, 65 of 196 dirs cannot lock, and they keep the 4 missing-dependency errors
   and 12 `NoMixin`/`NoSuperclass` failures. No issue needed.
2. **Overload `maybe` for signature-only classes**, #2844, open. It still causes 3 errors and
   affects every overloaded collection API.
3. **Empty literal carriers that later code fills**, #3031, open. The faraday and railties
   proposals stand.
4. **Intersections read as their first member**, #3032, open (faker, stripe).
5. **Type-parameter upper bounds in overload selection**, #3033, open (concurrent-ruby, 2).
6. **Default-gem collection RBS against stdlib**, #3034, open. The quarantine warning is gone on
   the lockfile route, but `CSV.open` still reads `IO?`.
7. **mail `uri_parser`**, #2950, open.
8. **New, filed as #3046: `def.override-return-widened` reaches an RBS-only ancestor through a project
   class that does not define the method** and names that class as the owner (actioncable). It
   relates to #130. File it with the `void`-over-`nil` question.
9. **New, recorded on #2850: an intermittent VM segfault in sig-gen** (rubyXL/3.4, Flake Ruby 4.0.5,
   `alias_mutation_floor.rb:258`). It did not reproduce in two re-runs. Worth an issue only if it
   recurs.

Closed since the 11-10 ranking: #3029 (gap 1, `bot`), #3030 (gap 2), #3035 (gap 9) and #3036
(gap 10).

Unfiled, collection side: the sidekiq `Client#push -> String` RBS bug, still proposed as
`perform_in -> String`, and marcel `Magic.by_extension`/`by_path`/`all_by_magic` missing from
`marcel.rbs`, which the local edit exercises.
