# frozen_string_literal: true

require_relative "../declaration_walk/rules"

module Rigor
  module Inference
    module ScopeIndexer
      # The factory call an expression unwinds to, moved out of `scope_indexer.rb` whole (ADR-116 WD9, #3400).
      # {.resolve_meta_factory_call} answers the `Data.define` or `Struct.new` call under any `Class.new(...)`
      # wrappers, or nil; the other two functions are its private steps.
      #
      # Three files call it, at four sites: `scope_indexer.rb` from the methods table
      # (`ScopeIndexer.record_meta_members`), {DeclarationArtifacts} from the arm that takes a constant write
      # (`DeclarationArtifacts.record_meta_new_constant?`), and {SharedWalkTables} from its two layout recorders. It
      # asks {DeclarationWalk::Rules} which call is which factory, calls nothing left in `scope_indexer.rb` and reads
      # none of the indexer's constants. Each caller requires this file, and it requires none back, so it loads and
      # answers alone.
      module FactoryCallResolver
        module_function

        # Unwinds nested single-parent `Class.new(...)` calls to a root `Struct.new(...)` / `Data.define(...)`.
        # A nested wrapper or factory block is declined because its method overrides belong to the intermediate
        # superclass and cannot be attributed to the outer class's reader-override guard.
        def resolve_meta_factory_call(call_node, allow_outer_block: true)
          wrapped = false
          while DeclarationWalk::Rules.class_new_call?(call_node)
            return nil if intermediate_factory_block?(call_node, wrapped, allow_outer_block)

            arguments = call_node.arguments&.arguments
            return nil unless arguments&.one?

            call_node = arguments.first
            wrapped = true
          end
          return nil unless meta_factory_call?(call_node)
          return nil if intermediate_factory_block?(call_node, wrapped, allow_outer_block)

          call_node
        end

        def intermediate_factory_block?(call_node, wrapped, allow_outer_block)
          (wrapped || !allow_outer_block) && !call_node.block.nil?
        end

        def meta_factory_call?(call_node)
          DeclarationWalk::Rules.data_define_call?(call_node) || DeclarationWalk::Rules.struct_new_call?(call_node)
        end

        private_class_method :intermediate_factory_block?, :meta_factory_call?
      end
    end
  end
end
