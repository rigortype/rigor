# 03 — Test and ship

Covers **Phase 3** — testing the plugin from outside the rigor
monorepo, pinning against the pre-1.0 contract, and shipping.

## Testing — drive the public CLI

The rigor monorepo's plugin specs use an internal `plugin_helpers.rb`
(`run_plugin`, `plugin_diagnostics`). That helper is **not part of
the published `rigortype` surface** — an external plugin cannot use
it. Test against what you *do* have: the `rigor` CLI.

The robust pattern is a **fixture project + `rigor check --format
json`**. It exercises the real load path, the real walker, the real
diagnostic pipeline — exactly what your users get — and works
identically under RSpec or Minitest.

### Fixture layout

```text
spec/fixtures/basic/          (or test/fixtures/basic/)
├── .rigor.yml                # plugins: [rigor-<id>]
└── sample.rb                 # code that exercises the plugin
```

The fixture's `.rigor.yml` activates the plugin and scopes `paths:`
to the sample file:

```yaml
paths:
  - sample.rb
plugins:
  - rigor-<id>
```

### RSpec

```ruby
# spec/rigor_<id>_spec.rb
require "json"
require "open3"

RSpec.describe "rigor-<id>" do
  def diagnostics_for(fixture)
    dir = File.expand_path("fixtures/#{fixture}", __dir__)
    out, _err, _status = Open3.capture3(
      "bundle", "exec", "rigor", "check", "--format", "json", chdir: dir
    )
    JSON.parse(out).fetch("diagnostics")
  end

  it "flags a dimensional mismatch" do
    diags = diagnostics_for("basic")
    rule = diags.map { |d| d["rule"] }
    expect(rule).to include("plugin.<id>.dimension-mismatch")
  end
end
```

### Minitest

```ruby
# test/rigor_<id>_test.rb
require "minitest/autorun"
require "json"
require "open3"

class RigorPluginTest < Minitest::Test
  def diagnostics_for(fixture)
    dir = File.expand_path("fixtures/#{fixture}", __dir__)
    out, = Open3.capture3("bundle", "exec", "rigor", "check",
                          "--format", "json", chdir: dir)
    JSON.parse(out).fetch("diagnostics")
  end

  def test_flags_dimensional_mismatch
    rules = diagnostics_for("basic").map { |d| d["rule"] }
    assert_includes rules, "plugin.<id>.dimension-mismatch"
  end
end
```

`rigor check --format json` emits one object per run; the
`"diagnostics"` array carries `path` / `line` / `column` / `message`
/ `severity` / `rule`. Assert on `rule` and `severity` — they are the
stable fields. Avoid asserting on exact `message` wording; it changes
between Rigor releases.

### Unit-test the pure parts directly

Dispatch tables, parsers, and dimension maths inside the plugin are
plain Ruby — test them as ordinary objects, no `rigor` process
needed:

```ruby
it "dispatches distance / time to speed" do
  result = Rigor::Plugin::Units::MethodTable.dispatch(
    receiver: :distance, method: :/, args: [:time]
  )
  expect(result.dimension).to eq(:speed)
end
```

Split the suite: fast unit tests for the logic, a few fixture-driven
CLI tests for the end-to-end wiring.

## Version pinning — the pre-1.0 contract

The plugin contract is **not frozen until `rigortype` v0.2.0** (see
SKILL.md). Concretely:

- Gemspec / Gemfile: `rigortype` `>= 0.1.0, < 0.2.0`. Never `>= 0.1`
  alone — that floats across the contract-changing v0.2.0 boundary.
- Your plugin's own version is normal semver, independent of
  `rigortype`'s.
- When you bump the `rigortype` pin to a new minor, **re-run the
  full test suite** — the walker hook signature or the `Diagnostic` /
  type-carrier shapes may have changed. The fixture CLI tests are
  what catch a contract drift.
- State the supported `rigortype` range in the README so users do
  not pair the plugin with an incompatible Rigor.

When v0.2.0 lands, re-pin to the stable range and ordinary
compatibility rules apply.

## README

A plugin README should carry:

1. **What it does** — the DSL / framework it teaches Rigor, and one
   sample diagnostic.
2. **Install** — `gem "rigor-<id>"` (or the path-gem snippet for a
   project-private plugin).
3. **Activate** — the `.rigor.yml` `plugins:` entry, plus any
   `config:` keys and `signature_paths:`.
4. **Compatibility** — the supported `rigortype` version range, and
   the pre-1.0-contract caveat.
5. **License.**

## Ship

**Standalone gem** — `gem build rigor-<id>.gemspec` then
`gem push`. Tag the release. Announce the supported `rigortype`
range.

**Project-private plugin** — nothing to publish. Commit it with the
app (the `rigor-plugin/` path-gem directory, or the `RUBYLIB` file).
Make sure CI runs `rigor check` so the plugin stays
wired and the fixture tests run.

Either way, if the plugin uncovered a gap that *should* be core
Rigor behaviour — or if you hit a plugin-contract rough edge — report
it: <https://github.com/rigortype/rigor/issues>. External plugin
authors are the main source of pre-v0.2.0 contract feedback.

## Output of this module — plugin shipped

- A test suite: fast unit tests + fixture-driven `rigor check`
  tests, in RSpec or Minitest.
- A `rigortype` pin tight to `< 0.2.0`.
- A README stating the compatibility range.
- The plugin published as a gem, or committed project-private with
  CI wired.
