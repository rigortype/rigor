# frozen_string_literal: true

require "prism"

require_relative "../../type"

module Rigor
  module Inference
    class ExpressionTyper
      # Typers of nodes whose answer is built from the types of their children: hash, array, range, interpolation and
      # the pass-through nodes (parentheses, statements, `else`, `ensure`, `when` / `in`, `class` / `module` bodies).
      # Reads no state; calls back {ExpressionTyper#type_of}. The entries are `type_of_statements_node`,
      # `type_of_program`, `type_of_hash`, `type_of_interpolated_string`, `type_of_embedded_statements`,
      # `type_of_class_or_module`, `type_of_else`, `type_of_when_or_in`, `type_of_ensure`, `statements_or_nil`,
      # `type_of_shareable_constant`, `type_of_implicit`, `array_type_for`, `parentheses_type_for`, `type_of_range`;
      # every other method is private to the module (ADR-116 C3). State is passed, not shared: each entry takes the
      # values it reads from the typer as trailing positional parameters (`scope`, `tracer`) and the typer itself
      # (`typer`) when it calls back.
      module Composites
        module_function

        def type_of_statements_node(node, typer)
          statements_type_for(node, typer)
        end

        def type_of_program(node, typer)
          statements_type_for(node.statements, typer)
        end

        # Slice 5 phase 1 upgrades hash literals to `HashShape{...}` when every entry is a static `AssocNode`
        # whose key is a value-pinned scalar literal — Symbol, plain String, Integer, Float, `true`, `false`,
        # or `nil` (covering `{ a: 1, "b" => 2 }` and `{ 1 => 2, 1.0 => 4 }` alike) — falling back to the
        # generic `Hash[K, V]` form otherwise. Splatted entries (`{ **other }`) and dynamic keys widen to the
        # underlying `Hash[K, V]` form by unioning the types each entry exposes — a splat exposes the `[K, V]`
        # of the hash it copies plus a `Dynamic[top]` arm (see {.hash_splat_pair}), so every entry contributes a
        # pair. A splat never keeps a shape, even over an exact closed one.
        def type_of_hash(node, typer)
          elements = node.respond_to?(:elements) ? node.elements : []
          # v0.0.7 — `{}` resolves to the empty `HashShape{}` carrier rather than `Nominal[Hash]`, mirroring the
          # v0.0.6 empty-array literal change. Both forms erase to plain `Hash`, but `HashShape{}` pins the
          # literal's known size (zero) so HashShape projections (`empty?`, `first`, `count`, …) fold against it.
          return Type::Combinator.hash_shape_of({}) if elements.empty?

          shape = static_hash_shape_for(elements, typer)
          return shape if shape

          keys, values = generic_hash_pairs_for(elements, typer)
          Type::Combinator.nominal_of(
            Hash,
            type_args: [Type::Combinator.union(*keys), Type::Combinator.union(*values)]
          )
        end

        # Builds `HashShape{...}` when every entry is an `AssocNode` whose key is a value-pinned scalar
        # literal (Symbol, plain String, Integer, Float, true, false, nil). Returns nil otherwise so the
        # caller falls back to the generic shape.
        #
        # Duplicate keys are LAST-WINS, matching the runtime (`{ a: 1, a: 2 }` keeps `a: 2`; Ruby itself
        # only warns under `-w`). Key identity is Ruby `Hash` `eql?` identity because `pairs` is a native
        # Hash — `1` and `1.0` stay distinct entries, `1.0` and `1.00` collide. The plain re-assignment
        # also reproduces the runtime's ordering: the key keeps its FIRST insertion position while the
        # value comes from the LAST occurrence.
        def static_hash_shape_for(elements, typer)
          pairs = {}
          elements.each do |entry|
            return nil unless entry.is_a?(Prism::AssocNode)

            key = static_hash_key(entry.key)
            return nil if key.equal?(NO_STATIC_HASH_KEY)

            pairs[key] = typer.type_of(entry.value)
          end
          return nil if pairs.empty?

          Type::Combinator.hash_shape_of(pairs)
        end

        # Returns the value-pinned scalar literal carried by a hash key node, or {NO_STATIC_HASH_KEY} when
        # the key is dynamic (a computed expression, an interpolated string — SymbolNode#value /
        # StringNode#unescaped are nil under interpolation — a constant, a local, …). `nil` / `false` are
        # real key values here, hence the sentinel rather than a nil return.
        def static_hash_key(node)
          case node
          when Prism::SymbolNode
            raw = node.value
            raw.nil? ? NO_STATIC_HASH_KEY : raw.to_sym
          when Prism::StringNode
            node.unescaped || NO_STATIC_HASH_KEY
          when Prism::IntegerNode, Prism::FloatNode then node.value
          when Prism::TrueNode then true
          when Prism::FalseNode then false
          when Prism::NilNode then nil
          else NO_STATIC_HASH_KEY
          end
        end

        def generic_hash_pairs_for(elements, typer)
          keys = []
          values = []
          elements.each do |entry|
            if entry.is_a?(Prism::AssocNode)
              keys << typer.type_of(entry.key)
              values << typer.type_of(entry.value)
            else
              key, value = hash_splat_pair(entry, typer)
              keys << key
              values << value
            end
          end
          [keys, values]
        end

        # The `[K, V]` a `**splat` entry adds to the literal: what the analysis can read of the hash it copies, each
        # side joined with `Dynamic[top]`. Ruby inserts every pair of that hash, so leaving the entry out typed
        # `o = { a: :z }; { **o, b: :y }` as `Hash[:b, :y]` and folded `h[:a] == :z` on correct code.
        #
        # The `Dynamic[top]` arm is there even when the copy is read exactly. The literal builds a new hash that no
        # declaration describes, while `MutationRejoin` regrows a `Hash[K, V]` after `[]=` / `merge!` only when it
        # already carries a gradual arm, because it reads a precise one as a declared claim. Without the arm
        # `h = { **o }; h[:b] = 2; h[:b] == 2` would fold always-falsey and `h[:e] = "s"; h[:e].upcase` would fire
        # `call.undefined-method`, where the `Hash` a splat-only literal used to type as had stayed quiet. The same
        # arm stands in for what the analysis cannot read: an anonymous `**`, an untyped value, a nominal other than
        # `Hash`, an open shape's unlisted entries, and a hash filled through an alias the engine does not track,
        # which still reads `{}`.
        def hash_splat_pair(entry, typer)
          untyped = Type::Combinator.untyped
          copied = entry.value && splatted_hash_pair(typer.type_of(entry.value))
          return [untyped, untyped] if copied.nil?

          copied.map { |side| Type::Combinator.union(side, untyped) }
        end

        # The `[K, V]` the analysis can read of a splatted value, or nil when it reads nothing: a shape's keys and
        # values, a `Hash[K, V]`'s type arguments (through a difference over one, `non-empty-hash[K, V]`), and the
        # join over a union's members. `nil` reads as nothing because `**nil` splats nothing (Ruby 3.4+; earlier
        # Rubies raise). A `Hash` subclass is not read: its own type arguments, if any, are not `Hash`'s `K` and `V`.
        def splatted_hash_pair(type)
          case type
          when Type::HashShape then splatted_shape_pair(type)
          when Type::Nominal then type.class_name == "Hash" && type.type_args.size == 2 ? type.type_args : nil
          when Type::Difference then splatted_hash_pair(type.base)
          when Type::Union then joined_hash_pair(type.members.filter_map { |member| splatted_hash_pair(member) })
          end
        end

        def splatted_shape_pair(shape)
          return nil if shape.pairs.empty?

          [Type::Combinator.union(*shape.pairs.keys.map { |k| Type::Combinator.constant_of(k) }),
           Type::Combinator.union(*shape.pairs.values)]
        end

        def joined_hash_pair(pairs)
          return nil if pairs.empty?

          [Type::Combinator.union(*pairs.map(&:first)), Type::Combinator.union(*pairs.map(&:last))]
        end

        # An interpolated string `"#{a}b#{c}"` is `literal-string` when every part contributes literal-bearing
        # material: plain text segments are literal by construction, embedded expressions count when their type
        # is itself literal-string-compatible (a `Constant<String>`, the `literal-string` carrier, an
        # `Intersection` containing it, or a `Union` whose members all qualify). Otherwise the result widens to
        # plain `Nominal[String]` as before.
        def type_of_interpolated_string(node, typer)
          return Type::Combinator.literal_string if interpolation_parts_literal?(node.parts, typer)

          Type::Combinator.nominal_of(String)
        end

        def interpolation_parts_literal?(parts, typer)
          parts.all? { |part| interpolation_part_literal?(part, typer) }
        end

        def interpolation_part_literal?(part, typer)
          case part
          when Prism::StringNode
            true
          when Prism::EmbeddedStatementsNode, Prism::EmbeddedVariableNode
            Type::Combinator.literal_string_compatible?(typer.type_of(part))
          else
            false
          end
        end

        def type_of_embedded_statements(node, typer)
          statements_type_for(node.statements, typer)
        end

        # `class Foo; body; end`, `module Foo; body; end`, and `class << x; body; end` evaluate to the value of
        # the body's last expression, or `nil` when the body is empty. We do not track class/module scope yet,
        # so the body is typed in the surrounding scope and that result is returned.
        def type_of_class_or_module(node, typer)
          body = node.body
          return Type::Combinator.constant_of(nil) if body.nil?

          typer.type_of(body)
        end

        def type_of_else(node, typer)
          statements_or_nil(node.statements, typer)
        end

        # `when` clauses for `case` and `in` clauses for `case ... in` have the same body shape; we reuse one
        # handler for both Prism node classes.
        def type_of_when_or_in(node, typer)
          statements_or_nil(node.statements, typer)
        end

        def type_of_ensure(node, typer)
          statements_or_nil(node.statements, typer)
        end

        def type_of_range(node, typer)
          left_static, left = static_range_endpoint(node.left, typer)
          right_static, right = static_range_endpoint(node.right, typer)
          if left_static && right_static
            range = static_range_value(left, right, node.exclude_end?)
            return Type::Combinator.constant_of(range) if range
          end

          nominal_range_for_endpoints(node.left, node.right, typer)
        end

        # The `Range` the static endpoints denote, or nil when Ruby would refuse to build it (`1.."a"`,
        # `"a"..1` raise `ArgumentError: bad value for range`). The literal is a runtime error,
        # not a constant, so the fold declines and the caller types it as a plain Range.
        def static_range_value(left, right, exclude_end)
          Range.new(left, right, exclude_end)
        rescue ArgumentError
          nil
        end

        # Derives `Nominal[Range, [T]]` from the endpoint expression types when at least one endpoint is
        # statically typeable. The element parameter is the union of the endpoint types (lifted from
        # `Constant<v>` to `Nominal<v.class>` so the carrier matches what `Range#each` would yield). Falls back
        # to bare `Nominal[Range]` when no endpoint contributes a typable shape.
        def nominal_range_for_endpoints(left_node, right_node, typer)
          endpoints = [left_node, right_node].compact.map { |n| range_endpoint_element_type(n, typer) }
          endpoints.reject! { |t| Type::Combinator.untyped?(t) }
          return Type::Combinator.nominal_of("Range") if endpoints.empty?

          Type::Combinator.nominal_of("Range", type_args: [Type::Combinator.union(*endpoints)])
        end

        def range_endpoint_element_type(node, typer)
          type = typer.type_of(node)
          case type
          when Type::Constant
            value = type.value
            return Type::Combinator.untyped if value.nil?

            Type::Combinator.nominal_of(value.class.name)
          when Type::IntegerRange
            Type::Combinator.nominal_of("Integer")
          when Type::FloatRange
            Type::Combinator.nominal_of("Float")
          else
            type
          end
        end

        # A range endpoint folds to a static value when it is a literal (`IntegerNode` / `StringNode`) or when
        # its *evaluated* type is a `Constant<v>` carrying a range-able value (Integer / Float / String —
        # matching the literal-path value kinds). The evaluated arm lets `(1..n)` fold to `Constant<Range>`
        # when per-call body inference has pinned `n` to a constant (fact2 chain). A `nil` node is a
        # beginless/endless boundary: keep today's static-nil behaviour (which yields `Constant<Range>` only
        # when the *other* end is also static, preserving today's beginless/endless path).
        def static_range_endpoint(node, typer)
          return [true, nil] if node.nil?
          return [true, node.value] if node.is_a?(Prism::IntegerNode)
          return [true, node.unescaped] if node.is_a?(Prism::StringNode) && node.respond_to?(:unescaped)

          type = typer.type_of(node)
          if type.is_a?(Type::Constant)
            value = type.value
            return [true, value] if value.is_a?(Integer) || value.is_a?(Float) || value.is_a?(String)
          end

          [false, nil]
        end

        # Helper for the many control-flow handlers that read a body `Prism::StatementsNode` or treat its
        # absence as nil. Note that Prism uses nil (rather than an empty `StatementsNode`) for missing bodies
        # in many node kinds.
        def statements_or_nil(statements_node, typer)
          return Type::Combinator.constant_of(nil) if statements_node.nil?

          statements_type_for(statements_node, typer)
        end

        # `# shareable_constant_value:` magic comment wraps the next constant write. Type is the wrapped
        # write's value.
        def type_of_shareable_constant(node, typer)
          typer.type_of(node.write)
        end

        # `{ x: }` shorthand hash. The implicit value is the call to `x` (or a local read of `x`). Delegate.
        def type_of_implicit(node, typer)
          typer.type_of(node.value)
        end

        # Slice 5 phase 1 upgrades array literals to `Tuple[T1..Tn]` when every element is a non-splat value.
        # Splatted entries (`[*xs, 1]`) preserve the Slice 4 phase 2d behavior: we union the contributed
        # element types and emit `Nominal[Array, [union]]`.
        #
        # v0.0.6 — the empty literal `[]` resolves to the empty `Tuple[]` carrier rather than the raw
        # `Nominal[Array]`. Both carriers erase to RBS `Array`, but `Tuple[]` pins the literal's known arity
        # (zero), which lets the per-element block fold concatenate across all-empty positions like `[1,
        # 2].flat_map { |_| [] }`.
        def array_type_for(node, typer)
          elements = node.elements
          return Type::Combinator.tuple_of if elements.empty?

          if elements.any?(Prism::SplatNode)
            element_types = elements.map { |e| typer.type_of(e) }
            element_union = Type::Combinator.union(*element_types)
            return Type::Combinator.nominal_of(Array, type_args: [element_union])
          end

          Type::Combinator.tuple_of(*elements.map { |e| typer.type_of(e) })
        end

        def parentheses_type_for(node, typer)
          body = node.body
          return Type::Combinator.constant_of(nil) if body.nil?

          typer.type_of(body)
        end

        def statements_type_for(statements_node, typer)
          return Type::Combinator.constant_of(nil) if statements_node.nil?

          body = statements_node.body
          return Type::Combinator.constant_of(nil) if body.empty?

          typer.type_of(body.last)
        end

        private_class_method :static_hash_shape_for, :static_hash_key, :generic_hash_pairs_for, :hash_splat_pair,
                             :splatted_hash_pair, :splatted_shape_pair, :joined_hash_pair,
                             :interpolation_parts_literal?, :interpolation_part_literal?, :static_range_value,
                             :nominal_range_for_endpoints, :range_endpoint_element_type, :static_range_endpoint,
                             :statements_type_for
      end
    end
  end
end
