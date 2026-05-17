# frozen_string_literal: true

require_relative "../reflection"
require_relative "../type/nominal"
require_relative "../type/singleton"
require_relative "../type/constant"
require_relative "../type/refined"
require_relative "../type/difference"

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
        result = { contents: { kind: "markdown", value: body } }
        result[:range] = lsp_range_for(node) if node.respond_to?(:location) && node.location
        result
      end

      private

      # Converts a Prism `Location` to an LSP `Range` (0-based
      # line, 0-based UTF-16-character column). UTF-16 conversion
      # is queued — slice E1 emits byte columns which match for
      # ASCII source; non-ASCII falls back gracefully because
      # clients clamp out-of-range columns to the end of line.
      def lsp_range_for(node)
        loc = node.location
        {
          start: { line: loc.start_line - 1, character: loc.start_column },
          end:   { line: loc.end_line - 1,   character: loc.end_column }
        }
      end

      def render_body(node, type, node_scope_lookup)
        case node
        when Prism::CallNode
          render_call(node, type, node_scope_lookup) || render_default(node, type)
        when Prism::ConstantReadNode, Prism::ConstantPathNode
          render_constant(node, type, node_scope_lookup) || render_default(node, type)
        when Prism::LocalVariableReadNode, Prism::LocalVariableWriteNode,
             Prism::LocalVariableTargetNode
          render_local(node, type)
        when Prism::InstanceVariableReadNode, Prism::InstanceVariableWriteNode,
             Prism::InstanceVariableTargetNode
          render_ivar(node, type, node_scope_lookup)
        when Prism::IntegerNode, Prism::FloatNode, Prism::RationalNode,
             Prism::ImaginaryNode, Prism::StringNode, Prism::SymbolNode,
             Prism::RegularExpressionNode, Prism::TrueNode, Prism::FalseNode,
             Prism::NilNode, Prism::ArrayNode, Prism::HashNode
          render_literal(node, type)
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
        if (doc = rbs_documentation(definition))
          # Close the code fence first so the comment text renders
          # as prose, then a fresh fenced block isn't necessary —
          # plain markdown below the code reads better in clients.
          body << "\n\n---\n\n#{doc}"
        end
        body
      end

      # Returns the concatenated text of every RBS comment attached
      # to the method definition, or nil when no comments exist.
      # `RBS::Definition::Method#comments` is an Array<AST::Comment>
      # with each entry's `.string` carrying the raw text (newline-
      # terminated `# foo` lines). Multiple comments are joined
      # with a blank line so each upstream `# Foo bar` paragraph
      # is preserved.
      def rbs_documentation(definition)
        comments = definition.respond_to?(:comments) ? definition.comments : nil
        return nil if comments.nil? || comments.empty?

        text = comments.map(&:string).join("\n\n").strip
        text.empty? ? nil : text
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
        body << "\n# Defined in\n#{location}\n" if location
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

      # Specialises local-variable reads / writes / target nodes.
      # Surfaces the variable name + narrowed type. "Bound at"
      # source-line attribution is queued (Scope#locals tracks
      # {name => Type} but not the binding location); when the
      # ScopeIndexer grows a side-table for it, slice A3 follow-up
      # can fill the row in.
      def render_local(node, type)
        body = +"```ruby\n"
        body << "# Local\n#{node.name}\n\n"
        body << "# Type\n#{type.describe}\n"
        body << "```"
        body
      end

      # Specialises instance-variable reads / writes / targets.
      # Surfaces the ivar name + narrowed type + the enclosing
      # class context derived from the scope's `self_type`. When
      # the self_type isn't a Nominal (e.g., top-level main) the
      # enclosing-class row is omitted.
      def render_ivar(node, type, node_scope_lookup)
        scope = node_scope_lookup[node]
        body = +"```ruby\n"
        body << "# Ivar\n#{node.name}\n\n"
        body << "# Type\n#{type.describe}\n"
        if scope && (enclosing = enclosing_class_for(scope))
          body << "\n# In class\n#{enclosing}\n"
        end
        body << "```"
        body
      end

      def enclosing_class_for(scope)
        self_type = scope.self_type
        # Both `Nominal[C]` and `Singleton[C]` carry `class_name`;
        # we want the class label either way. Combined branch
        # keeps the slice-A3 contract simple.
        self_type.class_name if self_type.is_a?(Type::Nominal) || self_type.is_a?(Type::Singleton)
      end

      # Specialises literal-bearing nodes (Integer / Float / String /
      # Symbol / Regex / true / false / nil / Array / Hash). Drops
      # the slice-A1 `node:` debug row in favour of a cleaner
      # `# Type` + `# Erased` framing, and surfaces the refinement
      # / difference name when one is present. For Array / Hash
      # the shape carriers (`Tuple<...>` / `HashShape<...>`) already
      # describe element types, so the framing is identical to
      # primitive literals.
      def render_literal(_node, type)
        body = +"```ruby\n"
        body << "# Type\n#{type.describe}\n"
        body << "\n# Erased\n#{type.erase_to_rbs}\n"
        if (name = refinement_name_for(type))
          body << "\n# Refinement\n#{name}\n"
        end
        body << "```"
        body
      end

      # Surfaces the canonical kebab-case refinement name when the
      # type is a `Refined` or `Difference` carrier with a
      # registered canonical_name (e.g. `non-empty-string` /
      # `positive-int`). `canonical_name` is private on both
      # carriers; the LSP layer is a trusted internal consumer
      # and `send` is the documented escape hatch for surfacing
      # display-level metadata. Returns nil for unrefined carriers
      # and for refinements that don't have a canonical name (those
      # are presented through the predicate-id operator form by
      # `describe`).
      def refinement_name_for(type)
        return nil unless type.is_a?(Type::Refined) || type.is_a?(Type::Difference)

        type.send(:canonical_name)
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
