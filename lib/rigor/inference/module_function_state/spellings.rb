# frozen_string_literal: true

require "prism"
require_relative "../../source/literals"

module Rigor
  module Inference
    module ModuleFunctionState
      # Issue #2209 — the `module_function` spellings other than the receiverless call that the deferred-ranges
      # prescan ({ModuleFunctionState.prescan_deferred}) reads: `self.module_function(...)`, and
      # `send(:module_function, ...)` or `__send__(:module_function, ...)` on no receiver or `self`, which Ruby runs
      # as the receiverless call. `public_send` raises on a private method such as `module_function`, so it is not
      # one.
      #
      # A literal name gives the `:singleton` row and a `def` argument the `:both` or `:singleton` row a receiverless
      # call gives. The bare form, and an argument that is neither (`*names`, a local), gives an {ANY_ROW_NAME} row
      # over the call: the prescan reads neither the toggle these spellings set nor such a name, so every singleton
      # copy of the owner is uncertain (`DefinerResolution.module_function_row?`).
      module Spellings
        SEND_CALLS = %i[send __send__].freeze
        private_constant :SEND_CALLS

        module_function

        # The arguments the spelling `node` passes `module_function`, or nil for any other call.
        def arguments(node)
          arguments = node.arguments&.arguments || []
          return arguments if node.name == :module_function && node.receiver.is_a?(Prism::SelfNode)
          return nil unless SEND_CALLS.include?(node.name)
          return nil unless node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode)
          return nil unless Source::Literals.symbol_or_string(arguments.first) == :module_function

          arguments.drop(1)
        end

        # Appends the rows of the spelling `node` with `arguments` ({.arguments}) to `ranges`, and prescans the rest
        # as {ModuleFunctionState.prescan_deferred} prescans a receiverless call's.
        def prescan(node, arguments, qualified_prefix, in_singleton_class, offsets, ranges)
          owner = qualified_prefix.empty? ? nil : qualified_prefix.join("::")
          call_span = [node.location.start_offset, node.location.end_offset]
          any = arguments.empty?
          arguments.each do |arg|
            if arg.is_a?(Prism::DefNode)
              kind = ScopeIndexer.def_singleton?(arg, qualified_prefix, in_singleton_class) ? :singleton : :both
              ranges << [arg.location.start_offset, arg.location.end_offset, arg.name, kind, owner]
            elsif (name = Source::Literals.symbol_or_string(arg))
              ranges << [*call_span, name, :singleton, owner]
            else
              any = true
              nested_prescan(arg, qualified_prefix, in_singleton_class, offsets, ranges)
            end
          end
          ranges << [*call_span, ANY_ROW_NAME, :singleton, owner] if any
          nested_prescan(node.block, qualified_prefix, in_singleton_class, offsets, ranges) if node.block
        end

        def nested_prescan(node, qualified_prefix, in_singleton_class, offsets, ranges)
          ModuleFunctionState.prescan_deferred(node, qualified_prefix, in_singleton_class, offsets, ranges,
                                               nested: true)
        end
      end
    end
  end
end
