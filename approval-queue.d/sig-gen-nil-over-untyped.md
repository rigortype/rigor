# Keep an authored untyped over a body that returns only nil

- **PR:** [#2069](https://github.com/rigortype/rigor/pull/2069)
- **Issue:** [#1891](https://github.com/rigortype/rigor/issues/1891)
- **Class:** open-choice
- **Precedent:** [#1890](https://github.com/rigortype/rigor/pull/1890)
- **Decided:** 2026-10-20

## Background

#1891 reported that `rigor sig-gen` over a `-> untyped` the author wrote in `sig/` proposed `-> nil` for a method whose body returns only `nil`, typically a template method (`def hook = nil`) that a subclass overrides with a value. After `--write --overwrite`, every such override is a `def.override-return-widened` ("widened from nil to String") on correct code. The issue suggested declining might be the answer but left it open. #2069 shipped the decline before the approval queue existed; this entry, added later, records the choice for ratification.

## Options and trade-offs

- **Decline, keep `untyped` (taken).** The member is classified `equivalent` and the authored `untyped` stays. No override false positive; the cost is that a method that really always returns `nil` keeps an imprecise signature, which the author can write as `-> nil` (or `-> void`) by hand.
- **Propose `-> nil`.** The strictest type the body proves, and what a method no `.rbs` declares still gets; but it turns every value-returning override into a warning, the failure the issue reports.
- **Widen to some wider type** (`Object?`, `untyped`). No type wider than `nil` is one the body proves, so any choice would be invented; `untyped` is the honest answer and is what the author already wrote.

## Decision

Decline. #1890 (#1489) set the precedent that an authored `untyped` abstracts over value literals the body happens to return; for `nil` there is no class to widen to that the body proves, so keeping the author's `untyped` is the sound reading. `nil` inside a union (`T?`) is an honest type and is still proposed. A method no `.rbs` declares, or one whose `untyped` only the inline reader synthesizes, still gets `-> nil`.

## To undo

Remove the `bare_nil?` early return in `Generator#declared_untyped_candidate` and change the "declines a bare nil return" example in `spec/rigor/sig_gen/generator_spec.rb` and the `--write` example in `spec/rigor/cli/sig_gen_command_declared_params_spec.rb` to expect `-> nil`.
