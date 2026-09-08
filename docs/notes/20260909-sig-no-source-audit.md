# Where the 224 `no_source` declarations in `sig/` come from (2026-09-09)

Status: the follow-up audit for [#839](https://github.com/rigortype/rigor/issues/839), filed as P4 out
of the [seeding audit](20260908-sig-provenance-audit.md). Measured on `sig-no-source-839` at
`origin/master`, rbs 4.x, Ruby 4.0.5.

The seeding audit put 227 declarations in `no_source` — "no `def` `sig-gen` can attribute to this
declaration" — and found that **nine of them described code that does not exist**: seven methods on
`StatementEvaluator` / `ScopeIndexer` that had been removed or renamed, and the whole of
`NumericCatalog`, folded onto `MethodCatalog.for_topic("numeric")`. Nothing in the tree noticed.
`make check` and `make steep-check` both ask whether the implementation matches `sig/`; neither asks
the converse, and a stale declaration is worse than a missing one, because RBS resolves calls through
it.

The nine were deleted with the seeding gate. This note answers the question that made them hard to
see: **of everything left in `no_source`, why did the static scan find no `def`** — and can the
legitimate cases be told from the stale ones without hand-listing exemptions?

## Command

The audit is the gate's own classifier, so the note and the gate cannot drift:

```sh
nix --extra-experimental-features 'nix-command flakes' develop --command \
  bundle exec ruby -Ilib -Ispec/support -rsig_provenance_auditor \
    -e 'SigProvenanceAuditor.report(root: Dir.pwd)'
```

Its last two sections are the tables below. `report` runs with `runtime: true`, which opts the two
new tiers in (`spec/support/sig_source_index.rb`).

## Two more sources of truth

`sig-gen` enumerates `def`s. A method is not always a `def`, so `no_source` was answering a narrower
question than it appeared to. Two tiers now run behind it, in order, and only a declaration none of
the three can find is reported as stale.

**Tier 1 — Rigor's own recognition (static).**
`Inference::ScopeIndexer.discovered_project_index_for_paths` is the cross-file pre-pass
`Analysis::Runner` builds before every `rigor check`. It already recognises `attr_*`,
`define_method`, `alias` / `alias_method`, `module_function`, an `extend` fold, and `Data` / `Struct`
member layouts — the `call.undefined-method` rule would fire on all of them otherwise — and
`Scope#discovered_method_through_ancestors?` walks the project's own superclasses and mixins. Asking
it, rather than re-deriving the shapes in the auditor, keeps **one** recognition in the tree: a second
one would drift, and its drift would surface as a false stale-declaration report, which AGENTS.md
§ "Implementation Guidelines" ranks above any worst-case reading.

**Tier 2 — the runtime (reflection).** What no static pass can see: `ValueSemantics#value_fields`
defines `==` / `eql?` / `hash` from a class macro, `Data.define` generates `.new` and `#with` on an
anonymous parent, and `Source::NodeChildren` compiles `#rigor_each_child` onto every concrete
`Prism::*Node` class at load. Reflection over a loaded tree confirms each of them, the way
`spec/rigor/public_api_drift_spec.rb` already reflects over the public surface — and confirming beats
an exemption list, because an exemption stays true after the code under it is deleted. Loading a tree
runs its code, so the tier is opt-in and only ever pointed at this repository; a fixture project,
whose `lib/` is written by the example auditing it, must never be required.

Reflection is deliberately blind to `Object` / `Kernel` / `BasicObject` (and `Class` / `Module` on the
singleton side). Every object answers `hash`, `==`, `to_s` and `inspect`, and `sig/` declares all four
on the type carriers that generate them from `value_fields`; an owner that hands the method to every
object would confirm such a declaration after the `value_fields` call under it was deleted, which is
the exact miss this audit exists to close.

## What was in `no_source`

224 declarations, every one explained, **none stale**:

| classification | shape | n | what it is |
| --- | --- | --- | --- |
| `inherited_source` | project ancestor | 71 | the project declares the method on a superclass or an included module (`Type::Top#accepts`, owner `Type::AcceptanceRouter`; the five `CLI::*Command#initialize`, owner `CLI::Command`) |
| `synthetic_source` | Data member | 70 | a `Data.define` member reader (`Analysis::FactStore::Target#kind`) |
| `runtime_defined` | defined on the class itself at load | 56 | `ValueSemantics#value_fields` emitting `==` (×19), `hash` (×19) and `eql?` (×18) on the type carriers |
| `synthetic_source` | def or alias | 8 | a `def` `sig-gen` declines to emit: a parameterless `initialize` (skipped on purpose — `Generator#non_trivial_initialize?`), or an `alias eql? ==`, which the indexer records against the aliased def node |
| `synthetic_source` | `attr_*` / `define_method` / `alias_method` | 6 | dominated by singleton-side `attr_reader` (`Trinary.yes` / `.no` / `.maybe` inside `class << self`) |
| `runtime_defined` | singleton method, from a generated ancestor | 4 | `.new` on the anonymous `Data.define` parent of a `class X < Data.define(…)` |
| `runtime_defined` | singleton method, from the class itself at load | 4 | `VoidOrigin.new` / `.[]`, `ParamOverride.new`, `ClassFrame.new` |
| `runtime_defined` | inherited from `Data` | 3 | `ClassFrame#initialize`, `CallContext#with`, `DiscoveryIndex#with` |
| `runtime_defined` | compiled onto every subclass at load | 1 | `Prism::Node#rigor_each_child` |
| `runtime_defined` | inherited from `Exception` | 1 | `Plugin::LoadError#cause` |
| `no_source` | — | **0** | a declaration nothing defines |

Tier 1 resolves **155 of 224 (69%)**; tier 2 resolves the remaining 69. The single documented
runtime-generated case, `sig/prism_node_children.rbs`, is confirmed by reflection rather than
exempted: the declaration sits on the abstract `Prism::Node` so every subclass resolves against one
declaration, and the subclass sweep is what tells that apart from a stale declaration.

## Per file

Only the files with an unattributed declaration; every other `sig/` file has none.

| file | `synthetic_source` | `inherited_source` | `runtime_defined` | `no_source` |
| --- | --- | --- | --- | --- |
| `sig/prism_node_children.rbs` | 0 | 0 | 1 | 0 |
| `sig/rigor.rbs` | 0 | 2 | 0 | 0 |
| `sig/rigor/analysis/fact_store.rbs` | 10 | 0 | 2 | 0 |
| `sig/rigor/cli/diff_command.rbs` | 0 | 1 | 0 | 0 |
| `sig/rigor/cli/explain_command.rbs` | 0 | 1 | 0 | 0 |
| `sig/rigor/cli/sig_gen_command.rbs` | 0 | 1 | 0 | 0 |
| `sig/rigor/environment.rbs` | 1 | 0 | 0 | 0 |
| `sig/rigor/inference.rbs` | 19 | 0 | 3 | 0 |
| `sig/rigor/inference/void_origin.rbs` | 3 | 0 | 2 | 0 |
| `sig/rigor/plugin/fact_store.rbs` | 1 | 0 | 0 | 0 |
| `sig/rigor/plugin/load_error.rbs` | 0 | 0 | 1 | 0 |
| `sig/rigor/rbs_extended.rbs` | 12 | 0 | 3 | 0 |
| `sig/rigor/scope.rbs` | 29 | 0 | 1 | 0 |
| `sig/rigor/trinary.rbs` | 3 | 0 | 0 | 0 |
| `sig/rigor/type.rbs` | 6 | 66 | 56 | 0 |

`sig/rigor/type.rbs` is 128 of the 224 on its own, and for one reason: the type carriers are a
polymorphic family, and each declares the whole shared surface. The 66 inherited rows are `accepts`
(×21, from `Type::AcceptanceRouter`) and the lattice trio `top` / `bot` / `dynamic` (×15 each, from
`Type::PlainLattice`); the 56 runtime rows are `==` / `hash` / `eql?` from `ValueSemantics`. One
mixin extraction and one class macro, multiplied by the family.

## What this changes, and what it does not

**The three new states are residue, not earned.** Knowing that a declared method *exists* says nothing
about where its *type* came from, and the type is what [ADR-107](../adr/107-checked-types-and-typeless-comments.md)
§ Decision asks about. Splitting `no_source` into `synthetic_source` / `inherited_source` /
`runtime_defined` therefore leaves every per-file residue pin in
`spec/rigor/sig_gen/provenance_spec.rb` exactly where it was — 677 today, unchanged by this work.

**`no_source` is now a hard rule**, not a counted bucket. Zero on a correct tree, so a hard rule costs
nothing; it was nine before the seeding audit deleted them. The failure names each row as
`sig/path.rbs:line: Class#method — no source`.

**The check is a repository gate.** It reads `sig/` against `lib/` in Rigor's own tree and requires
that tree; it is not a `sig-gen` CLI feature, and an adopting project's workflow is unchanged.

**Cost.** Measured in one warm process, 12-core M3 Max: `sig-gen` over `lib/` **18.7 s** (the
pre-existing cost the gate already paid), tier 1's project index **1.4 s**, and tier 2's require plus
every classification **0.3 s**. The two tiers add **~1.8 s (+9%)** to a pass that was already the
reason this gate lives in `spec/rigor/sig_gen/` rather than `make docs-check`.

## What this does not measure

- **`plugins/*/sig` and `examples/*/sig`.** The gate walks the repository's own `sig/` only;
  `make check-plugins` covers a different property there.
- **Whether a declaration is *correct*.** Existence is not correctness — `make check` (G2) and
  `make steep-check` answer that, and provenance (G3's other two mechanisms) answers where the type
  came from.
- **A method that exists but is unreachable.** `rigor unused` is the reachability surface.
- **A plugin-contributed member.** The runtime tier loads `lib/` and not `plugins/`, because
  requiring a plugin registers it into every spec process that shares the one running the gate.
  Nothing in `sig/` describes such a member today; one would be reported stale, and the fix is to
  require its plugin in `spec/support/sig_source_index.rb` — the way
  `spec/rigor/public_api_drift_spec.rb` requires `rigor-ffi` for the same reason — never an exemption.
