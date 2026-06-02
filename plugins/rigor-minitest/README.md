# rigor-minitest

Rigor plugin that narrows locals through **Minitest** and
**Test::Unit** assertions (and the Minitest/spec / matchers_vaccine
spec-style `must_*` / `wont_*` matchers layered on top). It recognises
every supported assertion shape and emits a `:local`-kind narrowing
fact on the post-call edge, so downstream calls in the same test body
resolve against the narrowed type.

> **Using this plugin?** The user guide — the full matcher table, what
> each shape narrows to, and the recognised limitations — lives in the
> manual at
> [docs/manual/plugins/rigor-minitest.md](../../docs/manual/plugins/rigor-minitest.md).
> This README covers the plugin's internals.

## Why both Minitest and Test::Unit in one plugin

The two frameworks share the `assert_*` / `refute_*` surface
(Test::Unit's `assert_not_*` aliases are recognised by the same rule
table). matchers_vaccine layers RSpec-style matcher composition on top
of Minitest's `must` API and is covered by the spec-style recogniser
without additional wiring. A single plugin avoids the per-framework
activation churn for projects that mix the two.

## Plugin authoring surface this exercises

| Surface | Used for |
| --- | --- |
| `type_specifier methods: …` (ADR-37 slice 2) | Method-gated narrowing — the analyzer returns a `:local`-kind `post_return_fact` for each recognised assertion, gated on `AssertionAnalyzer::SUPPORTED_METHODS`. |
| `additional_initializers:` (ADR-38) | Declares `setup` as an initialiser on `Minitest::Test` / `ActiveSupport::TestCase` / `Test::Unit::TestCase`, so ivars assigned there aren't read as possibly-nil in the test body. |
| `ASSERT_FORM` / `SPEC_MATCHER_FORM` tables | The closed recogniser sets — shape + positive/negative flag per method name, in `assertion_analyzer.rb`. |

## Layout

```text
plugins/rigor-minitest/
├── README.md
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
