# frozen_string_literal: true

require "prism"

require_relative "alias_mutation_floor"
require_relative "mutation_rejoin"
require_relative "mutation_widening"
require_relative "receiver_alias"
require_relative "set_mutation"

module Rigor
  module Inference
    # Issue #3340 — a variable handed to code the engine cannot read, in a form that may mutate the object it holds
    # without the call site spelling `xs.<mutator>`:
    #
    # - the receiver of a `send` / `public_send` / `__send__` whose name is computed (`xs.send(name)`), or is a
    #   literal mutator the call gives a block ({AliasMutationFloor.literal_send_target} reads only the blockless
    #   form);
    # - the receiver of a `Method` object the statement calls at once under a computed name (`xs.method(name).call`).
    #   A literal name is the call it makes instead ({.method_object_target}), as a literal `send` is;
    # - the receiver of `instance_eval` / `instance_exec`, whose block runs with that object as `self`: a literal
    #   block that calls a mutator on `self` (`xs.instance_eval { clear }`), a block passed as a value, or a string;
    # - a local among the arguments of a `yield` ({.yielded}), which the method's block receives as a call's
    #   arguments are received by an opaque proc.
    #
    # Each such variable takes one unknown store, and only when its binding holds a literal shape or an empty-witness
    # refinement ({AliasMutationFloor.callee_floor}): a `Tuple`, a `HashShape`, a literal String or Set,
    # `non-empty-array[T]`. A nominal (`Array[String]`) is a claim no store is read to falsify, and is left alone, so
    # the floor forgets only what the mutation can make false. The locals that may hold the same object floor with
    # it ({AliasMutationFloor.floor_after_written_local}).
    #
    # Not covered: a `Method` object kept in a variable and called later (`m = xs.method(:clear); m.call`), and a
    # block passed as a value over a literal Array of locals (`[xs].each(&blk)`).
    module OpaqueMutation
      SEND_NAMES = %i[send public_send __send__].to_set.freeze
      SELF_EVAL_NAMES = %i[instance_eval instance_exec].to_set.freeze
      METHOD_OBJECT_NAMES = %i[method public_method].to_set.freeze
      # The names that run a `Method` object: `m.call`, `m.()` (which parses as `call`), `m[]` and `m === x`.
      METHOD_CALL_NAMES = %i[call [] ===].to_set.freeze
      # Every call name {.floor} reads, so any other call returns at one lookup.
      NAMES = (SEND_NAMES | SELF_EVAL_NAMES | METHOD_CALL_NAMES).freeze
      # The names a mutation of `self` is read by inside an `instance_eval` block: the straight-line widening's, a
      # Set-only adder's, and a `send`, which may name any of them.
      SELF_MUTATORS = (MutationWidening::SHAPE_MUTATORS | SetMutation::MUTATORS | SEND_NAMES).freeze
      NAME_LITERALS = [Prism::SymbolNode, Prism::StringNode].freeze
      NO_READS = [].freeze
      private_constant :SEND_NAMES, :SELF_EVAL_NAMES, :METHOD_OBJECT_NAMES, :METHOD_CALL_NAMES, :NAMES,
                       :SELF_MUTATORS, :NAME_LITERALS, :NO_READS

      module_function

      # `recv.method(:name).call(args)` (or `.()`, `[]`, `===`; `public_method` too) as the call it makes,
      # `recv.name(args)`, or nil: for a `Method` object any other way, a computed name, or a call with a block.
      def method_object_target(call_node)
        taker = method_object(call_node)
        return nil if taker.nil? || !call_node.block.nil?

        name = literal_name(taker.arguments.arguments.first)
        name && call_node.copy(receiver: taker.receiver, name: name)
      end

      # `scope` after `call_node`, with each variable its opaque receiver names floored ({.floor_reads}).
      def floor(call_node, scope)
        return scope unless NAMES.include?(call_node.name)

        receiver = opaque_receiver(call_node)
        return scope if receiver.nil?

        floor_reads(ReceiverAlias.mutated_reads(receiver), scope, call_node)
      end

      # `scope` after `node` when it is a `yield`, with each local it passes, positionally or as a keyword's value,
      # floored; `scope` itself for any other node.
      def yielded(node, scope)
        arguments = node.arguments&.arguments if node.is_a?(Prism::YieldNode)
        return scope if arguments.nil?

        floor_reads(local_arguments(arguments), scope, nil)
      end

      # The receiver `call_node` hands to code that may mutate it, or nil.
      def opaque_receiver(call_node)
        receiver = call_node.receiver
        return nil if receiver.nil? || receiver.is_a?(Prism::SelfNode)

        name = call_node.name
        if SEND_NAMES.include?(name) then receiver if opaque_send?(call_node)
        elsif SELF_EVAL_NAMES.include?(name) then receiver if self_mutating_eval?(call_node)
        else
          taker = method_object(call_node)
          taker.receiver if taker && literal_name(taker.arguments.arguments.first).nil?
        end
      end

      # A `send` with a computed name, or with a literal mutator's name and a block.
      def opaque_send?(call_node)
        target = call_node.arguments&.arguments&.first
        return false if target.nil?

        name = literal_name(target)
        name.nil? ? !target.is_a?(Prism::BlockArgumentNode) : !call_node.block.nil? && SELF_MUTATORS.include?(name)
      end

      # An `instance_eval` / `instance_exec` whose code may mutate its receiver: a literal block calling a mutator
      # on `self`, or code the call does not show (a block passed as a value, a string).
      def self_mutating_eval?(call_node)
        block = call_node.block
        return true unless block.is_a?(Prism::BlockNode)

        self_mutation?(block.body)
      end

      # Whether `node` calls a {SELF_MUTATORS} name on `self`, implicitly or as `self.`, outside a nested `def`. A
      # nested block is read too: it runs on the same `self`.
      def self_mutation?(node)
        return false if node.nil? || node.is_a?(Prism::DefNode)

        if node.is_a?(Prism::CallNode) && SELF_MUTATORS.include?(node.name)
          receiver = node.receiver
          return true if receiver.nil? || receiver.is_a?(Prism::SelfNode)
        end
        node.rigor_each_child { |child| return true if self_mutation?(child) }
        false
      end

      # The `recv.method(name)` call `call_node` runs at once (`recv.method(name).call`), or nil.
      def method_object(call_node)
        return nil unless METHOD_CALL_NAMES.include?(call_node.name)

        taker = call_node.receiver
        return nil unless taker.is_a?(Prism::CallNode) && METHOD_OBJECT_NAMES.include?(taker.name)
        return nil if taker.receiver.nil? || taker.receiver.is_a?(Prism::SelfNode)

        taker.arguments&.arguments&.size == 1 && taker.block.nil? ? taker : nil
      end

      # The method a literal Symbol or String names, or nil for any other node.
      def literal_name(node)
        return nil unless NAME_LITERALS.include?(node.class) && node.unescaped.valid_encoding?

        node.unescaped.to_sym
      end

      # The local reads among `arguments`: a positional argument or a keyword's value.
      def local_arguments(arguments)
        reads = nil
        arguments.each do |argument|
          if argument.is_a?(Prism::KeywordHashNode)
            argument.elements.each do |pair|
              next unless pair.is_a?(Prism::AssocNode)

              value = pair.value.is_a?(Prism::ImplicitNode) ? pair.value.value : pair.value
              (reads ||= []) << value if value.is_a?(Prism::LocalVariableReadNode)
            end
          elsif argument.is_a?(Prism::LocalVariableReadNode)
            (reads ||= []) << argument
          end
        end
        reads || NO_READS
      end

      # `scope` with each variable of `reads` at one unknown store, where its binding holds a literal shape. With a
      # `call_node`, every local that may hold a local read's object floors too.
      def floor_reads(reads, scope, call_node)
        reads.reduce(scope) do |acc, read|
          getter, builder = MutationWidening::ALIAS_ACCESSORS[read.class]
          next acc if getter.nil?

          if call_node && read.is_a?(Prism::LocalVariableReadNode)
            acc = AliasMutationFloor.floor_after_written_local(acc, read, call_node)
          end
          name = ReceiverAlias.read_name(read)
          current = acc.public_send(getter, name)
          floored = current && AliasMutationFloor.callee_floor(current)
          next acc if floored.nil? || floored == current

          MutationRejoin.rebind(acc, builder, name, floored, pre_state: current, kind: getter)
        end
      end
    end
  end
end
