# rigor-shoulda-matchers

Rigor plugin that validates [shoulda-matchers](https://github.com/thoughtbot/shoulda-matchers)
calls against the `:model_index` cross-plugin fact
([ADR-9](../../docs/adr/9-cross-plugin-api.md)) published by
[`rigor-activerecord`](../rigor-activerecord/).

The plugin walks every `RSpec.describe <ModelConst> do ...
end` (or `describe <ModelConst> do ... end`) block and
validates the shoulda matchers inside its body against the
model's known columns / associations.

## What the plugin catches

```ruby
RSpec.describe User do
  it { should validate_presence_of(:email) }   # OK if `email` is a column
  it { should validate_presence_of(:nme) }     # warning: unknown column
  it { should belong_to(:author) }             # OK if `author` is :singular
  it { should belong_to(:posts) }              # warning: kind mismatch (posts is :collection)
  it { should have_many(:comments) }           # OK if `comments` is :collection
  it { should have_many(:nonexistent) }        # warning: unknown association
end
```

Rules fired:

| Rule                                            | Trigger                                                    |
|-------------------------------------------------|------------------------------------------------------------|
| `shoulda-matchers.unknown-column`               | Column matcher names a column missing on the model         |
| `shoulda-matchers.unknown-association`          | Association matcher names a missing association            |
| `shoulda-matchers.association-kind-mismatch`    | Matcher kind (singular/collection) ≠ the association's kind|

## Recognised matchers (v0.1.0)

### Column matchers

The first symbol arg is looked up against the model's
columns via `Entry#column?`:

- `validate_presence_of(:col)`
- `validate_uniqueness_of(:col)`
- `validate_length_of(:col)`
- `validate_numericality_of(:col)`
- `validate_acceptance_of(:col)`
- `validate_inclusion_of(:col)`
- `validate_exclusion_of(:col)`
- `validate_absence_of(:col)`
- `validate_format_of(:col)`
- `validate_confirmation_of(:col)`
- `have_db_column(:col)`
- `have_db_index(:col)`

### Association matchers

The first symbol arg is looked up against the model's
associations; the matcher's expected kind must match:

| Matcher                          | Expected kind |
|----------------------------------|---------------|
| `belong_to(:assoc)`              | `:singular`   |
| `have_one(:assoc)`               | `:singular`   |
| `have_many(:assoc)`              | `:collection` |
| `have_and_belong_to_many(:assoc)`| `:collection` |

## Cross-plugin dependency

The plugin consumes `:model_index` from `rigor-activerecord`.
When `rigor-activerecord` is **NOT** loaded — or hasn't
published an index for the analysed model — the plugin falls
silent. The cross-check is opt-in. Activate both plugins in
`.rigor.yml`:

```yaml
plugins:
  - rigor-activerecord     # publishes :model_index
  - rigor-shoulda-matchers # consumes :model_index
```

## Limitations (v0.1.0)

- **No chained-matcher arg validation.** The chain options on
  `validate_length_of(:col).is_at_most(50)`,
  `validate_inclusion_of(:col).in_array([...])`,
  `allow_value("foo").for(:col)`, etc. are NOT validated
  (the `.is_at_most` etc. terminals are runtime-only).
- **No polymorphic / through validation.** `belong_to(:user).polymorphic`,
  `have_many(:posts, through: :memberships)` only check the
  named association; the chain modifiers are ignored.
- **No nested-attribute matchers.**
  `accept_nested_attributes_for(:posts)` not yet covered.
- **No callback matchers.** `callback(:before_save).before(:save)`
  would need a separate slice (overlaps with the
  model_index's `callbacks` column already exposed but no
  rspec-side recogniser yet).
- **No `route` / `routing` matchers** (rspec-rails domain;
  `rigor-rspec-rails`'s queued `route_to` slice would cover
  the equivalent).
- **Only the first describe-with-constant anchors the
  model.** A `describe ".some_method" do ... end` nested
  inside `describe User do ... end` still uses `User` as the
  anchor; a NESTED `describe Comment` would override inside
  its subtree (rare; we still honour it).

## Layout

```text
examples/rigor-shoulda-matchers/
├── README.md
├── rigor-shoulda-matchers.gemspec
├── lib/
│   ├── rigor-shoulda-matchers.rb
│   └── rigor/plugin/
│       ├── shoulda_matchers.rb               ← Plugin::ShouldaMatchers class
│       └── shoulda_matchers/
│           └── analyzer.rb                   ← describe-walker + matcher recognizer
└── demo/
    ├── .rigor.yml
    └── spec/
        └── user_spec.rb                      ← worked example
```

## License

MPL-2.0, matching the parent Rigor project.
