# frozen_string_literal: true

require "prism"

require_relative "../run_scoped_slots"
require_relative "closure_escape_analyzer"
require_relative "construction_escape"

module Rigor
  module Inference
    # Issue #2608, review rounds 1 and 2 of #2621 — which locals of a body another holder may write, so a remover on
    # them is not narrowed ({RemoverNarrowing}): a narrowing is a fact about the object, and a write through any other
    # holder after the call would outlive it. One flow-insensitive scan per frame body; a local is a holder's when:
    #
    # - a closure that may run later references it: a lambda, or a block passed to a call that is not a catalogued
    #   iterator or `tap` / `then` / `yield_self` (`proc { l << 1 }`), created before or after the remover;
    # - it is read anywhere inside the value of any write (local, instance, class, global or constant variable, an
    #   index or attribute write, an operator or `||=` / `&&=` write, a multiple assignment) or inside the subject of a
    #   `case`/`in`, `=>` or `in` pattern: `al = c ? l : []`, `al = l.push(1)`, `@k = l`, `case l; in al`. The local
    #   such a write or pattern binds is a holder too (both names of a copy), unless the write's value is a fresh
    #   object: an Array or Hash literal, or `new` / `[]` on a bare or top-level `Array`, `Hash` or `Set`
    #   (`a = Array.new(n, "a")`);
    # - a method's parameter, when its body has a zero-argument `super`, which passes every parameter on;
    # - it is read inside an Array element, a Hash key or value, a splat, or an argument of any call, `yield` or
    #   `super` (positional, keyword, splat or block-pass), unless the read is the receiver of a call that answers
    #   a value other than the receiver and keeps no reference to it ({PURE_READERS}: #2555's per-class
    #   `ConstructionEscape::READERS`, less the conversions that return self on another class): `puts(l.size)`,
    #   `dump_type(l.dup)` and `dump_type(l.first)` hold nothing, `Keep.new(l)` and `foo(l.push(1))` do;
    # - it receives a reflective call (`l.send(...)`, `l.instance_eval { }`, `l.tap { }`);
    # - and every local, when the body calls `binding`, `eval`, `local_variable_get` or `local_variable_set` on any
    #   receiver (`-> {}.binding`), or a receiverless `instance_variable_set`.
    #
    # A receiver position, a `return` and a body's last expression hand nothing on.
    module RemoverHolderScan
      REFLECTIVE_CALLS = %i[
        send public_send __send__ instance_eval instance_exec tap then yield_self itself method
        define_singleton_method
      ].to_set.freeze
      # A conversion one class lists as a reader returns the receiver itself on another (`Array#to_a`, `Hash#to_h`,
      # `Set#to_set`), so the union of the per-class lists leaves them out.
      SELF_CONVERSIONS = %i[to_a to_h to_set].freeze
      PURE_READERS = (ConstructionEscape::READERS.values.reduce(:|) - SELF_CONVERSIONS).freeze
      IMMEDIATE_BLOCK_CALLS = %i[tap then yield_self].to_set.freeze
      FRAME_CALLS = %i[binding eval local_variable_get local_variable_set instance_variable_set].to_set.freeze
      # Frame calls that reach the locals whatever their receiver (`pr.binding`, `Kernel.eval`).
      ANY_RECEIVER_FRAME_CALLS = %i[binding eval local_variable_get local_variable_set].to_set.freeze
      NON_WRITER_OPERATORS = %i[== != <= >= ===].to_set.freeze
      CORE_COLLECTIONS = %i[Array Hash Set].to_set.freeze
      LOCAL_REFERENCES = [
        Prism::LocalVariableReadNode, Prism::LocalVariableWriteNode, Prism::LocalVariableOperatorWriteNode,
        Prism::LocalVariableOrWriteNode, Prism::LocalVariableAndWriteNode, Prism::LocalVariableTargetNode
      ].freeze
      LOCAL_WRITES = [
        Prism::LocalVariableWriteNode, Prism::LocalVariableOperatorWriteNode, Prism::LocalVariableOrWriteNode,
        Prism::LocalVariableAndWriteNode
      ].freeze
      ALL = :all
      # A run-scoped slot ({RunScopedSlots}): emptied when a run ends, so no verdict outlives the body it read.
      UNSAFE_CACHE_KEY = RunScopedSlots.register(:__rigor_remover_narrowing_unsafe)
      private_constant :REFLECTIVE_CALLS, :SELF_CONVERSIONS, :PURE_READERS, :IMMEDIATE_BLOCK_CALLS, :FRAME_CALLS,
                       :ANY_RECEIVER_FRAME_CALLS, :NON_WRITER_OPERATORS, :CORE_COLLECTIONS,
                       :LOCAL_REFERENCES, :LOCAL_WRITES, :ALL, :UNSAFE_CACHE_KEY

      module_function

      # Whether the local `name` may be written through another holder somewhere in the body `scope` runs. A scope
      # with no known body answers true.
      def unsafe_receiver?(scope, name)
        frame = scope.match_frame
        body = frame&.body
        return true if body.nil?

        table = (Thread.current[UNSAFE_CACHE_KEY] ||= ObjectSpace::WeakKeyMap.new)
        names = table[body] ||= unsafe_names(body, frame.parameters)
        names.equal?(ALL) || names.include?(name.to_sym)
      end

      # `names` collects the locals; a collector that answers `site=` ({AliasMutationFloor}) is told, before each name
      # it is given, the node that hands the local on, or nil when no single node does (a capture by a closure that may
      # run later, a zero-argument `super`). One that answers `keeps_arguments?` says which calls' plain arguments it
      # counts as held.
      def unsafe_names(body, parameters = nil, names = Set.new)
        sited = names.respond_to?(:site=)
        catch(ALL) do
          collect_unsafe(body, false, names, sited:)
          names.site = nil if sited
          parameter_names(parameters, names) if forwards_parameters?(body)
          return names.freeze
        end
        ALL
      end

      def collect_unsafe(node, in_closure, names, sited: false)
        in_closure ||= node.is_a?(Prism::LambdaNode)
        names.site = in_closure ? nil : node if sited
        names << node.name if in_closure && LOCAL_REFERENCES.any? { |k| node.is_a?(k) }
        record_node(node, names)

        node.compact_child_nodes.each do |child|
          child_in_closure = in_closure || (child.is_a?(Prism::BlockNode) && deferred_block?(node))
          collect_unsafe(child, child_in_closure, names, sited:)
        end
      end

      def record_node(node, names) # rubocop:disable Metrics/CyclomaticComplexity
        case node
        when Prism::CallNode then record_call(node, names)
        when Prism::YieldNode, Prism::SuperNode then node.arguments&.arguments&.each { |a| record_held(a, names) }
        when Prism::ArrayNode then node.elements.each { |element| record_held(element, names) }
        when Prism::AssocNode then [node.key, node.value].each { |part| record_held(part, names) }
        when Prism::SplatNode, Prism::BlockArgumentNode then record_held(node.expression, names)
        when Prism::CaseMatchNode then record_pattern(node.predicate, node.conditions, names)
        when Prism::MatchRequiredNode, Prism::MatchPredicateNode then record_pattern(node.value, [node.pattern], names)
        when Prism::MultiWriteNode then record_multi_write(node, names)
        else record_write(node, names)
        end
      end

      def record_call(node, names)
        throw ALL if frame_call?(node)

        receiver = unparenthesised(node.receiver)
        names << receiver.name if receiver.is_a?(Prism::LocalVariableReadNode) && REFLECTIVE_CALLS.include?(node.name)
        arguments = node.arguments&.arguments || []
        if writer_call?(node) && !arguments.empty?
          *keys, value = arguments
          keys.each { |key| record_held(key, names) }
          every_read(value, names)
        elsif keeps_arguments?(node, names)
          arguments.each { |argument| record_held(argument, names) }
        end
      end

      def keeps_arguments?(node, names) = !names.respond_to?(:keeps_arguments?) || names.keeps_arguments?(node)

      # A zero-argument `super` passes every parameter of the method on, implicitly. (A `...` forward passes only the
      # anonymous parameters, which name no local.)
      def forwards_parameters?(node)
        node.is_a?(Prism::ForwardingSuperNode) || node.compact_child_nodes.any? { |child| forwards_parameters?(child) }
      end

      def parameter_names(node, names)
        return if node.nil?

        names << node.name if node.class.name.end_with?("ParameterNode") && node.respond_to?(:name) && node.name
        node.compact_child_nodes.each { |child| parameter_names(child, names) }
      end

      def frame_call?(node)
        ANY_RECEIVER_FRAME_CALLS.include?(node.name) || (node.receiver.nil? && FRAME_CALLS.include?(node.name))
      end

      def unparenthesised(node)
        node = node.body.body.first while node.is_a?(Prism::ParenthesesNode) && node.body&.body&.size == 1
        node
      end

      # An index or attribute write (`h[k] = v`, `o.x = v`, `o&.x = v`): its value is a write's value.
      def writer_call?(node)
        name = node.name
        name.end_with?("=") && !NON_WRITER_OPERATORS.include?(name)
      end

      # A write's value hands on every local read anywhere inside it, and the local it binds holds what it read.
      def record_write(node, names)
        return unless node.class.name.end_with?("WriteNode") && node.respond_to?(:value)
        return unless every_read(node.value, names)

        names << node.name if LOCAL_WRITES.any? { |k| node.is_a?(k) } && !fresh_value?(node.value)
      end

      # `Array`, `Hash` or `Set`, bare or as a top-level path (`::Set`): a project class may define its own `self.[]` or
      # `self.new` that returns its argument.
      def core_collection_constant?(node)
        top_level = node.is_a?(Prism::ConstantReadNode) || (node.is_a?(Prism::ConstantPathNode) && node.parent.nil?)
        top_level && CORE_COLLECTIONS.include?(node.name)
      end

      # A value that is a new object whatever it reads, so the local it binds aliases nothing.
      def fresh_value?(value)
        case value
        when Prism::ArrayNode, Prism::HashNode then true
        when Prism::CallNode then %i[new []].include?(value.name) && core_collection_constant?(value.receiver)
        else false
        end
      end

      def record_multi_write(node, names)
        return unless every_read(node.value, names)

        local_targets([*node.lefts, node.rest, *node.rights], names)
      end

      def record_pattern(subject, patterns, names)
        return unless every_read(subject, names)

        local_targets(patterns, names)
      end

      # Adds every local `node` reads, at any depth; answers whether it read any.
      def every_read(node, names)
        return false if node.nil?

        found = node.is_a?(Prism::LocalVariableReadNode)
        names << node.name if found
        node.compact_child_nodes.reduce(found) { |acc, child| every_read(child, names) || acc }
      end

      def local_targets(nodes, names)
        nodes.compact.each do |node|
          names << node.name if node.is_a?(Prism::LocalVariableTargetNode)
          local_targets(node.compact_child_nodes, names)
        end
      end

      # A held position: every local read inside it but the receiver of a {PURE_READERS} call.
      def record_held(node, names)
        return if node.nil?
        return if pure_read?(node)

        names << node.name if node.is_a?(Prism::LocalVariableReadNode)
        node.compact_child_nodes.each { |child| record_held(child, names) }
      end

      # A {PURE_READERS} call on a local hands the local on to nothing. Its own arguments are held positions of the
      # call itself, which the body walk records when it reaches that call.
      def pure_read?(node)
        node.is_a?(Prism::CallNode) && PURE_READERS.include?(node.name) &&
          node.receiver.is_a?(Prism::LocalVariableReadNode)
      end

      # A block that may run after its call returns: any but a catalogued iterator's, or `tap` / `then` /
      # `yield_self`'s.
      def deferred_block?(call_node)
        return true unless call_node.is_a?(Prism::CallNode)

        !(ClosureEscapeAnalyzer.iterator_name?(call_node.name) || IMMEDIATE_BLOCK_CALLS.include?(call_node.name))
      end
    end
  end
end
