# frozen_string_literal: true

require_relative "../../type"
require_relative "singleton_folding"
require_relative "member_shape_projection"

module Rigor
  module Inference
    module MethodDispatcher
      # ADR-48 — `Data.define` value folding. Three responsibilities, all gated on a fully-decidable shape
      # and degrading to today's behaviour (no carrier / the `Data` nominal) the moment a premise is
      # uncertain, so the tier is precision-additive and adds no false-positive surface:
      #
      # 1. `Data.define(:x, :y)` on a `Singleton[Data]` receiver with literal-Symbol args ->
      #    `DataClass{members: [...]}`. A `do ... end` block folds too when its body redefines no member
      #    reader (bare-local block-form parity — the block AST stands in for the class name the read-time
      #    guard would otherwise need); a `&proc` block, a reader-redefining block, or non-literal members
      #    (`Data.define(*names)`) defer.
      # 2. `.new` / `.[]` on a `DataClass` receiver -> a `DataInstance` whose member map is built from the
      #    call's positional or keyword arguments. An arity / key mismatch degrades to the `Data` (or the
      #    tagged class) nominal rather than a wrong member map.
      # 3. member reads + `[]` / `to_h` / `deconstruct` / `deconstruct_keys` / `members` / `with` on a
      #    `DataInstance` receiver -> the precise projected type. Unhandled methods return nil so the
      #    pipeline projects the instance to its nominal through RbsDispatch.
      #
      # See docs/adr/48-data-struct-value-folding.md.
      module DataFolding
        module_function

        # The `[]` / `to_h` / `deconstruct` / `members` / `with` projections
        # and the reader-redefinition guard are shared with {StructFolding}.
        extend MemberShapeProjection

        # @return [Rigor::Type, nil] the folded result, or nil to defer.
        def try_dispatch(context)
          receiver = context.receiver

          return fold_define(context) if SingletonFolding.receiver?(receiver, "Data")

          case receiver
          when Type::DataClass
            materialize_instance(receiver.members, receiver.class_name, context)
          when Type::DataInstance
            fold_instance(receiver, context)
          when Type::Singleton
            fold_named_new(receiver, context)
          end
        end

        # A `Data.define` value object assigned to a constant (or a `class Point < Data.define(...)`
        # subclass) is canonicalised by the engine to `Singleton[Point]`, not a `DataClass` — so its member
        # layout is read from the project side-table the scope indexer built (`Scope#data_member_layout`)
        # rather than from the receiver carrier.
        def fold_named_new(singleton, context)
          scope = context.scope
          return nil if scope.nil?

          members = scope.data_member_layout(singleton.class_name)
          return nil if members.nil?

          materialize_instance(members, singleton.class_name, context)
        end

        # --- 1. Data.define(:x, :y) -------------------------------------

        def fold_define(context)
          return nil unless context.method_name == :define

          members = member_names_from_args(context.args)
          return nil if members.nil? || members.empty?

          # Block-form (`Data.define(:x) do ... end`) bare-local parity (ADR-48 "Remaining"): the assigned
          # constant / subclass forms already fold via the layout side-table, with the reader-redefinition
          # guard consulting `Scope#user_def_for`; the bare-local form has no resolvable class name for it
          # to key on. But the block AST is in hand, so the guard is applied directly against it: fold when
          # the block redefines no member's synthesised reader (folding `inst.x` would otherwise run the
          # redefined `def x`), and bail conservatively — the prior behaviour — the moment the block cannot
          # be soundly cleared (a `&proc` argument, or any `def <member>` in the body).
          return fold_define_block(context, members) unless context.block_type.nil?

          Type::Combinator.data_class_of(members: members)
        end

        # The block-form fold decision. Only a literal `do ... end` block whose body redefines no member
        # reader folds; a `&proc` block argument (no scannable body) or a body with a member-reader `def`
        # stays unfolded. The resulting `DataClass` carries no `class_name` — folding is already proven
        # reader-safe here, so the read-time `reader_overridden?` guard (which keys on the class name) has
        # nothing left to catch.
        def fold_define_block(context, members)
          block = context.call_node&.block
          return nil unless block.is_a?(Prism::BlockNode)
          return nil if block_redefines_member_reader?(block, members)

          Type::Combinator.data_class_of(members: members)
        end

        # The ordered Symbol member names, or nil when any argument is not a literal `Constant[Symbol]` (a
        # splat or dynamic name).
        def member_names_from_args(args)
          names = args.map do |arg|
            return nil unless arg.is_a?(Type::Constant) && arg.value.is_a?(Symbol)

            arg.value
          end
          return nil unless names.uniq.size == names.size

          names
        end

        # --- 2. Point.new(...) / Point[...] -----------------------------

        def materialize_instance(members, class_name, context)
          method_name = context.method_name
          return nil unless %i[new []].include?(method_name)

          map = member_map_for_new(members, context)
          return degraded_instance(class_name) if map.nil?

          Type::Combinator.data_instance_of(members: widen_unowned_emptiness(map), class_name: class_name)
        end

        # Builds the member -> type map from the call's arguments, honouring the keyword vs positional
        # distinction read off the call node. nil when the arguments cannot soundly populate every member.
        def member_map_for_new(members, context)
          if keyword_new?(context)
            keyword_member_map(members, context.args)
          else
            positional_member_map(members, context.args)
          end
        end

        # `Point.new(x: 1, y: 2)` arrives as a single trailing `HashShape` arg whose call node is a
        # `KeywordHashNode`. Distinguishing it from a positional hash (`Point.new({x: 1})`, a `HashNode`)
        # needs the call node, since both type to a `HashShape`.
        def keyword_new?(context)
          node = context.call_node
          return false if node.nil?

          arguments = node.arguments&.arguments
          return false if arguments.nil? || arguments.empty?

          arguments.last.is_a?(Prism::KeywordHashNode)
        end

        def keyword_member_map(members, args)
          return nil unless args.size == 1

          shape = args.first
          return nil unless shape.is_a?(Type::HashShape) && shape.closed?
          return nil unless shape.optional_keys.empty?
          # Non-Symbol keys (a HashShape may carry String / numeric / bool / nil scalar keys) can never
          # match the Symbol member list — and mixed-class keys would make the `.sort` below raise.
          return nil unless shape.pairs.keys.all?(Symbol)
          return nil unless shape.pairs.keys.sort == members.sort

          members.to_h { |name| [name, shape.pairs.fetch(name)] }
        end

        def positional_member_map(members, args)
          return nil unless args.size == members.size

          members.zip(args).to_h
        end

        # A `.new` whose arguments do not fold to a precise map still has a sound, more-precise-than-Dynamic
        # answer: an instance of the tagged class (or the `Data` supertype).
        def degraded_instance(class_name)
          Type::Combinator.nominal_of(class_name || "Data")
        end

        # --- 3. inst.x / inst[...] / inst.to_h / ... --------------------

        def fold_instance(instance, context)
          method_name = context.method_name
          args = context.args
          members = instance.members

          if members.key?(method_name) && args.empty? && !reader_overridden?(instance, method_name, context.scope)
            return members.fetch(method_name)
          end

          case method_name
          when :[] then instance_index(instance, args)
          when :to_h, :to_hash then instance_to_h(instance)
          when :deconstruct then instance_deconstruct(instance)
          when :deconstruct_keys then instance_deconstruct_keys(instance, args)
          when :members then instance_members(instance)
          when :with
            instance_with(instance, args) do |members, class_name|
              Type::Combinator.data_instance_of(members: members, class_name: class_name)
            end
          end
        end
      end
    end
  end
end
