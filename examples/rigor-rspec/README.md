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

## What the plugin recognises

```ruby
RSpec.describe "User" do
  let(:user) { :alice }
  let(:user) { :bob }            # ← warning: duplicate `let(:user)`

  let(:tags) { tags.map(&:up) }  # ← error: self-referencing let

  context "when admin" do
    let(:user) { :admin }        # ← OK: different scope
  end
end
```

```text
spec/user_spec.rb:5:3: warning: duplicate `let(:user)` in this scope (first declared at line 4); the last declaration wins at runtime
spec/user_spec.rb:7:3: error:   `let(:tags)` references its own name `tags` — this will infinite-loop at runtime
```

## What it checks

1. **Duplicate `let` / `subject` declarations** within
   the same scope — `warning`. RSpec's runtime lets the
   last declaration win, so the first one is silently
   shadowed. The diagnostic message names the line of
   the first declaration so the user can reconcile.
2. **Self-referencing `let` / `subject`** — calling the
   declared name from inside its own block body —
   `error`. At runtime this infinite-loops; users
   typically meant to call a different method or forgot
   to introduce a `super` chain through `before`.

The walker recognises:

- `RSpec.describe ... do` (root scope)
- `describe ... do` / `context ... do` (nested scopes)
- `let(:name) { ... }` / `let!(:name) { ... }`
- `subject(:name) { ... }` / `subject { ... }` (the
  implicit `:subject`)

## Configuration

No configuration knobs in v0.1.0. The plugin walks every
file on the project's `paths:` looking for
`RSpec.describe ... do` blocks; spec files outside the
configured paths are not scanned. Files with no
recognised describe block are silently skipped (so this
plugin is safe to enable project-wide alongside
non-spec files).

## Limitations (v0.1.0)

- **No let-typo detection in `it` bodies.** Detecting
  an `it` block's reference to a misspelled `let` name
  requires resolving every method call inside the block
  against the let scope chain, the included modules,
  the matchers DSL (`expect`, `not_to`, `eq`, ...), and
  helper methods. Reliable diagnostics here need a much
  heavier walker — queued for v0.2.x.
- **No mock-target validation.**
  `expect(x).to receive(:nme)` validating against `x`'s
  methods is a separate slice. It overlaps with the
  engine's general method-existence diagnostics and needs
  careful coordination to avoid double-firing.
- **No shared-context resolution.** `include_context`,
  `shared_context`, and `it_behaves_like` are silently
  ignored. Pulling shared declarations into the host
  scope would require reading the source of the shared
  context, possibly across files — a future slice.
- **Constant validation is the engine's job.**
  `RSpec.describe SomeClass do` does not validate
  `SomeClass`; the engine's `inference.unresolved-constant`
  catches that already.
- **Self-reference detection is intra-block only.**
  `let(:user) { foo }` where `foo` then calls back to
  `user` is NOT flagged — that's a multi-step trap
  that would need the engine's call graph, and is
  vastly less common than the literal `let(:user) {
  user }` case.

## Layout

```text
examples/rigor-rspec/
├── README.md
├── rigor-rspec.gemspec
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
cd examples/rigor-rspec/demo
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

## License

MPL-2.0, matching the parent Rigor project.
