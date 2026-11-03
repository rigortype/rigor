# frozen_string_literal: true

require "prism"

require_relative "../run_scoped_slots"
require_relative "remover_holder_scan"
require_relative "unknown_store_widening"

module Rigor
  module Inference
    # Issue #2335 — a local's literal shape describes its object, and a mutation through another path to that object
    # makes it stale: `y = x; y << "s"`, `a.each { |x| x << "s" }` on an Array holding `inner`, `@a = a; @a << "s"`,
    # `h[:k] = a; h[:k] << "s"`, `Hash.new(a)[:k] << "s"`, `[acc].each { |a| poke(a) }`. The named-binding widening
    # ({MutationWidening.widen_after_call}) and the callee floor only rebind the binding a receiver or argument names,
    # so every other local holding the object kept its literal and a later read reported on correct code.
    #
    # One flow-insensitive scan per frame body answers two sets:
    #
    # - the *aliased* locals: those whose object another holder may reach, which is {RemoverHolderScan}'s set (a copy,
    #   a container element, a call argument, an ivar or index write's value, a capture by a deferred closure, a
    #   reflective receiver; every local under `binding` / `eval`);
    # - the *foreign* locals: those whose object may have come from elsewhere, so they may be one of the aliased
    #   locals' objects: a method, block or lambda parameter, a local any target node binds (a multiple assignment,
    #   a `rescue => e`, a pattern, a `for` index), and a local written from anything but a new object.
    #
    # A receiver is *own* when it is a local in neither set: it names the only binding of its object, and the
    # named-binding path is already complete for it. A mutating call whose receiver is anything else (a foreign or
    # aliased local, a block parameter, an ivar, an index read, a call result) may mutate any aliased local's object,
    # so every aliased local takes the unknown store {UnknownStoreWidening.widen_store} gives a site whose stored
    # values nothing typed: the same widening the named path applies, fed `Dynamic[top]` arguments, with its gradual
    # arm. The bindings the receiver itself names are left to the named path, so its precise answer stands.
    #
    # A body with no aliased local, and a receiver that is own, change nothing.
    module AliasMutationFloor
      Facts = Data.define(:aliased, :foreign, :entry)
      EMPTY = Set.new.freeze

      ALL = :all
      NUMBERED_PARAMETER = /\A_[1-9]\z/
      SEND_NAMES = %i[send public_send __send__].to_set.freeze
      FRESH_VALUES = [
        Prism::ArrayNode, Prism::HashNode, Prism::StringNode, Prism::InterpolatedStringNode, Prism::XStringNode,
        Prism::InterpolatedXStringNode, Prism::IntegerNode, Prism::FloatNode, Prism::RationalNode, Prism::ImaginaryNode,
        Prism::SymbolNode, Prism::InterpolatedSymbolNode, Prism::NilNode, Prism::TrueNode, Prism::FalseNode,
        Prism::RangeNode, Prism::RegularExpressionNode, Prism::InterpolatedRegularExpressionNode
      ].freeze
      # `+"x"`, `"x".dup`, `String.new`: a new String.
      FRESH_STRING_CALLS = %i[+@ dup clone].to_set.freeze
      FACTS_CACHE_KEY = RunScopedSlots.register(:__rigor_alias_mutation_floor_facts)
      IVAR_CACHE_KEY = RunScopedSlots.register(:__rigor_alias_mutation_floor_ivar_mutators)
      private_constant :ALL, :NUMBERED_PARAMETER, :SEND_NAMES, :FRESH_VALUES, :FRESH_STRING_CALLS, :FACTS_CACHE_KEY,
                       :IVAR_CACHE_KEY

      module_function

      # `scope` after `call_node`, a shape mutator, ran on a receiver that may be another local's object. `except` names
      # the locals the receiver itself names, whose own widening (the named path's) stands.
      def floor_after_call(call_node, scope, except: nil)
        return scope unless MutationWidening::SHAPE_MUTATORS.include?(call_node.name)

        receiver = call_node.receiver
        return scope if receiver.nil?

        facts = facts_for(scope)
        return scope if facts.nil?

        targets = targets(receiver_name(receiver), facts)
        return scope if targets.empty?

        method_name, arg_types = UnknownStoreWidening.unknown_store(call_node)
        floor_targets(scope, targets, except) { |type| UnknownStoreWidening.widen_store(type, method_name, arg_types) }
      end

      # `scope` after a callee wrote the object the local `name` holds (the callee floor): every local that may be that
      # object takes what the block answers.
      def floor_after_written_local(scope, name, &)
        facts = facts_for(scope)
        return scope if facts.nil?

        targets = targets(name, facts)
        targets.empty? ? scope : floor_targets(scope, targets, [name], &)
      end

      # Whether a write through the local `name` may reach another local's object.
      def reaches_other_locals?(scope, name)
        facts = facts_for(scope)
        !facts.nil? && !targets(name, facts).empty?
      end

      # Whether the body of `def_node` runs a shape mutator on one of its own instance variables or an element of one
      # (`@items << v`, `@h[k] = v`, `@rows[0] << v`): a call to it on an object that holds another local's object
      # (`box = Box.new(a)`, whose `initialize` keeps `@items = a`) may mutate that object. A nested def is not entered.
      def mutates_ivar?(def_node)
        return false if def_node.nil?

        table = (Thread.current[IVAR_CACHE_KEY] ||= ObjectSpace::WeakKeyMap.new)
        cached = table[def_node]
        return cached unless cached.nil?

        table[def_node] = ivar_mutation?(def_node.body)
      end

      def ivar_mutation?(node)
        return false if node.nil? || node.is_a?(Prism::DefNode)
        return true if node.is_a?(Prism::CallNode) && MutationWidening::SHAPE_MUTATORS.include?(node.name) &&
                       ivar_rooted?(node.receiver)

        node.compact_child_nodes.any? { |child| ivar_mutation?(child) }
      end

      def ivar_rooted?(receiver)
        receiver = RemoverHolderScan.unparenthesised(receiver)
        receiver = receiver.receiver while receiver.is_a?(Prism::CallNode) && %i[[] first last fetch dig].include?(receiver.name)
        receiver.is_a?(Prism::InstanceVariableReadNode)
      end

      # A literal-symbol `send` / `public_send` / `__send__` as the call it makes (`a.send(:push, x)` is `a.push(x)`),
      # or nil.
      def literal_send_target(call_node)
        return nil unless SEND_NAMES.include?(call_node.name) && call_node.block.nil?

        arguments = call_node.arguments&.arguments
        target = arguments&.first
        return nil unless target.is_a?(Prism::SymbolNode) && target.unescaped

        rest = arguments.drop(1)
        call_node.copy(name: target.unescaped.to_sym,
                       arguments: rest.empty? ? nil : call_node.arguments.copy(arguments: rest))
      end

      def facts_for(scope)
        frame = scope.match_frame
        body = frame&.body
        return nil if body.nil?

        table = (Thread.current[FACTS_CACHE_KEY] ||= ObjectSpace::WeakKeyMap.new)
        facts = (table[body] ||= scan(body, frame.parameters))
        facts.aliased.equal?(ALL) || !facts.aliased.empty? ? facts : nil
      end

      def scan(body, parameters)
        aliased = RemoverHolderScan.unsafe_names(body, parameters)
        aliased = ALL unless aliased.is_a?(Set)
        entry = Set.new
        collect_parameters(parameters, entry)
        foreign = Set.new(entry)
        written = Set.new
        collect_foreign(body, foreign, written)
        Facts.new(aliased:, foreign: foreign.freeze, entry: (entry - written).freeze)
      end

      def receiver_name(receiver)
        receiver = RemoverHolderScan.unparenthesised(receiver)
        receiver.name if receiver.is_a?(Prism::LocalVariableReadNode)
      end

      # The locals a write through the local `name` (nil for any other receiver) may reach:
      #
      # - every aliased local, through a receiver that may hold any object: an ivar, an index read, a call result, a
      #   block parameter, or a local some write binds to an object from elsewhere;
      # - only the aliased locals that are themselves foreign, through a local only ever written a new object (when it
      #   is aliased) or a method parameter the body never rebinds: either is an object no new-object local can be;
      # - none, through a local only ever written a new object that no other holder reaches.
      def targets(name, facts)
        aliased = facts.aliased
        return ALL if aliased.equal?(ALL)
        return aliased if name.nil? || NUMBERED_PARAMETER.match?(name)
        return aliased & facts.foreign if facts.entry.include?(name)
        return aliased if facts.foreign.include?(name)

        aliased.include?(name) ? aliased & facts.foreign : EMPTY
      end

      # Each target but `except` takes what the block answers for its binding.
      def floor_targets(scope, targets, except)
        names = targets.equal?(ALL) ? scope.locals.keys : targets
        names.reduce(scope) do |acc, name|
          next acc if except&.include?(name)

          current = acc.local(name)
          next acc if current.nil?

          floored = yield(current)
          floored.nil? || floored == current ? acc : acc.with_mutated_local(name, floored)
        end
      end

      def collect_parameters(node, names)
        return if node.nil?

        names << node.name if node.class.name.end_with?("ParameterNode") && node.respond_to?(:name) && node.name
        node.compact_child_nodes.each { |child| collect_parameters(child, names) }
      end

      # `foreign` gains every block or lambda parameter and every local a write binds to an object from elsewhere (an
      # operator write's value is a call result); `written` every local any write or target binds.
      def collect_foreign(node, foreign, written)
        case node
        when Prism::BlockNode, Prism::LambdaNode then collect_parameters(node.parameters, foreign)
        when Prism::LocalVariableTargetNode then foreign << written_name(node, written)
        when Prism::LocalVariableOperatorWriteNode then foreign << written_name(node, written)
        when Prism::LocalVariableWriteNode, Prism::LocalVariableOrWriteNode, Prism::LocalVariableAndWriteNode
          name = written_name(node, written)
          foreign << name unless fresh_value?(node.value)
        when Prism::DefNode then return
        end
        node.compact_child_nodes.each { |child| collect_foreign(child, foreign, written) }
      end

      def written_name(node, written)
        written << node.name
        node.name
      end

      # A value that is a new object, so the local it binds holds no other holder's object.
      def fresh_value?(value)
        value = RemoverHolderScan.unparenthesised(value)
        return true if FRESH_VALUES.any? { |klass| value.is_a?(klass) }
        return false unless value.is_a?(Prism::CallNode)
        return true if RemoverHolderScan.fresh_value?(value)

        receiver = value.receiver
        (FRESH_STRING_CALLS.include?(value.name) &&
          (receiver.is_a?(Prism::StringNode) || receiver.is_a?(Prism::InterpolatedStringNode))) ||
          (value.name == :new && receiver.is_a?(Prism::ConstantReadNode) && receiver.name == :String)
      end
    end
  end
end
