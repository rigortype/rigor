require "rigor/testing"
include Rigor::Testing

# ADR-55 slice 2 — fixpoint recursive return summaries. The in-cycle
# re-entry of a recursive method no longer widens to `Dynamic[top]`;
# instead a Kleene iteration from `bot` computes a signature-free
# return summary, so a recursive contribution carries the method's
# real return type rather than `untyped` contamination.

# A non-constant (`Dynamic`) argument source. `[1, 2, 3].sample`
# returns `Integer` per RBS, but routed through a local `def` it reaches
# the body as a non-value-pinned argument — the path that previously
# joined the recursive call with `Dynamic[top]`.
def some_int = [1, 2, 3].sample

# factorial / String-builder recursions. NOTE (2026-06-11 audit): these
# two assertions are NOT slice-2 wins — the pre-slice-2 baseline
# (commit 2ba608a0) already typed `Factorial#of` as `1 | Integer` and
# `Builder#build` as `String`. The recursive `of(n - 1)` / `build(n - 1)`
# branch is an *arithmetic / `String#+`* expression whose result type is
# fixed by RBS return-type absorption (`Integer#*`, `String#+`)
# REGARDLESS of what the recursive call itself returns, so the in-cycle
# `Dynamic[top]` was already absorbed away before slice 2. They are kept
# as termination + non-regression anchors, not as discriminating
# fixpoint evidence. The passthrough / pick cases below DO discriminate:
# their recursive branch is a *bare* self-call whose type flows straight
# through, so the fixpoint summary (not RBS absorption) decides the
# result.
class Factorial
  def of(n)
    n <= 1 ? 1 : n * of(n - 1)
  end
end

assert_type("1 | Integer", Factorial.new.of(some_int))

class Builder
  def build(n)
    n <= 0 ? "" : "x" + build(n - 1)
  end
end

assert_type("String", Builder.new.build(some_int))

# DISCRIMINATING fixpoint case. The recursive branch is a *bare*
# self-call (`passthrough(n - 1)`), so its type flows straight through
# with no RBS absorption to mask it. Slice 2 raises this from the
# pre-slice-2 `Dynamic[top]` to the precise `:done` — the Kleene
# iteration discovers the base-case constituent and the recursive branch
# contributes exactly the summary, not `untyped`.
#
# Regression guard for the 2026-06-11 bot-collapse bug: the call-site
# argument (`some_int : 1 | 2 | 3`) narrows `n <= 0` to always-false and
# prunes the `:done` tail branch, so the body computes `bot`; the
# unguarded `joined == assumption` check converged at the `bot` seed and
# returned `bot` (UNSOUND — `passthrough` returns `:done` at runtime,
# `bot` means never-returns and feeds ADR-47 reachability). The fix
# re-runs the fixpoint over a parameter-widened body scope that un-prunes
# the base case.
class Walker
  def passthrough(n)
    n <= 0 ? :done : passthrough(n - 1)
  end

  # The base case is an explicit early `return` whose value the tail-only
  # body evaluator never folds into the result, so the fixpoint cannot
  # see the `nil`. The bot-collapse fix detects the reachable explicit
  # `return` and floored to the sound `Dynamic[top]` (the pre-slice-2
  # observable) instead of the unsound `bot`. ADR-57 slice 2 then made
  # explicit-return values contribute to method-return inference, so the
  # `nil` is now visible: `pick` infers its true return `nil` (the base
  # case joined with the bare recursive branch, which the fixpoint
  # resolves to `nil`), no longer needing the `Dynamic[top]` floor.
  def pick(n)
    return nil if n <= 0

    pick(n - 1)
  end
end

assert_type(":done", Walker.new.passthrough(some_int))
assert_type("nil", Walker.new.pick(some_int))

# A method that ONLY recurses never returns: its summary stays `bot`
# (the always-diverging shape) without hanging or blowing the stack.
class Diverge
  def spin(n)
    spin(n + 1)
  end
end

assert_type("bot", Diverge.new.spin(some_int))

# Mutual recursion (the ADR-24 WD5 `module_function` shape) terminates
# — no `SystemStackError`; termination is the load-bearing property.
# Module-singleton call resolution (ADR-57 follow-up) now resolves the
# `Parity.even?` singleton call against the module's `module_function`
# body instead of leaving it `Dynamic[top]`. The cross-signature
# fixpoint still does not fold to a precise `bool`: it yields the same
# imprecise one-sided `false` the engine already produces for the
# instance-method form `Parity.new.even?(some_int)` — a pre-existing
# mutual-recursion fixpoint limitation independent of this slice.
module Parity
  module_function

  def even?(n)
    n == 0 ? true : odd?(n - 1)
  end

  def odd?(n)
    n == 0 ? false : even?(n - 1)
  end
end

assert_type("false", Parity.even?(some_int))
