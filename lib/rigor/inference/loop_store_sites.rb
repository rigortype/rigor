# frozen_string_literal: true

require_relative "../type"
require_relative "../source/node_walker"
require_relative "narrowing"

module Rigor
  module Inference
    # Issue #3337, ADR-56 WD2.14 — the scope a `while` / `until` loop's content join types each store's arguments
    # in. The join's own scope, `post_loop`, reads a local the loop rebinds at its continuation binding: the join of
    # the pre-loop binding and the body's EXIT binding. The store saw neither. A local first assigned in the body
    # carries the `nil` its zero-iteration seed gives it, though the store never ran on that path (`s = f; out << s`
    # read `Array[String?]` and drew `call.possible-nil-receiver` on correct code), and a local rebound after the
    # store carries a value the store never held (`out << s; s = nil` read `Array[nil]`).
    #
    # `StatementEvaluator#evaluate` leaves the scope it enters each store site with in a {Pass}'s table while the
    # loop's rebind fixpoint runs, and {.argument_scopes} overlays each rebound local's binding there on
    # `post_loop`. No body pass is added.
    module LoopStoreSites
      # What the rebind fixpoint's passes leave: `scopes`, the identity-keyed table of each store site's scope, and
      # `entry`, a copy of the assumption the last pass ran from.
      #
      # A loop nested in another loop's body shares the outer table: the outer scan already listed every site of the
      # inner body, and the outer join reads what the inner loop leaves there ({.argument_scopes}).
      class Pass
        attr_reader :scopes
        attr_accessor :entry

        # `stores` is `{ name => [site, ...] }`; `shared` is an enclosing loop's table, or nil.
        def initialize(stores, shared)
          @scopes = shared || {}.compare_by_identity
          stores.each_value { |sites| sites.each { |site| @scopes[site] = nil unless @scopes.key?(site) } }
          @entry = nil
        end
      end

      EMPTY = {}.freeze
      private_constant :EMPTY

      module_function

      # `{ name => [site, ...] }` for the nodes under `statements` the block answers `[name, site]` for (it answers
      # a nil name for any other node); the frozen empty table for a body with none.
      def scan(statements)
        return EMPTY if statements.nil?

        stores = nil
        Source::NodeWalker.each(statements) do |descendant|
          name, site = yield(descendant)
          ((stores ||= {})[name] ||= []) << site unless name.nil?
        end
        stores || EMPTY
      end

      # `{ site => scope }`: for each store the fixpoint's last pass reached, `post_loop` with every local the loop
      # rebinds (`converged`'s names) at the binding that pass reached the store with ({.binding}). A store the pass
      # did not reach as a statement — dead under its assumption, or nested in an expression the statement walk hands
      # to the expression typer — has no entry, and the join keeps `post_loop` for it. `pass` is nil for a body with
      # no store.
      #
      # Each scope is also left in the pass's table, so an enclosing loop's join reads this loop's locals as settled
      # here, not at the raw pass binding.
      def argument_scopes(stores, pass, post_loop, converged, body_first)
        return EMPTY if pass.nil?

        capped = pass.entry != converged
        table = pass.scopes
        stores.each_value.with_object({}.compare_by_identity) do |sites, scopes|
          sites.each do |site|
            reached = table[site]
            next if reached.nil?

            argument_scope = converged.each_key.reduce(post_loop) do |acc, name|
              type = binding(name, reached, post_loop, capped: capped, first_in_body: body_first.include?(name),
                                                       mutated: stores.key?(name))
              type.nil? ? acc : acc.with_local(name, type)
            end
            table[site] = argument_scope
            scopes[site] = argument_scope unless argument_scope.equal?(post_loop)
          end
        end
      end

      # The type a store's arguments read the rebound local `name` at, given `reached`, the scope the fixpoint's
      # last pass reached the store with; nil to keep the continuation binding `post_loop` holds.
      #
      # - The continuation binding stays when the pass did not bind the name as a local at the store (an instance
      #   variable the fixpoint tracks never is one), and when the fixpoint floored it to `Dynamic[top]`: a precise
      #   arm in its place would read as knowledge the analysis lacks (`v = "a" if i > 1; out << v`, where `v`
      #   first moves on the capped pass).
      # - A capped fixpoint's last pass ran from an assumption the cap then widened, so the binding it reached the
      #   store with is widened the same way (`n = i; out << n` is `Integer`, not the `0 | 1 | 2` of the pass).
      #   {BodyFixpoint} moves a name on that pass to its value-pinned widening or to the `Dynamic[top]` floor
      #   above, and nowhere else.
      # - A body-first local is not fed back into the next pass (`StatementEvaluator#loop_body_exit_bindings`), so
      #   where the pass reaches the store with a `nil` — a path that skips this iteration's assignment — an earlier
      #   iteration's value may be what is stored (`c = 1 if x; out << c; c = "s"` pushes `"s"`): the continuation
      #   binding joins in.
      # - A local the body also mutates in place is stored as an object the body may go on mutating (`rows << row;
      #   row << 2`), so the non-nil part of its continuation binding joins in.
      def binding(name, reached, post_loop, capped:, first_in_body:, mutated:)
        at_store = reached.local(name)
        settled = post_loop.local(name)
        return nil if at_store.nil? || settled.nil? || Type::Combinator.untyped?(settled)

        at_store = Type::Combinator.widen_value_pinned(at_store) if capped
        joined = join(at_store, settled, first_in_body, mutated)
        joined == settled ? nil : joined
      end

      # `at_store` with the part of the continuation binding `settled` a store may also hold ({.binding}'s last two
      # cases).
      def join(at_store, settled, first_in_body, mutated)
        if first_in_body && Narrowing.narrow_non_nil(at_store) != at_store
          Type::Combinator.union(at_store, settled)
        elsif mutated
          Type::Combinator.union(at_store, Narrowing.narrow_non_nil(settled))
        else
          at_store
        end
      end
    end
  end
end
