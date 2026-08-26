# rigor-rspec-rails

Validates [rspec-rails](https://github.com/rspec/rspec-rails)
**behavioral** matchers whose arguments are statically checkable —
currently `have_http_status(int_or_symbol)`, flagging out-of-range
status codes and typo'd status symbols. It is the behavioral sibling
of [rigor-rspec](rigor-rspec.md): where rigor-rspec *narrows a local's
type* through matchers like `be_a` / `be_nil` / `eq(literal)`,
rigor-rspec-rails emits *domain diagnostics* on matcher arguments
without narrowing anything. The two activate independently and compose.

It ships bundled in `rigortype`. Activate it under `plugins:` (usually
alongside rigor-rspec):

```yaml
plugins:
  - rigor-rspec
  - rigor-rspec-rails
```

## What it checks

```ruby
RSpec.describe HomeController do
  it "returns 200" do
    expect(response).to have_http_status(200)       # OK
    expect(response).to have_http_status(:ok)       # OK
    expect(response).to have_http_status(:success)  # OK (Rails 2xx group alias)
    expect(response).to have_http_status(99)        # warning: out-of-range
    expect(response).to have_http_status(:succes)   # warning: unknown symbol (typo)
  end
end
```

| Rule | Severity | Fires when |
| --- | --- | --- |
| `plugin.rspec-rails.have_http_status.out-of-range` | warning | an integer argument is outside `100..599` |
| `plugin.rspec-rails.have_http_status.unknown-symbol` | warning | a symbol argument is not a known Rack status code nor a Rails status-group alias (with a did-you-mean) |

The accepted status symbols come from the **real**
`Rack::Utils::SYMBOL_TO_STATUS_CODE` read at analysis time (the same
authority `have_http_status` itself uses), not a vendored snapshot — so
a newly-added Rack symbol is never mistaken for a typo
([ADR-39](https://github.com/rigortype/rigor/blob/master/docs/adr/39-plugin-target-library-invocation.md)). When Rack
can't be loaded the plugin **declines** to flag any symbol (reduced
coverage, never a false positive). The eight Rails status-group aliases
(`:success`, `:successful`, `:missing`, `:redirect`, `:error`,
`:client_error`, `:server_error`, `:informational`) are a small stable
constant set. Only literal integer / symbol arguments are checked;
strings, variables, and computed expressions pass through.

## No configuration

The plugin has no configuration knobs.

## Limitations

- **Only `have_http_status`.** Other rspec-rails matchers are queued
  behind cross-plugin coordination: `render_template` (overlaps
  rigor-actionpack render-target validation), `route_to` / `redirect_to`
  / `be_routable` (need the rigor-rails-routes table), `have_enqueued_job`
  / `have_received` (overlap engine constant / undefined-method rules).
- **Literal arguments only** — a status passed via a variable or method
  call is not statically checkable, so it's accepted silently.
- **No roots for [`rigor unused`](../02-cli-reference.md#rigor-unused)**,
  for the reason [`rigor-rspec`](rigor-rspec.md#limitations) gives: a
  spec's constant reference is already recorded with the `test` role,
  and rooting it would delete the report's "reachable only from tests"
  answer.

## Plugin internals

The matcher recogniser, the Rack-table lookup, and the contract
surfaces this plugin exercises are in the
[plugin's README](https://github.com/rigortype/rigor/blob/master/plugins/rigor-rspec-rails/README.md). To
write a plugin, see [`examples/`](https://github.com/rigortype/rigor/blob/master/examples/README.md) and the
[`rigor-plugin-author`](../08-skills.md) skill.
