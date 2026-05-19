# rigor-minitest

Rigor plugin that narrows locals through **Minitest** and
**Test::Unit** assertions (and the Minitest/spec / matchers_vaccine
spec-style `must_*` / `wont_*` matchers layered on top).

The plugin recognises every supported assertion shape at every
call site the dispatcher visits and emits a Rigor
`post_return_fact` whose `:local`-kind target narrows the
named local on the post-call edge. Downstream calls in the
same test body — `def test_foo`, an `it` block, etc. — then
resolve against the narrowed type.

## What the plugin recognises

### Minitest / Test::Unit `assert_*` (positive)

```ruby
def test_user
  user = build_user
  assert_kind_of(User, user)   # narrow `user` to User
  user.name.upcase             # `.name` resolves on User

  found = find_user(1)
  assert_nil(found)            # narrow `found` to Constant<nil>
  # `found.foo` would now fire `possible-nil-receiver`

  age = compute_age
  assert_equal(42, age)        # narrow `age` to Constant<42>
  age + 1                      # `+` still resolves
end
```

### Minitest / Test::Unit `refute_*` / `assert_not_*` (negative)

```ruby
def test_user
  result = fetch
  refute_nil(result)           # narrow `result` AWAY from nil
  result.length                # `.length` resolves cleanly
end
```

Test::Unit's `assert_not_kind_of(...)` / `assert_not_nil(...)` /
`assert_not_equal(...)` / `assert_not_instance_of(...)` are
recognised by the same rule table as the corresponding
`refute_*` calls.

### Minitest/spec `_(x).must_*` (positive)

```ruby
it "narrows the user" do
  user = build_user
  _(user).must_be_kind_of(User)   # narrow `user` to User
  user.name.upcase                # `.name` resolves
end
```

`value(x)` and `expect(x)` are accepted as aliases for `_(x)` —
all three are spec-wrapper synonyms in Minitest.

### Minitest/spec `_(x).wont_*` (negative)

```ruby
it "rejects the nil case" do
  result = fetch
  _(result).wont_be_nil           # narrow `result` AWAY from nil
  result.length                   # `.length` resolves
end
```

### Matcher table

| Assertion / matcher                       | Effect on `x`                                |
|-------------------------------------------|----------------------------------------------|
| `assert_kind_of(T, x)`                    | narrow to `T`                                |
| `assert_instance_of(T, x)`                | narrow to `T`                                |
| `assert_nil(x)`                           | narrow to `Constant<nil>`                    |
| `assert_equal(literal, x)`                | narrow to `Constant<literal>`                |
| `assert_match(regex, x)`                  | narrow to `String`                           |
| `refute_kind_of(T, x)` / `assert_not_*`   | narrow AWAY from `T`                         |
| `refute_instance_of(T, x)`                | narrow AWAY from `T`                         |
| `refute_nil(x)` / `assert_not_nil(x)`     | narrow AWAY from nil                         |
| `refute_equal(literal, x)`                | narrow AWAY from `Constant<literal>`         |
| `_(x).must_be_kind_of(T)` / `must_be_a(T)`| narrow to `T`                                |
| `_(x).must_be_instance_of(T)`             | narrow to `T`                                |
| `_(x).must_be_nil`                        | narrow to `Constant<nil>`                    |
| `_(x).must_equal(literal)`                | narrow to `Constant<literal>`                |
| `_(x).must_match(regex)`                  | narrow to `String`                           |
| `_(x).wont_be_kind_of(T)`                 | narrow AWAY from `T`                         |
| `_(x).wont_be_nil`                        | narrow AWAY from nil                         |
| `_(x).wont_equal(literal)`                | narrow AWAY from `Constant<literal>`         |

## Configuration

No knobs in v0.1.0. Activate via:

```yaml
# .rigor.yml
plugins:
  - rigor-minitest
```

The plugin walks every analysed file looking for the
recognised assertion shapes; non-test files are silently
unaffected (the analyzer falls through when the call shape
does not match).

## Limitations (v0.1.0)

- **No `assert_raises(T) { ... }`.** Block-shape matchers
  need a separate slice — Rigor's narrowing model targets
  straight-line locals.
- **No `assert_predicate(x, :foo?)`.** Needs a predicate-state
  carrier Rigor doesn't model today.
- **No `assert_respond_to(x, :m)`.** Same shape gap
  (respond-to-set carrier).
- **No legacy bare `x.must_be_kind_of(T)`.** The receiver IS
  the value, so the analyzer has nothing to narrow against.
  Users should migrate to `_(x).must_*`.
- **No `assert_in_delta` / `assert_operator`.** Float-range /
  generic operator narrowing is future work.
- **No `assert_throws(:tag) { ... }` / similar block forms.**

## Why both Minitest and Test::Unit in one plugin

The two frameworks share the `assert_*` / `refute_*` surface
(Test::Unit's `assert_not_*` aliases are recognised by the
same rule table). matchers_vaccine layers RSpec-style matcher
composition on top of Minitest's `must` API and is covered
by the spec-style recogniser without additional wiring. A
single plugin avoids the per-framework activation churn for
projects that mix the two.

## Layout

```text
examples/rigor-minitest/
├── README.md
├── rigor-minitest.gemspec
├── lib/
│   ├── rigor-minitest.rb
│   └── rigor/plugin/
│       ├── minitest.rb                ← Plugin::Minitest class
│       └── minitest/
│           └── assertion_analyzer.rb  ← assert_* / refute_* / must_* recognizer
└── demo/
    ├── .rigor.yml
    └── test/
        └── narrowing_test.rb          ← worked example showing each shape
```
