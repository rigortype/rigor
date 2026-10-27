# A `scan` / `gsub` / `sub` block on an untyped receiver enters with the call's own match; other receivers keep the frame-wide entry

- **PR:** [#2468](https://github.com/rigortype/rigor/pull/2468)
- **Issue:** [#2443](https://github.com/rigortype/rigor/issues/2443)
- **Class:** open-choice
- **Precedent:** [ADR-5](../docs/adr/5-robustness-principle.md)
- **Decided:** 2026-10-28

## Background

`String#scan`, `#gsub`, `#gsub!`, `#sub` and `#sub!` set the caller's `$~` to the current match
before every run of their block, so `Regexp.last_match` there is never `nil`. Rigor typed the block
under the enclosing frame's match state, and `m = Regexp.last_match; m.begin(0)` in erubi's
`input.scan(regexp) do … end` reported `call.possible-nil-receiver` on correct code. The fix
narrows the block's entry when the receiver is a String. Two receivers were left open by the issue:

- One the analyzer cannot type (`Dynamic`), like erubi's `input` parameter. It may be some other
  object whose own block-taking `scan` runs no match in the caller's frame.
- One known to be neither a String nor `Dynamic`: a project class with a `scan` / `gsub` of its
  own, `Pathname`, or a union containing either.

## Options and trade-offs

`Dynamic` receiver:

- **Narrow only a String.** Sound, but it leaves the erubi report and every other untyped-receiver
  idiom in place, which is most of the real code that reads `$~` in such a block.
- **Narrow a `Dynamic` receiver too.** Clears those reports. It is wrong only for a non-String
  object with a block-taking `scan` / `gsub` / `sub` whose block reads a caller's `$~` that is
  `nil`. That can withhold a true positive and cannot add a diagnostic.

Any other receiver:

- **Enter with the match globals unbound.** This was the first revision, following #1371's wording.
  Review showed it adds `possible nil receiver` reports on correct code. A method defined in Ruby
  matches in a frame of its own, so its block reads the caller's `$~`: `Tok.new.scan(/x/) { $1 }`
  after `"a12" =~ /(\d+)/` reads `"12"`. The same happens for a String-or-`Pathname` union.
- **Read the globals as `Dynamic[top]` (`untyped_match_globals`).** This does not silence
  `Regexp.last_match`, because `RegexpFolding.fold_last_match` ignores an untyped `$~`.
- **Keep the frame-wide entry, the behaviour before this PR.** It adds nothing new. Where a C
  method does match on the caller's behalf, as `Pathname#sub` does (its block reads its own match,
  `"b"`), the entry stays as precise as it was before.

## Decision

Narrow a `Dynamic` receiver, as the coordinator decided on the issue. ADR-5 and the false-positive
rule in `AGENTS.md` favour the side that only withholds diagnostics.

Keep the frame-wide entry for every other receiver. This was the coordinator's ruling after
review, and it is the only option that adds no report on correct code.

Separately, the block entry binds only what every match binds: `$~`, `$&`, and the pre- and
post-match. These are laid over the frame-wide entry, and every `$N` and `$+` keeps the binding
that entry gives it, exactly as before this PR. This is the coordinator's ruling after review.

Typing `$N` from the call's own pattern was backed out. Three rounds found
`unconditional_capture_groups` misreading one source shape after another: inline flags, comments,
lookarounds, nested character classes. #2472 tracks fixing the walk.

Forgetting the groups at entry was also backed out. A group narrowed by an earlier match in the
method then read `String?` and reported correct code, as in
`return unless s =~ /(\d+)/; s.gsub(/(\w)/) { w = $1; w.upcase }`.

Keeping the frame-wide binding leaves #1371's stale-binding cases as they were on master. The
erubi report needs only `$~`.

## To undo

- To stop narrowing a `Dynamic` receiver, drop the `dynamic` kind from
  `Narrowing.string_match_receiver?`.
- To narrow another receiver, widen that predicate.
- To type the groups from the pattern once #2472 lands, extend `Narrowing.yielded_match_scope`.
  It must also replace a group an earlier match bound, which #1371 asks for.

The fixture `spec/integration/fixtures/regex_global_narrowing.rb` pins both choices:
`match_block_erubi`, `match_block_project_receiver`, `match_block_project_gsub`,
`match_block_pathname` and `match_block_union`.
