# `rigor-tapioca`? — Tapioca DSL-RBI Coverage Investigation

Status: **investigation, 2026-05-09.** Companion to
[`20260509-rigor-tapioca-comparison.md`](20260509-rigor-tapioca-comparison.md).
Asks whether a dedicated `rigor-tapioca` plugin is justified
to consume Tapioca-generated DSL RBIs, or whether the gap
is better closed inside the existing `rigor-sorbet` plugin.

**Recommendation (TL;DR): close the gap inside
`rigor-sorbet`. Don't build `rigor-tapioca` until a
Tapioca-specific concern surfaces that doesn't fit the
generic RBI surface.**

## The actual gap

Tapioca's DSL compilers emit a specific structural pattern.
For an ActiveRecord model `Post` with a `body` column the
generated `sorbet/rbi/dsl/post.rbi` looks like this (per the
[`compiler_activerecordcolumns.md`](../../references/tapioca/manual/compiler_activerecordcolumns.md)
documentation):

```rbi
# typed: true
class Post
  include GeneratedAttributeMethods

  module GeneratedAttributeMethods
    sig { returns(T.nilable(::String)) }
    def body; end

    sig { params(value: T.nilable(::String)).returns(T.nilable(::String)) }
    def body=; end

    # ...
  end
end
```

The sig is on `Post::GeneratedAttributeMethods#body`, NOT
on `Post#body`. The user-facing call `post.body` resolves
to `Post#body` through the `include` chain at runtime.

`rigor-sorbet` slice 4's catalog walker records
`(class_name, method_name, kind) → MethodSignature`
verbatim. When the user writes `post.body` and the receiver
type is `Nominal["Post"]`, the plugin's lookup is
`("Post", :body, :instance)` — **MISS**, because the sig is
recorded under `("Post::GeneratedAttributeMethods", :body, :instance)`.

A reproduction in `tmp/rigor_tapioca_check.rb` confirms
this: `rigor check` emits `call.undefined-method` for
`post.body` even with the Tapioca-shaped RBI in place. The
plugin reads the file, parses the sig, but the resolution
machinery doesn't walk the `include` chain to bridge the
two namespaces.

The same pattern shows up across Tapioca's compiler family:

| Compiler | Generated module name | Mixin direction |
| --- | --- | --- |
| `ActiveRecordColumns` | `GeneratedAttributeMethods` | `include` (instance side) |
| `ActiveRecordAssociations` | `GeneratedAssociationMethods` | `include` (instance side) |
| `ActiveRecordRelations` | `GeneratedRelationMethods` | `include` (instance side) |
| `ActiveRecordScope` | `GeneratedRelationMethods` | `extend` (class-method side) |
| `UrlHelpers` | (host module) | `include` (mixed into helper modules) |
| `Protobuf` | (per message class) | direct `def` (no mixin) |
| `SidekiqWorker` | direct `def` on the class | no mixin |
| `ActiveSupportConcern` | `ClassMethods` | `extend` |

**Most of Tapioca's compilers use the include / extend
pattern.** Without mixin chain resolution, `rigor-sorbet`
silently drops the contribution for every one of those
compilers — exactly the long tail of "DSL-derived methods"
the plugin was supposed to cover.

The pattern is also used by hand-written shims under
`sorbet/rbi/shims/` and the community-curated
`rbi-central` annotations. So fixing this is not a
Tapioca-specific concern — it's general RBI semantics
that any consumer of Sorbet's RBI dialect needs.

## Two ways to fix it

### Option A — extend `rigor-sorbet` (recommended)

Add **mixin chain resolution** to the catalog walker.
Two-pass walk:

1. **Pass 1 (declarations)**: walk every file, record
   per class:
   - The class's own `def` sigs (already done by
     slice 1's `CatalogWalker`).
   - The list of `include`/`extend` declarations the
     class makes (`include GeneratedAttributeMethods`,
     `extend ClassMethods`, etc.).
2. **Pass 2 (lookup)**: when `flow_contribution_for`
   asks for `("Post", :body, :instance)`:
   - Try the direct lookup first.
   - On miss, walk Post's recorded `include` chain.
     For each `include Module`, try
     `("Post::Module", :body, :instance)` and any
     transitive includes inside `Post::Module`.
   - Mirror for the `extend` chain on singleton-side
     lookups.

The implementation is a small extension of the existing
catalog (same shape as a slice in ADR-11). Likely fits
under a "Slice 7 (deferred from slice 1)" entry. New
catalog field: `Catalog#includes_for(class_name) →
[module_name, ...]`. New `Catalog#walk_lookup_chain(...)`
helper that mirrors Ruby's MRO traversal but only over
the catalog's recorded mixins.

#### What changes

- `MethodSignature` stays unchanged (still keyed by the
  declaring class/module).
- `Catalog` gains a `mixins:` map (`{class_name → {include: [...], extend: [...]}}`).
- `CatalogWalker` recognises top-level `include`/`extend`
  CallNodes inside class/module bodies and records the
  RHS constant name.
