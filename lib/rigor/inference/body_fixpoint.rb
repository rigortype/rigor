# frozen_string_literal: true

require_relative "../type"
require_relative "budget_trace"

module Rigor
  module Inference
    # ADR-56 WD3 — the single capped-fixpoint mechanism shared by the
    # non-escaping block captured-local write-back (slice A) and the
    # loop-body fixpoint (slice B). Computes the continuation binding of a
    # set of locals that a body (a block body or a loop body) may rebind
    # across an unknown number (0..N) of iterations.
    #
    # The body may run zero times, so the seed (pre-state) binding is kept
    # as a join constituent throughout; it may compound (`a = [a]`), so the
    # join is iterated to a fixed point under a hard cap (ADR-41 WD4). On
    # the final permitted iteration value-pinned constituents are widened to
    # their nominal base to force convergence; a local that still moves is
    # collapsed to `Dynamic[top]` — the established escaping-block floor —
    # and a {BudgetTrace::BLOCK_WRITEBACK_CAP} hit is recorded.
    #
    # The mechanism is parameterized over an `evaluate_body` callable so
    # slice B can reuse it: given the current per-name bindings it returns
    # the per-name exit bindings produced by one body evaluation from those
    # bindings (names the body leaves unwritten in a given pass simply do
    # not appear in the returned hash).
    module BodyFixpoint
      # One body evaluation per iteration; ADR-55's shape (cap 3).
      CAP = 3

      module_function

      # @param names [Array<Symbol>] the outer locals the body can rebind.
      # @param seed_bindings [Hash{Symbol=>Type}] pre-state binding per name.
      # @param widen [#call] value-pinned widener (Constant -> Nominal).
      # @param evaluate_body [#call] `bindings -> exit_bindings` — evaluates
      #   the body once from `bindings` (the per-name current assumption) and
      #   returns the per-name exit binding it produced.
      # @return [Hash{Symbol=>Type}] the continuation binding per name.
      def converge(names:, seed_bindings:, widen:, evaluate_body:)
        return {} if names.empty?

        # Running assumption per name; seeded with the pre-state binding,
        # which stays a join constituent throughout (0-iteration soundness).
        assumption = seed_bindings.dup

        (0...CAP).each do |iteration|
          last_iteration = iteration == CAP - 1
          exit_bindings = evaluate_body.call(assumption)

          stable = true
          names.each do |name|
            exit_type = exit_bindings[name]
            next if exit_type.nil? # body did not write it this pass

            if last_iteration
              # On the final permitted iteration widen BOTH the running
              # assumption and the fresh exit type to their nominal bases
              # before joining: Rigor's `union` keeps `Constant[1]` and
              # `Nominal[Integer]` as distinct members, so an accumulator
              # (`+=`/`*=`) producing a fresh constant per pass would never
              # converge without collapsing both sides first. If the join
              # is still wider than the widened assumption (structural
              # compounding, `a = [a]`), the local floors to `Dynamic[top]`.
              base = widen.call(assumption[name])
              joined = Type::Combinator.union(base, widen.call(exit_type))
              if joined == base
                assumption[name] = joined
              else
                BudgetTrace.hit(BudgetTrace::BLOCK_WRITEBACK_CAP)
                assumption[name] = Type::Combinator.untyped
              end
            else
              joined = Type::Combinator.union(assumption[name], exit_type)
              next if joined == assumption[name]

              stable = false
              assumption[name] = joined
            end
          end

          break if stable
        end

        assumption
      end
    end
  end
end
