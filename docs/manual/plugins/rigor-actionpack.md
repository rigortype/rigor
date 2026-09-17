# rigor-actionpack

Checks controller-side Action Pack code across four areas, by
consuming facts other Rails plugins publish (ADR-9):

- **Route-helper calls** — `redirect_to user_path(@user)` against
  the `:helper_table` from [`rigor-rails-routes`](rigor-rails-routes.md).
- **Filter chains** — `before_action :name` against the
  controller's (and its parents') defined methods.
- **Render targets** — `render :show` / `render partial:` against
  the view templates under `view_search_paths`.
- **Strong parameters** — `params.require(:user).permit(:name, …)`
  keys against the model's columns (via `:model_index` from
  [`rigor-activerecord`](rigor-activerecord.md)).

It ships bundled in `rigortype`. Activate it under `plugins:`,
alongside the producers whose facts it consumes:

```yaml
plugins:
  - rigor-rails-routes   # publishes :helper_table  (optional)
  - rigor-activerecord   # publishes :model_index   (optional)
  - rigor-actionpack
```

Both dependencies are declared `optional` — a project that omits a
producer still loads; the area that needed that fact degrades to a
no-op rather than erroring.

## What it checks

| Rule | Severity | Fires when |
| --- | --- | --- |
| `plugin.actionpack.helper-call` | info | a `*_path` / `*_url` call resolved against the helper table |
| `plugin.actionpack.unknown-helper` | error | the helper name is not in the table (with a did-you-mean) |
| `plugin.actionpack.wrong-helper-arity` | error | the call's positional-arg count ≠ the helper's recorded arity |
| `plugin.actionpack.filter-call` | info | a filter reference (`before_action :name`, `skip_around_action`, …) resolved to a defined method |
| `plugin.actionpack.unknown-filter-method` | error | a filter reference names a method not defined on the controller or a parent (with a did-you-mean) |
| `plugin.actionpack.render-target` | info | an explicit `render :symbol` / `"string"` / `partial:` resolved to a view template |
| `plugin.actionpack.missing-template` | error | an explicit `render` resolved to a view path that doesn't exist under any `view_search_paths` |
| `plugin.actionpack.permit-call` | info | a `params.require(:m).permit(:key, …)` chain resolved to a known model; keys matched against its columns |
| `plugin.actionpack.unknown-permit-key` | error | a literal `permit(:key)` is a near-miss (edit distance ≤ 2) of a real column but not one — a likely typo (with a did-you-mean). A key nothing like any column (a legitimate virtual attribute) does not fire |

Filter and render resolution honours nested-module controller
qualification (`module Admin; class WidgetsController` resolves
views under `admin/widgets/…`) and silences gem-shipped parent
classes it can't see.

## Configuration

```yaml
plugins:
  - gem: rigor-actionpack
    config:
      controller_search_paths: ["app/controllers"]  # default
      view_search_paths: ["app/views"]               # default
      view_type_checks: false                        # default
```

## What it types

Inside a controller, `params`, `request`, `session`, `flash` and
`cookies` type as their Action Pack classes, and so do the chains
built on them:

```ruby
request.post?          # bool — and so do get? / put? / patch? / delete? /
                       # head? / options? / trace? / link? / unlink? /
                       # xhr? / xml_http_request? / ssl? / local? / form_data?
flash.now              # ActionDispatch::Flash::FlashNow
flash.keep             # ActionDispatch::Flash::FlashHash
flash[:notice] = "hi"  # "hi" — an assignment is its right-hand side
```

Rigor ships **no signature** for these Action Pack classes, on
purpose: the receiver becomes concrete (so `rigor coverage
--protection` counts the site) while the method surface stays
lenient, so `request.headers`, `flash.now[:alert] = x` and anything
else the framework adds resolve without a diagnostic. A partial
signature would be worse than none — every member it omitted would
become a false `call.undefined-method`.

The predicates are typed `bool` — the union of `true` and `false` —
which is both the real contract (every one of them is an `==`,
`match?` or `include?` in Rails or Rack) and the reason they are safe
to type at all: a condition that folds needs to prove *one* constant,
and a union of both never does. `return unless request.post?` and
`mode = request.get? ? :a : :b` read exactly as they did before.

`request.format` is **not** typed. That inertness argument is
narrower than it looks — it holds for a union of the two boolean
constants, not for a union of ordinary classes, which is nil-free and
so *can* fold a condition — and `Mime::NullType`, the value `format`
returns when there is no format, answers `nil?` with `true` while
being a real object. Typing it needs a nil-aware answer.

