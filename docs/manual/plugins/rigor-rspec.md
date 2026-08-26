# rigor-rspec

Validates RSpec `let` / `subject` declarations within each
`describe` / `context` scope. It is deliberately small: the two
checks it ships have the lowest false-positive risk of the
proposed RSpec surface, run in pure syntactic-walk mode, and
catch real bugs that `rspec` / `rubocop-rspec` don't always
surface clearly. No RSpec runtime dependency.

It ships bundled in `rigortype`. Activate it under `plugins:`:

```yaml
plugins:
  - rigor-rspec
```

## What it checks

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

The snippet above is condensed for reading; the output below is what
Rigor actually prints for the plugin's own demo
(`plugins/rigor-rspec/demo/`), so the line numbers are that file's:

```text
spec/errors_spec.rb:23:3: warning: duplicate `let(:user)` in this scope (first declared at line 22); the last declaration wins at runtime [plugin.rspec.duplicate-let]
spec/errors_spec.rb:27:3: error: `let(:tags)` references its own name `tags` — this will infinite-loop at runtime [plugin.rspec.self-reference]
```

1. **Duplicate `let` / `subject` declarations** within the same
   scope — `warning`. RSpec's runtime lets the last declaration
   win, so the first is silently shadowed; the message names the
   line of the first declaration.
2. **Self-referencing `let` / `subject`** — calling the declared
   name from inside its own block body — `error`. At runtime this
   infinite-loops.

The walker recognises `RSpec.describe … do` (root), nested
`describe` / `context … do`, `let(:name)` / `let!(:name)`, and
`subject(:name)` / bare `subject` (the implicit `:subject`).

## Configuration

No configuration knobs. The plugin walks every file on the
project's `paths:` for `RSpec.describe … do` blocks; files with
no recognised describe block are silently skipped, so it is safe
to enable project-wide alongside non-spec files.

## Limitations

- **No let-typo detection in `it` bodies.** Flagging a misspelled
  `let` name inside an `it` block needs a much heavier walker
  (matcher DSL, helper methods, the let scope chain) — queued.
- **No mock-target validation.** `expect(x).to receive(:nme)`
  against `x`'s methods is a separate slice.
- **No shared-context resolution.** `include_context`,
  `shared_context`, and `it_behaves_like` are ignored.
- **Self-reference detection is intra-block only.** An indirect
  loop (`let(:user) { foo }` where `foo` calls back to `user`) is
  not flagged.
- Constant validation (`RSpec.describe SomeClass`) is the
  engine's job, not this plugin's.
- **No roots for [`rigor unused`](../02-cli-reference.md#rigor-unused).**
  `RSpec.describe User` is already recorded as a reference, stamped
  with the `test` role because it came from a spec. Publishing spec
  references as roots would strip that role, promote every
  spec-referenced class to production-reachable, and delete the
  report's **Reachable only from test code** section — the row that
  tells you a class is dead production code with a live test. The
  ordinary handling is the correct one.

## Related plugins

`rspec-rails` and `shoulda-matchers` matchers are mostly
*behavioral* (they assert runtime state, not a static type), so
they are out of scope here; the queued `rigor-rspec-rails` and
`rigor-shoulda-matchers` plugins would emit domain-specific
diagnostics for them. The README covers that boundary in detail.

## Plugin internals

The scope-walker / analyzer layout, how to run the demo, the
contract surfaces this plugin exercises, and the future-direction
slices are in the
[plugin's README](https://github.com/rigortype/rigor/blob/master/plugins/rigor-rspec/README.md). To
write a plugin, see [`examples/`](https://github.com/rigortype/rigor/blob/master/examples/README.md)
and the [`rigor-plugin-author`](../08-skills.md) skill.
