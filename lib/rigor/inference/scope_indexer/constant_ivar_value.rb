# frozen_string_literal: true

require "prism"

require_relative "../../source/constant_path"
require_relative "../../source/node_walker"

module Rigor
  module Inference
    module ScopeIndexer
      # Issue #2291 — the class-ivar census types an `@x = LIT` write from the type the constant's own write binds, the
      # same way a method body reads `LIT`. The census runs before the file's in-source constant table is seeded, so
      # without it the write typed under no constant table and a reader over the ivar (`def q = @q`) read `Dynamic[top]`
      # where `def g = LIT` read the constant's type.
      #
      # One instance serves one census walk. The file's constant table is built on the first constant-valued write, so
      # a file with none pays nothing; it is built as {ScopeIndexer#index} builds it later (typed under the census's
      # scope, merged over the scope's project seed, a mutated literal widened), and resolved through the ordinary
      # constant lookup. {#type_of} answers nil, leaving the write's ordinary typing, when:
      #
      # - the value is not a constant read whose every segment is a constant (`LIT`, `A::LIT`, `::LIT`; not
      #   `self.class::LIT`);
      # - the file may rebind a constant of that last segment: a second write in any form, an operator, `||=` or `&&=`
      #   write, a multiple-assignment target, or a `const_set` / `remove_const` naming it — or naming anything but a
      #   literal, which may be it.
      #
      # A constant another file assigns resolves only through the scope's own project seed, as it did before.
      class ConstantIvarValue
        WRITE_NODES = [Prism::ConstantWriteNode, Prism::ConstantPathWriteNode].freeze
        REBIND_NODES = [Prism::ConstantOperatorWriteNode, Prism::ConstantOrWriteNode, Prism::ConstantAndWriteNode,
                        Prism::ConstantPathOperatorWriteNode, Prism::ConstantPathOrWriteNode,
                        Prism::ConstantPathAndWriteNode, Prism::ConstantTargetNode,
                        Prism::ConstantPathTargetNode].freeze
        REBIND_CALLS = %i[const_set remove_const].freeze
        ANY_NAME = :any
        private_constant :WRITE_NODES, :REBIND_NODES, :REBIND_CALLS, :ANY_NAME

        def initialize(root, scope)
          @root = root
          @scope = scope
        end

        # The type `value` reads under the file's constant table, or nil when the write keeps its ordinary typing.
        def type_of(value, scope)
          return nil unless value.is_a?(Prism::ConstantReadNode) || value.is_a?(Prism::ConstantPathNode)
          return nil if Source::ConstantPath.qualified_name_or_nil(value).nil?
          return nil if rebound?(value.name)

          scope.with_discovery(scope.discovery.with(in_source_constants: constants)).type_of(value)
        end

        private

        def constants
          @constants ||= begin
            literal_mutations = ScopeIndexer.collect_literal_receiver_mutations(@root)
            per_file = ScopeIndexer.widen_mutated_constants(
              ScopeIndexer.build_in_source_constants(@root, @scope), literal_mutations[:constants]
            )
            ScopeIndexer.merge_seeded_constants(@scope.in_source_constants, per_file)
          end
        end

        def rebound?(name)
          @rebound ||= rebound_names
          @rebound.include?(ANY_NAME) || @rebound.include?(name)
        end

        def rebound_names
          written = Set.new
          rebound = Set.new
          Source::NodeWalker.each(@root) do |node|
            case node
            when *WRITE_NODES
              name = write_name(node)
              rebound << name unless written.add?(name)
            when *REBIND_NODES then rebound << write_name(node)
            when Prism::CallNode then rebound << call_name(node) if REBIND_CALLS.include?(node.name)
            end
          end
          rebound
        end

        def write_name(node) = node.respond_to?(:target) ? node.target.name : node.name

        def call_name(node)
          argument = node.arguments&.arguments&.first
          return argument.unescaped.to_sym if argument.is_a?(Prism::SymbolNode) || argument.is_a?(Prism::StringNode)

          ANY_NAME
        end
      end
    end
  end
end