## Framework constants resolve

The plugin ships a small bundled signature naming the
`ActionController` namespace and the errors controllers rescue —
`ParameterMissing`, `UnpermittedParameters`, `RoutingError`,
`BadRequest`, `UnknownFormat`, `InvalidAuthenticityToken` and their
siblings. A `rescue ActionController::ParameterMissing => e` now types
`e` as that class instead of leaving it opaque.

The signature names **only** those. `ActionController::Base` and
`ActionController::API` are left undeclared on purpose: every
controller in the app inherits from one of them, and an incomplete
declaration of a superclass turns every member it omits — `render`,
`before_action`, `head` — into a report on working code. For the same
reason `ActionController::Parameters` and the `ActionDispatch` readers
above stay undeclared; their leniency is what makes the `params`
typing safe.

## ERB templates as effect units

Every `app/views/**/*.erb` is compiled to Ruby and analysed as one
**effect unit**, keyed `view:users/show.html` — Rails' own logical
name with the handler dropped, so an ERB → Haml rewrite is not a
rename. Nothing has to be enabled: activating the plugin is what
claims the templates.

What that buys is the answer to *"what does this request actually
do"* past the `render` line. A partial that calls `@user.update`
reports `io.db.write` at `app/views/users/_card.html.erb`, a
`Time.now` in a layout fragment reports `nondet.time`, a leftover
`binding.pry` reports `io.input` — all of it in `rigor effects` and
in the snapshot, so a template that starts writing shows up in a
diff.

```
$ rigor effects
view:users/_card.html: [mutate.local, nondet.time] ≤ [io.db.write] …?
view:users/show.html:  [mutate.local]              ≤ [io.db.read]  …?
```

**The compiler** is Erubi when it resolves in your project's bundle
— Rails' own — and stdlib `ERB` otherwise. Erubi is never added to
your Gemfile and is not a Rigor dependency
([ADR-90](../../adr/90-target-library-resolution-from-project-bundle.md)).
Either way the line map is measured rather than assumed, so a
finding names the template's own line; the column is always 1,
because a compiler rewrites the text of each line and a column of
the compiled Ruby would name nothing you wrote.

**What `self` is.** `ActionView::Base`, declared so the name
resolves and **open** so its method surface stays lenient. That is
what keeps `link_to`, `form_with`, `t`, `content_for`, your own
`ApplicationHelper` methods and every route helper from drawing a
finding per line.

**What is in scope.** `@ivars` are seeded from the controller
actions that render the template — the implicit render
(`UsersController#show` → `users/show`) and explicit
`render :edit` / `render "admin/form"`. Two restrictions keep a seed
from claiming a type the template will not find: only assignments
whose right-hand side cannot be `nil` contribute (`User.find`,
`Model.new`; never `find_by`), and only assignments the action
reaches on **every** path — not one inside an `if`, a `case`, a
`rescue`, a loop or a block, and nothing from a `before_action`
carrying `if:` / `unless:`. Anything else leaves the ivar unseeded,
which reads as `Dynamic` and is silent. A partial inherits the
assigns of its own directory, because an ivar is not a local. Locals
come from the Rails 7.1 strict-locals comment:

```erb
<%# locals: (user:, admin: false) %>
```

