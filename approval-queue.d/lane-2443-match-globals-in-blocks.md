# A `scan` / `gsub` / `sub` block on an untyped receiver enters with the call's own match

- **PR:** [#2468](https://github.com/rigortype/rigor/pull/2468)
- **Issue:** [#2443](https://github.com/rigortype/rigor/issues/2443)
- **Class:** open-choice
- **Precedent:** [ADR-5](../docs/adr/5-robustness-principle.md)
- **Decided:** 2026-10-28

## Background

`String#scan`, `#gsub`, `#gsub!`, `#sub` and `#sub!` set the caller's `$~` to the current match
before every run of their block, so `Regexp.last_match` there is never `nil`. Rigor typed the block
under the enclosing frame's match state, and `m = Regexp.last_match; m.begin(0)` in erubi's
`input.scan(regexp) do … end` reported `call.possible-nil-receiver` on correct code. erubi's
`input` is an untyped parameter. The question the issue left open was what a receiver the analyzer
cannot type gets: it may be some other object whose own block-taking `scan` runs no match in the
caller's frame, and then the block reads whatever the caller's `$~` held.

## Options and trade-offs

- **Narrow only a receiver known to be a String.** Sound in every case, but it leaves the erubi
  report and every other untyped-receiver idiom in place, which is most of the real code that reads
  `$~` in such a block.
- **Narrow a `Dynamic` receiver too.** Clears those reports. The only way to be wrong is a
  non-String object with a block-taking `scan` / `gsub` / `sub` whose block reads a caller's `$~`
  that is `nil`; the block then reads `MatchData` where runtime has `nil`. That can withhold a true
  positive, and cannot add a diagnostic.

## Decision

Narrow a `Dynamic` receiver too, as the coordinator decided on the issue. ADR-5 and the
false-positive rule in `AGENTS.md` favour the side that only withholds diagnostics, and the losing
case needs a project class that reuses String's method names with a different contract.

A receiver known to be something else (neither String nor `Dynamic`) enters with the match globals
unbound, per #1371, rather than with the narrowing at the call site. Ruby runs such a method in its
own frame, so its block actually reads the caller's `$~` unchanged
(`Foo.new.scan(/x/) { $1 }` after `"a12" =~ /(\d+)/` reads `"12"`). Unbinding is the more
conservative of the two readings and can add a `String?` read there.

## To undo

Drop the `dynamic` kind from `Narrowing.string_match_receiver?`; the `Dynamic` receiver then takes
the unbound entry. To give a non-String receiver the frame-wide entry instead of the unbound one,
return `scope` rather than `scope.forget_match_globals` in `MatchRebinding::YieldingMatch.entry`.
The fixture `spec/integration/fixtures/regex_global_narrowing.rb` (`match_block_erubi`,
`match_block_other_receiver`) pins both.
