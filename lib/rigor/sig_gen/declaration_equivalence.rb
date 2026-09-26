# frozen_string_literal: true

require "rbs"

module Rigor
  module SigGen
    # ADR-112 WD4 — whether a method's inline declaration and its `sig/` declaration say the same thing, so that
    # `rigor sig-gen` refuses (or, under `--overwrite`, replaces) only a real disagreement (#1076).
    #
    # Two declarations are compared as types, not text. What is ignored, because RBS gives it no meaning:
    #
    # - parameter names (`(String)` and `(String s)`);
    # - how a union is spelled: member order, `T?` for `T | nil`, `bool` for `true | false`, nesting;
    # - a name written absolute or relative, when both resolve to the same constant — `::Foo` and `Foo` inside
    #   `module NS` are the same only if `NS` declares no `Foo` of its own ({#initialize}'s `resolve`).
    #
    # What is kept: overload order (RBS picks the first overload that matches, so `A | B` and `B | A` can
    # answer a call differently), method type parameters as named, and everything else about the shape.
    class DeclarationEquivalence
      # @param resolve — maps a type name as written (`String`, `::Foo`, `Bar::Baz`) to the name it denotes,
      #   in the namespace both declarations sit in.
      def initialize(resolve:)
        @resolve = resolve
      end

      def same?(left, right)
        left.size == right.size && left.zip(right).all? { |a, b| method_type(a) == method_type(b) }
      end

      # The overloads with their returns left out, for comparing what an author wrote against a member whose
      # return is inferred.
      def same_parameters?(left, right)
        left.size == right.size && left.zip(right).all? do |a, b|
          method_type(a, with_return: false) == method_type(b, with_return: false)
        end
      end

      private

      def method_type(method_type, with_return: true)
        [
          method_type.type_params.map { |param| param.name.to_s },
          function(method_type.type, with_return: with_return),
          block(method_type.block)
        ]
      end

      def block(block)
        return nil if block.nil?

        [block.required, function(block.type), block.self_type && type(block.self_type)]
      end

      def function(function, with_return: true)
        returned = with_return ? type(function.return_type) : nil
        return [:untyped_function, returned] if function.is_a?(::RBS::Types::UntypedFunction)

        [
          function.required_positionals.map { |param| type(param.type) },
          function.optional_positionals.map { |param| type(param.type) },
          function.rest_positionals && type(function.rest_positionals.type),
          function.trailing_positionals.map { |param| type(param.type) },
          keywords(function.required_keywords),
          keywords(function.optional_keywords),
          function.rest_keywords && type(function.rest_keywords.type),
          returned
        ]
      end

      def keywords(map)
        map.map { |name, param| [name.to_s, type(param.type)] }.sort
      end

      def type(node)
        case node
        when ::RBS::Types::Optional, ::RBS::Types::Union, ::RBS::Types::Bases::Bool then union(node)
        when ::RBS::Types::ClassInstance then [:instance, @resolve.call(node.name.to_s), types(node.args)]
        when ::RBS::Types::ClassSingleton then [:singleton, @resolve.call(node.name.to_s)]
        when ::RBS::Types::Interface, ::RBS::Types::Alias then named(node)
        else composite(node)
        end
      end

      # An interface or alias is compared by its written name, a leading `::` aside: those names are rarely
      # nested, and the environment question this class asks of a class name has no counterpart for them.
      def named(node)
        [:named, node.name.to_s.delete_prefix("::"), types(node.args)]
      end

      def composite(node)
        case node
        when ::RBS::Types::Tuple then [:tuple, types(node.types)]
        when ::RBS::Types::Record then [:record, record_fields(node)]
        when ::RBS::Types::Intersection then [:intersection, types(node.types).sort_by(&:inspect)]
        when ::RBS::Types::Proc then [:proc, function(node.type), block(node.block)]
        else [:other, node.to_s]
        end
      end

      def types(nodes)
        nodes.map { |node| type(node) }
      end

      def record_fields(node)
        required = node.fields.map { |key, field| [key.to_s, true, type(field)] }
        optional = node.respond_to?(:optional_fields) ? node.optional_fields : {}
        (required + optional.map { |key, field| [key.to_s, false, type(field)] }).sort_by(&:inspect)
      end

      def union(node)
        members = union_members(node).uniq.sort_by(&:inspect)
        members.size == 1 ? members.first : [:union, members]
      end

      # `true` / `false` / `nil` canonicalise as their literal spellings do (`[:other, "true"]`), so `bool` and
      # `true | false`, or `T?` and `T | nil`, land on the same members.
      def union_members(node)
        case node
        when ::RBS::Types::Union then node.types.flat_map { |member| union_members(member) }
        when ::RBS::Types::Optional then union_members(node.type) + [[:other, "nil"]]
        when ::RBS::Types::Bases::Bool then [[:other, "true"], [:other, "false"]]
        else [type(node)]
        end
      end
    end
  end
end
