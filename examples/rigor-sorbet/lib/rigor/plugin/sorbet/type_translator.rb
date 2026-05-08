# frozen_string_literal: true

require "prism"

module Rigor
  module Plugin
    class Sorbet < Rigor::Plugin::Base
      # Maps Sorbet's type expressions (the AST inside a `sig`
      # block's `params(...)` and `returns(...)` clauses) into
      # Rigor's internal type carriers.
      #
      # Slice 1 covers the minimum vocabulary that lets a typical
      # `sig { params(x: Integer).returns(String) }` round-trip:
      #
      # | Sorbet form         | Rigor carrier                           |
      # | ------------------- | --------------------------------------- |
      # | `Integer` etc.      | `Nominal["Integer"]`                    |
      # | `::Foo::Bar`        | `Nominal["Foo::Bar"]`                   |
      # | `T.untyped`         | `Dynamic[top]`                          |
      # | `T.anything`        | `top`                                   |
      # | `T.noreturn`        | `bot`                                   |
      # | `T.nilable(X)`      | `Union[X, Constant[nil]]`               |
      # | `T.any(A, B, ...)`  | `Union[A, B, ...]`                      |
      # | `T.all(A, B, ...)`  | `Intersection[A, B, ...]`               |
      # | `T::Boolean`        | `Union[Constant[true], Constant[false]]`|
      #
      # Anything else (T.proc / T.class_of / T::Array[E] /
      # T.attached_class / T::Class / T::Struct / etc.) degrades
      # to `Dynamic[top]` for slice 1; later slices widen the
      # vocabulary. The degraded path is intentionally silent in
      # slice 1 — emitting a diagnostic for every unsupported
      # construct would drown out the actual sig-level errors.
      module TypeTranslator
        BOOLEAN_NAME = "Boolean"
        SORBET_T_NAMESPACES = [%w[T], %w[T :: Sig]].freeze

        module_function

        # @param node [Prism::Node, nil]
        # @return [Rigor::Type] never `nil`; unrecognised forms
        #   degrade to `Type::Combinator.untyped`.
        def translate(node)
          return Rigor::Type::Combinator.untyped if node.nil?

          case node
          when Prism::ConstantReadNode then translate_constant_read(node)
          when Prism::ConstantPathNode then translate_constant_path(node)
          when Prism::CallNode then translate_call(node)
          else degraded
          end
        end

        # @param node [Prism::ConstantReadNode]
        def translate_constant_read(node)
          name = node.name.to_s
          return Rigor::Type::Combinator.untyped if name.empty?

          Rigor::Type::Combinator.nominal_of(name)
        end

        # @param node [Prism::ConstantPathNode]
        def translate_constant_path(node)
          name = constant_path_name(node)
          return degraded if name.nil?

          # Sorbet's `T::Boolean` is a special alias rather than a
          # nominal class, expressed as the Boolean type alias.
          return boolean_type if name == "T::Boolean"

          Rigor::Type::Combinator.nominal_of(name)
        end

        def translate_call(node)
          return degraded unless sorbet_t_namespaced?(node.receiver)

          case node.name
          when :untyped then Rigor::Type::Combinator.untyped
          when :anything then Rigor::Type::Combinator.top
          when :noreturn then Rigor::Type::Combinator.bot
          when :nilable
            inner = first_argument(node)
            return degraded if inner.nil?

            Rigor::Type::Combinator.union(
              translate(inner), Rigor::Type::Combinator.constant_of(nil)
            )
          when :any
            args = call_arguments(node)
            return degraded if args.empty?

            Rigor::Type::Combinator.union(*args.map { |arg| translate(arg) })
          when :all
            args = call_arguments(node)
            return degraded if args.empty?

            Rigor::Type::Combinator.intersection(*args.map { |arg| translate(arg) })
          else
            degraded
          end
        end

        # Renders a constant-path node (`Foo::Bar`, `::Foo::Bar`)
        # as a `::`-joined String. Mirrors the helper used by
        # rigor-activerecord's ModelDiscoverer for parity.
        def constant_path_name(node)
          return nil if node.nil?

          case node
          when Prism::ConstantReadNode then node.name.to_s
          when Prism::ConstantPathNode then constant_path_name_for_path(node)
          end
        end

        def constant_path_name_for_path(node)
          parts = []
          current = node
          while current.is_a?(Prism::ConstantPathNode)
            parts.unshift(current.name.to_s)
            current = current.parent
          end
          case current
          when nil
            "::#{parts.join('::')}"
          when Prism::ConstantReadNode
            "#{current.name}::#{parts.join('::')}"
          end
        end

        def sorbet_t_namespaced?(receiver)
          receiver.is_a?(Prism::ConstantReadNode) && receiver.name == :T
        end

        def first_argument(node)
          node.arguments&.arguments&.first
        end

        def call_arguments(node)
          node.arguments&.arguments || []
        end

        def degraded
          Rigor::Type::Combinator.untyped
        end

        # `T::Boolean` corresponds to the union of the singleton
        # `true` / `false` values, matching how RBS's `bool`
        # would translate. Built from `Constant[true]` /
        # `Constant[false]` so the analyzer's flow-sensitive
        # narrowing recognises the discriminating shape.
        def boolean_type
          Rigor::Type::Combinator.union(
            Rigor::Type::Combinator.constant_of(true),
            Rigor::Type::Combinator.constant_of(false)
          )
        end
      end
    end
  end
end
