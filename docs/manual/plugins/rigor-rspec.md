# rigor-rspec

Validates RSpec `let` / `subject` declarations within each
`describe` / `context` scope. It is deliberately small: the two
checks it ships have the lowest false-positive risk of the
proposed RSpec surface, run in pure syntactic-walk mode, and
catch real bugs that `rspec` / `rubocop-rspec` don't always
surface clearly. It also narrows a local through `expect(x).to`
matchers, described under [Matcher narrowing](#matcher-narrowing).
No RSpec runtime dependency.

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

## Matcher narrowing

`expect(x).to MATCHER` narrows the local `x` for the rest of the
example body, so downstream calls resolve against the matched type.
Only a plain local is a target.

```ruby
RSpec.describe "Counter" do
  it "narrows through the matcher" do
    count = rand(10) if rand(2).zero?  # count is Integer?
    expect(count).to eq(42)            # count is 42 from here on
    count + 1                          # no possible-nil-receiver warning
  end
end
```

| Matcher | Effect on `x` |
| --- | --- |
| `eq(literal)` / `eql(literal)` | meet with `Constant<literal>` (see below) |
| `be_a(T)` / `be_kind_of(T)` / `be_instance_of(T)` / `be_an_instance_of(T)` | meet with `T` |
| `be_nil` | narrow to `Constant<nil>` |
| `match(/regex/)` | keep the `String` and `Symbol` members, remove `nil`, `true`, `false` and numeric members; unchanged when a member may be anything else |
| `not_to be_nil` / `to_not be_nil` | narrow away from `nil` |
| `not_to be_a(T)` / `not_to be_kind_of(T)` / `not_to be_instance_of(T)` / `not_to be_an_instance_of(T)` | narrow away from `T` |
| `not_to eq(literal)` / `not_to eql(literal)` (and `to_not`) | unchanged (see below) |
| `not_to match(/regex/)` (and `to_not`) | unchanged: a `String` that does not match passes |

Other matchers emit nothing. `be_truthy` is not narrowed, nor is
`expect { ... }.to raise_error(...)` (the block form), nor an
`expect(foo.bar)` whose argument is not a local.

### Equality is a meet, not a replacement

`eq(literal)` passes when `x == literal`, and `eql(literal)` when
`x.eql?(literal)`. The local is the receiver, so `x`'s own operator
decides, and that operator can hold across classes: `1 == 1.0`, and a
class with its own `==` (a `ModInt` that compares `to_i`) passes
`expect(m).to eq(9)`. The matcher therefore never replaces `x`'s
type. It narrows each member of `x`'s type on its own.

The core equality classes are the nine in `EQUALITY_CORE_CLASSES`
(`plugins/rigor-rspec/lib/rigor/plugin/rspec/matcher_analyzer.rb`):
`Integer`, `Float`, `Rational`, `Complex`, `String`, `Symbol`,
`NilClass`, `TrueClass`, and `FalseClass`. The first four are the
numeric classes.

- a member of the literal's own class narrows to the literal,
  refinements of that class included. After `x = rand(10)`,
  `expect(x).to eq(9)` gives `9`; `Integer?` with `eq(9)` gives `9`,
  because the `nil` member cannot equal `9`. A refinement such as
  `decimal-int-string?` (from `y = x && x.to_s` with `x` an
  `Integer?`) gives `"3"` under `eq("3")`. A `Constant` member is kept
  when it equals the literal and dropped otherwise;
- a `Float` member meets `0.0` and is kept, since `-0.0` also equals
  it;
- a numeric member of another class (`Integer`, `Float`, `Rational`,
  `Complex`) is kept under `eq`: `Integer | Float` with `eq(1)` gives
  `1 | Float`;
- any other member of a core equality class is dropped:
  `String | Integer` with `eq(9)` gives `9`;
- `eql(literal)` takes the same path, except that a numeric member of
  another class is dropped, because `eql?` compares classes:
  `Integer | Float` with `eql(1)` gives `1`.

### A member, or the whole local, keeps its type in these cases

A member outside the core equality classes makes the whole fact
unavailable, so the local keeps its type, not just that member:

- a member is `Dynamic`, or of a class outside `EQUALITY_CORE_CLASSES`,
  such as a user class (`ModInt`), `Numeric`, or a generic `Array` or
  `Hash`. Under `eq(9)` the whole local stays unchanged, so `9 | [1]`
  and `9 | { a: 1 }` do not narrow;
- the project defines the operator (`==` for `eq`, `eql?` for `eql`)
  on the literal's class, in any analysed file. A `def` or a
  `define_method` both count. A core `==` can call back into the
  literal's own `==` (`Integer#==` for a non-numeric argument,
  `String#==` for one that responds to `to_str`), so the plugin does
  not narrow there even when a kept member would survive;
- the project reopens a core ancestor of the member's class and
  defines the operator there, such as `class Numeric; def eql?` or
  `class Object; def ==`. Under `eql(9)` an `Integer` stays
  `Integer`; under `eq(9)` the `nil` member of `Integer?` stays `nil`
  while the `Integer` member narrows (`9?`);
- the literal is `nil`, `true`, or a Symbol, and a member is a user
  class or `Dynamic`: the local's own `==` can match these literals
  too, so the local keeps its type as it does for `9`;
- the local is unbound, no scope is available, or no member survives
  the match (`nil` with `eq(9)`).

A reopening that defines only other methods, such as
`class String; def shout`, does not count: `String?` with
`eq("a")` still narrows to `"a"`. A `class Symbol; def ==` in the
project keeps the `Symbol` member and narrows the rest:
`Symbol | Integer | nil` with `eq(9)` gives `9 | Symbol`.

`not_to eq(literal)`, `to_not eq(literal)`, and their `eql` forms do
not narrow: `x` keeps the type it had before the matcher.

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
[plugin's README](../../../plugins/rigor-rspec/README.md). To
write a plugin, see [`examples/`](../../../examples/README.md)
and the [`rigor-plugin-author`](../08-skills.md) skill.
