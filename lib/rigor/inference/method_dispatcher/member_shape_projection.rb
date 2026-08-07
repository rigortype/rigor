# frozen_string_literal: true

require "prism"

require_relative "../../type"
require_relative "../../source/node_children"
require_relative "../mutation_widening"

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
        # A value object's member holds a **reference** to whatever the constructor was handed, and an
        # EMPTY container literal's emptiness is a fact about that argument at the instant of
        # construction — never a fact about the member. The caller keeps its own alias, and "construct
        # empty, then fill" (`r = R.new([], []); xs.each { |x| r.items << x }`) is the dominant Ruby
        # shape, so of every literal a member map can pin, emptiness is the one falsified most often.
        #
        # It is also the only one whose reads fold to `nil` — `.first` / `.last` / `[]` on an empty
        # container — and `nil` is the receiver type that fires `call.undefined-method` on correct code
        # (issue #293). A non-empty literal's element evidence, by contrast, survives an append and its
        # reads never fold to `nil`, so it is kept intact.
        #
        # So an empty `Tuple` / closed empty `HashShape` is recorded widened to its bare nominal —
        # the same carrier, through the same helpers, that {Inference::MutationWidening} installs when
        # it retracts a mutated local's literal shape.
        def widen_unowned_emptiness(member_map)
          return member_map if member_map.nil?

          member_map.transform_values { |type| widened_empty_container(type) }
        end

        def widened_empty_container(type)
          case type
          when Type::Tuple
            type.elements.empty? ? MutationWidening.widen_tuple(type) : type
          when Type::HashShape
            # An OPEN shape claims nothing about the keys it does not list — a read of an unlisted key
            # is already `untyped`, not `nil` — so only the closed literal `{}` carries the emptiness.
            type.closed? && type.pairs.empty? ? MutationWidening.widen_hash_shape(type) : type
          else
            type
          end
        end

        # A Data/Struct subclass body can redefine a member's synthesised reader (`def x`); when it does,
        # `inst.x` runs that `def`, not the member, so folding the read would be unsound. A real `def` node
        # under the class name is the discriminator (the synthesised reader has none), so an entry in the
        # project def-node table gates the bare member read off.
        def reader_overridden?(instance, method_name, scope)
          class_name = instance.class_name
          return false if class_name.nil? || scope.nil?

          !scope.user_def_for(class_name, method_name).nil?
        end

        # The bare-local block-form counterpart of {#reader_overridden?}: when a `Data.define`/`Struct.new`
        # block has no resolvable class name to look up in the project def-node table, its member-reader
        # redefinitions are read straight off the block AST instead. True when the block body defines a
        # `def <member>` (a plain instance method, receiver-less) for any member — folding that member's
        # read would run the redefined reader, not return the member. Nested `class`/`module`/`sclass`
        # bodies open a different namespace and are skipped; a `def` anywhere else in the body counts.
        def block_redefines_member_reader?(block, members)
          body = block.body
          return false if body.nil?

          member_set = members.is_a?(Set) ? members : members.to_set
          reader_def?(body, member_set)
        end

        def reader_def?(node, member_set)
          return false unless node.is_a?(Prism::Node)
          return true if node.is_a?(Prism::DefNode) && node.receiver.nil? && member_set.include?(node.name)
          # A nested class / module / singleton-class body opens a different namespace — its `def`s do not
          # redefine the value object's reader, so the walk does not descend into it.
          return false if reader_scope_boundary?(node)

          node.rigor_each_child { |child| return true if reader_def?(child, member_set) }
          false
        end

        def reader_scope_boundary?(node)
          node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode) ||
            node.is_a?(Prism::SingletonClassNode)
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

          merged = widen_unowned_emptiness(instance.members.merge(shape.pairs))
          yield(merged, instance.class_name)
        end
      end
    end
  end
end
