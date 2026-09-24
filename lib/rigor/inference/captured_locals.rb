# frozen_string_literal: true

require "prism"

require_relative "../source/node_walker"
require_relative "block_parameter_binder"
require_relative "element_read_widening"
require_relative "index_write_widening"
require_relative "mutation_widening"
require_relative "receiver_alias"
require_relative "unknown_store_widening"

module Rigor
  module Inference
    # The outer locals a block body can REBIND — the one name set that ADR-56's captured-local write-back
    # (`StatementEvaluator#write_back_block_captures`), the escaping-block narrowing drop
    # (`StatementEvaluator#drop_captured_narrowing`) and issue #587's per-element fold
    # (`ExpressionTyper#per_element_captured_bindings`) all key on. It lives in one place so the four
    # cannot disagree about what "captured" means.
    #
    # A write counts across every local-write form — plain `=` (`LocalVariableWriteNode`), the operator /
    # `||=` / `&&=` compound forms, and a multi-assign target (`x, y = …` → `LocalVariableTargetNode` under
    # a `MultiWriteNode`) — at ANY depth: a block is a closure, so a write inside a nested block binds the
    # same outer variable. Block-introduced names (parameters, numbered parameters, `;`-locals), names
    # not bound in the outer scope, a write a nested block's own parameter or block-local shadows, and a
    # write inside a nested `def` or class body ({.outer_local?}) are excluded; a write to any of them is
    # not a captured rebind of an outer variable.
    #
    # All three also ask for the instance variables the body rebinds (`ivars: true`). The per-element fold asks
    # for every other binding that outlives an iteration as well (`non_locals: true`): the class variables and
    # globals the body rebinds, and the instance variable behind an attribute setter it calls on `self`. Names
    # keep their sigil, so a map over every kind never collides, and {.bound_type} / {.bind} reach each name
    # through its own kind of binding.
    #
    # {.content_mutations} is the sibling set on the same terms: the captured outer locals the body mutates
    # IN PLACE rather than rebinds, which the rebind set cannot see and the per-element fold needs as well.
    module CapturedLocals
      LOCAL_WRITE_NODES = Set[
        Prism::LocalVariableWriteNode,
        Prism::LocalVariableOperatorWriteNode,
        Prism::LocalVariableOrWriteNode,
        Prism::LocalVariableAndWriteNode,
        Prism::LocalVariableTargetNode
      ].freeze

      # The write forms of the bindings other than locals that outlive an iteration: instance variables, class
      # variables and globals.
      NON_LOCAL_WRITE_NODES = Set[
        Prism::InstanceVariableWriteNode,
        Prism::InstanceVariableOperatorWriteNode,
        Prism::InstanceVariableOrWriteNode,
        Prism::InstanceVariableAndWriteNode,
        Prism::InstanceVariableTargetNode,
        Prism::ClassVariableWriteNode,
        Prism::ClassVariableOperatorWriteNode,
        Prism::ClassVariableOrWriteNode,
        Prism::ClassVariableAndWriteNode,
        Prism::ClassVariableTargetNode,
        Prism::GlobalVariableWriteNode,
        Prism::GlobalVariableOperatorWriteNode,
        Prism::GlobalVariableOrWriteNode,
        Prism::GlobalVariableAndWriteNode,
        Prism::GlobalVariableTargetNode
      ].freeze

      # The call forms that invoke an attribute setter: `self.w = v`, the compound `self.w += v` / `||=` / `&&=`,
      # and a multi-assign target `self.w, x = …`.
      SETTER_CALL_NODES = Set[
        Prism::CallNode, Prism::CallOperatorWriteNode, Prism::CallOrWriteNode, Prism::CallAndWriteNode,
        Prism::CallTargetNode
      ].freeze
      private_constant :SETTER_CALL_NODES

      # An attribute writer's name: an identifier followed by `=`. `==`, `!=`, `<=`, `>=`, `===` and `[]=` are
      # not setters.
      SETTER_NAME = /\A[A-Za-z_]\w*=\z/
      private_constant :SETTER_NAME

      # The binding the per-element fold lays under a block's parameters: each name's type across iterations, and
      # the optimistic nil-freeness mark an iteration's own rebind gave it, which {.bind} adds to the one the
      # call site already holds — as `Scope#join` unions the marks of the scopes it joins. `repeated` is the
      # `RepeatedOrWrites::Marks` of the index `||=` sites whose slot an earlier run may have filled, marked on the
      # same scope: those of the per-element fold's `position`, or every site when no position is given.
      Bindings = Data.define(:types, :marks, :repeated) do
        def names = types.keys

        def lay(scope, position: nil)
          bound = types.reduce(scope) do |acc, (name, type)|
            CapturedLocals.bind(acc, name, type, optimistic: marks[name])
          end
          bound.with_repeated_or_writes(repeated.at(position))
        end
      end

      # The empty answers, shared: every block-bearing call's return pass asks both questions, and nearly every
      # body answers nothing to either.
      NO_NAMES = [].freeze
      NO_SITES = {}.freeze
      private_constant :NO_NAMES, :NO_SITES

      module_function

      # @param base_scope — the call-site scope the block closes over.
      # @param ivars — also collect the instance variables the body rebinds. An ivar is not captured — the
      #   block shares the caller's `self` — but it outlives an iteration, and the call, exactly as a captured
      #   local does. It counts on the same terms as a local (every write form, any depth, bound in
      #   `base_scope`), except that one still on its class-wide binding does not: ADR-58's declaration seed is
      #   the union of every write in the class, this body's included, so nothing the body stores can move it,
      #   and rebinding it would only drop the declaration mark that keeps its nil from being diagnostic fuel.
      #   A nested block that rebinds `self` (`o.instance_eval`) writes another object's ivar, and a nested
      #   `def` runs only when called; both still count, because an `instance_eval` without a receiver, or a
      #   call to that `def` inside the body, does write this one.
      # @param non_locals — the per-element fold's superset of `ivars`: the class variables and globals the body
      #   rebinds count too, on the same terms, and so does an attribute setter called on `self` (`self.w = v`)
      #   as a rebind of the instance variable it is named after, `@w`: the `attr_writer` / `attr_accessor`
      #   convention stores there, and no write node shows it. A hand-written setter storing elsewhere is not
      #   seen.
      # @return the captured names the body writes, each once, in first-write order.
      def writes(block_node, base_scope, ivars: false, non_locals: false)
        body = block_node.body
        return NO_NAMES if body.nil?

        introduced = nil
        names = nil
        outliving = non_locals || ivars
        Source::NodeWalker.each_with_ancestors(body) do |descendant, ancestors|
          name =
            if LOCAL_WRITE_NODES.include?(descendant.class)
              captured_local_write(descendant, ancestors, base_scope) { introduced ||= introduced_locals(block_node) }
            elsif outliving
              rebindable_outliving_write(descendant, base_scope, non_locals)
            end
          (names ||= []) << name if name
        end
        names ? names.uniq : NO_NAMES
      end

      def rebindable_outliving_write(node, base_scope, non_locals)
        name = outliving_write_name(node, non_locals)
        name if name && rebindable_non_local?(base_scope, name)
      end

      # The outer local a local-write node rebinds, or nil when the call site does not bind it, the write resolves
      # inside a nested block or `def` ({.outer_local?}), or the block introduces it (the block yields the
      # introduced set, computed only when needed).
      def captured_local_write(node, ancestors, base_scope)
        name = node.name
        return nil unless base_scope.locals.key?(name) && outer_local?(node, ancestors)

        yield.include?(name) ? nil : name
      end

      # The non-local `node` rebinds under `non_locals:` — or, without it, the instance variable only.
      def outliving_write_name(node, non_locals)
        name = non_local_write_name(node)
        non_locals || (name && ivar_name?(name) && NON_LOCAL_WRITE_NODES.include?(node.class)) ? name : nil
      end

      # The instance, class or global variable `node` rebinds, or nil when it rebinds none of them.
      def non_local_write_name(node)
        return node.name if NON_LOCAL_WRITE_NODES.include?(node.class)

        setter_ivar_name(node)
      end

      # `@w` for an attribute setter called on `self` (`self.w = …` and its compound and target forms), else nil.
      def setter_ivar_name(node)
        return nil unless SETTER_CALL_NODES.include?(node.class) && node.receiver.is_a?(Prism::SelfNode)

        setter = node.respond_to?(:write_name) ? node.write_name : node.name
        return nil unless SETTER_NAME.match?(setter)

        :"@#{setter.to_s.delete_suffix('=')}"
      end

      def rebindable_non_local?(scope, name)
        variable_kind(name) == :ivar ? rebindable_ivar?(scope, name) : !bound_type(scope, name).nil?
      end

      def rebindable_ivar?(scope, name)
        !scope.ivar(name).nil? && !scope.declaration_sourced?(:ivar, name)
      end

      # The binding `scope` holds for a name from {.writes}.
      def bound_type(scope, name)
        case variable_kind(name)
        when :ivar then scope.ivar(name)
        when :cvar then scope.cvar(name)
        when :global then scope.global(name)
        else scope.local(name)
        end
      end

      # `scope` with a name from {.writes} bound to `type`, keeping the name's optimistic nil-freeness mark
      # (issue #286). `Scope#with_local` / `#with_ivar` drop it as a fresh write should, but here `type`
      # stands for the binding across iterations, and a value that was nil-free only optimistically still is:
      # without the mark `x.nil?` folds to `false` where the runtime answers `true`. `optimistic` is a mark the
      # binding carries besides the one `scope` already holds — one an iteration's own rebind made. Class
      # variables and globals carry no mark.
      def bind(scope, name, type, optimistic: nil)
        case variable_kind(name)
        when :ivar
          scope.with_ivar(name, type).with_optimistic_ivar(name, scope.optimistic_ivar(name) || optimistic)
        when :cvar then scope.with_cvar(name, type)
        when :global then scope.with_global(name, type)
        else
          scope.with_local(name, type).with_optimistic_local(name, scope.optimistic_local(name) || optimistic)
        end
      end

      # The optimistic nil-freeness mark `scope` holds for a name from {.writes}, or nil.
      def optimistic_mark(scope, name)
        case variable_kind(name)
        when :ivar then scope.optimistic_ivar(name)
        when :local then scope.optimistic_local(name)
        end
      end

      def ivar_name?(name) = variable_kind(name) == :ivar

      # Ruby spells a global with a leading `$`, a class variable with `@@`, an instance variable with a single
      # `@`, and a local with none of them.
      def variable_kind(name)
        if name.start_with?("$") then :global
        elsif name.start_with?("@@") then :cvar
        elsif name.start_with?("@") then :ivar
        else :local
        end
      end

      # The nodes that change a receiver's CONTENT without rebinding it: a call to a name the straight-line
      # widening responds to ({MutationWidening::SHAPE_MUTATORS}), and the index writes that store through
      # `[]=` without being a `[]=` call ({IndexWriteWidening::CONTENT_WRITE_NODE_CLASSES}, the one list the
      # block-return threading gate and the captured-local write-back read too).
      INDEX_STORE_NODES = IndexWriteWidening::CONTENT_WRITE_NODE_CLASSES
      private_constant :INDEX_STORE_NODES

      # The captured outer locals the body mutates in place, each mapped to its mutation sites (the nodes
      # above) in source order. A site counts through every variable its receiver can evaluate to
      # ({ReceiverAlias.candidates}), at any nesting depth as long as a local's read does not resolve inside a nested
      # block ({.outer_local?}), and a local is excluded on exactly the terms {.writes} excludes it.
      #
      # Under `non_locals: true` the instance variables, class variables and globals the body mutates in place
      # count too, on the terms {.writes} takes a rebound one ({.rebindable_non_local?}). Since the block-return
      # threading gate threads an index write, `@cache[:first] ||= e; @cache[:first] == 2` would otherwise type
      # every position from the empty entry hash, store THAT position's `e`, and fold `find` to `2` where Ruby,
      # keeping the first iteration's `1`, answers `nil`; `$seen << x; n == 1` after `n = $seen.size` folded
      # `find` to `nil` the same way. A class variable or global counts only as the receiver itself (parentheses
      # aside), not through a branch that selects it.
      #
      # A local also counts through the two routes straight-line code widens it by without reading it as the
      # receiver. A mutator on an element read rooted at it (`a[0] << e`, the local {ElementReadWidening}
      # widens) is a site of that local. A self-call whose callee content-mutates the parameter a local is passed
      # to (`add_to(a, e)`, the local `StatementEvaluator#content_mutated_arguments` reports) is a
      # {UnknownStoreWidening::CalleeStore} site of it. Both were invisible here, so every position of the fold
      # read the local at its entry contents: `a = [[1]]; [1, 2].map { |e| v = a[0].size; a[0] << e; v }`
      # folded to `[1, 1]` where Ruby answers `[1, 2]`.
      #
      # @param base_scope — the call-site scope the block closes over.
      # @param non_locals — also collect the instance variables, class variables and globals the body mutates
      #   in place.
      # @return `{ name => [site, ...] }`, empty for the overwhelmingly common body that mutates nothing
      #   captured.
      def content_mutations(block_node, base_scope, non_locals: false)
        body = block_node.body
        return NO_SITES if body.nil?

        introduced = nil
        sites = nil
        evaluator = nil
        Source::NodeWalker.each_with_ancestors(body) do |descendant, ancestors|
          # A callee is resolved in the call-site scope, as the straight-line callee floor resolves it.
          site = mutation_site(descendant) { evaluator ||= StatementEvaluator.new(scope: base_scope) }
          next if site.nil?

          site_reads(site).each do |read|
            next unless captured_target?(read, ancestors, base_scope, non_locals) do
              introduced ||= introduced_locals(block_node)
            end

            ((sites ||= {})[read.name] ||= []) << site
          end
        end
        sites || NO_SITES
      end

      # The mutation site `node` is — the node itself, or a {UnknownStoreWidening::CalleeStore} for a self-call
      # whose callee content-mutates a local it is passed — or nil. A self-call is resolved by the
      # `StatementEvaluator` the block yields, which the caller builds only when one is needed. A mutator name
      # called on `self` (`self.store(h, k)`, `self.push(a, x)`) names no variable as its receiver, so it is asked
      # as a self-call, as the straight-line callee floor asks it.
      def mutation_site(node)
        receiver = mutated_receiver(node)
        return node if receiver && !receiver.is_a?(Prism::SelfNode)
        return nil unless callee_call?(node)

        arguments = yield.content_mutated_arguments(node)
        arguments.empty? ? nil : UnknownStoreWidening::CalleeStore.new(node, arguments)
      end

      # The variable reads a mutation site reaches: a callee store's arguments, the local an element read is
      # rooted at, or else {ReceiverAlias.mutated_reads} of the receiver.
      def site_reads(site)
        return site.arguments if site.is_a?(UnknownStoreWidening::CalleeStore)

        receiver = mutated_receiver(site)
        path = ElementReadWidening.element_read_path(receiver)
        path ? [path.first] : ReceiverAlias.mutated_reads(receiver)
      end

      # A call to a method on `self` (implicit or explicit) that passes a local as an argument — the only kind
      # the callee floor can report a site for, so the only kind worth resolving.
      def callee_call?(node)
        return false unless node.is_a?(Prism::CallNode)
        return false unless node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode)

        arguments = node.arguments&.arguments
        !arguments.nil? && arguments.any?(Prism::LocalVariableReadNode)
      end

      # True when `read` names a variable {.content_mutations} collects: a {.content_target?} which, when it is a
      # local, does not resolve inside a nested block and is not one the block introduces (the block yields that set,
      # computed only when needed). An `it` read is never one: it is the parameter of the innermost block around
      # it, so the body's own `it` is introduced and a nested block's `it` is that block's.
      def captured_target?(read, ancestors, base_scope, non_locals)
        return false if read.is_a?(Prism::ItLocalVariableReadNode)
        return false unless content_target?(read, base_scope, non_locals)
        return true unless read.is_a?(Prism::LocalVariableReadNode)

        outer_local?(read, ancestors) && !yield.include?(read.name)
      end

      # A local bound at the call site (the block's own names are excluded by the caller), or — under
      # `non_locals:` — an instance variable, class variable or global {.rebindable_non_local?} accepts.
      def content_target?(read, base_scope, non_locals)
        return base_scope.locals.key?(read.name) if read.is_a?(Prism::LocalVariableReadNode)

        non_locals && rebindable_non_local?(base_scope, read.name)
      end

      # False when a local read or write resolves inside a scope nested between the body and `node`. Prism resolves a
      # name in a nested block's own scope first, so `[[9]].each { |a| a << x }` mutates, and `[[9]].each { |a| a =
      # x }` rebinds, that block's parameter, not the outer local that happens to share its name: its `depth` stops
      # short of the body's own scope. A `def`, `class`, `module` or `class << self` body opens a scope of its own
      # that sees no outer local at all, so `def helper; z = 5; end` writes the method's `z` — but only its body,
      # and a `def`'s parameters, are that scope: a `def (o = x).m` receiver, a `class Foo < (s = x)` superclass or
      # a `class << (t = x)` target runs in the enclosing one and is left to the depth test. {.writes} and
      # {.content_mutations} both ask it, so the two sets cannot disagree about which `a` a site names. A name
      # resolving in the body's own scope is left to the block-introduced exclusion: Prism puts an outer local there
      # only when the parse never saw it declared, which a synthetic call-site scope can still bind.
      def outer_local?(node, ancestors)
        nesting = 0
        ancestors.each_with_index do |ancestor, index|
          return false if hard_scope_entered?(ancestor, ancestors[index + 1] || node)

          nesting += 1 if NESTED_SCOPE_NODES.include?(ancestor.class)
        end
        node.depth >= nesting
      end

      # True when `child`, the next node on the path, is inside the scope `ancestor` opens.
      def hard_scope_entered?(ancestor, child)
        case ancestor
        when Prism::DefNode then child.equal?(ancestor.body) || child.equal?(ancestor.parameters)
        when Prism::ClassNode, Prism::ModuleNode, Prism::SingletonClassNode then child.equal?(ancestor.body)
        else false
        end
      end

      NESTED_SCOPE_NODES = Set[Prism::BlockNode, Prism::LambdaNode].freeze
      private_constant :NESTED_SCOPE_NODES

      def mutated_receiver(node)
        case node
        when Prism::CallNode then node.receiver if MutationWidening::SHAPE_MUTATORS.include?(node.name)
        when *INDEX_STORE_NODES then node.receiver
        end
      end

      # Names the block itself introduces: parameters (numbered parameters included, via
      # `BlockParameterBinder`) plus the explicit `;`-prefixed block-locals on `BlockParametersNode`.
      def introduced_locals(block_node)
        introduced = Set.new(BlockParameterBinder.new.bind(block_node).keys)
        params_root = block_node.parameters
        params_root.locals.each { |loc| introduced << loc.name } if params_root.is_a?(Prism::BlockParametersNode)
        introduced
      end
    end
  end
end
