---
name: rigor-builtin-import
description: Import Ruby built-in method types from the CRuby reference checkout into Rigor's runtime catalogues. Use when the user asks to add a new core/stdlib class to the constant-fold dispatcher, extend per-class catalog coverage (e.g. Hash, Range, Set, Pathname, Time, Date, Enumerable), regenerate the YAML catalogues, or onboard a refinement carrier through `RBS::Extended`. The procedure is decided but the per-step details (which classifier patterns to extend, which methods to blocklist, how aggressive to be on a new container's mutators) are choices the operator makes; this skill captures the steps and the decision points, not a frozen recipe.
---

# Rigor Built-in Type Import

Use this skill to fold a new core / stdlib class (or a new family of refinement names) into Rigor's catalog-driven inference pipeline. The flow is the same whether you are importing `Hash`, `Range`, `Set`, `Pathname`, `Time`, `Date`, `Enumerable`-aware projections, or a brand-new `Refined`-tier predicate.

## Background

Rigor's constant-fold dispatcher consults two complementary surfaces:

- **Hand-rolled allow lists** in `lib/rigor/inference/method_dispatcher/constant_folding.rb` — `INTEGER_UNARY` / `STRING_BINARY` / `NIL_UNARY` etc. These are the trusted floor.
- **Generated catalogues** under `data/builtins/ruby_core/<topic>.yml` — produced offline from the CRuby reference checkout by `tool/extract_builtin_catalog.rb` and consumed by `lib/rigor/inference/builtins/method_catalog.rb` plus the per-topic singletons (`STRING_CATALOG`, `ARRAY_CATALOG`, …).

The catalog tier is the additive superset; the hand-rolled tier remains the safety net. Adding a new class means deciding for each method whether the catalog's static classification is correct and, when it is not, how to express the override (blocklist, hand-rolled add, RBS-tier rule).

The principled background lives in:

- [`docs/adr/3-type-representation.md`](../../docs/adr/3-type-representation.md) — type-object layout and the OQ3 working decision (Difference + Refined).
- [`docs/adr/5-robustness-principle.md`](../../docs/adr/5-robustness-principle.md) — strict-on-returns, lenient-on-parameters.
- [`docs/type-specification/imported-built-in-types.md`](../../docs/type-specification/imported-built-in-types.md) — the canonical kebab-case refinement names.

Read those before extending the catalogue if you have not already; the decision points below assume the principle's framing.

## Workflow

The flow has six stages. The first four are mechanical; the last two are decision-heavy.

### Stage 0 — Run the scaffold script (recommended)

`tool/scaffold_builtin_catalog.rb` automates the mechanical 70 % of stages 1–4 and 7. Run it once and the manual work that remains is just the per-class judgement calls — blocklist curation, fixture body, and the `[Unreleased]` bullet.

```sh
nix --extra-experimental-features 'nix-command flakes' develop --command \
  bundle exec ruby tool/scaffold_builtin_catalog.rb <topic> <ClassName> \
    --c-path references/ruby/<topic>.c \
    --rb-prelude references/ruby/<topic>.rb \
    --rb-global rb_c<ClassName> \
    --extract
```

What the script writes for you:

- a `TOPICS` entry in `tool/extract_builtin_catalog.rb` (matching the existing two-space indentation);
- a `BASE_CLASS_VARS` row when `--rb-global` is given;
- `lib/rigor/inference/builtins/<topic>_catalog.rb` (loader stub with a `TODO(blocklist curation)` marker);
- a `CATALOG_BY_CLASS` row plus the `require_relative` line in `constant_folding.rb`;
- `spec/integration/fixtures/<topic>_catalog.rb` (fixture stub with a `TODO(scaffold)` marker);
- a `describe` block in `spec/integration/type_construction_spec.rb`;
- with `--extract`, runs `bundle exec ruby tool/extract_builtin_catalog.rb <topic>` so the YAML is in place by the time you start curating.

What you still do by hand (the script prints this checklist on exit):

