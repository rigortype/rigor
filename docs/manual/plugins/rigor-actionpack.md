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

## Limitations

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
