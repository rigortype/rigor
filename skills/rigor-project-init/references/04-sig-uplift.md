# 04 — Generate initial RBS sigs and uplift precision

Covers **Phase 5**. Inputs: the configured `.rigor.dist.yml` from
Phase 4 and the detected source paths.

## Why generate sigs before triaging

Rigor's inference engine uses RBS signatures from `sig/` to sharpen
its type flow. Without them, whole chains of methods fall back to
`untyped`. Running `rigor triage` against an uninitialized `sig/`
inflates the diagnostic count with cascade noise that sigs would
eliminate. Generating sigs first means Phase 6's `rigor triage`
report is as signal-rich as possible — the `genuine-bugs` hint
counts bugs, not sig gaps.

This phase is **optional if the project already has a `sig/`
directory** with handwritten RBS annotations. In that case skip
straight to Phase 6.

## Step 5-a — Dry-run sig-gen

Inspect what sig-gen would produce without writing anything:

```sh
rigor sig-gen lib        # adjust path to match the paths: key
```

Typical output at this point: most `new_method` candidates have
literal or concrete return types (`"hello"`, `42`, `:done`, `nil`).
Methods whose return type cannot be inferred show up with
`skip_reason: :untyped_return` — these are the sig precision targets.

To get a breakdown in JSON:

```sh
rigor sig-gen --format json lib | ruby -e '
  require "json"
  data = JSON.parse($stdin.read)["candidates"]
  puts "=== classification breakdown ==="
  data.group_by { |c| c["classification"] }
      .sort_by { |k, _| k }
      .each { |k, v| puts "  #{k}: #{v.size}" }
  skipped = data.select { |c| c["classification"] == "skipped" }
  puts "\n=== skip reasons ==="
  skipped.group_by { |c| c["skip_reason"] }
         .sort_by { |_, v| -v.size }
         .each { |r, v| puts "  #{r}: #{v.size}" }
'
```

## Step 5-b — Write the baseline sigs

```sh
rigor sig-gen --write lib
```

This creates `sig/**/*.rbs` with one method signature per inferred
method. Check in a few files:

```sh
head -40 sig/lib/your_class.rbs
```

At this point, `attr_reader` and `attr_accessor` methods that rely on
ivar types set from `initialize` parameters will likely still be
absent (classified as `:untyped_return`). Step 5-c fixes that.

## Step 5-c — Precision uplift with --params=observed

`--params=observed` tells sig-gen to collect observed argument types
from every call site it processes during the analysis pass. The most
important use case: **`attr_reader` / `attr_writer` / `attr_accessor`
methods whose `@ivar` is assigned from an `initialize` parameter**.

### Example

```ruby
class Person
  attr_reader :name, :age

  def initialize(name, age)
    @name = name
    @age  = age
  end
end

Person.new("Alice", 30)
Person.new("Bob",   25)
```

Without observations: `attr_reader :name` → skipped as `:untyped_return`
(the ivar's type is unknown because the blank inference scope never
sees the parameter values).

With `--params=observed`: sig-gen accumulates `name → "Alice" | "Bob"`,
`age → 25 | 30` from the `Person.new(...)` call sites, then propagates:
`@name: ("Alice" | "Bob")` → `def name: () -> ("Alice" | "Bob")`.

Run:

```sh
rigor sig-gen --params=observed --write lib
```

The cascade effect is significant: a single resolved `attr_reader`
can unlock dozens of downstream methods whose precision depends on it.

### Measuring the uplift

```sh
rigor sig-gen --format json lib | ruby -e '
  require "json"
  data = JSON.parse($stdin.read)["candidates"]
  new_m = data.select { |c| c["classification"] == "new_method" }
  untyped  = new_m.count { |c| (c["inferred_return"] || "").include?("untyped") }
  concrete = new_m.count { |c| !(c["rbs"] || "").include?("untyped") }
  puts "new_method: #{new_m.size} | still-untyped return: #{untyped} | concrete: #{concrete}"
'
```

Run this before and after `--params=observed` to see how many methods
resolved.

## Step 5-d — Handle remaining untyped methods

For methods still showing `untyped` return after `--params=observed`,
there are a few options depending on the cause:

| Pattern | Cause | Fix |
|---|---|---|
| `attr_reader :x` with `@x` never set in `initialize` | ivar set from a DB query, config read, or side effect | Add a hand-written sig: create (or edit) `sig/your_class.rbs` with `attr_reader x: String` |
| Deep method chains on untyped receivers | Cascade from a gem with no RBS | `rbs collection install`; Phase 7 escalation path B |
| Recursive or mutually recursive methods | Return type not inferrable without a base case | Add a `# @rbs return: YourType` inline annotation, or a hand-written sig |
| Dynamic methods (`define_method`, DSL) | Metaprogramming Rigor cannot follow | Phase 7 escalation path A (project plugin) |

Do not spend long on residual `untyped` methods at this stage — a
handful of `untyped` returns in `sig/` does not block adoption. The
objective is to reduce the false-positive count before triage, not to
reach perfect sig coverage.

## Step 5-e — Commit the sig/ directory

Once you are satisfied with the initial sig quality:

```sh
git add sig/
git commit -m "Add initial RBS sigs from rigor sig-gen (--params=observed)"
```

A committed `sig/` is a first-class project artefact: it improves
inference quality on every subsequent run and is maintained alongside
the source (add new sig files when adding classes; update sigs with
`rigor sig-gen --write lib` when method signatures change).

## Quick reference — sig-gen flags used in this phase

| Flag | Effect |
|---|---|
| *(no flags)* | Print candidates to stdout; nothing written |
| `--write` | Write `sig/**/*.rbs` files |
| `--params=observed` | Collect observed argument types from call sites; used to resolve attr_reader / attr_accessor / attr_writer ivar types from initialize observations |
| `--format json` | Output structured JSON (for scripted analysis) |
| `--diff` | Show what would change vs. existing sigs (useful for incremental updates) |

## Output of this module

A committed `sig/` directory with RBS skeletons for all statically
inferrable methods. Remaining `:untyped_return` methods are noted for
potential manual annotation; they do not block Phase 6.

Proceed to Phase 6 ([`03-baseline-and-bugs.md`](03-baseline-and-bugs.md)).
