# sig-gen declares a core subclass only beside its source file's other declarations, and only for core and stdlib superclasses

- **PR:** [#2454](https://github.com/rigortype/rigor/pull/2454)
- **Issue:** [#2224](https://github.com/rigortype/rigor/issues/2224)
- **Class:** scope
- **Precedent:** none — sets one
- **Decided:** 2026-10-27

## Background

Issue #2224 asks sig-gen to declare an empty subclass of a core class (`class MyHash < Hash; end`) as `class MyHash < ::Hash[untyped, untyped] end`, so a method that returns one resolves. The fix reuses the writer's existing class-shell path, the one that declares a `Const = Data.define(...)` class. A shell rides on the candidates of the source file it was found in, and the writer writes a file only for a source file that has at least one method to emit. The issue's example keeps the subclass and a method in one file, but it did not say what should happen when a file holds nothing but empty subclasses (a typical `errors.rb`), or which superclasses count as "core".

## Options and trade-offs

- **Shells beside the file's own methods, core and stdlib superclasses only (taken).** This fits the existing shell path without a new candidate kind, and it adds no row to `--print` or `--format=json` output, whose formats are a public contract. A file holding only empty subclasses still gets no declaration, so a method in another file that returns one of those classes still fails `rbs validate`.
- **A new candidate kind for a class declaration.** This would cover a file holding only empty subclasses, but it adds a classification to the JSON payload and to `--print`, which changes the public output format. Under contribution-flow.md that change is serious.
- **Any superclass the environment knows, including gem and project classes.** This would declare `class Post < ::ApplicationRecord` for an empty model as well. It goes past the issue, and it changes `--write` output for every Rails project.

## Decision

Take the first option. It closes the issue's example within the existing writer path, and it leaves the public output formats unchanged. A file holding only empty subclasses, and a subclass of a project or gem class, are reported to the coordinator as follow-ups rather than widening this PR.

## To undo

Delete `register_core_subclass_shell` and its call in `lib/rigor/sig_gen/generator.rb`, along with the #2224 examples in `spec/rigor/sig_gen/generator_core_type_spelling_spec.rb`. Nothing else depends on the shells. To widen the fix instead, relax the `core_or_stdlib_class?` guard, or give the writer a carrier for shells from a file that has no candidates.
