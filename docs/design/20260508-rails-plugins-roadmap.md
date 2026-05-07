# Rails Ecosystem Plugins — Roadmap

Status: **planning, 2026-05-08.** This document captures the
planned `rigor-*` plugin family for Rails apps. It is informational;
the binding sources for individual plugin contracts remain the
`README.md` and integration spec under each plugin's directory.

The first plugin in this family — [`rigor-activerecord`](../../examples/rigor-activerecord/) —
landed on `master` (commit `e8fda84`) and is staged in the
monorepo per [`.codex/skills/rigor-plugin-author/SKILL.md`](../../.codex/skills/rigor-plugin-author/SKILL.md)'s
"start in monorepo, extract via `git subtree split` once stable"
discipline.

## Working principles

1. **Each plugin will be subtree-split** to its own repository
   (`rigortype/rigor-<id>`) once its contract has stabilised
   against a real Rails consumer. The monorepo is the
   incubator; the eventual home is independent gems.
2. **Per-plugin `demo/` directories ship with their plugin.**
   No shared Rails-app skeleton across plugins — after
   subtree-split each `demo/` travels with its plugin and must
   be self-contained. Some duplication of Rails-shaped
   directory tree (e.g. `app/models/application_record.rb`) is
   accepted in exchange for clean extraction.
3. **Real-Rails alignment is a goal, not a runtime
   dependency.** The plugin source code does NOT
   `require "rails"` / `require "active_record"`. It analyses
   project source files. But the plugin's behaviour (path
   helpers generated, column types accepted, filter chains
   recognised) MUST match what real Rails generates / accepts
   for the same input. Integration specs that compare plugin
   output against a small real Rails app's `rails routes -E` /
   schema dump output are encouraged.
4. **Cross-plugin facts go through a shared API.** The
   `rigor-actionpack` strong-params consumer needs the model
   index `rigor-activerecord` builds. That cross-plugin handoff
   is via the v0.1.x cross-plugin API ([ADR-9](../adr/9-cross-plugin-api.md)),
   not via duplicated reads or shared cache producer ids.

## Plugin tier table

Tier 1 plugins land first because they have the highest user
value AND do not require new analyser-side API. Tier 2 either
extends an existing plugin or needs the cross-plugin API ADR-9
ships. Tier 3 is specialised — author when there is concrete
user demand.