- `Sorbet#lookup_signature` walks the recorded mixin chain
  on miss.

#### Why this is the right path

1. The pattern isn't Tapioca-specific. Hand-written shims
   in `sorbet/rbi/shims/` use it. Community annotations
   in `rbi-central` use it. Sorbet itself uses it for its
   own embedded core / stdlib RBIs. **Fixing
   `rigor-sorbet` helps every RBI consumer, not just
   Tapioca users.**
2. Avoids plugin proliferation. A separate `rigor-tapioca`
   would duplicate the file walker, the catalog, the
   lookup machinery — for a tiny incremental capability.
3. Keeps the dispatcher tier clean. Adding another plugin
   competing at the same tier ordering invites
   contribution-merge conflicts that don't pay rent.

### Option B — separate `rigor-tapioca` plugin

Build a parallel plugin that special-cases Tapioca's
generated DSL RBIs.

Tapioca-specific things a separate plugin could do that
don't fit `rigor-sorbet`:

- **Staleness detection**: `db/schema.rb`'s mtime is
  newer than `sorbet/rbi/dsl/post.rbi`'s — emit a
  `plugin.tapioca.stale-rbi` warning suggesting
  `bin/tapioca dsl Post`.
- **Drift detection**: compare Tapioca-generated column
  list against `rigor-activerecord`'s static parse of the
  same `db/schema.rb`. Mismatches surface as
  `plugin.tapioca.drift`.
- **Generation-marker honouring**: Tapioca prefixes its
  RBIs with `# DO NOT EDIT THIS FILE BY HAND` and
  `# This file is autogenerated by tapioca`. A plugin
  could refuse to read RBIs missing the marker (treating
  them as user shims) or prioritise them differently.
- **Fast-path for known Generated\* module names**:
  short-circuit the mixin chain walk when the include is
  recognised as Tapioca's `GeneratedAttributeMethods` /
  `GeneratedAssociationMethods` / etc.

#### Why this is the wrong path *today*

1. **Doesn't address the core gap**. Mixin chain
   resolution is the actual fix; everything above is
   bonus features.
2. **The bonus features are small.** Combined, maybe
   100-200 lines of code. Doesn't justify a plugin.
3. **Ecosystem cost**. A plugin needs README, demo,
   integration spec, gemspec — overhead for a thin
   feature surface.
4. **Cross-plugin coordination cost**. `rigor-tapioca`
   would need to read RBIs (overlapping `rigor-sorbet`)
   AND consult `rigor-activerecord`'s output via
   `Plugin::FactStore` (ADR-9). Two-way cross-plugin
   dependencies are the most fragile shape of the
   contract.

## When `rigor-tapioca` becomes justified

Defer the plugin until at least two of these hold:

1. The `rigor-sorbet` mixin-chain extension has landed
   and is exercised on real Tapioca-using projects.
2. A concrete user request for staleness / drift
   detection surfaces (i.e., someone hits a
   stale-RBI bug and asks for it).
3. Tapioca evolves a feature `rigor-sorbet`'s generic
   RBI support genuinely can't model — e.g., a
   Tapioca-specific annotation in the `# typed:`
   comment header, or a new file naming convention.

If only one of these holds, the work fits cleanly inside
`rigor-sorbet`'s scope.

## Implementation sketch — `rigor-sorbet` slice 7

