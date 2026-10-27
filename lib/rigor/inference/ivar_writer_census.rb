# frozen_string_literal: true

require "prism"

module Rigor
  module Inference
    # Issue #1154 — the instance-variable writers {GlobalWriteCensus} records for the declared-parameter credit
    # ({ScopeIndexer::DeclaredParamWrites}), which must not type an ivar a writer the class-ivar census never walks may
    # replace. The standard is parity with a literal write: `@x = 1` in `initialize` already reads `1` in every sibling
    # method whatever an unknown object's code does, so only the writers that literal writes would also have to answer
    # for are recorded, and an unknown-receiver writer records nothing (as `ReflectiveIvarWrite` leaves
    # `o.instance_variable_set` alone). Three entry kinds go into the census `Set`:
    #
    # - `[:ivar_set, name]` — a literal `o.instance_variable_set(:@x, v)` (or the same through a `send` that spells
    #   it) on an explicit receiver other than `self`, and an `@x` write in the literal block of an
    #   `o.instance_eval { … }` / `instance_exec`: code that names the ivar it writes.
    # - `[:ivar_set_class, class_name]` — an open-world writer ({#open_world?}) with an implicit or `self` receiver
    #   inside an instance body of the class — a `def` or a `define_method` block in its class body, in the block of a
    #   `K = Struct.new` / `Data.define` / `Class.new` constant, or in a `K.class_eval` block (the host walk passes
    #   that class as `owner`): it may write any ivar of the class's instances. A writer in a class body, a
    #   `def self.` or at the top level records nothing.
    # - `[:own_write, class_name, name]` — an `@x` write inside an instance body of the class.
    #   {ScopeIndexer#merge_constant_literal_tables} appends the file's path, so a reader can tell whether a second
    #   file writes the same ivar of the same class.
    # - `[:own_write_type, class_name, name, value]` — issues #2079 / #2170: the same write with its coarse value, a
    #   literal's as `[:lit, value]` and anything else as {DYNAMIC}, and a class-body `attr_writer` /
    #   `attr_accessor` of the name as {DYNAMIC}. The path is appended as for `:own_write`. The class-ivar census
    #   of a file joins another file's entries, and those of the modules and superclasses on the class's chain,
    #   into the ivars it already holds ({ScopeIndexer::IvarContributions}).
    class IvarWriterCensus
      SEND_CALLS = %i[send __send__ public_send].to_set.freeze
      # The methods a `send` reaching which is an open-world writer.
      OPEN_WORLD_SENDS = %i[instance_variable_set instance_eval instance_exec extend
                            define_singleton_method].to_set.freeze
      EVAL_CALLS = %i[instance_eval instance_exec].to_set.freeze
      # The calls on a `singleton_class` receiver that give the object methods or code the census cannot read.
      SINGLETON_CLASS_CALLS = %i[
        class_eval class_exec module_eval module_exec define_method include prepend extend attr attr_reader
        attr_writer attr_accessor send public_send __send__
      ].to_set.freeze
      NO_ARGUMENTS = [].freeze
      # Issue #2079 — the coarse value of a write that is not a literal.
      DYNAMIC = :dynamic
      # The writer declarations a class body records as a {DYNAMIC} write of each name it spells.
      WRITER_DECLARATIONS = %i[attr_writer attr_accessor].to_set.freeze

      # The call names any rule here reads, so every other call returns at one Set probe.
      # (`define_method` is in {SINGLETON_CLASS_CALLS}.)
      WATCHED_CALLS = (SEND_CALLS | OPEN_WORLD_SENDS | EVAL_CALLS | SINGLETON_CLASS_CALLS).freeze

      def initialize(census)
        @census = census
        @instance_ranges = []
        @owner_names = {}.compare_by_identity
        @own_writes = {}
        @typed_writes = Set.new
      end

      # Fed each node of a pre-order descent. `owner` is the class whose body the node sits in, as its qualified name
      # or as the host walk's prefix Array (joined here only when an entry needs it), or nil where no class owns an
      # instance (`class << self`, the top level, an opaque block).
      def visit(node, owner)
        case node
        when Prism::DefNode then remember(node.location, owner) if owner && node.receiver.nil?
        when Prism::SingletonClassNode then visit_singleton_class(node)
        when Prism::CallNode then visit_call(node, owner) if WATCHED_CALLS.include?(node.name)
        when Prism::InstanceVariableWriteNode, Prism::InstanceVariableOrWriteNode, Prism::InstanceVariableAndWriteNode,
             Prism::InstanceVariableOperatorWriteNode, Prism::InstanceVariableTargetNode
          record_own_write(node) unless @instance_ranges.empty?
        end
      end

      private

      # One entry per class and ivar: a repeated write costs a Hash probe, not a location and an Array.
      def record_own_write(node)
        owner = instance_owner(node)
        return if owner.nil?

        record_typed_write(owner, node.name, coarse_value(node))
        seen = (@own_writes[owner] ||= {})
        return if seen[node.name]

        seen[node.name] = true
        @census << [:own_write, owner_name(owner), node.name].freeze
      end

      def record_typed_write(owner, name, value)
        entry = [:own_write_type, owner_name(owner), name, value].freeze
        @census << entry if @typed_writes.add?(entry)
      end

      # Issue #2079 — a literal's value as `[:lit, value]`; any other value, an operator write and a multiple
      # assignment target as {DYNAMIC}.
      def coarse_value(node)
        value = node.value if node.respond_to?(:value) && !node.is_a?(Prism::InstanceVariableOperatorWriteNode)
        case value
        when Prism::NilNode then [:lit, nil].freeze
        when Prism::TrueNode then [:lit, true].freeze
        when Prism::FalseNode then [:lit, false].freeze
        when Prism::IntegerNode, Prism::FloatNode then [:lit, value.value].freeze
        when Prism::SymbolNode, Prism::StringNode then literal_text(value)
        else DYNAMIC
        end
      end

      def literal_text(node)
        text = node.unescaped
        return DYNAMIC unless text.valid_encoding?

        [:lit, node.is_a?(Prism::SymbolNode) ? text.to_sym : text.dup.freeze].freeze
      end

      # Issue #2079 — `attr_writer :x` / `attr_accessor :x` in a class body writes `@x` with whatever the caller hands.
      def record_writer_declaration(node, owner)
        return unless owner && WRITER_DECLARATIONS.include?(node.name) && self_receiver?(node)
        return unless instance_owner(node).nil?

        (node.arguments&.arguments || NO_ARGUMENTS).each do |argument|
          name = literal_name(argument)
          record_typed_write(owner, :"@#{name}", DYNAMIC) if name
        end
      end

      def owner_name(owner) = owner.is_a?(Array) ? (@owner_names[owner] ||= owner.join("::")) : owner

      def visit_call(node, owner)
        record_writer_declaration(node, owner)
        remember(node.block.location, owner) if owner && define_method_block?(node)
        if self_receiver?(node) || own_singleton_class_call?(node)
          return if @instance_ranges.empty? || !(own_singleton_class_call?(node) || open_world?(node))

          instance = instance_owner(node)
          record_class(instance) if instance
        else
          visit_foreign(node)
        end
      end

      # `class << self` inside an instance `def` opens the instance's singleton class.
      def visit_singleton_class(node)
        return unless node.expression.is_a?(Prism::SelfNode) && !@instance_ranges.empty?

        instance = instance_owner(node)
        record_class(instance) if instance
      end

      def record_class(owner) = @census << [:ivar_set_class, owner_name(owner)].freeze

      # The self writers whose target or code the census cannot read: a `send` with a computed method name or one
      # naming {OPEN_WORLD_SENDS}; `instance_eval` / `instance_exec` given a block argument, and `instance_eval`
      # given a string; `extend`; `define_singleton_method` with a body; and an `instance_variable_set` whose name no
      # literal spells. A call in {SINGLETON_CLASS_CALLS} on the object's own `singleton_class` counts as well.
      def open_world?(node)
        name = node.name
        arguments = node.arguments&.arguments || NO_ARGUMENTS
        return open_world_send?(arguments) if SEND_CALLS.include?(name)
        return open_world_eval?(node, arguments) if EVAL_CALLS.include?(name)
        # #1931's census already makes every ivar of the class gradual for one in the same file; this entry covers one
        # in a reopening in another file, which that census does not see.
        return ivar_name(arguments.first).nil? if name == :instance_variable_set

        name == :extend || (name == :define_singleton_method && (!node.block.nil? || arguments.size > 1))
      end

      def open_world_send?(arguments)
        return false if arguments.empty?

        sent = literal_name(arguments.first)
        sent.nil? || OPEN_WORLD_SENDS.include?(sent)
      end

      def open_world_eval?(node, arguments)
        node.block.is_a?(Prism::BlockArgumentNode) || (node.name == :instance_eval && !arguments.empty?)
      end

      # A call on another receiver: a named foreign write, or `self.singleton_class.class_eval` and its kin.
      def visit_foreign(node)
        arguments = node.arguments&.arguments || NO_ARGUMENTS
        name = node.name
        if SEND_CALLS.include?(name) && arguments.first && literal_name(arguments.first) == :instance_variable_set
          name = :instance_variable_set
          arguments = arguments.drop(1)
        end
        if name == :instance_variable_set
          ivar = ivar_name(arguments.first)
          @census << [:ivar_set, ivar].freeze if ivar
        elsif EVAL_CALLS.include?(name) && node.block.is_a?(Prism::BlockNode)
          record_block_ivar_writes(node.block)
        end
      end

      def record_block_ivar_writes(node)
        return unless node.is_a?(Prism::Node)
        return if node.is_a?(Prism::DefNode) || node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode)

        case node
        when Prism::InstanceVariableWriteNode, Prism::InstanceVariableOrWriteNode, Prism::InstanceVariableAndWriteNode,
             Prism::InstanceVariableOperatorWriteNode, Prism::InstanceVariableTargetNode
          @census << [:ivar_set, node.name].freeze
        end
        node.rigor_each_child { |child| record_block_ivar_writes(child) }
      end

      def define_method_block?(node)
        node.name == :define_method && self_receiver?(node) && node.block.is_a?(Prism::BlockNode)
      end

      # An instance body (`def` or `define_method` block) and the class it belongs to. A `define_method` block's own
      # nodes may reach the walk with no owner (the walk reads its `self` as opaque), so the class rides the range.
      def remember(location, owner)
        @instance_ranges << [(location.start_offset...location.end_offset), owner]
      end

      # The class of the innermost instance body covering `node` (pre-order, so the last covering range), or nil.
      def instance_owner(node)
        offset = node.location.start_offset
        @instance_ranges.reverse_each { |(range, owner)| return owner if range.cover?(offset) }
        nil
      end

      def self_receiver?(node) = node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode)

      # A call in {SINGLETON_CLASS_CALLS} on the object's own `singleton_class` (`singleton_class.class_eval { … }`).
      def own_singleton_class_call?(node)
        receiver = node.receiver
        receiver.is_a?(Prism::CallNode) && receiver.name == :singleton_class && self_receiver?(receiver) &&
          SINGLETON_CLASS_CALLS.include?(node.name)
      end

      def literal_name(argument)
        return unless argument.is_a?(Prism::SymbolNode) || argument.is_a?(Prism::StringNode)

        text = argument.unescaped
        text.to_sym if text.valid_encoding?
      end

      def ivar_name(argument)
        name = literal_name(argument)
        name if name.to_s.start_with?("@")
      end
    end
  end
end
