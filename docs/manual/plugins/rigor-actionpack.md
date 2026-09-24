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
`puts` reports `io.output.stdout` — all of it in `rigor effects` and
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
whose right-hand side is one record and cannot be `nil` contribute
(`User.find(id)`, `Model.new`; never `find_by`, and never a call
that returns several records, such as `User.find(a, b)`,
`User.find([1, 2])`, `User.find(*ids)` or `User.create([…])`), and
only assignments the action
reaches on **every** path — not one inside an `if`, a `case`, a
`rescue`, a loop or a block, and nothing from a `before_action`
carrying `if:` / `unless:`. Anything else leaves the ivar unseeded,
which reads as `Dynamic` and is silent. A partial inherits the
assigns of its own directory, because an ivar is not a local. Locals
come from the Rails 7.1 strict-locals comment:

```erb
<%# locals: (user:, admin: false) %>
```

**`call.*` findings are off inside templates by default**, while the
synthesised receivers are still coarse — measured on redmine and
mastodon, the feature adds **zero** new findings to either
([the measurement note](../../notes/20260917-erb-template-units.md)).
Set `view_type_checks: true` to opt in and have `@user.nmae` in
`show.html.erb` reported like any other call.

`flow.*` **reports in a template like anywhere else.** It was
suppressed alongside `call.*` for one measured reason — a partial's
optional-local preamble (`<% path = nil unless defined? path %>`)
really did assign nil, because nothing told the unit its render site
had bound `path`. Render-site `locals:` are traced now, and the same
two projects re-measured with the family reporting are byte-identical
to the runs with it suppressed ([the #1047 note](../../notes/20260917-render-locals-and-layouts.md)).

### Locals come from the render site

A partial's parameters are bound by whoever renders it, and every
spelling of that is read — on both sides of the render:

```erb
<%= render partial: "card", locals: { user: @user } %>
<%= render "card", user: @user %>          <%# a view's trailing hash IS locals %>
<%= render partial: "card", collection: @users, as: :row %>
<%= render partial: "card", object: @user %>
```

`collection:` binds `row`, `row_counter` and `row_iteration`;
`object:` and `as:` bind one local named after the partial or after
`as:`. A controller's `render partial: …, locals: …` is read the same
way — but a controller's *trailing hash* is options, so
`render :show, status: :ok` binds nothing.

A partial rendered from several sites gets the **union** of the
names. A name only some of them pass is still bound, typed
`Dynamic` — absence is what produced the false positives above.
A **type** is claimed only where every site agrees on one it could
settle from the call itself (`User.find(1)`, or an ivar the rendering
action's own seeds typed); anything else is `Dynamic`. A
strict-locals comment still wins where a template carries one.

A partial's **own** optional-local test counts too:
`<% size = nil unless defined?(size) %>`, `local_assigns[:size]` and
`local_assigns.key?(:size)` bind `size` even when no render site the
plugin can read passes it — a `locals: opts` hash, a `render` from a
helper, or a local with a default nobody passes. A name a helper under
`app/helpers` defines is left alone, so
`<% if defined?(current_user) %>` stays a helper call. A helper that a
gem or a concern defines is not seen by that scan, and its name is
bound as a `Dynamic` local instead.

### The controller → template edge

A controller action's summary **includes what its template does**.
`render :show`, `render "show"`, `render "admin/form"`,
`render template:`, `render action:`, `render partial:` (with or
without `collection:`) and the implicit render of
`<controller>/<action>` all reach the template's own unit, and a
template reaches the partials *it* renders — so an `io.db.write` in
`app/views/users/_card.html.erb` shows up on `UsersController#show`
three hops away, and `rigor effects explain` prints the path.

A partial is looked up in the rendering template's own format, with
the one fallback Action View itself hard-codes: a `.js.erb` template
reaches `_list.js.erb` where it exists and `_list.html.erb`
otherwise, which is how "a JS response that injects rendered HTML"
works at all. Only one of the two is joined, never both. A `.json`,
`.xml` or `.turbo_stream` template gets no fallback — what those fall
back to depends on the request's `Accept` header, which the source
does not say — and neither does a render site that names its format
(`formats: [:js]`, `render "list.js"`) or a controller-side `render`.

The fallback stops at a template that **exists and produced no
unit**: a `_list.js.haml`, or a `_list.js.erb` whose compiled Ruby
does not parse. Rails runs that file, so the `.html` one's effects
are not what the render produces, and the taint stays. That is why
this plugin claims `app/views/**/*.{haml,slim,jbuilder,builder,rabl,ruby}`
and compiles none of them: the claim is how the engine learns a
template is there. A handler outside that list is invisible, and a
render of one still falls back.

Two approximations ride along, and each costs labels rather than a
taint. A partial reached *through* the fallback renders its own
partials in `html`, while Action View's context is still
`[:js, :html]`; where a nested partial exists in both formats, the
`.js` template gets the `.html` one's labels. And a template whose
name carries no format at all (`_row.jbuilder`) blocks nothing, since
its key has no format to block — which happens to agree with Rails,
which ranks a formatted template above it. Both are zero occurrences
on the measured corpus.

The `template-not-analysed` taint on a `render` is discharged
exactly when the edge lands on a real unit. It **stays** when it
does not, and both cases are common enough to name:

- the target is computed — `render params[:view]`, or
  `render formats: some_format`. The render site is read from
  literals only, so anything computed keeps the honest "and possibly
  more";
- the target names no template this plugin compiled — a `render
  partial: @thing`, or a partial that exists in neither the requested
  format nor its fallback;
- the template is outside `app/views/**/*.erb` — a Haml, Slim or
  Jbuilder view, which this plugin does not claim.

`render json:`, `render plain:` and the rest of the non-template
family are left alone: they render no template, the rule declines,
and the row reads exactly as it did before.

An action that answered for itself is **not** edged to the
conventional template. `redirect_to`, `head`, `send_data` and
`send_file` each mean the implicit render did not happen, and
attributing `users/away` to an action that redirects would be a view
it never runs.

### Holding views to an effect budget

A view unit is an `effects.envelopes:` subject like any class, and a
finding is positioned in the template:

```yaml
effects:
  envelopes:
    - match: "app/views/**/*"
      effect: [mutate.local]
```

A bound judges only what Rigor proved by reading code, so what this
catches in a view is what Rigor's own catalogue proves: a `puts`
(`io.output.stdout`) or a `Time.now` (`nondet.time`).

**Plugin-sourced labels are never judged by an envelope.** A plugin's
statement about a framework method — `User.find` is `io.db.read`,
`@user.update` is `io.db.write`, `perform_later` is `job.enqueue` —
rides the declared (`≤`) lane, and the envelope check reads the proven
one. Listing `io.db.read` in a view's envelope, or leaving it out,
changes nothing: the lazy `<%= user.posts.count %>` is not a finding
either way. That is a property of the whole Rails effect layer rather
than of views ([ADR-103](../../adr/103-effect-labels.md) WD17, ruled
in [#1059](https://github.com/rigortype/rigor/issues/1059)).

What notices a view that starts reading the database is the effect
snapshot. With `.rigor-effects.yml` committed, `rigor effects check`
fails by default on drift in either lane, and a template that gains a
query shows up in the diff as a declared-lane addition:

```
view:users/show.html  ≤+ io.db.read
```

That is a ratchet on the whole project's recorded effects, reviewed as a
diff — not a policy scoped to `app/views/**/*`. See
[Effect labels](../19-effect-labels.md#what-a-bound-can-and-cannot-see).

## Limitations

- **A controller's own layout is not edged.** A layout is a unit
  now, and a `render layout:` *inside a view* reaches it — but the
  layout Rails wraps an action's template in (`layouts/application`,
  or whatever `layout "base"` named) is not attributed to that
  action. A callee rule may read the call's literals, the unit's
  owner and the unit's key, and a layout's name is none of those:
  it is a class-body declaration plus a convention lookup against
  the view tree. So the layout's own effects reach a view that
  renders it explicitly and no further.
- **`yield` in a layout is a `String` and nothing more.** The
  keyword is rewritten into a declared call on the view context so
  the body parses; what the inner template produced is never
  modelled.
- **Unsaved render sites are not read in the editor.** The
  render-site index reads templates and controllers from disk, so a
  `locals:` you have typed but not saved does not reach the partial
  until the save. A keystroke recompiles only the buffer, and a save
  rebuilds the project's analysis as it always has. A view changed on
  disk *without* a save the editor sees (a `git checkout`, a
  formatter run elsewhere) recompiles every view on the next
  publish, because a partial's locals can come from any of them. A
  full `rigor check` does
  the same compile work it did before — the index hands its compiled
  sources to the unit transform rather than compiling twice.
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
