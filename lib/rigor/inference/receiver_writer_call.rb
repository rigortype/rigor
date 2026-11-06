# frozen_string_literal: true

require "prism"

module Rigor
  module Inference
    # Issue #2488 — a writer a class gains from a call on an explicit receiver outside its body: `E.attr_writer :w`,
    # `E.send(:attr_accessor, :y)`, `E.define_method(:set) { @v = … }` (and `define_method` through `send`). Ruby made
    # `attr_*` and `define_method` public in 2.5, so each is the receiver class's own declaration, exactly as the same
    # call in a `E.class_eval { … }` block is. Both ivar censuses read the calls through here: the per-file class-ivar
    # walk ({ScopeIndexer}) and the cross-file {IvarWriterCensus}. The receiver's name is the caller's to resolve, the
    # same way each resolves a `class_eval` receiver.
    module ReceiverWriterCall
      SEND_CALLS = %i[send __send__ public_send].to_set.freeze
      WRITER_MACROS = %i[attr_writer attr_accessor].to_set.freeze
      # The names a direct call spells; a `send` reaches any of them through its literal first argument.
      CALLS = (WRITER_MACROS | SEND_CALLS | %i[define_method]).freeze
      NO_ARGUMENTS = [].freeze

      module_function

      # The receiver of `node` when it is one of these calls on a receiver other than `self`, else nil.
      def receiver(node)
        return nil unless node.is_a?(Prism::CallNode) && CALLS.include?(node.name)

        recv = node.receiver
        recv unless recv.nil? || recv.is_a?(Prism::SelfNode)
      end

      # The ivar names an explicit-receiver `attr_writer` / `attr_accessor` declares (`[:@w]`), or an empty Array.
      def writer_ivars(node)
        name, arguments = called(node)
        return NO_ARGUMENTS unless WRITER_MACROS.include?(name)

        arguments.filter_map do |argument|
          text = literal_name(argument)
          :"@#{text}" if text
        end
      end

      # The literal block an explicit-receiver `define_method` installs as an instance method, or nil.
      def define_method_block(node)
        name, = called(node)
        block = node.block
        block if name == :define_method && block.is_a?(Prism::BlockNode)
      end

      # The method `node` calls and its arguments, seen through a `send` whose first argument spells the name.
      def called(node)
        return [nil, NO_ARGUMENTS] if receiver(node).nil?

        arguments = node.arguments&.arguments || NO_ARGUMENTS
        return [node.name, arguments] unless SEND_CALLS.include?(node.name)

        sent = literal_name(arguments.first)
        sent ? [sent, arguments.drop(1)] : [nil, NO_ARGUMENTS]
      end

      def literal_name(argument)
        return unless argument.is_a?(Prism::SymbolNode) || argument.is_a?(Prism::StringNode)

        text = argument.unescaped
        text.to_sym if text.valid_encoding?
      end
    end
  end
end
