# rigor-rspec-rails

Rigor plugin that validates [rspec-rails](https://github.com/rspec/rspec-rails)
**behavioral** matchers whose arguments are statically
checkable. Sibling to `rigor-rspec` (Pillar 2 Slice 1) and
`rigor-minitest`, but covers a different shape: instead of
narrowing a local's static type, it emits domain-specific
diagnostics on matcher argument typos / out-of-range values.

## What the plugin recognises (v0.1.0)

### `have_http_status(int_or_symbol)`

```ruby
RSpec.describe HomeController do
  it "returns 200" do
    get :index
    expect(response).to have_http_status(200)          # OK
    expect(response).to have_http_status(:ok)          # OK
    expect(response).to have_http_status(:success)     # OK (Rails alias for 2xx)
    expect(response).to have_http_status(99)           # warning: out-of-range
    expect(response).to have_http_status(:succes)      # warning: typo
  end
end
```

Rules fired:

| Rule                                | Trigger                                                                                    |
|-------------------------------------|--------------------------------------------------------------------------------------------|
| `have_http_status.out-of-range`     | `IntegerNode` arg outside `100..599`                                                       |
| `have_http_status.unknown-symbol`   | `SymbolNode` arg not in Rack's status-code keys nor a Rails status-group alias             |

### What's accepted as a status symbol

The plugin vendors a frozen snapshot of `Rack::Utils::SYMBOL_TO_STATUS_CODE`
(Rack 3.x) plus Rails' eight status-group aliases —
`:success`, `:successful`, `:missing`, `:redirect`, `:error`,
`:client_error`, `:server_error`, `:informational`. There's
no runtime dependency on `rack` or `actionpack`; the catalogue
lives in `lib/rigor/plugin/rspec_rails/http_status_codes.rb`
and can be extended in-place when a Rack release adds a new
alias (or a project's status-symbol vocabulary differs).

## Why this is a separate plugin from rigor-rspec

`rigor-rspec` (Pillar 2 Slice 1) handles the **type-narrowing**
matchers — `be_a` / `be_kind_of` / `be_nil` / `eq(literal)` etc.
— ones that refine a local's static type so downstream calls
in the same `it` body resolve at the narrowed type.

`rigor-rspec-rails` handles the **behavioral** matchers — ones
that assert runtime state (HTTP status, rendered template,
route shape) without narrowing a type. The two plugins are
activated independently in `.rigor.yml`.

## Configuration

No knobs in v0.1.0. Activate via:

```yaml
# .rigor.yml
plugins:
  - rigor-rspec
  - rigor-rspec-rails
```

The two plugins compose: `rigor-rspec` provides matcher
narrowing on the type-narrowing matchers, `rigor-rspec-rails`
provides the diagnostic on `have_http_status` typos.

## Deferred matchers (rspec-rails surface)

Queued for follow-up slices — each needs cross-plugin
coordination or overlaps with an existing rigor diagnostic:

- **`render_template(...)`** — overlaps with `rigor-actionpack`'s
  render-target validation (`render :show` against the view
  tree). A future slice would coordinate to avoid double-firing.
- **`route_to(...)` / `redirect_to(...)`** — needs the routes
  table from `rigor-rails-routes` (`:helper_table` cross-plugin
  fact, ADR-9). Future slice.
- **`have_enqueued_job(JobClass)` / `have_enqueued_mail(MailerClass)`** —
  class-existence overlaps with engine's
  `inference.unresolved-constant`. Queued behind a decision
  on which surface owns the diagnostic.
- **`have_received(:method)`** — overlaps with engine's
  `call.undefined-method`. Same coordination question.
- **`be_routable`** — needs routes table.
- **`match_response_schema(...)`** (rswag / OpenAPI) — out of
  scope; a separate plugin would consume the project's
  OpenAPI definitions.

## Layout

```text
examples/rigor-rspec-rails/
├── README.md
├── rigor-rspec-rails.gemspec
├── lib/
│   ├── rigor-rspec-rails.rb
│   └── rigor/plugin/
│       ├── rspec_rails.rb                       ← Plugin::RspecRails class
│       └── rspec_rails/
│           ├── http_status_codes.rb             ← vendored Rack/Rails symbol catalogue
│           └── have_http_status_analyzer.rb     ← recognizer + diagnostic builder
└── demo/
    ├── .rigor.yml
    └── spec/
        └── http_status_spec.rb                  ← every diagnostic + clean cases
```

## License

MPL-2.0, matching the parent Rigor project.
