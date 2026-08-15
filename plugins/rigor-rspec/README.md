# rigor-rspec

Tier 3A of Rigor's Rails ecosystem family
([roadmap](../../docs/design/20260508-rails-plugins-roadmap.md)).
Validates RSpec `let` / `subject` declarations within
each `describe` / `context` scope. **Deliberately scoped**
— the roadmap describes a much larger plugin (let-typo
detection in `it` bodies, mock-target validation); both
are out of scope for v0.1.0 of this plugin. See the
[`Future direction`](#future-direction) section for what's
queued.

The two checks shipped today have the lowest false-positive
risk of the proposed surface, both run in pure
syntactic-walk mode, and catch real bugs that `rspec` /
`rubocop-rspec` don't always surface clearly. No RSpec
runtime dependency.

> **Using this plugin?** The user guide — what it checks, its
> (lack of) configuration, and its limitations — lives in the
> manual at
> [docs/manual/plugins/rigor-rspec.md](../../docs/manual/plugins/rigor-rspec.md).
> This README covers the plugin's internals and the contract
> surfaces it exercises.

## Layout

```text
plugins/rigor-rspec/
├── README.md
├── lib/
│   ├── rigor-rspec.rb
│   └── rigor/plugin/
│       ├── rspec.rb
│       └── rspec/
│           ├── scope_walker.rb   ← collects describe / context / let scopes
│           └── analyzer.rb       ← duplicate + self-reference checks
└── demo/
    ├── .rigor.yml
    ├── .gitignore
    └── spec/
        ├── user_spec.rb     ← clean usage (no diagnostics)
        └── errors_spec.rb   ← every error path
```

## Running the demo

```sh
cd plugins/rigor-rspec/demo
nix --extra-experimental-features 'nix-command flakes' develop --command \
  env RUBYLIB="$PWD/../lib" bundle exec --gemfile=$PWD/../../../Gemfile \
  rigor check
```

## Plugin authoring surface this exercises

| Surface | Used for |
| --- | --- |
| `manifest(...)` | Single-line manifest declaration (no config schema needed). |
| `Plugin::Base#diagnostics_for_file` | Per-file walker emits both warnings and errors. |
| Nested-scope walk | `ScopeWalker` recursively builds a tree of `describe` / `context` scopes; declarations are scoped per-node so duplicate detection is scope-local. |
| Two-pass detection per scope | First collect declarations, then check duplicates + self-references; mirrors `rigor-statesman`'s pattern. |

This plugin doesn't need:

- IoBoundary / cache producer (per-file analysis only)
- Cross-plugin facts
- Engine type inference (everything is syntactic)
- Custom config schema (no knobs)

That makes it a useful counterpoint to the more
architecturally-rich `rigor-activerecord`: same plugin
contract, much smaller surface — proof that the contract
scales down.

## Why this plugin supplies no `rigor unused` roots

It was considered for the reachability report ([ADR-102](../../docs/adr/102-unused-code-reachability-report.md) WD3) and **deliberately contributes nothing** — the same decision `rigor-rspec-rails` records.

`RSpec.describe User` and `described_class` name the class as an ordinary constant, so `rigor unused`'s scan already sees the reference. What it also does — and must keep doing — is stamp that reference with the `:test` role, because the file it came from is a spec (ADR-102 WD8).

Publishing spec references as **roots** would strip that role and promote every spec-referenced class to production-reachable. That erases the report's `Reachable only from test code` section outright: a class used solely by its own spec is dead production code with a live test, which is the single most actionable row the report produces, and it is precisely the class a spec reference would have promoted. The right handling is the one the ordinary scan already gives it, so there is nothing for this plugin to add.

## Future direction

The two slices below are the obvious follow-ups; both
need significantly more analyzer surface:

- **Let-typo detection in `it` bodies.** Walk each `it`
  block, find every method call without an explicit
  receiver, classify it (RSpec DSL? matcher? helper
  method? let?), and flag references that look like
  let-name typos via `DidYouMean`. Requires a built-in
  set of RSpec DSL names and probably a configurable
  helper-method allowlist to suppress false positives.
- **Mock-target validation.** `expect(x).to
  receive(:nme)` validating against `x`'s methods. The
  trickiest case is doubles (`instance_double(User)`,
  `class_double(User)`) — the inferred type carries the
  doubled class, not the double. Coordinate with the
  engine's `call.undefined-method` to avoid
  double-firing.
- **Shared-context resolution.** Walk `shared_context`
  bodies, register their declarations under the
  `include_context` / `it_behaves_like` host scope so
  duplicate / self-reference checks run there too.
- **Subject reference detection.** Detect blocks that
  use `subject` (the implicit one) without naming it —
  emit a hint to switch to the explicit form when the
  scope has more than one example.

## rspec-rails / shoulda-matchers boundary

The `MatcherAnalyzer` (Pillar 2 Slice 1 — `expect(x).to
MATCHER` narrows `x`) covers the **type-narrowing** floor
of RSpec's matcher DSL. The two ecosystem gems most
projects also pull in (`rspec-rails` for Rails-specific
matchers; `shoulda-matchers` for ActiveRecord / ActiveModel
matchers) are **mostly** behavioral — they assert
runtime behavior rather than narrowing a static type:

- `expect(response).to have_http_status(200)` /
  `render_template(:show)` / `route_to(...)` /
  `redirect_to(...)` — assertions about the
  `ActionDispatch::TestResponse` object's state, not its
  type. The receiver stays at `Nominal[ActionDispatch::TestResponse]`
  regardless of the matcher; nothing for Rigor to narrow.
- `should validate_presence_of(:email)` /
  `should belong_to(:user)` /
  `should have_many(:posts)` — schema-shape matchers on a
  model class. The receiver is `Singleton[<Model>]` and
  the matcher asserts the model's DSL configuration, not
  a type narrowing on an instance.

A small number of matchers in these gems DO fit the
narrowing model — for example, `expect(model).to be_a(User)`
or `expect(response_body).to match(/foo/)` work cleanly via
the existing matcher table because they reduce to the
RSpec-core forms `be_a` / `match`. No new wiring is needed
for those; they fall through the existing recogniser.

The behavioral matchers (have_http_status, render_template,
validate_presence_of, …) would each need a domain-specific
diagnostic (e.g. "render_template :show but no
app/views/<controller>/show.html.erb"), which is a different
plugin shape from type narrowing. Those queued for follow-up
plugins:

- `rigor-rspec-rails` — would absorb the response-state /
  route-shape / template-existence matchers and emit
  domain-specific diagnostics. Currently `rigor-actionpack`'s
  render-target validation (`render :show` against the
  view tree) overlaps; the slice would coordinate to avoid
  double-firing.
- `rigor-shoulda-matchers` — would consume the
  `:model_index` cross-plugin fact (published by
  `rigor-activerecord`) and validate `should validate_presence_of(:email)`
  against the model's actual columns / associations /
  validations.

Both are queued under [the Rails plugins
roadmap](../../docs/design/20260508-rails-plugins-roadmap.md);
neither has an active slice today.

## License

MPL-2.0, matching the parent Rigor project.
