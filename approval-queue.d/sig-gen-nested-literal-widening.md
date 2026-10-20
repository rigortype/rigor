# Widen literals nested in tuples, records and type arguments over an authored untyped

- **PR:** [#2173](https://github.com/rigortype/rigor/pull/2173)
- **Issue:** [#1891](https://github.com/rigortype/rigor/issues/1891)
- **Class:** open-choice
- **Precedent:** [#2069](https://github.com/rigortype/rigor/pull/2069)
- **Decided:** 2026-10-20

## Background

Over a `-> untyped` the author wrote in `sig/`, `rigor sig-gen` widens a top-level Integer, String or Symbol literal to its class (#1489) and `true`/`false` to `bool` (#2069). #1891 listed as "worth deciding alongside" the same literals nested in a tuple, a record or a generic argument: `[1, "a"]`, `{ a: 1 }` and `Hash[String, 1]` were still written verbatim. Once sig-gen also writes a subclass's override (`[2, "b"]`), `rigor check` reports `def.override-return-widened` on correct code, the failure #2069 removed for top-level literals. #2069 left the nested case undecided.

## Options and trade-offs

- **Widen the nested literals, keep the shape (taken).** `[1, "a"]` becomes `[Integer, String]`, `{ a: 1 }` becomes `{ a: Integer }`, `Array[1 | 2]` becomes `Array[Integer]`; `true`/`false` inside become `false | true`; a nested `nil` stays, as `nil` in a top-level union does. It is the existing widening applied recursively, so it falls out of the same code path. An override with the same shape and other values is no longer a widening. An override with a different arity or key set still is, which the tuple or record shape asserts on purpose.
- **Widen the shape too** (`[1, "a"]` to `Array[Integer | String]`, a record to `Hash[Symbol, …]`). Removes more override warnings, but discards structure the body proves and that callers use (positional and key access), and it is a new erasure rule rather than the #1489 widening.
- **Leave nested literals verbatim.** No change; the override false positive stays for every tuple- or record-returning method.

## Decision

Widen the nested literals and keep the shape. It is the narrowest step that applies #1489's and #2069's reasoning (a value literal under an authored `untyped` is an implementation detail the author abstracted over) to the same literals one level down, without inventing a new erasure. A method no `.rbs` declares, and an `untyped` only the inline reader synthesizes, keep the strictest carrier, as they do for top-level literals. Only the arguments of the core generics whose RBS parameters are all covariant (`Array`, `Hash`, `Set`, `Range`, `Enumerator`) widen; a user generic with an invariant or `in` parameter keeps its literal argument, since the widened type would be no supertype there. A method whose inline `# @rbs` annotation covers its parameters only, over a `sig/` `-> untyped`, is spelled from the unwidened body, so a nested literal that would be widened declines the whole proposal there (a nested `nil`, a Float, or a literal argument of a non-covariant generic does not), and the `untyped` stays, as a top-level literal already did (#1489). Before this change such a method was proposed `-> [1, Integer]` for `[1, x]`; it now gets nothing, which says less but nothing wrong.

## To undo

Drop the `Type::Tuple`, `Type::HashShape` and `Type::Nominal` branches of `Generator#widen_value_literals` and restore the nested rows of `spec/rigor/sig_gen/generator_spec.rb` and the `--write` example in `spec/rigor/cli/sig_gen_command_declared_params_spec.rb`. Nothing else reads the widened form.
