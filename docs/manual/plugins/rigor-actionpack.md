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

## Plugin internals

The cross-plugin fact contract (`:helper_table` / `:model_index`),
the controller/view discovery producers, the demo, and the
contract surfaces this plugin exercises are in the
[plugin's README](../../../plugins/rigor-actionpack/README.md). To
write a plugin, see [`examples/`](../../../examples/README.md) and
the [`rigor-plugin-author`](../08-skills.md) skill.
