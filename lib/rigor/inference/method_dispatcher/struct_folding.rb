# frozen_string_literal: true

require_relative "../../type"
require_relative "singleton_folding"

module Rigor
  module Inference
    module MethodDispatcher
      # ADR-48 Struct follow-up — `Struct.new` value folding, the mutable
      # sibling of {DataFolding}. Same fully-decidable-shape, degrade-on-any-
      # uncertainty discipline, with one extra premise the immutable `Data`
      # path does not need: **mutation soundness.**
      #
      # A `Struct` instance is mutable (`s.x = v`, `s[:x] = v`, escape), so a
      # member map bound to a variable can be invalidated by a later write.
      # This slice (ADR-48 slices 1+2 in the sound *transient* form) folds a
      # member read ONLY off a **fresh** instance — the transient receiver of
      # a `.new(...).x` / `.with(...).x` chain, which provably cannot have
      # been mutated between materialisation and the read. A member read off
      # a *stored* binding degrades to `Dynamic[top]` rather than fold a
      # possibly-stale value. Promoting the fold to mutation-free bound
      # locals is the deferred slice 3 (relax the fresh-receiver gate to a
      # fold-safe-local scan); precise mutated-member re-typing is slice 4.
      #
      # Responsibilities:
      #
      # 1. `Struct.new(:x, :y [, keyword_init: <bool>])` on a
      #    `Singleton[Struct]` receiver, literal-Symbol members, NO block ->
      #    `StructClass{members:, keyword_init:}`. A block / non-literal
      #    members defer.
      # 2. `.new` / `.[]` on a `StructClass` (or a `Singleton[Point]` with a
      #    recorded struct layout) -> a `StructInstance`, the member map built
      #    from the call's arguments (positional or keyword per the class's
      #    `keyword_init`). A form / arity mismatch degrades to `Dynamic[top]`
      #    rather than a wrong member map. `.members` on the class folds.
      # 3. member reads + `[]` / `to_h` / `deconstruct` / `deconstruct_keys`
      #    / `members` / `with` on a *fresh* `StructInstance` -> the precise
      #    projected type; member *setters* (`s.x = v`) return the assigned
      #    value type. Unhandled / stored-receiver calls return nil so the
      #    pipeline projects the instance to its nominal through RbsDispatch.
      #
      # See docs/adr/48-data-struct-value-folding.md § "Struct follow-up".
      module StructFolding
        module_function

        # @return [Rigor::Type, nil] the folded result, or nil to defer.
        def try_dispatch(context)
          receiver = context.receiver

          return fold_struct_new(context) if SingletonFolding.receiver?(receiver, "Struct")

          case receiver
          when Type::StructClass
            dispatch_struct_class(receiver, context)
          when Type::StructInstance
            fold_instance(receiver, context)
          when Type::Singleton
            fold_named_new(receiver, context)
          end
        end

        # A `Struct.new`-defined class assigned to a constant (or a
        # `class Point < Struct.new(...)` subclass) is canonicalised by the
        # engine to `Singleton[Point]`, not a `StructClass` — so its member
        # layout is read from the project side-table the scope indexer built
        # (`Scope#struct_member_layout`) rather than from the receiver
        # carrier.
        def fold_named_new(singleton, context)
          scope = context.scope
          return nil if scope.nil?

          layout = scope.struct_member_layout(singleton.class_name)
          return nil if layout.nil?

          materialize_instance(layout[:members], layout[:keyword_init], singleton.class_name, context)
        end

        # --- 1. Struct.new(:x, :y) --------------------------------------

        def fold_struct_new(context)
          return nil unless context.method_name == :new
          # Block-form (`Struct.new(:x) do ... end`) defers — the named
          # constant/subclass forms still fold via the layout side-table.
          return nil unless context.block_type.nil?

          parsed = parse_struct_new_args(context.args)
          return nil if parsed.nil?

          Type::Combinator.struct_class_of(members: parsed[:members], keyword_init: parsed[:keyword_init])
        end

        # Parses `Struct.new`'s arguments into `{ members:, keyword_init: }`,
        # or nil when any argument is non-conforming (a dynamic member name,
        # an unexpected trailing keyword). Handles the optional leading String
        # class name and the trailing `keyword_init:` option hash.
        def parse_struct_new_args(args)
          rest = args.dup
          keyword_init = false

          if rest.last.is_a?(Type::HashShape)
            options = rest.pop
            return nil unless struct_options_hash?(options)

            value = options.pairs[:keyword_init]
            keyword_init = value.is_a?(Type::Constant) && value.value == true
          end

          # Optional leading String name: `Struct.new("Point", :x, :y)`.
          rest = rest[1..] if rest.first.is_a?(Type::Constant) && rest.first.value.is_a?(String)

          members = []
          rest.each do |arg|
            return nil unless arg.is_a?(Type::Constant) && arg.value.is_a?(Symbol)

            members << arg.value
          end
          return nil if members.empty?
          return nil unless members.uniq.size == members.size

          { members: members, keyword_init: keyword_init }
        end

        # A trailing hash is the `Struct.new` options hash only when it is a
        # closed shape whose sole key is `:keyword_init`. Any other key means
        # the call is not a recognisable member-list definition -> defer.
        def struct_options_hash?(shape)
          shape.closed? && shape.optional_keys.empty? &&
            shape.pairs.keys.all? { |key| key == :keyword_init }
        end

        # --- 2. Point.new(...) / Point[...] / Point.members -------------

        def dispatch_struct_class(struct_class, context)
          case context.method_name
          when :new, :[]
            materialize_instance(struct_class.members, struct_class.keyword_init,
                                 struct_class.class_name, context)
          when :members
            Type::Combinator.tuple_of(*struct_class.members.map { |name| Type::Combinator.constant_of(name) })
          end
        end

        def materialize_instance(members, keyword_init, class_name, context)
          return nil unless %i[new []].include?(context.method_name)

          map = member_map_for_new(members, keyword_init, context)
          return degraded_instance if map.nil?

          Type::Combinator.struct_instance_of(members: map, class_name: class_name)
        end

        # Builds the member -> type map honouring the class's `keyword_init`
        # flag: a `keyword_init: true` struct accepts only the keyword form,
        # a positional struct only the positional form. The mismatched form
        # is a different runtime shape, so it degrades rather than fold.
        def member_map_for_new(members, keyword_init, context)
          if keyword_new?(context)
            keyword_init ? keyword_member_map(members, context.args) : nil
          else
            keyword_init ? nil : positional_member_map(members, context.args)
          end
        end

        # `Point.new(x: 1)` arrives as a single trailing `HashShape` whose
        # call node is a `KeywordHashNode`; distinguishing it from a
        # positional hash needs the call node (both type to a `HashShape`).
        def keyword_new?(context)
          node = context.call_node
          return false if node.nil?

          arguments = node.arguments&.arguments
          return false if arguments.nil? || arguments.empty?

          arguments.last.is_a?(Prism::KeywordHashNode)
        end

        # `Struct.new(:a, :b).new(v)` is legal — trailing members default to
        # `nil` — so fewer positionals than members pad with `Constant[nil]`;
        # more positionals than members is an ArgumentError -> degrade.
        def positional_member_map(members, args)
          return nil if args.size > members.size

          members.each_with_index.to_h do |name, index|
            [name, index < args.size ? args[index] : Type::Combinator.constant_of(nil)]
          end
        end

        # `Struct.new(:a, :b).new(a: 1)` is legal — omitted members default
        # to `nil` — so a keyword subset pads the rest; an unknown key is an
        # ArgumentError -> degrade.
        def keyword_member_map(members, args)
          return nil unless args.size == 1

          shape = args.first
          return nil unless shape.is_a?(Type::HashShape) && shape.closed?
          return nil unless shape.optional_keys.empty?
          return nil unless shape.pairs.keys.all? { |key| members.include?(key) }

          members.to_h { |name| [name, shape.pairs[name] || Type::Combinator.constant_of(nil)] }
        end

        # A `.new` whose arguments cannot soundly populate the member map
        # degrades to `Dynamic[top]` (today's behaviour for `Struct.new(...)`
        # instances), never a wrong map.
        def degraded_instance
          Type::Combinator.untyped
        end

        # --- 3. inst.x / inst.x = v / inst[...] / inst.to_h / ... -------

        def fold_instance(instance, context)
          method_name = context.method_name
          args = context.args
          members = instance.members

          # Member setter `s.x = v`: returns the assigned value type. Sound
          # regardless of mutation state (it models the setter's own return),
          # and avoids a fall-through undefined-method on a writer the
          # existence table does not register.
          setter = member_setter_target(method_name, members)
          return args.first if setter && args.size == 1

          foldable = foldable_receiver?(context)

          if members.key?(method_name) && args.empty? && !reader_overridden?(instance, method_name, context.scope)
            # A stored receiver folds only when the bound local is proven
            # fold-safe (ADR-48 slice 3 — never mutated / aliased / escaped);
            # otherwise the member value may be stale, so it degrades to
            # `Dynamic[top]` (not nil -> no undefined-method fall-through).
            return foldable ? members.fetch(method_name) : Type::Combinator.untyped
          end

          # Projections fold only off a foldable (fresh, or proven fold-safe)
          # instance; off any other stored binding they defer to Struct's RBS
          # (`to_h` / `[]` / `members` / `deconstruct*` all exist on `Struct`),
          # which is sound and non-regressive.
          return nil unless foldable

          fold_fresh_projection(instance, method_name, args)
        end

        def fold_fresh_projection(instance, method_name, args)
          case method_name
          when :[] then instance_index(instance, args)
          when :to_h, :to_hash then instance_to_h(instance)
          when :deconstruct then instance_deconstruct(instance)
          when :deconstruct_keys then instance_deconstruct_keys(instance, args)
          when :members then instance_members(instance)
          when :with then instance_with(instance, args)
          end
        end

        # The member name a `:<member>=` setter targets, or nil. Comparison
        # operators (`==`, `>=`, ...) end with `=` too but never strip to a
        # member symbol, so they fall through to the normal dispatch path.
        def member_setter_target(method_name, members)
          name = method_name.to_s
          return nil unless name.end_with?("=")

          base = name[0..-2].to_sym
          members.key?(base) ? base : nil
        end

        # A member read is foldable when the receiver is either FRESH (the
        # transient result of a `.new(...)`/`.with(...)` chain, which cannot
        # have been mutated between materialisation and this read) or a
        # FOLD-SAFE stored local (ADR-48 slice 3 — `StructFoldSafety` proved
        # the binding is never mutated / aliased / escaped in its scope).
        def foldable_receiver?(context)
          fresh_receiver?(context) || fold_safe_local_receiver?(context)
        end

        # A fresh receiver is the transient result of a chained call
        # (`Point.new(1, 2).x`, `inst.with(x: 9).y`).
        def fresh_receiver?(context)
          node = context.call_node
          return false if node.nil?

          node.receiver.is_a?(Prism::CallNode)
        end

        # A fold-safe stored receiver is a local-variable read whose name the
        # body's fold-safe set (on the scope) marks as never mutated.
        def fold_safe_local_receiver?(context)
          node = context.call_node
          receiver = node&.receiver
          scope = context.scope
          return false unless receiver.is_a?(Prism::LocalVariableReadNode) && scope

          scope.struct_fold_safe?(receiver.name)
        end

        # A `Struct` subclass body can redefine a member's synthesised
        # reader (`def x`); when it does, `inst.x` runs that `def`, not the
        # member, so folding the read would be unsound. Mirrors
        # {DataFolding#reader_overridden?}: a real `def` node under the class
        # name is the discriminator (the synthesised reader has none).
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

        def instance_deconstruct_keys(instance, args)
          return nil unless args.size <= 1

          Type::Combinator.hash_shape_of(instance.members.dup)
        end

        def instance_members(instance)
          Type::Combinator.tuple_of(*instance.member_names.map { |name| Type::Combinator.constant_of(name) })
        end

        # `Struct#with(x: 9)` (Ruby 3.2+) returns a new copy with the named
        # members overridden. Only a closed keyword `HashShape` whose keys
        # are a subset of the members folds; anything else defers.
        def instance_with(instance, args)
          return instance if args.empty?
          return nil unless args.size == 1

          shape = args.first
          return nil unless shape.is_a?(Type::HashShape) && shape.closed?
          return nil unless shape.optional_keys.empty?
          return nil unless shape.pairs.keys.all? { |key| instance.members.key?(key) }

          merged = instance.members.merge(shape.pairs)
          Type::Combinator.struct_instance_of(members: merged, class_name: instance.class_name)
        end
      end
    end
  end
end