1. Read `data/builtins/ruby_core/<topic>.yml` and curate the blocklist in the loader file (Stage 5).
2. Replace the placeholder `assert_type` lines in the fixture with the receiver-specific projections (Stage 7).
3. Add a `[Unreleased]` bullet to `CHANGELOG.md` (Stage 9).
4. Run `make verify` and commit (Stage 8).

Pass `--dry-run` to preview the planned edits without writing. Pass `--init-fn` / `--rbs` to override the defaults when the upstream layout differs (e.g. `Init_DateCore` instead of `Init_Date`, or a multi-class RBS).

The remaining stages below describe the underlying procedure for cases the script cannot handle (modules with `rb_m*` mixins, multi-class topics like Numeric where `Init_Numeric` defines Integer + Float + Numeric simultaneously, prelude paths whose name does not match the topic — like Time's `timev.rb`).

### Stage 1 — Locate the upstream sources

Confirm every source the extractor needs is in `references/`:

```sh
ls references/ruby/<topic>.c references/ruby/<topic>.rb 2>&1
ls references/rbs/core/<class>.rbs
grep -n "^Init_<Topic>" references/ruby/<topic>.c
```

The `<topic>.rb` prelude is OPTIONAL — many classes do not have one (string.c, file.c, …). If the C file lacks an `Init_<Topic>(void)` block at module scope, the extractor cannot find it; either point to the actual init function (e.g. `Init_HashImpl`) or fall back to a hand-rolled catalogue.

If `references/ruby` or `references/rbs` is not the version the user expects, run `make pull-submodules` before continuing.

### Stage 2 — Add the topic to the extractor

Edit `tool/extract_builtin_catalog.rb` and append a new entry to the `TOPICS` table:

```ruby
"hash" => {
  init_function: "Init_Hash",
  ruby_c_path: "references/ruby/hash.c",
  ruby_prelude_path: "references/ruby/hash.rb",  # nil if absent
  rbs_paths: { "Hash" => "references/rbs/core/hash.rbs" },
  c_index_paths: %w[references/ruby/hash.c],
  output_path: "data/builtins/ruby_core/hash.yml"
}
```

Common decisions at this stage:

- *RBS for multi-class topics*: when one Init function defines several classes (e.g. `Init_String` defines both `String` and `Symbol`), list every RBS file you want resolved. The extractor's `RbsCatalog` takes a `class_name => path` map.
- *C body indexing across files*: `c_index_paths` is the search list for cfunc bodies. Adding `references/ruby/bignum.c` to the Numeric topic recovered `rb_int_powm` for example. If the topic's methods delegate into siblings (`rb_str_*` helpers in `string.c` only, but `rb_ary_*` helpers split across `array.c` + `internal/array.h`), include every `.c` file the cfunc bodies might live in.
- *Class-var aliases*: `BASE_CLASS_VARS` already maps `rb_cArray`, `rb_cHash`, `rb_cIO`, `rb_cFile`, `rb_eIndexError`, etc. If your topic's Init block references a global the table does not know, add it once and every future topic benefits.

Run the extractor:

```sh
nix --extra-experimental-features 'nix-command flakes' develop --command \
  bundle exec ruby tool/extract_builtin_catalog.rb <topic>
```

The output prints a per-purity histogram; treat it as the first sanity check (e.g. `mutates_self: 0` on a class that obviously mutates means the classifier missed something).

### Stage 3 — Regenerate the catalogue + commit the YAML

```sh
nix --extra-experimental-features 'nix-command flakes' develop --command \
  make extract-builtin-catalogs
```

The Make target regenerates every topic in `TOPICS` so the YAMLs stay coherent. Commit `data/builtins/ruby_core/<topic>.yml` alongside the extractor change so downstream readers see the same view.

The YAML is documentation-grade: humans MAY read it. Skim the `instance_methods` map for surprises before moving on.

### Stage 4 — Wire the runtime loader (when introducing a new catalog file)

For an entirely new class family, add a singleton loader under `lib/rigor/inference/builtins/`:

```ruby
# lib/rigor/inference/builtins/hash_catalog.rb
HASH_CATALOG = MethodCatalog.new(
  path: File.expand_path("../../../../data/builtins/ruby_core/hash.yml", __dir__),
  mutating_selectors: { "Hash" => Set[…] }
)
```

Then route the new singleton from `MethodDispatcher::ConstantFolding#catalog_for(receiver_value)`. For a class that already has a loader (e.g. you're extending `STRING_CATALOG` because you added `string.rb` extraction), no Ruby code change is required — re-running the extractor is enough.

### Stage 5 — Decide which catalog `:leaf` entries are actually safe

This is the first decision-heavy step. The static classifier in the extractor has known limits:

- **Indirect mutators slip through.** `rb_str_replace` calls `str_modifiable` (a helper not in the regex's mutator list), so it lands as `:leaf` even though it mutates. The String catalog's `mutating_selectors` blocklist exists exactly to catch these.
- **Block-dependent methods may classify as `:leaf`** when the C body does not call `rb_yield` directly but routes through a helper. Cross-check `block_dependent` count against the obvious iteration methods (`each`, `map`, `select`, `reduce`, …) — if your gut says "this should be block-dependent" and the YAML says `:leaf`, blocklist it.
- **Bang-suffixed methods are universally blocked** by `MethodCatalog#blocked?` regardless of the YAML's purity. You do not need to enumerate them in `mutating_selectors`.

Walk the new YAML and curate:

```sh
grep -A1 "purity: leaf" data/builtins/ruby_core/<topic>.yml | less
```

Add any false-positive `:leaf`s to the topic's blocklist. Conservatism wins: a blocked-but-safe method is a missed fold opportunity (small loss); an allowed-but-mutating method is a soundness bug (large loss).

When in doubt, write a one-line probe (`bundle exec exe/rigor check /tmp/probe.rb`) that exercises the suspect method on a `Constant` literal and check whether the result is plausible.

### Stage 6 — Decide which RBS-side returns deserve a refinement override

The robustness principle (ADR-5) directs you to tighten returns where you can prove a precise carrier. Common candidates:

- **`#size` / `#length` / `#count` / `#bytesize`** on a container always return non-negative-int. `MethodDispatcher::ShapeDispatch` already handles this for Array / String / Hash / Set / Range. Extend `SIZE_RETURNING_NOMINALS` if you import a new container.
- **`#empty?` / `#any?` / `#none?`** on a non-empty refinement (`Difference[Array, Tuple[]]`) collapses to `Constant[false]` / `Constant[true]`. The empty-removal projection in `ShapeDispatch#dispatch_difference` already covers Array / Hash / Set / String.
- **Methods that the RBS sig declares as `String` but that always return a non-empty string.** Tighten via `%a{rigor:v1:return: non-empty-string}` directly in the project's `.rbs` (the user opts in).

Do NOT tighten:

- Methods whose signature is "for all callers, all values" (e.g. `Array#first` returning `T?` — sometimes nil for empty arrays).
- Methods whose return depends on platform (`File.basename` etc — gated behind `fold_platform_specific_paths`).
- Methods that delegate into user-redefinable code (everything classified `:dispatch`).

### Stage 7 — Self-asserting fixture + spec

Every new topic gets a fixture under `spec/integration/fixtures/<topic>_catalog.rb` (or sister directory for refinement-bearing fixtures) and a one-line entry in `spec/integration/type_construction_spec.rb`:

```ruby
describe "fixtures/<topic>_catalog.rb — <topic> catalog-driven folding" do
  let(:harness) { harness_for("<topic>_catalog") }

  it "self-asserts the new <topic> fold coverage" do
    mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
    expect(mismatches).to be_empty
  end
end
```

The fixture's `assert_type` calls double as documentation; readers see the behaviour without cross-referencing the spec body. Demonstrate at least one folded leaf method, one composite operation (catalog + narrowing), and one mutator that intentionally does NOT fold (so the blocklist is exercised end-to-end).

### Stage 8 — Verify, lint, self-check

Final gate before commit:

```sh
nix --extra-experimental-features 'nix-command flakes' develop --command make verify
nix --extra-experimental-features 'nix-command flakes' develop --command bundle exec exe/rigor check lib exe bin
```

Self-check on the project's own `lib` MUST stay clean. If your changes introduce false positives in Rigor's own code, fix them before committing — usually by extending the catalog blocklist or by adding a `# rigor:disable <rule>` comment with a load-bearing reason.

### Stage 9 — Document and changelog

- Add a `### Added` entry to `CHANGELOG.md`'s `[Unreleased]` section describing the new topic in user-visible terms (which methods now fold, which refinements are now available through `RBS::Extended`).
- If the topic introduces a new refinement carrier or a new `RBS::Extended` directive, update `docs/type-specification/imported-built-in-types.md` and the matching ADR / spec doc.

## Decision Points (where the procedure is NOT mechanical)

These are the non-mechanical judgement calls. The skill records the *question* and the rule of thumb; the operator picks.

### When to import a class vs. expand the hand-rolled allow list

- *Catalog (preferred)*: the class has a stable Init function in CRuby, the method count is large (>15), and the catalogue can be regenerated without per-method curation.
- *Hand-rolled*: the class is a thin wrapper (e.g. `Pathname` mostly delegates to `File`), or the method count is small (<10), or the project does not vendor the upstream source.

### When to add a `mutating_selectors` blocklist entry

- The catalog says `:leaf` AND the method's name implies mutation (`replace`, `clear`, `<<`, `[]=`, `concat`, `insert`, `prepend`, `freeze`, …).
- The catalog says `:leaf` AND a runtime probe of `Constant<base>.method(args)` raises `FrozenError` against a frozen literal carrier (a strong signal of mutation).
- The catalog says `:leaf` AND the method's docstring or RBS sig describes mutation in language even if the C-body classifier missed the indirect mutator.

When in doubt, blocklist. The cost of a missed fold is one method's loss; the cost of a wrong fold is downstream type rot.

### When to tighten a return type via RBS::Extended

- The method's value is always non-empty / always positive / always within a known range across the API contract — not "happens to be in the test suite".
- The tightening would observably help a call-site narrowing tier (e.g. the next `if x > 0` actually narrows because the input is `non-negative-int` rather than `Integer`).
- The user has opted in by writing the annotation in their `.rbs` file. Rigor never silently writes the override; the annotation is the user's authorship.

### When to introduce a new refinement carrier

- The new shape is already in `imported-built-in-types.md` — implement it.
- The new shape is a **point-removal** (e.g. `non-empty-string`, `non-zero-int`) — use `Type::Difference` and add a `Combinator.<name>` factory plus a `Builtins::ImportedRefinements` registry entry. The carrier landed in v0.0.3.
- The new shape is a **predicate-subset** (e.g. `lowercase-string`, `numeric-string`, `decimal-int-string`) — use `Type::Refined`. The carrier landed in v0.0.4. Concrete steps:
  1. Pick a `predicate_id` Symbol (kebab-case → snake_case, e.g. `numeric-string` → `:numeric`).
  2. Add an entry to `Type::Refined::PREDICATES` whose recogniser MUST be total over arbitrary input (return `false` rather than raise on non-base values). The recogniser is invoked at constant-fold and acceptance time over `Constant<base>` values.
  3. Add an entry to `Type::Refined::CANONICAL_NAMES` keyed on `[base_class_name, predicate_id]` so `describe` prints the kebab-case spelling.
  4. Add a `Combinator.<snake_case_name>` factory that returns `Refined.new(nominal_of(base), predicate_id)`, plus the matching `sig/rigor/type.rbs` entry under the `Combinator` module so the self-check accepts call sites.
  5. Add a `Builtins::ImportedRefinements::REGISTRY` entry mapping the kebab-case name to the new factory.
  6. Add catalog-tier projections in `MethodDispatcher::ShapeDispatch#dispatch_refined` for any methods whose answer is determined by the refinement (e.g. case-fold idempotence). Methods without a specific projection delegate to the base nominal so size-tier projections still apply.
  7. Add a self-asserting fixture under `spec/integration/fixtures/<name>/` (`demo.rb` + `sig/`) and wire it into `spec/integration/type_construction_spec.rb`.
- The new shape is an **Enumerable-aware projection** (e.g. `Enumerable[T]` block parameter typing across Array / Set / Range) — that is a v0.0.4 architecture slice, not a per-class import.

### When to update ADR-3 / ADR-5 / spec docs

- Adding a new carrier class → ADR-3 Class Catalogue Draft entry.
- Adding a new refinement family → `imported-built-in-types.md` table row + ADR-5 case mention if the family stresses the strict-return / lenient-parameter asymmetry.
- Adding a new `RBS::Extended` directive → `docs/type-specification/rbs-extended.md` grammar update + ADR-2 *Extension surface* note.

## Quick Checklist

Before declaring an import done:

- [ ] `tool/extract_builtin_catalog.rb` `TOPICS` entry present.
- [ ] `make extract-builtin-catalogs` regenerated every YAML cleanly.
- [ ] The new YAML committed under `data/builtins/ruby_core/`.
- [ ] Per-topic blocklist (`MethodCatalog.new(mutating_selectors: …)`) curated for false-positive `:leaf`s.
- [ ] `MethodDispatcher::ConstantFolding#catalog_for` routes the new receiver class.
- [ ] At least one self-asserting fixture under `spec/integration/fixtures/`.
- [ ] `make verify` and `bundle exec exe/rigor check lib exe bin` both clean.
- [ ] `CHANGELOG.md` `[Unreleased]` records the user-visible additions.
- [ ] If a new refinement / directive lands, the matching ADR / spec doc is updated.

## Future Optimisation Surface

The procedure above is correct but not yet optimal. Known optimisation candidates are tracked here so future passes have a single place to look. Items that landed in v0.0.4 (`Type::Refined`, the parameterised refinement parser, the `param:` / `assert:` directive routes, the predicate catalogue, the `each_with_index` Enumerable tier, the `tool/scaffold_builtin_catalog.rb` automation) have moved to `CHANGELOG.md`'s `[Unreleased]` section and out of this list.

- **Composed predicate refinements** (e.g. `non-empty-lowercase-string` is already in via `Type::Intersection`). Further composites — `non-empty-hex-int-string`, locale-restricted variants — slot in as registry data plus per-`String` recognisers.
- **C-body classifier upgrades.** Track indirect mutators (`str_modifiable`, `ary_resize`, `time_modify`, `set_compare_by_identity`, …) so the blocklists shrink. Each new class import currently adds its own blocklist for the helpers the regex misses; long-term, the YAML's `:leaf` set should match a hand-curated set with high precision so blocklists become the exception.
- **More Enumerable methods.** `#each_with_index` landed; `#each_with_object`, `#inject` / `#reduce` (memo-typed), `#group_by` / `#partition` (returning shaped containers), and IO line iteration are the natural follow-ups when a concrete slice needs them.
- **Refinement negation in `assert:` / `predicate-if-*:`.** Refinement-form directives currently reject `~T` payloads. A future slice could land a difference-against-refinement algebra so `assert value is ~non-empty-string` means `Constant[""]`.
- **Module imports** (`Comparable`, `Enumerable`). The scaffold script targets concrete classes today; modules need a slightly different topic shape (no `rb_c*` global, methods mixed into many classes). A `--module` mode or a sibling `tool/scaffold_builtin_module.rb` would close the gap.
- **Cross-source consistency check.** A CI step that fails when the catalogue references a cfunc not present in any `c_index_paths` file or an RBS class not present in the matching `.rbs` would catch regressions when CRuby or RBS gem upgrades shift symbol names.
- **Catalogue diff tooling.** A `make catalog-diff` that prints the (additions, removals, purity-changes) between two extractor runs so reviewers can audit a CRuby submodule bump in seconds.

These are NOT prerequisites for landing a new class import; they are improvements that make the next import easier.
