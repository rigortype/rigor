# rigor-minitest

Narrows local variables through **Minitest** and **Test::Unit**
assertions — and the Minitest/spec `_(x).must_*` / `.wont_*` matchers
layered on top. When the plugin recognises a supported assertion shape
it emits a `:local`-kind narrowing fact, so the rest of the test body
resolves against the asserted type. It also tells the engine that a
test framework's `setup` method initialises instance variables, which
suppresses spurious nil warnings on ivars read in the test body. It
reads source only, with no `minitest` runtime dependency.

It ships bundled in `rigortype`. Activate it under `plugins:`:

```yaml
plugins:
  - rigor-minitest
```

## What it infers

```ruby
def test_user
  user = build_user
  assert_kind_of(User, user)   # user narrowed to User
  user.name.upcase             # `.name` resolves on User

  found = find_user(1)
  refute_nil(found)            # found narrowed away from nil
  found.id                     # `.id` resolves cleanly
end

it "narrows the spec way" do
  _(value).must_be_kind_of(String)   # value narrowed to String
  value.upcase
end
```

`_(x)`, `value(x)`, and `expect(x)` are all accepted as the spec
wrapper. Test::Unit's `assert_not_kind_of` / `assert_not_nil` /
`assert_not_equal` / `assert_not_instance_of` share the recogniser with
their `refute_*` equivalents.

| Assertion / matcher | Effect on `x` |
| --- | --- |
| `assert_kind_of(T, x)` / `assert_instance_of(T, x)` | narrow to `T` |
| `assert_nil(x)` | narrow to `Constant<nil>` |
| `assert_equal(literal, x)` | meet with `Constant<literal>` (see below) |
| `assert_match(regex, x)` | narrow to `String` |
| `refute_kind_of` / `refute_instance_of` (+ `assert_not_*`) | narrow away from `T` |
| `refute_nil(x)` / `assert_not_nil(x)` | narrow away from nil |
| `refute_equal(literal, x)` / `assert_not_equal(...)` | unchanged |
| `_(x).must_be_kind_of(T)` / `must_be_a(T)` / `must_be_instance_of(T)` / `must_be_an_instance_of(T)` | narrow to `T` |
| `_(x).must_be_nil` | narrow to `Constant<nil>` |
| `_(x).must_equal(literal)` | meet with `Constant<literal>` (see below) |
| `_(x).must_match(regex)` | narrow to `String` |
| `_(x).wont_be_kind_of(T)` / `wont_be_instance_of(T)` | narrow away from `T` |
| `_(x).wont_be_nil` | narrow away from nil |
| `_(x).wont_equal(literal)` | unchanged |

### Equality is not identity

`assert_equal(literal, x)` and `_(x).must_equal(literal)` pass when
`literal == x`, and `==` can hold across classes: `1 == 1.0`,
`1 == 1r`, and a class with its own `==` (a `ModInt` that compares
`to_i`) passes `assert_equal 9, m`. The assertion therefore never
replaces `x`'s type:

- a `nil`, `true`, `false`, or Symbol literal has identity `==`, so `x`
  narrows to that literal whatever its type was;
- an Integer, Float, or String literal narrows `x` only when every
  member of `x`'s type is already of the literal's class (or a `nil`,
  boolean, or Symbol the literal cannot equal). After
  `x = rand(10); assert_equal 9, x`, `x` is `9`;
- otherwise — `x` is `Dynamic`, of a user class, or of another numeric
  class (`assert_equal 9.0, x` with an Integer `x`), or the literal is
  `0.0`, which `-0.0` also equals — `x` keeps its type.

## No diagnostics, no config

The plugin emits no diagnostics and has no configuration knobs — it
only contributes narrowing facts to the engine. It walks every analysed
file; non-test files fall through untouched when no recognised shape
matches.

## Limitations

- **No block-shape matchers** — `assert_raises(T) { ... }`,
  `assert_throws(:tag) { ... }`. Narrowing targets straight-line locals.
- **No predicate / respond-to matchers** — `assert_predicate(x, :foo?)`,
  `assert_respond_to(x, :m)` need carriers Rigor doesn't model.
- **No `assert_in_delta` / `assert_operator`** — float-range / generic
  operator narrowing is future work.
- **No legacy bare `x.must_be_kind_of(T)`** (Minitest < 6.0) — the
  receiver *is* the value, so there's nothing to narrow against; migrate
  to `_(x).must_*`.

## Plugin internals

The assertion recogniser and the contract surfaces this plugin
exercises — the ADR-37 `narrowing_facts` narrowing gate and the ADR-38
`additional_initializers` for `setup` — are in the
[plugin's README](../../../plugins/rigor-minitest/README.md). To write a
plugin, see [`examples/`](../../../examples/README.md) and the
[`rigor-plugin-author`](../08-skills.md) skill.
