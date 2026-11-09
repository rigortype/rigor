# A definer from a class object's prepend region is withheld when its prepends have no known order

- **PR:** [#3009](https://github.com/rigortype/rigor/pull/3009)
- **Issue:** [#2998](https://github.com/rigortype/rigor/issues/2998)
- **Class:** open-choice
- **Precedent:** [#2996](https://github.com/rigortype/rigor/pull/2996)
- **Decided:** 2026-11-09

## Background

Two singleton-side prepends can trade places when the tables do not fix their order. That happens with a class's own
`class << self; prepend Y` beside a prepended concern's `ClassMethods` (the tables keep the two statements apart), and
with two own prepends written in two files or where one statement's position is not a fact. The brief says to
decline there rather than answer. #2996 decided the analogous extend-against-hook fork by a retro world and compared
the chain with master's class-object answer where no retro world exists.

## Options and trade-offs

- A retro world with the other prepend order, as #2996 does for extends. It answers where both orders agree. But any
  second fork on the chain removes the retro world, and the fallback, a comparison with master's fold copies,
  agreed with the chain's arbitrary order on a probe (`Kh2.foo` typed `:y` where Ruby answers `"s"`).
- Settle such chains to master and compare as #2996's fallback does. Same false agreement.
- Mark the class (`:prepend_order`), count two forks, and have the typing read withhold any definer that sits in
  that class object's prepend region, whichever order the chain picked. A name defined behind the class object, such
  as a superclass's class method, still answers.

## Decision

The third option. It answers the brief's "decline rather than answer" without depending on how many other forks the
chain has, and it costs only names that one of the prepends defines alone.

## To undo

Drop the `:prepend_order` mark in `ResolutionChain::Builder#order_prepends` and
`ExpressionTyper#unordered_prepend_definer?`. Then build a retro world with the prepends' other order.
