# An Object, BasicObject or module subject reads String | Symbol after a regexp match, even though it may convert with to_str

- **PR:** [#2256](https://github.com/rigortype/rigor/pull/2256)
- **Issue:** [#2002](https://github.com/rigortype/rigor/issues/2002)
- **Class:** open-choice
- **Precedent:** [#1955](https://github.com/rigortype/rigor/issues/1955)
- **Decided:** 2026-10-21

## Background

`Regexp#===` (and so `case x when /re/`) matches a String, a Symbol, and any object whose class defines `to_str`. RSpec's `match(/re/)` matcher (rigor-rspec, [#2033](https://github.com/rigortype/rigor/issues/2033), [#2258](https://github.com/rigortype/rigor/pull/2258)) passes on the same values, and also on an object whose `match` returns truthy. #2002 and #2033 keep a subject whose class defines `to_str` (or `match`) on the match edge instead of narrowing it out. That leaves open what to do with a member whose class is `Object`, `BasicObject` or a module such as `Kernel`. Its instances may be anything, including a `to_str` object, so on a strict reading it should be kept whole. The first version of both PRs kept it whole. Review found that this reports correct code: `s.length if /\d/ === s` on an `Object` parameter gave `undefined method 'length' for Object`, which the String-narrowing base did not.

## Options and trade-offs

- **Keep the member whole.** This is the sound reading of the edge, but every String method called on the arm is then reported on correct code, the common case being an `Object` / untyped-ish parameter guarded by a regexp.
- **Narrow it to `String | Symbol`, as before the PRs.** This misses a `to_str` object behind an `Object` type. A call on the arm then reads `String | Symbol` for it, which can only under-report, since such an object answers String methods through its own class. It reports nothing new on correct code.
- **Narrow it to `Dynamic[top]`.** This reports nothing, but it throws away the String reading that base gave and that keeps follow-up calls typed.

## Decision

Narrow to `String | Symbol`, which is base's behaviour, following AGENTS.md's rule that false positives outrank worst-case static reading. A member is kept whole only when its class positively defines `to_str` (and, for the RSpec matcher, `match`) or when no signature declares the class. #2256 and #2258 apply the same rule.

## To undo

In `Narrowing#class_converts_with_to_str?` and rigor-rspec's `MatcherAnalyzer#regex_match_member`, drop the open-surface / module exclusion so such a member is kept whole. The `Object` rows in `regex_global_narrowing.rb`, `regexp_to_str_subject/demo.rb` and `rspec_plugin_spec.rb` would flip back.
