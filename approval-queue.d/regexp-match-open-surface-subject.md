# An Object, BasicObject, Kernel or Comparable subject reads String | Symbol after a regexp match, even though it may convert with to_str

- **PR:** [#2256](https://github.com/rigortype/rigor/pull/2256)
- **Issue:** [#2002](https://github.com/rigortype/rigor/issues/2002)
- **Class:** open-choice
- **Precedent:** [#1955](https://github.com/rigortype/rigor/issues/1955)
- **Decided:** 2026-10-21

## Background

`Regexp#===` (and so `case x when /re/`) matches a String, a Symbol, and any object whose class defines `to_str`. RSpec's `match(/re/)` matcher (rigor-rspec, [#2033](https://github.com/rigortype/rigor/issues/2033), [#2258](https://github.com/rigortype/rigor/pull/2258)) passes on the same values, and also on an object whose `match` returns truthy. #2002 and #2033 keep a subject whose class defines `to_str` (or `match`) on the match edge instead of narrowing it out. That leaves open what to do with a member whose class is `Object`, `BasicObject` or a module. Its instances may be anything, including a `to_str` object, so on a strict reading it should be kept whole. The first version of both PRs kept it whole. Review found that this reports correct code: `s.length if /\d/ === s` on an `Object` parameter gave `undefined method 'length' for Object`, which the String-narrowing base did not.

## Options and trade-offs

- **Keep the member whole.** This is the sound reading of the edge, but every String method called on the arm is then reported on correct code, the common case being an `Object` / untyped-ish parameter guarded by a regexp.
- **Narrow it to `String | Symbol`, as before the PRs.** This misses a `to_str` object behind an `Object` type, so the arm's type is wrong for that object. A String method called on the arm still reports nothing. A method only the object's own class has (`x.custom` after the guard) would be reported, which base also did. For a module that String and Symbol do not include (`module Named`), this reading is not even plausible: no String is a `Named`. A round-2 version that read every module this way reported `x.greet` on correct code and read a `Named` subject as `bot`.
- **Narrow it to `Dynamic[top]`.** This reports nothing, but it throws away the String reading that base gave and that keeps follow-up calls typed.

## Decision

Narrow to `String | Symbol`, which is base's behaviour, following AGENTS.md's rule that false positives outrank worst-case static reading. The rule covers only `Object`, `BasicObject` and the modules String or Symbol includes (`Kernel`, `Comparable`; read from the running Ruby's ancestors, not a list). A module that declares `to_str` (or, for the RSpec matcher, `match`) keeps its type. Any other module keeps its type in #2256, which is sound because a matching value may include it; in #2258 it means no fact. A class is kept whole when it declares `to_str` (or `match`) or when no signature declares it. #2256 and #2258 apply the same rule.

## To undo

In `Narrowing#class_converts_with_to_str?` and rigor-rspec's `MatcherAnalyzer#regex_match_member`, drop the `Object` / `BasicObject` / String-module exclusion so such a member is kept whole. The `Object`, `Kernel` and `Comparable` rows in `regex_global_narrowing.rb`, `regexp_to_str_subject/demo.rb` and `rspec_plugin_spec.rb` would flip back.
