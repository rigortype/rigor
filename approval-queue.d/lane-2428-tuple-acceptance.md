# A tuple accepts an Array of unknown length as maybe, unless an element contradicts a tuple member

- **PR:** [#2447](https://github.com/rigortype/rigor/pull/2447)
- **Issue:** [#2428](https://github.com/rigortype/rigor/issues/2428)
- **Class:** open-choice
- **Precedent:** [ADR-5](../docs/adr/5-robustness-principle.md)
- **Decided:** 2026-10-27

## Background

`Acceptance#accepts_tuple` rejected every argument that was not itself a tuple. `URI.encode_www_form`
takes `Enumerable[[_ToS, _ToS]]`, so passing it the `Array[Array[String]]` that `URI.decode_www_form`
answers reported `call.argument-type-mismatch` on correct code. An `Array[E]` does not carry its
length, so the analyzer cannot prove a wrong arity. The issue left open whether a tuple should
answer `maybe` only for a gradual element (`Array[untyped]`) or for any element that fits.

## Options and trade-offs

- `maybe` only when `E` has a gradual arm. This keeps `def.return-type-mismatch` on a declared
  `[String, String]` return built from an `Array[String]`, but still fires on the
  `URI.decode_www_form` round trip, whose element is the precise `Array[String]`.
- `maybe` for any `Array[E]` whose element no tuple member rejects outright, and `no` on an element
  contradiction. This clears the round trip. A wrong-length `Array[E]` where a tuple is declared is
  no longer reported.

## Decision

The second option, as the coordinator settled it in the issue's brief. ADR-5 weighs a false
positive on correct code above a missed report, and the analyzer has no arity evidence to reject
on. An element contradiction (`[Integer, Integer]` against `Array[String]`) is still `no`. The
tuple's `maybe` is no evidence for an overload in the strict pass, following the open-record
precedent, so `([Integer, Integer]) -> Symbol | (Array[Integer]) -> String` still selects the second
overload. `spec/rigor/inference/tuple_array_acceptance_spec.rb` pins the accepted cost: a declared
`(Array[String]) -> [String, String]` returning its parameter is silent.

## To undo

Restore the unconditional `no` for a non-tuple in `Acceptance#accepts_tuple`, drop
`array_element_verdict` and the `rests_on_unread_array?` arm of `maybe_rests_on_unread_shape?`, and
revert the tuple paragraphs in `docs/internal-spec/inference-engine.md` and
`docs/type-specification/rbs-compatible-types.md`. Nothing else depends on it yet.
