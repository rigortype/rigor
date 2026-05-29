# 02 — The walker and types

Covers **Phase 2** — making `diagnostics_for_file` analyse the AST,
emit diagnostics, and (optionally) contribute return types.

## `diagnostics_for_file` — the core hook

```ruby
def diagnostics_for_file(path:, scope:, root:)
  # root  — Prism::Node, the parsed file (a ProgramNode).
  # scope — answers inferred-type queries: scope.type_of(node).
  # path  — the file path, for Diagnostic#path.
  # → return Array<Rigor::Analysis::Diagnostic>
end
```

Walk `root` with a Prism visitor or a recursive descent, recognise
the DSL's call shapes, and collect diagnostics. Keep the walk in a
separate `Analyzer` class once it grows past a few methods — pass it
`path` and let it return the diagnostic array.

### Recognising call sites

Most DSL plugins key off `Prism::CallNode`:

```ruby
def each_call(node, &block)
  block.call(node) if node.is_a?(Prism::CallNode)
  node&.compact_child_nodes&.each { |child| each_call(child, &block) }
end
```

Then match on `node.name` (the method name, a Symbol),
`node.receiver`, and `node.arguments&.arguments`.

## Building a `Diagnostic`

Every diagnostic the plugin emits is a `Rigor::Analysis::Diagnostic`.
A small constructor helper keeps the call sites clean:

```ruby
def diagnostic(path, node, severity:, rule:, message:)
  loc = node.location
  Rigor::Analysis::Diagnostic.new(
    path:     path,
    line:     loc.start_line,
    column:   loc.start_column + 1,   # 1-based column
    message:  message,
    severity: severity,               # :error | :warning | :info
    rule:     rule                    # short kebab-case id
  )
end
```

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

## Optional — contribute a return type with `flow_contribution_for`

> **Critical — this hook does NOT make a method "defined", so it does
> NOT suppress `call.undefined-method`.** Method *existence* and call
> *type* are two independent checks. `flow_contribution_for` sharpens
> the type of a call the analyzer has **already resolved to a real
> method** (turning a `Dynamic` return into something precise). It is
> never consulted for a receiver/method the analyzer cannot find — that
> fires `call.undefined-method` first, and a flow contribution does
> nothing to silence it. **If your goal is to kill a
> `call.undefined-method` cluster on a DSL-generated method (the common
> reason `rigor-project-init` hands off to this skill), the fix is to
> make the method *exist* in Rigor's view — ship RBS declaring it (see
> "Shipping RBS for the DSL" below), not a flow contribution.** Reach
> for `flow_contribution_for` only when the call already resolves and
> you want a *better return type*.

A plugin can do more than emit diagnostics: it can *supply* the
inferred return type for a call site the core analyzer would
otherwise type as `Dynamic`. Implement `flow_contribution_for`:

```ruby
def flow_contribution_for(call_node:, scope:)
  return nil unless call_node.is_a?(Prism::CallNode)
  # ... decide the call site's real return type ...
  return nil if undecidable   # nil = "I have nothing to add"

  Rigor::FlowContribution.new(
    return_type: a_rigor_type,
    provenance: Rigor::FlowContribution::Provenance.new(
      source_family: "plugin.#{manifest.id}",
      plugin_id:     manifest.id,
      node:          call_node,
      descriptor:    nil
    )
  )
end
```

Build the `return_type` with `Rigor::Type::Combinator`:

```ruby
Rigor::Type::Combinator.nominal_of("Money")        # a class type
Rigor::Type::Combinator.constant_of(true)          # a literal
Rigor::Type::Combinator.union(a, b)                # a union
```

Returning `nil` is always safe — it means "no contribution", and the
core analyzer keeps its own answer. Contribute a type only when the
plugin is confident; a wrong contribution propagates downstream.

This hook is the most contract-sensitive surface — it is the part
most likely to shift before v0.2.0. Implement it only if the plugin
genuinely needs to sharpen call-site types; a diagnostics-only
plugin can skip it entirely.

## Shipping RBS for the DSL — the way to suppress `call.undefined-method`

If the DSL introduces methods or classes that Rigor cannot see (a
`Money` class defined by metaprogramming, `Setting.<name>` accessors a
`class_eval` heredoc generates, methods mixed into `Numeric`), give
Rigor RBS declaring them so *core* inference — not just your plugin —
treats them as **defined**. This is what removes the
`call.undefined-method` diagnostics on those methods; nothing else
(not `diagnostics_for_file`, not `flow_contribution_for`) makes a
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

A plugin whose `diagnostics_for_file` recognises the DSL and emits
diagnostics with correct severities and rule ids — optionally a
`flow_contribution_for` and a `sig/` bundle. Verify by eye with
`rigor check`; lock it down with tests in Phase 3
([`03-test-and-ship.md`](03-test-and-ship.md)).