(Numbered for easy reference; the actual slice number when
authored will follow ADR-11's running count.)

### Step 1 — extend `Catalog` with mixin tracking

```ruby
class Catalog
  def initialize
    @entries = {}
    @mixins = {}  # class_name → { include: [], extend: [] }
    @frozen_after_build = false
  end

  def record_mixin(class_name:, kind:, module_name:)
    raise "Catalog already finalised" if @frozen_after_build
    @mixins[class_name] ||= { include: [], extend: [] }
    @mixins[class_name][kind] << module_name
  end

  def mixins_for(class_name)
    @mixins[class_name] || { include: [], extend: [] }
  end

  # ...
end
```

### Step 2 — walker records `include` / `extend` declarations

In `CatalogWalker.walk_node`'s class-body handler, recognise
`Prism::CallNode` calls named `:include` / `:extend` whose
arguments are `ConstantReadNode` / `ConstantPathNode`:

```ruby
def record_mixin_declaration(call_node, lexical_path, catalog)
  return if lexical_path.empty?

  target_class = lexical_path.join("::")
  call_node.arguments.arguments.each do |arg|
    name = qualified_name_for(arg) or next
    # `include Foo` inside `class Bar` records under
    # `(Bar, include, Foo)` and resolves to `Bar::Foo` /
    # `Foo` based on lexical lookup; the catalog records
    # both candidates and the lookup tries them in order.
    catalog.record_mixin(class_name: target_class, kind: kind_for(call_node.name), module_name: name)
  end
end
```

### Step 3 — `Sorbet#lookup_signature` walks the chain

```ruby
def lookup_signature(call_node, scope)
  receiver = call_node.receiver
  method_name = call_node.name
  return nil if method_name.nil?

  if (singleton_target = constant_receiver_name(receiver))
    chain_lookup(singleton_target, method_name, kind: :singleton, mixin_kind: :extend)
  elsif receiver
    instance_lookup_with_chain(receiver, method_name, scope)
  end
end

def chain_lookup(class_name, method_name, kind:, mixin_kind:)
  # Try direct lookup first.
  direct = @catalog.lookup(class_name: class_name, method_name: method_name, kind: kind)
  return direct if direct

  # Walk the recorded mixin chain.
  visited = Set.new
  queue = @catalog.mixins_for(class_name)[mixin_kind].dup
  until queue.empty?
    candidate = queue.shift
    next unless visited.add?(candidate)

    # Try both the namespaced form (`Post::GeneratedAttributeMethods`)
    # and the bare form (`GeneratedAttributeMethods`) — Tapioca
    # uses the namespaced form, hand-shims often use the bare
    # form.
    namespaced = "#{class_name}::#{candidate}"
    direct = @catalog.lookup(class_name: namespaced, method_name: method_name, kind: :instance) ||
             @catalog.lookup(class_name: candidate, method_name: method_name, kind: :instance)
    return direct if direct

    # Recurse into mixins of the resolved module.
    [namespaced, candidate].each do |intermediate|
      queue.concat(@catalog.mixins_for(intermediate)[:include])
    end
  end
  nil
end
```

(The `:extend`-vs-`:include` distinction matters for
correctness: `extend Foo` adds methods to the singleton
class, so `Post.find` resolves through `extend`d modules,
while `Post.new.foo` resolves through `include`d modules.)

### Step 4 — integration spec

Add a Tapioca-shaped RBI fixture to
`spec/integration/examples/sorbet_plugin_spec.rb`:

```ruby
let(:tapioca_dsl_rbi) do
  <<~RBI
    # typed: true
    class Post
      include GeneratedAttributeMethods
      module GeneratedAttributeMethods
        extend T::Sig
        sig { returns(T.nilable(::String)) }
        def body; end
      end
    end
  RBI
end

it "resolves Tapioca-style mixin sigs through the include chain" do
  result = run_plugin(
    source: "#{SIG_STUB}post = Post.new; post.body\n",
    files: { "sorbet/rbi/dsl/post.rbi" => tapioca_dsl_rbi }
  )
  expect(result.diagnostics.select { |d| d.rule == "call.undefined-method" }).to be_empty
end
```

### Step 5 — README + CHANGELOG

Add a "Tapioca DSL RBI compatibility" subsection to
`examples/rigor-sorbet/README.md` listing which Tapioca
compilers the plugin now supports, and which (if any)
still need work.

### Estimated effort

- Catalog field + walker recognition: ~50 lines
- Lookup chain traversal: ~30 lines
- Integration spec coverage: ~80 lines
- README / CHANGELOG: ~20 lines

Total: ~180 lines, one focused commit. Smaller than slice
4's RBI walker.

## What `rigor-tapioca` could still be (later)

If a future user request makes a separate plugin
worthwhile, the **right minimum scope** would be:

```text
examples/rigor-tapioca/
├── README.md
├── rigor-tapioca.gemspec
├── lib/
│   ├── rigor-tapioca.rb
│   └── rigor/plugin/tapioca.rb       ← single file, ~150 lines
└── demo/
```

The plugin would:

1. Walk the `sorbet/rbi/dsl/` and `sorbet/rbi/gems/` trees
   (NOT to record sigs — `rigor-sorbet` handles that —
   but to read Tapioca's metadata headers).
2. Cross-reference `db/schema.rb`'s mtime (via
   `IoBoundary#read_file` for digest tracking) with
   the matching RBI mtime. Emit
   `plugin.tapioca.stale-rbi` if the schema is newer.
3. Consume `rigor-activerecord`'s `model_index` fact
   (via `Plugin::FactStore` after ADR-9 slice 5) and
   compare its column list with the RBI's
   `GeneratedAttributeMethods` body. Emit
   `plugin.tapioca.drift` for mismatches.
4. Honour Tapioca's `# DO NOT EDIT THIS FILE BY HAND`
   header — treat marked files as authoritative;
   unmarked files in `dsl/` as user shims.

None of these are urgent. Ship `rigor-sorbet` slice 7
first; revisit when (and if) a real user runs into
staleness or drift issues that the generic RBI path
can't surface.

## See also

- [`20260509-rigor-tapioca-comparison.md`](20260509-rigor-tapioca-comparison.md)
  — the strategic comparison this investigation builds on.
- [ADR-11 — Sorbet input as a plugin adapter](../adr/11-sorbet-input-adapter.md)
  — the binding contract for `rigor-sorbet`.
- [`tapioca/manual/compiler_activerecordcolumns.md`](../../references/tapioca/manual/compiler_activerecordcolumns.md)
  — sample of the Tapioca-generated DSL RBI shape this
  investigation tested against.
- `tmp/rigor_tapioca_check.rb` — the throwaway repro
  script confirming the gap. Not committed; recreate
  from this document's "The actual gap" section.
