# frozen_string_literal: true

require_relative "../../type"

module Rigor
  module Inference
    module MethodDispatcher
      # The member-shape projections shared by {DataFolding} and {StructFolding}. A `DataInstance` and a
      # `StructInstance` expose the same surface — an ordered `members` map, `member_names`, and a
      # `class_name` — so the value projections off that surface (`[]` / `to_h` / `deconstruct` /
      # `deconstruct_keys` / `members` / `with`) and the reader-redefinition guard are identical between the
      # two folders. Only `#with`'s carrier constructor differs (`data_instance_of` vs
      # `struct_instance_of`), so it takes a block that builds the new instance from the merged member map.
      #
      # Both folders `extend` this module so the projections resolve as their own module functions
      # (matching their `module_function` style).
      module MemberShapeProjection
        # A Data/Struct subclass body can redefine a member's synthesised reader (`def x`); when it does,
        # `inst.x` runs that `def`, not the member, so folding the read would be unsound. A real `def` node
        # under the class name is the discriminator (the synthesised reader has none), so an entry in the
        # project def-node table gates the bare member read off.
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

        # `deconstruct_keys(nil)` / `deconstruct_keys([:x])` both yield a subset of the member map; the
        # conservative, always-correct answer is the full closed member shape.
        def instance_deconstruct_keys(instance, args)
          return nil unless args.size <= 1

          Type::Combinator.hash_shape_of(instance.members.dup)
        end

        def instance_members(instance)
          Type::Combinator.tuple_of(*instance.member_names.map { |name| Type::Combinator.constant_of(name) })
        end

        # `#with(x: 9)` returns a new copy with the named members overridden. Only a closed keyword
        # `HashShape` whose keys are a subset of the members folds; anything else defers (RBS resolves
        # `with` to `self`, returning the unchanged instance type). The carrier constructor differs per
        # folder, so the caller supplies it as a block taking the merged member map and the class name.
        def instance_with(instance, args)
          return instance if args.empty?
          return nil unless args.size == 1

          shape = args.first
          return nil unless shape.is_a?(Type::HashShape) && shape.closed?
          return nil unless shape.optional_keys.empty?
          return nil unless shape.pairs.keys.all? { |key| instance.members.key?(key) }

          merged = instance.members.merge(shape.pairs)
          yield(merged, instance.class_name)
        end
      end
    end
  end
end
