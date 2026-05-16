# frozen_string_literal: true

require_relative "../reflection"
require_relative "../type/nominal"
require_relative "../type/singleton"
require_relative "../type/constant"

module Rigor
  module LanguageServer
    # Builds the LSP `Hover.contents` markdown body. Dispatches on
    # the hovered Prism node class so each shape (method call,
    # constant, local, literal, …) gets the most relevant
    # type-aware presentation.
    #
    # Slice A1 (this commit) ships:
    # - default body bit-for-bit matching the LSP v1 slice 5
    #   output (`type:` / `erased:` / `node:`),
    # - `Prism::CallNode` specialisation surfacing the receiver
    #   type + RBS-erased method signature.
    #
    # Slices A2-A4 extend the dispatch with constant /
    # local / ivar / literal renderers per
    # `docs/design/20260517-lsp-hover-completion.md`.
    class HoverRenderer
      # @param node_scope_lookup [#[]] node-to-scope table built
      #   by `ScopeIndexer.index`. The renderer indexes into it to
      #   retrieve the receiver's narrow scope when specialising on
      #   `CallNode`. The lookup never returns nil (the indexer's
      #   Hash carries `default_scope` as its default value), so
      #   the renderer trusts the lookup result.
      def render(node:, type:, node_scope_lookup:)
        body = render_body(node, type, node_scope_lookup)
        { contents: { kind: "markdown", value: body } }
      end

      private

      def render_body(node, type, node_scope_lookup)
        case node
        when Prism::CallNode
          render_call(node, type, node_scope_lookup) || render_default(node, type)
        when Prism::ConstantReadNode, Prism::ConstantPathNode
          render_constant(node, type, node_scope_lookup) || render_default(node, type)
        else
          render_default(node, type)
        end
      end

      # Renders a `CallNode` hover when the receiver's type can be
      # mapped to a known RBS class and the method is declared
      # there. Returns nil for shapes the slice-A1 floor doesn't
      # handle (implicit `self`, Union / Refined / Shape receivers
      # — those land in slices A2-A4 and slice 7); the caller falls
      # back to the default body.
      def render_call(call_node, return_type, node_scope_lookup)
        receiver_node = call_node.receiver
        return nil if receiver_node.nil?

        receiver_scope = node_scope_lookup[receiver_node]
        return nil if receiver_scope.nil?

        receiver_type = receiver_scope.type_of(receiver_node)
        definition, class_name, kind = lookup_method(receiver_type, call_node.name, receiver_scope)
        return nil if definition.nil?

        build_call_body(
          class_name: class_name,
          kind: kind,
          method_name: call_node.name,
          definition: definition,
          return_type: return_type
        )
      end

      # @return [[RBS::Definition::Method, String, Symbol], nil]
      #   the resolved method definition, the receiver class name,
      #   and the dispatch kind (`:instance` or `:singleton`); nil
      #   when the receiver shape isn't yet supported or the
      #   method doesn't resolve through the RBS env.
      def lookup_method(receiver_type, method_name, scope)
        case receiver_type
        when Type::Singleton
          definition = Reflection.singleton_method_definition(
            receiver_type.class_name, method_name, scope: scope
          )
          [definition, receiver_type.class_name, :singleton]
        else
          class_name = nominal_class_name(receiver_type)
          return [nil, nil, nil] if class_name.nil?

          definition = Reflection.instance_method_definition(
            class_name, method_name, scope: scope
          )
          [definition, class_name, :instance]
        end
      end

      # Maps a receiver carrier to the underlying RBS class name
      # for method lookup. v1 handles the two carriers that produce
      # well-defined ".methods to enumerate" semantics: `Nominal[C]`
      # (the canonical case) and `Constant<v>` (literal scalars,
      # where the value's runtime class is the receiver). Other
      # carriers fall through to the default hover; slice 7 of the
      # design adds Union / Refined / Shape handling.
      def nominal_class_name(type)
        case type
        when Type::Nominal then type.class_name
        when Type::Constant then constant_to_class_name(type.value)
        end
      end

      # `Type::Constant<value>`'s `value` is the literal Ruby
      # object; map it to the RBS-canonical class name through
      # `Object#class`. The cross-runtime mapping mirrors how the
      # dispatcher already widens a literal to its nominal class
      # at the call site — keep these in sync if a new literal
      # carrier lands.
      def constant_to_class_name(value)
        value.class.name
      end

      def build_call_body(class_name:, kind:, method_name:, definition:, return_type:)
        sep = kind == :singleton ? "." : "#"
        body = +"```ruby\n"
        body << "# Receiver\n"
        body << "#{class_name}\n\n"
        body << "# Method\n"
        body << "#{class_name}#{sep}#{method_name}: #{first_method_type(definition)}\n\n"
        body << "# Return\n"
        body << "#{return_type.describe}\n"
        body << "```"
        body
      end

      # v1 surfaces the FIRST overload only. Multi-overload
      # presentation is queued (design doc § "Out of scope for v2"
      # — multi-overload signature display).
      def first_method_type(definition)
        method_type = definition.method_types.first
        return "(unknown)" if method_type.nil?

        method_type.to_s
      end

      # Specialises `ConstantReadNode` (`Foo`) and `ConstantPathNode`
      # (`Foo::Bar`) when the inferred type is a `Type::Singleton`
      # — i.e., the constant refers to a class / module. Returns nil
      # for constants pointing at values (`FOO = 42`); those fall
      # through to the literal-polish slice (A4).
      def render_constant(node, type, node_scope_lookup)
        return nil unless type.is_a?(Type::Singleton)

        fqn = type.class_name
        scope = node_scope_lookup[node]
        location = defined_in(fqn, scope)

        body = +"```ruby\n"
        body << "# Constant\n#{fqn}\n\n"
        body << "# Type\nsingleton(#{fqn})\n"
        if location
          body << "\n# Defined in\n#{location}\n"
        end
        body << "```"
        body
      end

      # Resolves the source-file location for a class FQN by reading
      # the RBS loader's `class_decl_paths` table. Returns nil when
      # the table doesn't carry attribution (cache-hit paths replace
      # it with a sentinel, see `RunStats.attribution_available?`).
      def defined_in(fqn, scope)
        loader = scope&.environment&.rbs_loader
        return nil if loader.nil?

        path = loader.class_decl_paths[fqn]
        return nil if path.nil? || path.empty?

        path
      end

      def render_default(node, type)
        body = +"```ruby\n"
        body << "type:   #{type.describe}\n"
        body << "erased: #{type.erase_to_rbs}\n"
        body << "node:   #{node.class}\n"
        body << "```"
        body
      end
    end
  end
end
