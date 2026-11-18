# frozen_string_literal: true

require_relative "../type"
require_relative "../source/node_walker"
require_relative "captured_locals"
require_relative "jump_targets"
require_relative "narrowing"

module Rigor
  module Inference
    # Issue #3337, ADR-56 WD2.14 — the scope a `while` / `until` loop's content join types each store's arguments
    # in. The join's own scope, `post_loop`, reads a local the loop rebinds at its continuation binding: the join of
    # the pre-loop binding and the body's EXIT binding. A local first assigned in the body carries the `nil` its
    # zero-iteration seed gives it, though the store never ran on that path (`s = f; out << s` read
    # `Array[String?]` and drew `call.possible-nil-receiver` on correct code), and a local rebound after the store
    # carries a value the store never held (`out << s; s = nil` read `Array[nil]`).
    #
    # `StatementEvaluator#evaluate` leaves the scope it enters each store site with in a {Pass}'s table while the
    # loop's rebind fixpoint runs, and {.argument_scopes} overlays each rebound local's binding there on
    # `post_loop`. No body pass is added.
    #
    # The binding at the store REPLACES the continuation binding only where every execution of the store is known
    # to follow an assignment of the local in the same iteration ({Sites#assigned}). Everywhere else it is JOINED
    # with the continuation binding, so the answer holds every class the continuation binding holds.
    module LoopStoreSites
      # A body's stores. `stores` is `{ name => [site, ...] }` for every content mutation whose receiver is a local,
      # which the join reads. `assigned` is identity-keyed `{ site => [name, ...] }` for the sites the overlay
      # may type: the locals each one is reached with freshly assigned ({LoopStoreSites.assigned_before}). A site
      # that is not a key keeps the join's own scope ({LoopStoreSites.overlaid?}).
      Sites = Struct.new(:stores, :assigned)

      NONE = Sites.new({}.freeze, {}.compare_by_identity.freeze).freeze
      EMPTY = {}.freeze
      NO_NAMES = [].freeze
      private_constant :EMPTY, :NO_NAMES

      # What the rebind fixpoint's passes leave: `scopes`, the identity-keyed table of each overlaid store site's
      # scope, and `entry`, a copy of the assumption the last pass ran from.
      #
      # A loop nested in another loop's body shares the outer table: every site the inner loop overlays is one the
      # outer loop overlays too, and the outer join reads what the inner loop leaves there ({.argument_scopes}).
      class Pass
        attr_reader :scopes, :entry

        # `shared` is an enclosing loop's table, or nil.
        def initialize(sites, shared)
          @sites = sites.assigned
          @scopes = shared || {}.compare_by_identity
          @entry = nil
        end

        # Starts a fixpoint pass from `bindings`: a site the pass does not reach has no scope afterwards.
        def start(bindings)
          @entry = bindings.dup
          @sites.each_key { |site| @scopes[site] = nil }
        end
      end

      # The constructs {JumpTargets.boundary?} names that a store may still sit under: a nested loop of the seam's
      # own kind, whose rebind fixpoint settles the locals it rebinds. Every other one keeps a store on the join's
      # own scope. A block or lambda body runs at another time than the statement walk reaches it, or more often
      # (`saved = proc { out << s }` stores what `s` holds when it is called). A `for` body has no rebind fixpoint.
      # A method, class or module body has locals of its own, and a same-named one there is not the loop's (`s =
      # "a"; class Foo; s = 5; o = []; o << s; end`).
      SETTLING_LOOPS = [Prism::WhileNode, Prism::UntilNode].freeze
      # A rescue or `ensure` clause runs from any point of the body it guards, and the check path records such a
      # clause under a widened entry the display path does not use (issue #1231): a store typed there would answer
      # differently per path.
      CLAUSE_NODES = [Prism::RescueNode, Prism::EnsureNode, Prism::RescueModifierNode].freeze
      private_constant :SETTLING_LOOPS, :CLAUSE_NODES

      module_function

      # The {Sites} of a loop body: the block answers `[name, site]` for a node that is a store and a nil name for
      # any other.
      def scan(statements)
        return NONE if statements.nil?

        stores = nil
        assigned = nil
        Source::NodeWalker.each_with_ancestors(statements) do |descendant, ancestors|
          name, site = yield(descendant)
          next if name.nil?

          ((stores ||= {})[name] ||= []) << site
          (assigned ||= {}.compare_by_identity)[site] = assigned_before(site, ancestors) if overlaid?(ancestors)
        end
        stores.nil? ? NONE : Sites.new(stores, assigned || NONE.assigned)
      end

      # True when a store under `ancestors` (the loop body first) runs when the statement walk reaches it, once per
      # iteration of the loops it is nested in, and from the scope that walk holds on every path.
      def overlaid?(ancestors)
        ancestors.none? do |ancestor|
          CLAUSE_NODES.include?(ancestor.class) ||
            (JumpTargets.boundary?(ancestor) && !SETTLING_LOOPS.include?(ancestor.class))
        end
      end

      # True when a store under `ancestors` is in a `begin` with a rescue or `ensure` clause. Its body runs again
      # on `retry`, after its own later statements, so no assignment is one the store is known to follow.
      def guarded?(ancestors)
        ancestors.any? do |ancestor|
          ancestor.is_a?(Prism::BeginNode) && !(ancestor.rescue_clause.nil? && ancestor.ensure_clause.nil?)
        end
      end

      # The locals every execution of `site` follows an assignment of, in the same iteration: those a plain
      # `name = value` statement assigns earlier in a statement list on the way down to the site. Such a statement
      # always runs before the later statements of its list, and nothing on the way is a body that runs later or again
      # ({.overlaid?}), so the local holds at the store what this iteration gave it, never what an earlier
      # iteration left. A conditional write, a multiple assignment and a write nested in an expression do not count.
      def assigned_before(site, ancestors)
        return NO_NAMES if guarded?(ancestors)

        names = nil
        ancestors.each_with_index do |ancestor, depth|
          next unless ancestor.is_a?(Prism::StatementsNode)

          on_path = ancestors[depth + 1] || site
          ancestor.body.each do |statement|
            break if statement.equal?(on_path)

            (names ||= []) << statement.name if statement.is_a?(Prism::LocalVariableWriteNode)
          end
        end
        names || NO_NAMES
      end

      # `{ site => scope }`: for each overlaid store the fixpoint's last pass reached, `post_loop` with every local
      # the loop rebinds (`converged`'s names) at {.binding}. A store that pass did not reach as a statement — dead
      # under its assumption, or nested in an expression the statement walk hands to the expression typer — has no
      # entry, and the join keeps `post_loop` for it. `pass` is nil for a body with no store.
      #
      # Each scope is also left in the pass's table, so an enclosing loop's join reads this loop's locals as settled
      # here, not at the raw pass binding.
      def argument_scopes(sites, pass, post_loop, converged)
        return EMPTY if pass.nil?

        capped = pass.entry != converged
        table = pass.scopes
        closures = closure_written(post_loop) if sites.assigned.each_value.any? { |names| !names.empty? }
        sites.assigned.each_with_object({}.compare_by_identity) do |(site, assigned), scopes|
          reached = table[site]
          next if reached.nil?

          follows = closures.nil? ? NO_NAMES : assigned - closures
          argument_scope = argument_scope(reached, post_loop, converged, sites.stores, capped, follows)
          table[site] = argument_scope
          scopes[site] = argument_scope unless argument_scope.equal?(post_loop)
        end
      end

      # `post_loop` with each of `converged`'s names at its {.binding} for a store reached with the scope `reached`.
      # `follows` holds the locals the store is known to follow an assignment of.
      def argument_scope(reached, post_loop, converged, stores, capped, follows)
        converged.each_key.reduce(post_loop) do |acc, name|
          type = binding(name, reached, post_loop, capped: capped, assigned: follows.include?(name),
                                                   mutated: stores.key?(name))
          type.nil? ? acc : acc.with_local(name, type)
        end
      end

      # The locals a block or lambda writes anywhere in the frame `scope` runs in — a method body with its
      # parameters, or a class, module or file body: every local write whose `depth` is positive, which is one that
      # reaches a variable of an enclosing scope. Such a closure may run between an assignment and a store that
      # follows it (`pr = proc { s = nil }; s = "a"; pr.call; out << s` stores `nil`), and the walk does not model
      # the write at the call, so no assignment of such a local is one a store is known to follow. Where the closure
      # sits does not matter: one made after the loop is counted too, which only costs precision. Nil when the scope
      # carries no frame, where the frame's other closures cannot be seen, and when the frame holds a call that can
      # write any local by name ({.reflective_write?}).
      def closure_written(scope)
        frame = scope.match_frame
        return nil if frame.nil?

        names = nil
        [frame.body, frame.parameters].each do |root|
          Source::NodeWalker.each(root) do |node|
            return nil if reflective_write?(node)
            next unless CapturedLocals::LOCAL_WRITE_NODES.include?(node.class) && node.depth.positive?

            (names ||= []) << node.name
          end
        end
        names || NO_NAMES
      end

      # Calls that reach a frame's locals by name, whatever the receiver: `binding` and `local_variable_set`, and
      # `eval`; the `*_eval` forms count when given an argument, which may be source text.
      BINDING_CALLS = %i[binding eval local_variable_set].freeze
      STRING_EVAL_CALLS = %i[instance_eval class_eval module_eval].freeze
      private_constant :BINDING_CALLS, :STRING_EVAL_CALLS

      # True for a call through which a local may be rebound without a write node: `s = "a";
      # binding.local_variable_set(:s, nil); out << s` stores `nil`.
      def reflective_write?(node)
        return false unless node.is_a?(Prism::CallNode)

        BINDING_CALLS.include?(node.name) || (STRING_EVAL_CALLS.include?(node.name) && !node.arguments.nil?)
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
      # - A local the store does not follow an assignment of (`assigned` false; so is one a closure writes,
      #   {.closure_written}) may hold what an earlier iteration left, whatever the pass narrowed it to: `c = "x" if
      #   a; out << c if c; c = 5 if b` stores `5`. The continuation binding joins in whole.
      # - A local the body also mutates in place is stored as an object the body may go on mutating (`rows << row;
      #   row << 2`), so the non-nil part of its continuation binding joins in.
      def binding(name, reached, post_loop, capped:, assigned:, mutated:)
        at_store = reached.local(name)
        settled = post_loop.local(name)
        return nil if at_store.nil? || settled.nil? || Type::Combinator.untyped?(settled)

        at_store = Type::Combinator.widen_value_pinned(at_store) if capped
        joined = join(at_store, settled, assigned, mutated)
        joined == settled ? nil : joined
      end

      # `at_store` with the part of the continuation binding `settled` a store may also hold ({.binding}'s last two
      # cases).
      def join(at_store, settled, assigned, mutated)
        if !assigned
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
