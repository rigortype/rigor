# rigor-sorbet

Lets Rigor read an existing [Sorbet](https://sorbet.org/) codebase
as a type source: inline `sig { ... }` blocks, RBI files, and the
`T.let` / `T.cast` / `T.must` / `T.unsafe` / `T.bind` /
`T.assert_type!` / `T.absurd` assertion forms are translated into
Rigor's own carriers, so you can run `rigor check` alongside
`srb tc` without rewriting anything in RBS. It reads source only —
it does not load `sorbet-runtime`.

It ships bundled in `rigortype`. Activate it under `plugins:`:

```yaml
plugins:
  - rigor-sorbet
```

> **Full guide.** This page is the operational quick reference.
> The complete walkthrough — the Sorbet→Rigor type-vocabulary
> table, every assertion form, RBI / Tapioca-DSL handling, sigil
> semantics, `T.absurd` exhaustiveness, and the migration
> patterns — is
> [handbook chapter 10 — Coexisting with Sorbet](../../handbook/10-sorbet.md).

## Configuration

```yaml
plugins:
  - gem: rigor-sorbet
    config:
      enforce_sigil: true              # default; honour `# typed:` sigils
      rbi_paths: ["sorbet/rbi"]        # default; set [] to disable RBI loading
```

- **`enforce_sigil`** (default `true`) — mirror Sorbet's own
  contract: only record sigs from files at `# typed: true` or
  stricter. Set `false` to record sigs from every parseable file
  regardless of sigil. The inline assertion recognisers (`T.let`,
  `T.cast`, …) always fire, since the user wrote them deliberately.
- **`rbi_paths`** (default `["sorbet/rbi"]`) — directories of
  `.rbi` files to load (the standard Tapioca subdirectories
  `gems/` / `annotations/` / `dsl/` / `shims/` participate by
  recursion). Set `[]` to opt out, or add a vendored tree.

## Scope and limits

The plugin is **input-side only**: it translates Sorbet's syntax
into Rigor's type model. It does **not** run Sorbet's checker,
ship `sorbet-runtime`, or enforce Sorbet's runtime guarantees.
When an RBS sig and a Sorbet sig disagree, call sites get the
Sorbet sig's return type, and the method's body is checked
against the RBS return. Forms outside the
translation table (`T.proc`, `T.self_type`, …) degrade to
`Dynamic[top]`. Chapter 10 documents the full vocabulary and
these edges.

The plugin also types the annotation DSL's own expressions
(`sig`, `params`, `returns`, `void`, `abstract`, `override`,
`type_member`, `T::Array[...]`, `T::Helpers`/`T::Generic` macros,
`T::Struct`/`T::Enum` class bodies — `sig` on a plain
`T::Struct` subclass still needs the subclass's own `extend T::Sig`,
matching the runtime) through a bundled
`sorbet-runtime` RBS surface — so the sig DSL no longer reads as
`Dynamic[top]` on a Sorbet codebase.

On a `T::Struct`, `T::InexactStruct` or `T::ImmutableStruct`
subclass, `prop :name, Type` and `const :name, Type` at the top
level of the class body give `obj.name` the translated `Type`
(`T.nilable(String)` reads `String?`; a form outside the table
reads `Dynamic[top]`), and `prop` also answers `obj.name = v`.
A relative constant in `Type` resolves from the class body's
namespaces outward, and one that names no known class reads
`Dynamic[top]`.
A `const` has no writer, so `obj.name = v` still reports.
Subclasses inherit the accessors, a `def` of the same name in
the class body wins over the macro, and a `prop` nested under an
`if` or a block reads `Dynamic[top]`. A `prop` call in a class
outside the struct family defines nothing.

What it does not model: `include T::Props` does
not confer the `ClassMethods` surface (only the `< T::Struct`
subclass path does), and the deeper type-member machinery
(`T.attached_class` variance, `type_member` bounds) is not
propagated into call sites.

## Plugin internals

The slice-by-slice implementation (sig parsing, assertion
lifting, the RBI tree walker, mixin-chain resolution, the
dispatcher tier ordering), the source layout, and the demo are in
the [plugin's README](../../../plugins/rigor-sorbet/README.md).
The design rationale is
[ADR-11](../../adr/11-sorbet-input-adapter.md).
