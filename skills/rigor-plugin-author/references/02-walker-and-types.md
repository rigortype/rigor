# 02 — Node rules and types

Covers **Phase 2** — recognising the DSL's call shapes, emitting
diagnostics, and (optionally) contributing return types. The engine
owns the AST walk; you write the per-node check.

## `node_rule` — the core hook (ADR-37)

A diagnostic-emitting plugin declares a **node rule**. The engine walks
each analysed file's AST **once** and hands every node of the declared
type to your block — so you write the check and never the traversal:

```ruby
class MyPlugin < Rigor::Plugin::Base
  manifest(id: "my-plugin", version: "0.1.0")

  node_rule Prism::CallNode do |node, scope, path, file_context, context|
    # node    — the Prism::CallNode the engine matched.
    # scope   — answers inferred-type queries: scope.type_of(node).
    # path    — the file path, for the diagnostic location.
    # file_context — the value node_file_context built (see below); nil if none.
    # context — Rigor::Plugin::NodeContext: lexical ancestors.
    # → return Array<Rigor::Analysis::Diagnostic> ([] to fire nothing)
  end
end
```

`node_rule(node_type)` matches by `node.is_a?(node_type)`, so declare
the concrete class you care about (`Prism::CallNode` for almost every
DSL plugin) or `Prism::Node` to see everything. The block runs through
`instance_exec`, so `config`, `services`, `services.fact_store`, and the
`diagnostic` helper (below) are all in scope. Declare multiple rules
(they run in declaration order); a plugin that declares none pays zero
cost. Keep the matching logic in a separate `Analyzer` class once it
grows — have it take the call node and return location-free `Violation`
rows the rule positions with `diagnostic` (the bundled plugins follow
this `Analyzer.violations_for` split, which also makes the logic
unit-testable without running the whole engine).

> `diagnostics_for_file(path:, scope:, root:)` is the **file-rule**
> surface — use it for a genuinely file-scoped result (a single
> load-error row, a cross-file aggregation, or a check that needs the
> whole parsed file at once). It is not deprecated; it is the right tool
> when a check isn't per-node. Per-node checks use `node_rule` (you don't
> hand-roll a `def walk` / `compact_child_nodes.each` recursion — the
> engine owns the walk). Map a violation array to diagnostics with
> `diagnostics_for(violations, path:, node:)` rather than a hand-rolled
> `.map { diagnostic(...) }`.

### Recognising call sites

Inside the rule, match on `node.name` (the method name, a Symbol),
`node.receiver` (nil for an implicit-self call), and
`node.arguments&.arguments`. For literal `:sym` / `"str"` arguments
reach for `Rigor::Source::Literals` (`symbol_or_string(node)` /
`symbol_arguments(call)` / `symbol_arg(call, i)`) rather than
re-deriving the `unescaped.to_sym` shape.

### Two-pass and lexical context

- **Same-file collect-then-validate** (gather declared names, then
  validate references): declare `node_file_context { |root, scope| … }`.
  It runs once per file before the walk and its return value is threaded
  to every rule as `file_context`. (A *cross-file* collect belongs in
  `#prepare` + `services.fact_store.publish`; the consuming plugin reads
  it with `read_fact(plugin_id:, name:)` — the nil-inclusive memo means
  you never hand-roll an `@x_resolved` flag. See
  [`01-plan-and-scaffold.md`](01-plan-and-scaffold.md).)
- **Where the node sits**: `context` (a `Rigor::Plugin::NodeContext`)
  carries the lexical ancestor chain — `context.enclosing_def`,
  `context.enclosing_module`, `context.enclosing_block(:describe)`, and
  the raw `context.ancestors`. Read it when the check depends on the
  enclosing class / method / block DSL (the enclosing controller a
  `before_action` sits in, the `describe <Model>` a matcher is under).

## Building a `Diagnostic`

Use the `Base#diagnostic` helper — it internalises the load-bearing
1-based `line` / `start_column + 1` convention so you never unpack
`node.location` by hand:

```ruby
node_rule Prism::CallNode do |node, scope, path, _fc, _ctx|
  next [] unless offending?(node)

  [diagnostic(node, path: path, message: "...", severity: :error, rule: "my-rule")]
end
```

Pass `location:` (a Prism location) to point at a sub-location rather
than the whole node — typically `location: node.message_loc`, so a
method-name diagnostic points at the name, not the receiver-spanning
whole call. Do **not** set `source_family` — the runner stamps
`plugin.<manifest.id>` on every returned diagnostic, so anything you set
is overwritten.

