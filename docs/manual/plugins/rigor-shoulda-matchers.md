# rigor-shoulda-matchers

Validates [shoulda-matchers](https://github.com/thoughtbot/shoulda-matchers)
calls inside `RSpec.describe <Model> do … end` blocks against the
model's real schema: column matchers (`validate_presence_of(:col)`,
`have_db_column(:col)`, …) must name a real column, and association
matchers (`belong_to(:assoc)`, `have_many(:assoc)`, …) must name a real
association of the matching kind. It cross-checks against the
`:model_index` fact published by [rigor-activerecord](rigor-activerecord.md)
(ADR-9) — so it complements, rather than overlaps, rigor-rspec (which
handles RSpec's own `let` / `subject` DSL).

It ships bundled in `rigortype`. Activate it under `plugins:` together
with rigor-activerecord (which publishes the model index it consumes):

```yaml
plugins:
  - rigor-activerecord     # publishes :model_index
  - rigor-shoulda-matchers # consumes it
```

## What it checks

```ruby
RSpec.describe User do
  it { should validate_presence_of(:email) }   # OK if `email` is a column
  it { should validate_presence_of(:nme) }     # warning: unknown column
  it { should belong_to(:author) }             # OK if `author` is singular
  it { should belong_to(:posts) }              # warning: kind mismatch (posts is a collection)
  it { should have_many(:comments) }           # OK if `comments` is a collection
  it { should have_many(:nonexistent) }        # warning: unknown association
end
```

| Rule | Severity | Fires when |
| --- | --- | --- |
| `shoulda-matchers.unknown-column` | warning | a column matcher names a column absent from the model |
| `shoulda-matchers.unknown-association` | warning | an association matcher names an association absent from the model |
| `shoulda-matchers.association-kind-mismatch` | warning | the matcher's expected kind (singular / collection) disagrees with the association's actual kind |

Column matchers: `validate_presence_of` / `_uniqueness_of` /
`_length_of` / `_numericality_of` / `_acceptance_of` / `_inclusion_of`
/ `_exclusion_of` / `_absence_of` / `_format_of` / `_confirmation_of`,
plus `have_db_column` / `have_db_index`. Association matchers and their
expected kind: `belong_to` / `have_one` (singular), `have_many` /
`have_and_belong_to_many` (collection). The enclosing
`describe <Constant>` (innermost wins) anchors which model is checked.

> The rule ids above are the identifiers for `# rigor:disable
> shoulda-matchers.unknown-column` and the `disable:` config. In
> `rigor check` output they currently render with a doubled provenance
> prefix (`plugin.shoulda-matchers.shoulda-matchers.unknown-column`)
> because the rule strings already embed the plugin name — a cosmetic
> quirk flagged for a one-line plugin fix.

## No configuration

The plugin has no configuration knobs. When rigor-activerecord is not
loaded — or hasn't published an index for the analysed model — the
plugin falls silent; the cross-check is opt-in.

## Limitations

- **No chained-matcher argument validation** — the chain terminals on
  `validate_length_of(:col).is_at_most(50)`,
  `validate_inclusion_of(:col).in_array([...])`, etc. are runtime-only.
- **No polymorphic / `through:` validation** — only the named
  association is checked; the chain modifiers are ignored.
- **No nested-attribute or callback matchers**
  (`accept_nested_attributes_for`, `callback(...)`).
- **No route / routing matchers** — those are the rigor-rspec-rails
  domain.

## Plugin internals

The describe-walker / matcher recogniser and the contract surfaces this
plugin exercises (the optional `:model_index` consume, `NodeContext`
ancestor resolution) are in the
[plugin's README](../../../plugins/rigor-shoulda-matchers/README.md). To
write a plugin, see [`examples/`](../../../examples/README.md) and the
[`rigor-plugin-author`](../08-skills.md) skill.