**Type checks are off inside templates by default.** `call.*` **and
`flow.*`** findings are suppressed there while the synthesised
bindings are still coarse — measured on redmine and mastodon, the
feature adds **zero** new findings to either
([the measurement note](../../notes/20260917-erb-template-units.md)).
Set `view_type_checks: true` to opt in and have `@user.nmae` in
`show.html.erb` reported like any other call. It turns **both**
families back on, flow folding included — which is the half with the
known gap, since a partial's optional-local preamble reads as a
definite `nil` until its render site's `locals:` are traced
([#1047](https://github.com/rigortype/rigor/issues/1047)).

### Holding views to an effect budget

A view unit is an `effects.envelopes:` subject like any class, and a
finding is positioned in the template. The two presets the design
note describes are written like this — pick one, or neither:

```yaml
# views: lenient — reads are fine (lazy loading is the Rails default)
effects:
  envelopes:
    - match: "app/views/**/*"
      effect: [mutate.local, io.db.read, cache.read, cache.write,
               rails.config.read, rails.i18n.translate,
               rails.session.read, telemetry]
```

```yaml
# views: strict — the static twin of `strict_loading`: every datum is
# loaded in the controller
effects:
  envelopes:
    - match: "app/views/**/*"
      effect: [mutate.local, cache.read, cache.write,
               rails.config.read, rails.i18n.translate,
               rails.session.read, telemetry]
```

Under either, an `io.db.write`, a `job.enqueue`, an `io.output.stdout`
(`puts`), an `io.input` (`binding.pry`) or a `nondet.time` in a view
is a finding.

Only the labels the plugins in your `plugins:` list register are
known, and both stanzas above name two that rigor-actionpack does not
own: `rails.config.read` comes from
`rigor-railties` and `rails.i18n.translate` from
[`rigor-rails-i18n`](rigor-rails-i18n.md). Activate those alongside
rigor-actionpack, or drop the labels — without them each is reported
as `effect.unknown-label` and the entry bounds nothing, which is
deliberately loud rather than a silent no-op.

## Limitations

- **Layouts get no unit.** A layout's `<%= yield %>` is not valid
  Ruby outside a method body, so its compiled form does not parse
  and the file is declined — silently, because two parse errors on
  a template Rails renders perfectly would be worse than no unit.
  Any template whose compiled Ruby does not parse is declined the
  same way. See
  [#1047](https://github.com/rigortype/rigor/issues/1047).
- **Render-site `locals:` are not traced.** A partial's parameters
  are known only from a strict-locals comment; without one they
  read as helper calls on the view context. That is why `flow.*` is
  suppressed in templates by default — see the measurement note and
  [#1047](https://github.com/rigortype/rigor/issues/1047).
- **No controller → template edge yet.** A controller action's own
  summary does not include what its template does, and `render`
  keeps its `template-not-analysed` taint;
  [#1048](https://github.com/rigortype/rigor/issues/1048) carries
  it.
- **ERB only, under `app/views`.** `template_globs:` is a manifest
  row, read without running plugin code, so it cannot consult
  `view_search_paths:`. Haml, Slim and Jbuilder are the same seam
  behind a different compiler and are not claimed.
- **Implicit-self helpers only.** `*_path` / `*_url` calls with an
  explicit receiver (`Rails.application.routes.url_helpers.x_path`)
  are passed through.
- **Path-based file filter.** Files under
  `controller_search_paths` are checked regardless of class
  hierarchy; a non-controller file placed there (rare) would be
  scanned.
- **Coverage follows the upstream facts.** Helper validation only
  knows what `rigor-rails-routes` published, and `permit`
  validation only what `rigor-activerecord` published — enabling
  those producers widens what this plugin can check.
- **`params[:key]` stays untyped.** Inside a controller, `params`
  types as `ActionController::Parameters`, and so does the result
  of every builder method that always returns one — `require`,
  `permit`, `permit!`, `expect`, `slice`, `slice!`, `except`,
  `without`, `extract!`, `merge`, `merge!`, `reverse_merge`,
  `reverse_merge!`, `with_defaults`, `with_defaults!`, `compact`,
  `compact_blank`, `deep_dup` — so a chain built from them keeps a
  concrete receiver throughout. A subscript read is deliberately
  left untyped: `params[:missing]` is `nil` at runtime, and a type
  that says otherwise would let the flow rules fold live
  conditions (`if params[:q]`, `url.nil?`) to a constant and report
  working code. Methods whose result depends on the call — `dig`,
  `fetch`, `compact!`, and the block-less `select` / `reject` /
  `transform_keys` / `transform_values` — are untyped for the same
  reason.
- **`flash[:key]` and `session[:key]` stay untyped too**, for that
  same reason and measured the same way. Both are leaf reads that
  return whatever was stored — or `nil` for a key that is not set.
  A non-nil type folds `mode = flash[:notice] ? … : …` to one arm and
  reports the live guard after it; a nullable one puts
  `call.possible-nil-receiver` on `note = flash[:notice];
  note.upcase`. Writing through them is unaffected: `flash[:k] = v`
  is `v` because that is what an assignment expression means in Ruby,
  with no rule needed.

## Plugin internals

The cross-plugin fact contract (`:helper_table` / `:model_index`),
the controller/view discovery producers, the demo, and the
contract surfaces this plugin exercises are in the
[plugin's README](../../../plugins/rigor-actionpack/README.md). To
write a plugin, see [`examples/`](../../../examples/README.md) and
the [`rigor-plugin-author`](../08-skills.md) skill.
