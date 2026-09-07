# frozen_string_literal: true

require "prism"
require "rigor/type"

module Rigor
  module Plugin
    class Rspec < Rigor::Plugin::Base
      # Resolves the runtime type of a `let(:name) { body }` or `subject(:name) { body }` block by
      # pattern-matching its body's tail expression.
      #
      # Recognised body shapes (floor):
      #
      # - `ConstantClass.new(...)` → `Nominal[ConstantClass]`
      # - `Foo::Bar.new(...)` → `Nominal[Foo::Bar]`
      # - `described_class.new(...)` → `Nominal[<describe const>]` when the surrounding describe block has
      #   a constant anchor.
      # - `create(:factory)` / `build(:factory)` / `build_stubbed(:factory)` / `attributes_for(:factory)` →
      #   `Nominal[<factory.model_class>]` when the `:factory_index` ADR-9 fact is available and the
      #   factory name is known.
      # - `FactoryBot.create(:factory)` etc. — same as the implicit-receiver factorybot form.
      #
      # Returns `nil` for any other body shape. Multi-statement bodies use the LAST statement (the block's
      # return value).
      module LetTypeResolver
        FACTORYBOT_ENTRY_METHODS = %i[
          create build build_stubbed attributes_for
          create_list build_list build_stubbed_list
        ].freeze

        module_function

        # @param factory_index [Object, nil] something responding to `find(factory_name)` and returning an
        #   entry that responds to `model_class`.
        # @return [Rigor::Type, nil]
        def resolve(block_node, describe_const:, factory_index:, environment:)
          tail = body_tail(block_node)
          return nil if tail.nil?

          nominal_for_call(
            tail,
            describe_const: describe_const,
            factory_index: factory_index,
            environment: environment
          )
        end

        def body_tail(block_node)
          body = block_node.body
          return nil if body.nil?

          case body
          when Prism::StatementsNode
            body.body.last
          else
            body
          end
        end

        def nominal_for_call(node, describe_const:, factory_index:, environment:)
          return nil unless node.is_a?(Prism::CallNode)

          # `<Const>.new(...)` / `<ConstPath>.new(...)`
          if node.name == :new && const_receiver?(node.receiver)
            class_name = render_const(node.receiver)
            return nominal_for(class_name, environment: environment) if class_name
          end

          # `described_class.new(...)`
          if node.name == :new && described_class_receiver?(node.receiver)
            return nil if describe_const.nil?

            return nominal_for(describe_const, environment: environment)
          end

          # `create(:name)` / `build(:name)` / `FactoryBot.create(:name)` / `*_list`
          factorybot_nominal(node, factory_index: factory_index, environment: environment)
        end

        def factorybot_nominal(call_node, factory_index:, environment:)
          return nil if factory_index.nil?
          return nil unless factorybot_call?(call_node)

          factory_name = factorybot_first_arg(call_node)
          return nil if factory_name.nil?

          entry = factory_index.find(factory_name)
          return nil if entry.nil?

          model_class = entry.respond_to?(:model_class) ? entry.model_class : nil
          return nil if model_class.nil?

          nominal_for(model_class, environment: environment)
        end

        # Recognises both `create(:name)` (implicit receiver, via `include FactoryBot::Syntax::Methods`)
        # and the explicit `FactoryBot.create(:name)` / `FactoryGirl.create(:name)` (legacy) forms.
        def factorybot_call?(call_node)
          return false unless FACTORYBOT_ENTRY_METHODS.include?(call_node.name)

          recv = call_node.receiver
          recv.nil? || factorybot_constant?(recv)
        end

        def factorybot_constant?(node)
          case node
          when Prism::ConstantReadNode then %i[FactoryBot FactoryGirl].include?(node.name)
          when Prism::ConstantPathNode
            node.parent.nil? && %i[FactoryBot FactoryGirl].include?(node.name)
          else false
          end
        end

        def factorybot_first_arg(call_node)
          first_arg = call_node.arguments&.arguments&.first
          case first_arg
          when Prism::SymbolNode then first_arg.unescaped
          when Prism::StringNode then first_arg.unescaped
          end
        end

        def const_receiver?(node)
          node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)
        end

        def described_class_receiver?(node)
          node.is_a?(Prism::CallNode) && node.name == :described_class && node.receiver.nil?
        end

        def render_const(node)
          case node
          when Prism::ConstantReadNode then node.name.to_s
          when Prism::ConstantPathNode
            parts = []
            current = node
            while current.is_a?(Prism::ConstantPathNode)
              parts.unshift(current.name.to_s)
              current = current.parent
            end
            case current
            when nil then "::#{parts.join('::')}"
            when Prism::ConstantReadNode then "#{current.name}::#{parts.join('::')}"
            end
          end
        end

        def nominal_for(class_name, environment:)
          if environment
            environment.nominal_for_name(class_name) ||
              Rigor::Type::Combinator.nominal_of(class_name)
          else
            Rigor::Type::Combinator.nominal_of(class_name)
          end
        end
      end
    end
  end
end