`rule` is a short identifier (`dimension-mismatch`,
`unknown-state`). Rigor namespaces it under your plugin —
diagnostics surface as `plugin.<manifest.id>.<rule>`, and that
qualified id is what `.rigor.yml` `disable:` and the baseline key
on. Pick `severity`:

- `:error` — a real defect (a type mismatch, a call that will
  raise). Fails `rigor check`.
- `:warning` — suspicious but not certainly wrong.
- `:info` — informational; surfaces inferred facts without
  judgement.

## Asking the analyzer for types — `scope.type_of`

A plugin does not have to infer types itself. `scope.type_of(node)`
returns the type the core analyzer inferred for any AST node — the
plugin can build on it:

```ruby
receiver_type = scope.type_of(call_node.receiver)
```

The returned object is one of the `Rigor::Type::*` carriers. The
ones a plugin meets most:

- `Rigor::Type::Nominal` — a class type; `#class_name` is the
  String.
- `Rigor::Type::Constant` — a literal value; `#value` is the Ruby
  object.
- `Rigor::Type::IntegerRange` — a bounded integer.

Match with `case`/`when` on the carrier class. Treat any carrier you
do not recognise as "decline to act" — never crash on an unexpected
type.

## Use the target library, don't reimplement it (ADR-39)

A plugin may **call the pure methods of the library it targets
directly** instead of reimplementing them — the Ruby analogue of a
PHPStan extension calling into the real framework. Reimplementing a
library's rules (an inflector, a status-code table, …) risks diverging
from the real behaviour, and a wrong *derived* fact (a wrong class /
helper / column name) is a false positive on working code. So declare
the target gem as your plugin's dependency and call its safe methods.

The bundled `Rigor::Plugin::Inflector` is the worked example — it calls
the real `ActiveSupport::Inflector` rather than a hand-rolled
approximation. If your plugin needs inflection, use it:

```ruby
Rigor::Plugin::Inflector.classify("users")     # => "User"
Rigor::Plugin::Inflector.tableize("BlogPost")  # => "blog_posts"
```

For your own target library, follow the same harness: a **fixed
allow-list** of pure methods, inputs derived from source, and **decline
(return nil / emit nothing) when the library is unavailable — never
approximate**. How the call is isolated from Rigor (in-process, a forked
worker, or a `Ruby::Box`) is a configurable strategy the user picks
(`plugins_isolation:`); you just call the method.

For the common "did you mean …?" suggestion, use the shared helper
rather than hand-rolling Levenshtein:

```ruby
Rigor::Plugin::Base.suggest(typo, known_names)  # nearest match, or nil
```

## Optional — contribute a return type with `dynamic_return` / `narrowing_facts`

> **Critical — these hooks do NOT make a method "defined", so they do
> NOT suppress `call.undefined-method`.** Method *existence* and call
> *type* are two independent checks. A return-type contribution sharpens
> the type of a call the analyzer has **already resolved to a real
> method** (turning a `Dynamic` return into something precise). It is
> never consulted for a receiver/method the analyzer cannot find — that
> fires `call.undefined-method` first, and a contribution does nothing
> to silence it. **If your goal is to kill a `call.undefined-method`
> cluster on a DSL-generated method (the common reason
> `rigor-project-init` hands off to this skill), the fix is to make the
> method *exist* in Rigor's view — ship RBS declaring it (see "Shipping
> RBS for the DSL" below), not a return-type contribution.** Reach for
> these only when the call already resolves and you want a *better
> return type*.

A plugin can do more than emit diagnostics: it can *supply* the
inferred return type (or narrowing facts) for a call site the core
analyzer would otherwise type as `Dynamic`. ADR-37 gives two narrow,
declaratively-gated DSLs — prefer them; the engine indexes plugins by
their gate so it only calls the block for matching calls:

```ruby
# Per-call-site RETURN TYPE, gated on the receiver's class.
# The block fires only when the receiver type's class is (or inherits
# from) a declared `receivers:` entry. Return a Rigor::Type or nil.
dynamic_return receivers: ["Money"] do |call_node, scope|
  next nil unless call_node.name == :+
  Rigor::Type::Combinator.nominal_of("Money")
end

# Post-return NARROWING FACTS, gated on the call's method name.
# Return an Array of facts (or nil). Used for assertion / predicate
# narrowing (`assert_kind_of(Foo, x)` ⇒ x is Foo afterwards).
narrowing_facts methods: [:assert_kind_of] do |call_node, scope|
  # ... build and return the post-return facts ...
end
```

