# A supertype argument answers the union of the overloads it overlaps, not the widest declared return

- **PR:** [#2383](https://github.com/rigortype/rigor/pull/2383)
- **Issue:** [#2379](https://github.com/rigortype/rigor/issues/2379)
- **Class:** open-choice
- **Precedent:** none — sets one
- **Decided:** 2026-10-26

## Background

Overload selection took the first overload a `Numeric` argument reached: `Integer - Numeric` read `Integer` although
Ruby answers a Float, Rational or Complex for those subclasses. The issue left open whether such a call answers the
union of every overload the argument may select or declines to the method's widest declared return. The coordinator's
brief preferred the union when it is finite and small.

## Options and trade-offs

- **Union of the overlapping overloads' returns.** Precise where the overloads are few (`Complex | Float | Integer |
  Rational` for the numeric tower), and every member is one the RBS declares for some value of the argument. A plain
  union lets negative rules fire on an arm the program never reaches when the argument is in practice narrower than
  declared.
- **The widest declared return.** Not defined for most methods (the overloads return unrelated classes), so it would
  need a fallback of its own, usually `Dynamic[top]`, losing all precision.

## Decision

The union, joined as a plain (not `Dynamic`) union, as the keyword-value distribution of #1746 does. Only overloads
whose parameters are all strictly typed count, so an alias- or `untyped`-typed overload does not join on the argument's
overlap alone.

### Survey firings accepted as `named-mechanism`

`tool/engine_diag_diff.rb` over a private copy of textbringer (rgl: no delta) adds two rows, accepted by the
coordinator as `named-mechanism` firings (ADR-119 WD2; mechanism: #2379 per-member overload selection):

- `lib/textbringer/keymap.rb:20:25` `call.possible-nil-receiver` — possible nil receiver: `` `size' `` is undefined on
  NilClass
- `lib/textbringer/keymap.rb:24:27` `call.possible-nil-receiver` — possible nil receiver: `` `first' `` is undefined on
  NilClass

The project's own `sig/lib/textbringer/keymap.rbs` declares the key `define_key` passes to `kbd` to admit a Hash, and
`kbd`'s Hash overload to return `nil`:

```rbs
def define_key: (Symbol, Symbol) -> Symbol
              | (String, Symbol) -> Symbol
              | (Array[untyped], Symbol) -> Symbol
              | (String, Proc) -> Proc
              | (Array[untyped], Symbol) -> nil
              | (Hash[untyped, untyped], Symbol) -> nil

def kbd: (Symbol) -> Array[untyped]
       | (String) -> Array[untyped]
       | (Array[untyped]) -> Array[untyped]
       | (Hash[untyped, untyped]) -> nil
```

The Hash member of the key now selects the declared `-> nil` arm, so the finding follows the declared contract. At
runtime `kbd` raises `TypeError` for a Hash, but Rigor does not second-guess a signature the project wrote by reading
runtime behaviour; the fix on the user's side is to correct the signature. No special case was added for value-pinning
`-> nil` arms. The signature is tracked upstream (`shugo/textbringer`, added to `sig/` in commit `3f6b0d2`,
2026-05-25, with the rest of `sig/`); the measured copy is unmodified. With the two rows in an adjudication file the
tool passes (exit 0, `2 named-mechanism`).

## To undo

Wrap the join in `Dynamic` in `RbsDispatch#distributed_argument_return`, or drop `OverloadSelector.contested_matches`
to go back to the first-overload pick for a supertype argument; the spec example "joins every overload a supertype
argument overlaps" pins the current answer.