| Tier | Plugin | Scope | API needs |
| --- | --- | --- | --- |
| 1A | [`rigor-rails-routes`](#rigor-rails-routes) | Real `config/routes.rb` DSL → `*_path` / `*_url` validation | Current API |
| 1B | [`rigor-rails-i18n`](#rigor-rails-i18n) | `config/locales/*.yml` → `t('key.path')` validation | Current API |
| 1C | [`rigor-actionmailer`](#rigor-actionmailer) | Mailer methods + view template existence | Current API |
| 1D | [`rigor-activejob`](#rigor-activejob) | Job `perform` arity | Current API |
| 2A | `rigor-activerecord` extension | associations, enums, scopes, validations, callbacks | Current API; landed as 0.2.0+ of the existing gem |
| 2B | [`rigor-actionpack`](#rigor-actionpack) Phase 1 | Strong parameters → AR column validation | **Cross-plugin API (ADR-9)** |
| 2C | [`rigor-factorybot`](#rigor-factorybot) | Factory attribute → AR column validation | Cross-plugin API |
| 2D | `rigor-actionpack` Phase 2-4 | Filter chains, render targets, route-helper consumption | Cross-plugin API |
| 3A | [`rigor-rspec`](#rigor-rspec) | `let` / `subject` / mock target validation | Current API |
| 3B | [`rigor-pundit`](#rigor-pundit) | Policy method existence + `authorize` arg validation | Current API |
| 3C | `rigor-sidekiq` | Worker `perform` arity, queue config | Current API |
| 3D | `rigor-graphql` | Schema → resolver argument types | Current API |
| 3E | `rigor-activestorage` | `has_one_attached` macros + generated methods | Cross-plugin API |
| 3F | `rigor-actioncable` | Channel methods + broadcast names | Current API |

After Tier 1+2 lands, **`rigor-rails`** becomes a meta-gem that
declares these dependencies in its gemspec and lets users add
one line to their Gemfile to opt into the whole stack.

## Plugin sketches

### rigor-rails-routes

**Tier 1A — current API.** Parses real `config/routes.rb` (not
the YAML simplification `examples/rigor-routes/` uses for
teaching purposes).

DSL surface for v0.1.0 of the plugin:

- `Rails.application.routes.draw do ... end` block
- `resources :name [, only: [...] | except: [...]]`
- `resource :name`
- `get/post/patch/put/delete "/path", to: "controller#action", as: :name`
- `root to: "controller#action"`
- Nested `resources` (1 level deep)
- `member do ... end` / `collection do ... end`
- `namespace :admin do ... end` (prefixes path + helper name)

Out of scope for v0.1.0:
- `scope :module:` / `scope :path:` / `scope :as:`
- Constraints (`constraints: { id: /\d+/ }`)
- Custom `direct(:name) { |obj| ... }`
- Mountable engines (`mount Sidekiq::Web => "/sidekiq"`)
- Format restrictions

**Diagnostics:**

```text
controllers/users_controller.rb:42:7: info: `user_post_path` → GET /users/:user_id/posts/:id
controllers/users_controller.rb:50:1: error: no route helper `widgts_path` (did you mean `widgets_path`?)
controllers/users_controller.rb:51:1: error: `user_path` expects 1 argument (:id), got 0
```

**Architecture:** Mirrors `rigor-activerecord`'s `SchemaParser`
recursive-descent on Prism, plus `rigor-routes`' helper-name
table. Helper generation rules need careful real-Rails
verification — see "Real-Rails alignment" below.

**Real-Rails alignment:** integration spec compares the
plugin's `HelperTable` against `rails routes -E`'s output for
the same `config/routes.rb`. A small Rails app under
`demo/` provides the reference.

---

### rigor-rails-i18n

**Tier 1B — current API.** Validates `t('key.path')` against
`config/locales/*.yml`.

Surface:

- `t('key.path')` / `I18n.t('key.path')` / `I18n.translate('key.path')`
- `t('key.path', interpolation_var: value)` — validates the
  interpolation keys against the `%{var}` placeholders in the
  locale value
- `l(time, format: :short)` — validates `:short` against the
  locale's date format keys

Out of scope for v0.1.0:
- Lazy lookup (`t('.title')` resolved against the rendered
  controller / view path — needs `rigor-actionpack`)
- Locale fallbacks chains
- Plural rules

**Diagnostics:**

```text
view.html.erb:5:1: info: `t('users.welcome')` resolves in en, ja
view.html.erb:8:1: error: missing key `users.welcom` in en (did you mean `users.welcome`?)
view.html.erb:12:1: error: `users.welcome` expects interpolation `name`, got `username`
```

**Architecture:** `rigor-routes` (YAML reads) + `rigor-pattern`
(literal-string gating for `t(literal_key)`). Glob-loop the
locale paths through `IoBoundary`.

---

### rigor-actionmailer

**Tier 1C — current API.** Validates Mailer call shape and
view path existence.

Surface:

```ruby
class UserMailer < ApplicationMailer
  def welcome(user)
    @user = user
    mail(to: user.email)
  end
end

UserMailer.welcom(user).deliver_now    # error: undefined method
UserMailer.welcome.deliver_now          # error: missing required arg
UserMailer.welcome(user, foo: 1)        # error: wrong arity
```

Plus existence check for `app/views/<mailer_underscore>/<method_name>.{html,text}.erb`.

**Architecture:** `rigor-activerecord`'s `ModelDiscoverer`
pattern adapted to mailer classes (subclass of
`ApplicationMailer` / `ActionMailer::Base`). View path checked
via `IoBoundary`.

---

### rigor-activejob

**Tier 1D — current API.** Validates `Job.perform_later`
argument arity against the job class's `#perform` definition.

Surface:

```ruby
class WelcomeEmailJob < ApplicationJob
  def perform(user_id, locale = "en")
    ...
  end
end

WelcomeEmailJob.perform_later(123)              # info
WelcomeEmailJob.perform_later                   # error: missing user_id
WelcomeEmailJob.perform_later(123, "ja", :foo)  # error: wrong arity
```

**Architecture:** Tiny — class discovery + per-call arity check.
Same pattern as `rigor-actionmailer`.

---

### rigor-actionpack

**Tier 2B+2D — needs cross-plugin API (ADR-9).** The flagship
"Rails apps want this" plugin, but its primary value comes
from cross-checking against `rigor-activerecord`'s model
index. Phased rollout:

#### Phase 1 — strong parameters

```ruby
def user_params
  params.require(:user).permit(:name, :emial)
  # error: column `:emial` not on table `users` (did you mean `:email`?)
end
```

Reads ADR-9's `services.fact_store` for `rigor-activerecord`'s
`:model_index` fact. Resolves `:user` (Symbol arg of `require`)
to the `User` model, then validates `permit` keys against the
table.

#### Phase 2 — filter chains

```ruby
class UsersController < ApplicationController
  before_action :authenticate, only: [:create, :update]
  # validates :authenticate exists as an instance method
  # validates :create, :update exist as actions
end
```

Two-pass within the controller class: collect action method
declarations, then validate filter `:method_name` and `only:` /
`except:` Symbol lists.

#### Phase 3 — render targets

```ruby
def show
  render partial: "users/profile", locals: { user: @user }
  # validates app/views/users/_profile.html.erb exists
end
```

`IoBoundary` checks for the partial file's existence.

#### Phase 4 — route-helper consumption

```ruby
def show
  redirect_to user_path(@user)
end
```

Consumes `rigor-rails-routes`' `:helper_table` fact through
ADR-9. Validates the helper name + arity at the call site (not
at the controller-defining file — the controller might be
called from anywhere).

---

### rigor-factorybot

**Tier 2C — needs cross-plugin API.** Factory attribute
validation against AR columns.

```ruby
FactoryBot.define do
  factory :user do
    name { "Alice" }
    invlid_attribute { "x" }   # error if rigor-activerecord is loaded
  end
end

create(:usre)                  # error: factory undefined (did you mean :user?)
build(:user, emial: "x")       # error: column mismatch
```

Two-phase: discover factory definitions (similar to
rigor-statesman), then validate use sites. Consumes
`rigor-activerecord`'s model index via ADR-9 fact_store.

---

### rigor-rspec

**Tier 3A — current API.** Test DSL flow tracking.

```ruby
RSpec.describe User do
  let(:user) { User.new(name: "Alice") }
  subject(:greeting) { "Hello, #{user.name}" }

  it "greets" do
    expect(greeting).to eq("Hello, Alice")
    expect(user).to receive(:nme).and_return("X")  # error: no method :nme on User
  end
end
```

Heavy implementation (RSpec DSL is broad). Expected size:
600+ lines. Author when test-side validation becomes a clear
priority — likely Tier 3 because Rails apps benefit more from
controller / model / view validation first.

---

### rigor-pundit

**Tier 3B — current API.** Policy method existence + `authorize`
arg validation.

```ruby
authorize @user, :update?
authorize @user, :destory?      # error: undefined policy method (did you mean :destroy?)
```

Policy class discoverer + per-call validation. Conventional
mapping: `User` → `UserPolicy`, action method `:update?` →
`UserPolicy#update?`. `cancancan` is a separate plugin with
similar shape but different convention.

---

## Plugin dependency graph

```
                                   ┌────────────────────────┐
                                   │ rigor-activerecord     │
                                   │  (already landed)      │
                                   └──┬─────────────────────┘
                                      │ publishes :model_index via fact_store
                ┌─────────────────────┼─────────────────────┐
                ▼                     ▼                     ▼
   ┌────────────────────┐  ┌──────────────────────┐  ┌─────────────────┐
   │ rigor-actionpack   │  │ rigor-factorybot     │  │ rigor-active-   │
   │  Phase 1 (params)  │  │                      │  │  storage        │
   └────────────────────┘  └──────────────────────┘  └─────────────────┘
              ▲
              │ consumes :helper_table
              │
   ┌──────────┴───────────┐
   │ rigor-rails-routes   │
   │  publishes :helper_  │
   │  table               │
   └──────────────────────┘

   ┌──────────────────────┐  ┌──────────────────────┐  ┌──────────────────┐
   │ rigor-rails-i18n     │  │ rigor-actionmailer   │  │ rigor-activejob  │
   │  (independent)       │  │  (independent)       │  │  (independent)   │
   └──────────────────────┘  └──────────────────────┘  └──────────────────┘

   ┌──────────────────────┐  ┌──────────────────────┐
   │ rigor-rspec          │  │ rigor-pundit         │
   │  (independent)       │  │  (independent)       │
   └──────────────────────┘  └──────────────────────┘
```

`rigor-rails` (meta-gem) sits above all of these and pulls
them in via gem dependencies. Users who want the whole stack:
`gem "rigor-rails"`.

## Demo / test app strategy

**Per-plugin self-contained demos.** Each `examples/rigor-<id>/demo/`
ships a small Rails-shaped directory tree appropriate to the
plugin's scope. After `git subtree split`, the demo travels
with the plugin without manual fix-up.

For Tier 1+2 plugins that need a cross-cutting Rails app
(strong params + AR + routes), the demo is still per-plugin —
each plugin's demo includes only the Rails surfaces THAT
plugin needs. `rigor-actionpack`'s demo carries a controller
file and an `application_record.rb` for the model fixture, but
NOT a full Rails directory tree.

For real-Rails verification: integration specs may exec a
small `rails new` skeleton in a tmpdir and compare plugin
output against `rails routes -E` / `db:schema:dump` etc., but
that is a TEST-time tool, not a demo-time fixture.

## Subtree-split readiness checklist

Per plugin, verify before splitting:

- [ ] `examples/rigor-<id>/` directory is self-contained
      (no `require_relative`s pointing outside).
- [ ] `examples/rigor-<id>/demo/` runs cleanly via
      `RUBYLIB=$PWD/../lib bundle exec rigor check`.
- [ ] Integration spec at `spec/integration/examples/<id>_plugin_spec.rb`
      passes with the plugin loaded as a real
      `Plugin::Loader.load` consumer.
- [ ] Plugin's `gemspec` declares the right semver range on
      `rigortype` (e.g. `>= 0.1.0, < 0.2.0`).
- [ ] No cross-plugin file references — cross-plugin
      data flows only through `services.fact_store`
      (post-ADR-9) or through duplicated reads (pre-ADR-9).
- [ ] README has the "Future direction" section explaining
      what's queued post-extraction.

When all check, run:

```sh
git subtree split --prefix=examples/rigor-<id> -b rigor-<id>-extracted
git remote add rigor-<id> git@github.com:rigortype/rigor-<id>.git
git push rigor-<id> rigor-<id>-extracted:master
```

Then in the monorepo: remove `examples/rigor-<id>/`, drop the
matching `spec/integration/examples/<id>_plugin_spec.rb`,
update `examples/README.md`'s comparison table to remove the
row, and update `README.md`'s plugin list.

## Order of operations

1. **Document the plan** — this file + [ADR-9](../adr/9-cross-plugin-api.md). (Current
   commit.)
2. **Implement Tier 1 plugins (current API)** — `rigor-rails-routes`,
   `rigor-rails-i18n`, `rigor-actionmailer`, `rigor-activejob`.
   Each as its own commit, with subtree-split readiness in
   mind.
3. **Implement cross-plugin API (ADR-9)** — `Plugin::FactStore` +
   `prepare(services)` hook + `consumes:` manifest field +
   topological sort in `Plugin::Loader`. Update public-API
   drift snapshots. Add the SKILL section.
4. **Implement Tier 2 plugins (cross-plugin)** — `rigor-actionpack`
   Phase 1 (strong params), then `rigor-factorybot`. These
   exercise ADR-9 against real consumers.
5. **Stabilise + extract** — once each plugin's `examples/`
   directory has been stable for ≥ 2 releases, run the
   subtree-split flow and migrate to a separate repo.
6. **Tier 3 + meta-gem** — author Tier 3 plugins as user demand
   surfaces. Once Tier 1+2 are extracted, publish `rigor-rails`
   meta-gem with the dependency aggregation.

The Tier 1 plugins (current API) are blockers only on
authoring time, not on contract design. They can land in
parallel by independent implementers if desired. Tier 2
blocks on ADR-9 implementation.