> **`narrowing_facts` was renamed from `type_specifier` in ADR-80.**
> The old verb was removed in 0.3.0 — `narrowing_facts` is the only
> spelling a plugin can declare.

Build return types with `Rigor::Type::Combinator`:

```ruby
Rigor::Type::Combinator.nominal_of("Money")        # a class type
Rigor::Type::Combinator.constant_of(true)          # a literal
Rigor::Type::Combinator.union(a, b)                # a union
```

Returning `nil` (or `[]`) is always safe — it means "no contribution",
and the core analyzer keeps its own answer. Contribute only when the
plugin is confident; a wrong contribution propagates downstream.

`receivers:` / `methods:` are the greppable gates the
`rigor plugins --capabilities` catalogue enumerates — run it to see
exactly what each loaded plugin contributes.

> **The removed fat hook.** The original `flow_contribution_for(call_node:,
> scope:)` was **deleted pre-1.0 in ADR-52 WD3** — defining it now raises
> `ArgumentError` at load time. The two shapes it used to cover are
> expressed by `dynamic_return`'s callable gates: a **method-gated return
> type** (an RSpec `let(:x) { … }` binding, a Sorbet `sig`-driven return —
> keyed on the method, not a fixed receiver class) uses
> `dynamic_return methods: -> { [...] }` or `file_methods: ->(path) { [...] }`;
> a **dynamic per-project receiver set** (ActiveStorage's `Attached::One`
> on discovered model classes) uses `dynamic_return receivers: -> { [...] }`,
> the callable resolved once after `#prepare`. These return-type surfaces
> are the most contract-sensitive part of the API — implement one only
> if the plugin genuinely needs to sharpen call-site types; a
> diagnostics-only plugin skips them entirely.

## Shipping RBS for the DSL — the way to suppress `call.undefined-method`

If the DSL introduces methods or classes that Rigor cannot see (a
`Money` class defined by metaprogramming, `Setting.<name>` accessors a
`class_eval` heredoc generates, methods mixed into `Numeric`), give
Rigor RBS declaring them so *core* inference — not just your plugin —
treats them as **defined**. This is what removes the
`call.undefined-method` diagnostics on those methods; nothing else
(not a `node_rule`, not `dynamic_return` / `narrowing_facts`) makes a
method exist in Rigor's view.

Two ways to wire the RBS, depending on how the plugin is packaged:

1. **A packaged gem plugin** — declare `signature_paths:` in the
   **plugin manifest** (resolved relative to the plugin's gem root, per
   ADR-25), so activating the plugin contributes its RBS with no
   user-side wiring. This is how the bundled RBS-bundle plugins work —
   read one as a worked example:

   ```sh
   rigor plugin print rigor-activesupport-core-ext   # see manifest + sig/ layout
   rigor plugin path  rigor-activesupport-core-ext   # then browse its sig/ dir
   ```

2. **A project-private plugin** — the manifest field still works, but
   the simplest reliable route is to ship the `.rbs` under the plugin's
   own `sig/` and add **that path** to the *consuming project's*
   `.rigor.yml`:

   ```yaml
   signature_paths:
     - rigor-ext/sig    # the project-private plugin's RBS directory
   ```

If the DSL's method names are generated from a data file (Redmine's
`Setting` names come from `config/settings.yml`), generate the `.rbs`
from that same source — a small script that reads the data file and
emits one declaration per name keeps the RBS in sync with the DSL.

RBS covers what the *shape* of the DSL is (which methods exist, their
signatures); the plugin walker covers the *dynamic* parts RBS cannot
express (a value computed from a literal argument, a dimensional rule).
They compose — many plugins ship both.

> **Browse a real plugin instead of guessing the API.** Because Rigor
> is installed on disk (`mise` / `gem install`), every bundled plugin's
> source is readable as a worked example. `rigor plugin list` shows
> them all with absolute paths; `rigor plugin print <name>` inlines a
> plugin's main source; `rigor plugin root` points at the engine source
> and the public `Rigor::Plugin::Base` API. When the prose here is
> thinner than you need, read a shipped plugin that does the same thing.

## Output of this module

A plugin whose `node_rule`(s) recognise the DSL and emit diagnostics
with correct severities and rule ids — optionally a `dynamic_return` /
`narrowing_facts` and a `sig/` bundle. Verify by eye with `rigor check`;
lock it down with tests in Phase 3
([`03-test-and-ship.md`](03-test-and-ship.md)).
