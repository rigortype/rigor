# frozen_string_literal: true

require_relative "../../type"
require_relative "singleton_folding"

module Rigor
  module Inference
    module MethodDispatcher
      # ADR-48 — `Data.define` value folding. Three responsibilities, all
      # gated on a fully-decidable shape and degrading to today's behaviour
      # (no carrier / the `Data` nominal) the moment a premise is uncertain,
      # so the tier is precision-additive and adds no false-positive
      # surface:
      #
      # 1. `Data.define(:x, :y)` on a `Singleton[Data]` receiver with
      #    literal-Symbol args and NO block -> `DataClass{members: [...]}`.
      #    A block (`Data.define(:x) do ... end`) defers (slice 4 hardens
      #    the block-body case); non-literal members (`Data.define(*names)`)
      #    defer.
      # 2. `.new` / `.[]` on a `DataClass` receiver -> a `DataInstance`
      #    whose member map is built from the call's positional or keyword
      #    arguments. An arity / key mismatch degrades to the `Data` (or the
      #    tagged class) nominal rather than a wrong member map.
      # 3. member reads + `[]` / `to_h` / `deconstruct` / `deconstruct_keys`
      #    / `members` / `with` on a `DataInstance` receiver -> the precise
      #    projected type. Unhandled methods return nil so the pipeline
      #    projects the instance to its nominal through RbsDispatch.
      #
      # See docs/adr/48-data-struct-value-folding.md.
      module DataFolding
        module_function

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

        # A `Data.define` value object assigned to a constant (or a
        # `class Point < Data.define(...)` subclass) is canonicalised by the
        # engine to `Singleton[Point]`, not a `DataClass` — so its member
        # layout is read from the project side-table the scope indexer built
        # (`Scope#data_member_layout`) rather than from the receiver carrier.
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
          # Block-form (`Data.define(:x) do ... end`) defers — slice 4.
          return nil unless context.block_type.nil?

          members = member_names_from_args(context.args)
          return nil if members.nil? || members.empty?

          Type::Combinator.data_class_of(members: members)
        end

        # The ordered Symbol member names, or nil when any argument is not
        # a literal `Constant[Symbol]` (a splat or dynamic name).
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

          Type::Combinator.data_instance_of(members: map, class_name: class_name)
        end

        # Builds the member -> type map from the call's arguments, honouring
        # the keyword vs positional distinction read off the call node. nil
        # when the arguments cannot soundly populate every member.
        def member_map_for_new(members, context)
          if keyword_new?(context)
            keyword_member_map(members, context.args)
          else
            positional_member_map(members, context.args)
          end
        end

        # `Point.new(x: 1, y: 2)` arrives as a single trailing `HashShape`
        # arg whose call node is a `KeywordHashNode`. Distinguishing it from
        # a positional hash (`Point.new({x: 1})`, a `HashNode`) needs the
        # call node, since both type to a `HashShape`.
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
          return nil unless shape.pairs.keys.sort == members.sort

          members.to_h { |name| [name, shape.pairs.fetch(name)] }
        end

        def positional_member_map(members, args)
          return nil unless args.size == members.size

          members.zip(args).to_h
        end

        # A `.new` whose arguments do not fold to a precise map still has a
        # sound, more-precise-than-Dynamic answer: an instance of the
        # tagged class (or the `Data` supertype).
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
          when :with then instance_with(instance, args)
          end
        end

        # A `Data.define` class body (the `class Point < Data.define(:x);
        # def x; …; end; end` subclass body, or a `Const = Data.define(:x) do
        # def x; …; end; end` block) can redefine a member's synthesised
        # reader. When it does, `inst.x` runs that `def`, NOT the member, so
        # folding the read to the member type would be unsound (a downstream
        # FP). Both named forms register the override as a real `def` node
        # under the class name, so an entry in the project def-node table is
        # the discriminator (the synthesised reader has no def node). The
        # value accessors `[]` / `to_h` / `deconstruct` bypass the reader and
        # stay foldable, so this gate is on the bare member read only.
        def reader_overridden?(instance, method_name, scope)
          class_name = instance.class_name
          return false if class_name.nil? || scope.nil?

          !scope.user_def_for(class_name, method_name).nil?
        end

        def instance_index(instance, args)
          return nil unless args.size == 1

          arg = args.first
          return nil unless arg.is_a?(Type::Constant)

          key = arg.value
          case key
          when Symbol
            instance.members[key]
          when Integer
            values = instance.members.values
            idx = key.negative? ? key + values.size : key
            values[idx] if idx && idx >= 0 && idx < values.size
          end
        end

        def instance_to_h(instance)
          Type::Combinator.hash_shape_of(instance.members.dup)
        end

        def instance_deconstruct(instance)
          Type::Combinator.tuple_of(*instance.members.values)
        end

        # `deconstruct_keys(nil)` / `deconstruct_keys([:x])` both yield a
        # subset of the member map; the conservative, always-correct answer
        # is the full closed member shape.
        def instance_deconstruct_keys(instance, args)
          return nil unless args.size <= 1

          Type::Combinator.hash_shape_of(instance.members.dup)
        end

        def instance_members(instance)
          Type::Combinator.tuple_of(*instance.member_names.map { |name| Type::Combinator.constant_of(name) })
        end

        # `Data#with(x: 9)` returns a new frozen copy with the named members
        # overridden. Only a closed keyword `HashShape` whose keys are a
        # subset of the members folds; anything else defers (RBS resolves
        # `with` to `self`, returning the unchanged instance type).
        def instance_with(instance, args)
          return instance if args.empty?
          return nil unless args.size == 1

          shape = args.first
          return nil unless shape.is_a?(Type::HashShape) && shape.closed?
          return nil unless shape.optional_keys.empty?
          return nil unless shape.pairs.keys.all? { |key| instance.members.key?(key) }

          merged = instance.members.merge(shape.pairs)
          Type::Combinator.data_instance_of(members: merged, class_name: instance.class_name)
        end
      end
    end
  end
end
