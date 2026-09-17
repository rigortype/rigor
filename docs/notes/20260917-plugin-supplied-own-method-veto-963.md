# Plugin-supplied members vs. a same-named top-level `def` — the #963 item-2 measurement

Status: measurement note for item 2 of [#963](https://github.com/rigortype/rigor/issues/963)
(plugin-supplied methods as an own-method veto source). Taken on the `#963` fix branch (base
`00714154`), Ruby 4.0.5, against a private copy of the mastodon survey checkout
(`rigor-survey/mastodon` at `fb59dd94`). The issue asks for the scale to be measured before the veto
is widened; this note is that measurement, plus the same probe re-run on the fixed engine.

## The question

`ExpressionTyper#try_local_def_dispatch` binds an implicit-self call to a top-level `def` of the same
name (ADR-46 cross-file top-level binding) unless `self_type_answers?` says the enclosing class already
carries the name. Before this fix that veto consulted discovered `def`s, Struct/Data members, the
project ancestor walk, and RBS — never a plugin. So a column reader, an association accessor, or a
`scope` contributed by `rigor-activerecord` lost to any top-level `def` of the same name anywhere in
the project, and the call was typed as that helper's return.

Counted: **implicit-self call sites inside a modelled class (`self_type` non-`nil`) where a bindable
top-level `def` exists, the veto declined, and a loaded plugin supplies the name on that class.**

## Method

The survey tree was never run in place ([`docs/agents/measurement.md`](../agents/measurement.md)).
`rsync` is absent on the box, so the copy was a `tar` pipe:

```sh
mkdir -p tmp/corpus-mastodon
(cd ../rigor-survey/mastodon && tar --exclude=.git --exclude=node_modules --exclude=.rigor -cf - .) \
  | tar -xf - -C tmp/corpus-mastodon
```

The copy got this `.rigor.yml` (the `rigor-rails` meta-gem is not a valid single `plugins:` entry, so
the bundle is spelled out):

```yaml
paths: [app, lib, spec, config, db]
exclude: [vendor, tmp]
plugins:
  - rigor-railties
  - rigor-rails-routes
  - rigor-rails-i18n
  - rigor-actionmailer
  - rigor-activejob
  - rigor-activerecord
  - rigor-actionpack
  - rigor-activesupport-core-ext
severity_profile: lenient
```

The probe is a `prepend` on `ExpressionTyper` loaded with `ruby -r` — no engine source was edited. It
writes one TSV row per call that has a bindable top-level `def` (`path, line, name, self kind, class,
vetoed?, plugin-arm?`) and, in `before` mode, forces the new plugin/synthetic arm to `false` so the
pre-fix veto is reproduced on the *same* build, same flags:

```sh
cd tmp/corpus-mastodon
for m in before after; do
  PROBE963_MODE=$m PROBE963_OUT=/tmp/p963-$m.tsv BUNDLE_GEMFILE=$RIGOR/Gemfile \
    bundle exec ruby -I$RIGOR/lib -r$RIGOR/tmp/probe963.rb $RIGOR/exe/rigor check --no-cache --format json \
    > /tmp/p963-$m.json
done
```

(`RUBYOPT=-r` does not work here: the probe requires `rigor` before Bundler has set up the load path.)

## Counts

3310 Ruby files analysed; 5611 probe rows (calls with a bindable top-level `def`) in each run.

| | before | after |
| --- | --- | --- |
| rows vetoed | 444 | 480 |
| rows not vetoed | 5167 | 5131 |
| rows where the plugin arm answered `true` | 0 (forced) | 36 |
| distinct `(file, line, name)` not vetoed | 985 | 979 |
| `call.*` diagnostics | 4040 | 4040 (byte-identical set) |

The 36 rows that flip are **6 distinct sites**, all the same collision: `Status`'s `belongs_to
:reblog` association versus `def reblog(status, at_time)` — a helper defined directly inside an
`RSpec.describe` block in `spec/models/trends/statuses_spec.rb`, which the scope index records as a
bindable top-level `def`. (To Ruby it is not one: rspec-core runs the block with `module_exec` on the
example-group class, so the helper is an instance method of that class, not a private method on
`Object`. The bind was wrong either way — `Status#reblog` is the association.)

| site | self | rows |
| --- | --- | --- |
| `app/models/status.rb:235` (`reblog? ? reblog : self`) | `Nominal[Status]` | 2 |
| `app/models/status.rb:243` | `Nominal[Status]` | 1 |
| `app/models/status.rb:435` | `Nominal[Status]` | 18 |
| `app/models/status.rb:483` | `Nominal[Status]` | 7 |
| `app/models/status.rb:491` | `Nominal[Status]` | 7 |
| `app/controllers/api/v1/statuses_controller.rb:235` | `Nominal[Status]` | 1 |

Before the fix every one of them typed `reblog` as the spec helper's return; after it, the veto
declines the bind and dispatch reaches the association through `rigor-activerecord`.

## Controls

- **Positive (the fix does something):** the 36 flipped rows above, and the regression examples in
  `spec/integration/plugins/activerecord_plugin_spec.rb` (`#963`) — a top-level `def title` / `def user`
  / `def recent` / `def headline` / `def email` against a model's column, association, scope,
  `alias_attribute` and `delegate`. Without the engine change the must-not-bind example fails with
  `call.undefined-method` on `post.rb`; deleting either the instance-side or the singleton-side
  `plugin_supplied_self_answers?` line makes it fail too.
- **Negative (nothing else moves):** the `call.*` diagnostic set is identical before and after (4040 =
  4040, symmetric difference empty), and every row that was vetoed before is still vetoed after (the
  480 is a strict superset of the 444).
- **Must-still-fire:** 979 sites keep binding the top-level `def` after the fix — 4966 rows on a
  `nil` self (genuine top level and spec blocks), 165 rows on a `Nominal` self where no plugin
  supplies the name. Two arms of the regression spec pin the diagnostic that must keep firing: a
  `Widget` no plugin models, and a `User` model whose table lacks the `title` column another model
  has — the second is why `rigor-activerecord` answers per model rather than from its plugin-wide
  name union.

## Limitations

- **Diagnostics did not change.** Under `severity_profile: lenient` the mis-binding was a silent
  mis-typing (`reblog` read as the helper's return), not a reported false positive, so `rigor check`
  output alone cannot show this bug on mastodon. The probe, not the diagnostic diff, is the evidence.
- **One collision family.** Mastodon has few genuine top-level `def`s (six, all in `config/` and
  `spec/` support files); the colliding helper is a `describe`-block `def`. A project that defines
  helpers at file top level would collide more often; this run cannot say how much.
- **Mixin `self` is out of reach.** `app/models/concerns/status/visibility.rb:40` calls `reblog`
  with `self_type = Nominal[Status::Visibility]` (a concern module). At runtime the includer is
  `Status`, but the veto sees the module, which owns no association, so the top-level `def` still
  binds there (6 rows). Resolving a module's `self` through its includers is a separate change.
- **No `errors` / synthesized-member collision observed.** The `SyntheticMethodIndex` arm and the
  base `Plugin::Base#supplies_method?` (receiver+name `dynamic_return` gates) are exercised by unit
  specs only; mastodon produced no row where they decided the outcome.
- **The `ActiveRecord::Base` surface itself is still unclaimed.** #963 names `errors` explicitly, and
  it — like an inherited class method such as `count` — still binds a same-named top-level `def`:
  `framework.rbs` deliberately leaves `ActiveRecord::Base` undeclared, so the RBS arm cannot answer,
  and the `rigor-activerecord` override claims only what the model index records for the class
  (columns, predicates, associations, aliases, macro-installed members, finders, declared `scope`s).
  Reproduced in the #1058 review on the fixed engine with `class ApplicationRecord <
  ActiveRecord::Base` plus a top-level `def errors = nil` / `def count = nil`: `errors.full_messages`
  and `count.succ` both still report `undefined method … for nil`. Mastodon has no such collision;
  closing this needs either a declared `ActiveRecord::Base` surface or a base-class claim in the
  plugin, and is left open here.
- **Enum-generated scopes are unclaimed.** `enum :status, { draft: 0, published: 1 }` installs a
  `published` class-side scope whose spelling depends on `prefix:` / `suffix:` and which `scopes:
  false` removes; the model index keeps the per-value `?` predicates (instance side) but not the
  scope names, so `def self.pub = published.first` still binds a top-level `def published`.
- **Single corpus, single revision, workers default.** Wall time ~40 s either way; the extra
  registry/index lookups on the veto path did not register.
